"""
LambdaHub2 -- Lambda universal de teste do Struct8.

Recebe evento de qualquer origem suportada e reenvia a mensagem para TODOS os
recursos ligados a ela no diagrama. Quem configura o hub é o fio: o gerador
injeta uma variavel de ambiente por conexao, e o hub descobre os vizinhos lendo
o proprio ambiente. Nao existe lista de destinos no codigo.

FORMATO DA VARIAVEL (unico suportado):

    <TIPO_DO_ALVO>_<CHAVE>_<LABEL>        ex.: AWS_S3_BUCKET_NAME_0

- TIPO: o type do no alvo em maiuscula (aws_s3_bucket -> AWS_S3_BUCKET).
- CHAVE: vem do exportEnvVar da definition do alvo; quem nao declara cai no
  fallback NAME, cujo valor e o logicalName do no.
- LABEL: o texto do fio no diagrama, sanitizado. Fio sem texto vira "0".

O formato antigo, com o segmento TARGET_ no meio
(AWS_S3_BUCKET_TARGET_NAME_0), NAO e mais lido. Ele saiu do gerador e as
Lambdas que ainda o usam sao anteriores a essa mudanca.

O parse NAO e por regex: em AWS_LAMBDA_FUNCTION_URL_NAME_0 as particoes
AWS_LAMBDA_FUNCTION + URL_NAME e AWS_LAMBDA_FUNCTION_URL + NAME sao as duas
sintaticamente validas, e so a segunda esta certa. Por isso o casamento e por
vocabulario conhecido, do mais longo para o mais curto.
"""

import base64
import datetime
import http.client
import json
import os
import traceback
from urllib.parse import unquote

import boto3

# ----------------------------------------------------------------------------
# Dependencias opcionais
# ----------------------------------------------------------------------------

try:
    from aws_xray_sdk.core import patch_all, xray_recorder

    patch_all()
    XRAY_DISPONIVEL = True
except Exception:
    XRAY_DISPONIVEL = False
    print("XRay SDK nao encontrado.")

XRAY_LIGADO = XRAY_DISPONIVEL and os.getenv("XRAY_ENABLED", "False") != "False"

try:
    import pymysql

    MYSQL_DISPONIVEL = True
except Exception:
    MYSQL_DISPONIVEL = False
    print("pymysql nao encontrado -- destinos RDS serao ignorados.")


REGIAO = os.getenv("REGION") or os.getenv("AWS_REGION")
# ACCOUNT so e emitido pelo Struct8 quando o recurso esta em OUTRA conta, e a AWS
# nao publica o id da conta em variavel de ambiente nenhuma. No caso comum -- fila
# na mesma conta -- esta variavel fica vazia, a URL sai
# `https://sqs.{regiao}.amazonaws.com/None/{fila}` e todo send_message falha; o ARN
# do topico SNS quebra igual. Quem carrega o id e o ARN da propria invocacao, entao
# _registrar_conta o extrai de la na primeira chamada do handler.
CONTA = os.getenv("ACCOUNT")
# AWS_LAMBDA_FUNCTION_NAME e posto pela propria AWS. Sem ele o nome fica vazio e a
# guarda de laco (`NOME_DA_LAMBDA in mensagem`) para de valer -- e este hub tambem
# manda para Lambdas, entao uma cadeia que volta nele mesmo se realimentaria sem fim.
NOME_DA_LAMBDA = (
    os.getenv("LAMBDA_NAME") or os.getenv("NAME") or os.getenv("AWS_LAMBDA_FUNCTION_NAME") or ""
)

# PROXY: o API Gateway entrega o envelope HTTP inteiro e espera o envelope de
# volta. AWS: a integracao ja entrega o JSON limpo e espera so o dado.
MODO_API = os.getenv("API_INTEGRATION_TYPE", "PROXY").upper()

LIMITE_DA_MENSAGEM = 900


def com_xray(nome, funcao, *args, **kwargs):
    """Executa dentro de um subsegmento, quando o X-Ray esta ligado."""
    if not XRAY_LIGADO:
        return funcao(*args, **kwargs)
    with xray_recorder.in_subsegment(nome) as subsegmento:
        try:
            return funcao(*args, **kwargs)
        except Exception as erro:
            subsegmento.add_exception(erro, traceback.format_exc())
            raise


# ----------------------------------------------------------------------------
# Descoberta dos vizinhos pelo ambiente
# ----------------------------------------------------------------------------

# Tipos que este hub sabe acionar. Tipo novo aqui exige tambem um bloco de
# envio la embaixo -- sem ele a variavel e reconhecida e nada acontece.
TIPOS_CONHECIDOS = (
    "AWS_S3_BUCKET",
    "AWS_SQS_QUEUE",
    "AWS_SNS_TOPIC",
    "AWS_DYNAMODB_TABLE",
    "AWS_LAMBDA_FUNCTION_URL",
    "AWS_LAMBDA_FUNCTION",
    "AWS_KINESIS_STREAM",
    "AWS_KINESIS_FIREHOSE_DELIVERY_STREAM",
    "AWS_SSM_PARAMETER",
    "AWS_SECRETSMANAGER_SECRET",
    "AWS_DB_INSTANCE",
    "AWS_EFS_FILE_SYSTEM",
    "AWS_EFS_ACCESS_POINT",
    "AWS_INSTANCE",
    "AWS_CODEBUILD_PROJECT",
    "AWS_ELASTICACHE_REPLICATION_GROUP",
)

# Chaves que o gerador emite (exportEnvVar das definitions, mais o fallback
# NAME e os REGION/ACCOUNT de alvo em regiao ou conta diferente).
CHAVES_CONHECIDAS = (
    "SECRET_ARN",
    "QUEUE_URL",
    "USER_NAME",
    "DB_NAME",
    "ENDPOINT",
    "ACCOUNT",
    "REGION",
    "BUCKET",
    "PATH",
    "NAME",
    "ARN",
    "URL",
    "ID",
)

_TIPOS_ORDENADOS = tuple(sorted(TIPOS_CONHECIDOS, key=len, reverse=True))
_CHAVES_ORDENADAS = tuple(sorted(CHAVES_CONHECIDAS, key=len, reverse=True))


def descobrir_vizinhos(ambiente):
    """
    Varre o ambiente e agrupa as variaveis em vizinhos.

    Devolve {TIPO: [ {label, NAME, ARN, ...}, ... ]}, com a lista ordenada pelo
    label para o resultado nao depender da ordem do dicionario do ambiente.
    """
    agrupado = {}

    for variavel, valor in ambiente.items():
        tipo = next((t for t in _TIPOS_ORDENADOS if variavel.startswith(t + "_")), None)
        if tipo is None:
            continue

        resto = variavel[len(tipo) + 1 :]
        chave = next((c for c in _CHAVES_ORDENADAS if resto.startswith(c + "_")), None)
        if chave is None:
            continue

        label = resto[len(chave) + 1 :]
        if not label:
            # Sem label a variavel esta malformada: o gerador escreve "0"
            # quando o fio nao tem texto, nunca vazio.
            continue

        vizinho = agrupado.setdefault(tipo, {}).setdefault(label, {"label": label})
        vizinho[chave] = valor

    return {
        tipo: [porlabel[k] for k in sorted(porlabel)]
        for tipo, porlabel in agrupado.items()
    }


def _regiao_de(vizinho):
    return vizinho.get("REGION") or REGIAO


def _conta_de(vizinho):
    return vizinho.get("ACCOUNT") or CONTA


def _registrar_conta(contexto):
    """Preenche CONTA pelo ARN da invocacao quando a variavel nao veio."""
    global CONTA
    if CONTA:
        return
    arn = getattr(contexto, "invoked_function_arn", "") or ""
    partes = arn.split(":")
    if len(partes) > 4 and partes[4]:
        CONTA = partes[4]


def _url_da_fila(vizinho):
    """
    Monta a URL a partir do nome. A policy que o Struct8 gera para SQS concede
    SendMessage/ReceiveMessage/DeleteMessage/GetQueueAttributes -- nao concede
    GetQueueUrl, entao resolver o nome pela API falharia por permissao.
    """
    if vizinho.get("QUEUE_URL"):
        return vizinho["QUEUE_URL"]
    if vizinho.get("URL"):
        return vizinho["URL"]
    return f"https://sqs.{_regiao_de(vizinho)}.amazonaws.com/{_conta_de(vizinho)}/{vizinho['NAME']}"


def _arn_do_topico(vizinho):
    """Mesma razao da fila: a policy concede sns:Publish e mais nada."""
    if vizinho.get("ARN"):
        return vizinho["ARN"]
    return f"arn:aws:sns:{_regiao_de(vizinho)}:{_conta_de(vizinho)}:{vizinho['NAME']}"


# ----------------------------------------------------------------------------
# Estado preguicoso
# ----------------------------------------------------------------------------
#
# Tudo que fala com a nuvem fica aqui, e nada disso roda na importacao do
# modulo. Erro em tempo de import derruba a invocacao inteira com
# Runtime.ImportModuleError, antes do handler existir -- e num Event Source
# Mapping isso e pior que um erro comum: o lote e reprocessado ate o registro
# expirar, e com bisect_batch_on_function_error o lote ainda e partido ao meio
# a cada tentativa. Aqui dentro, cada bloco falha sozinho e o erro vai para o
# relatorio da resposta em vez de matar o resto.

_ESTADO = None


def estado():
    global _ESTADO
    if _ESTADO is None:
        _ESTADO = _montar_estado()
    return _ESTADO


def _montar_estado():
    vizinhos = descobrir_vizinhos(os.environ)
    falhas = []

    for tipo, lista in sorted(vizinhos.items()):
        print(f"[descoberta] {tipo}: {[v.get('NAME', v['label']) for v in lista]}")
    if not vizinhos:
        print("[descoberta] nenhum vizinho no ambiente -- nenhum fio desenhado, ou o tipo do alvo nao tem typeEnvVar")

    est = {
        "vizinhos": vizinhos,
        "falhas": falhas,
        "tabelas": [],
        "segredos": [],
        "rds": [],
        "ec2": [],
    }

    _preparar_dynamodb(est)
    _preparar_segredos(est)
    _preparar_rds(est)
    _preparar_ec2(est)

    return est


def _preparar_dynamodb(est):
    recurso = boto3.resource("dynamodb", region_name=REGIAO)
    for vizinho in est["vizinhos"].get("AWS_DYNAMODB_TABLE", []):
        nome = vizinho.get("NAME")
        if not nome:
            continue
        tabela = recurso.Table(nome)
        est["tabelas"].append((tabela, nome))
        try:
            if "Item" not in tabela.get_item(Key={"ID": "1"}):
                tabela.put_item(Item={"ID": "1", "LambdaName": f"Created by {NOME_DA_LAMBDA}", "Cont": 0})
        except Exception as erro:
            est["falhas"].append(f"DynamoDB {nome}: {erro}")


def _preparar_segredos(est):
    vizinhos = est["vizinhos"].get("AWS_SECRETSMANAGER_SECRET", [])
    if not vizinhos:
        return
    cliente = boto3.client("secretsmanager", region_name=REGIAO)
    for vizinho in vizinhos:
        identificador = vizinho.get("ARN") or vizinho.get("SECRET_ARN") or vizinho.get("NAME")
        try:
            bruto = cliente.get_secret_value(SecretId=identificador)["SecretString"]
            segredo = json.loads(bruto)
            est["segredos"].append((vizinho.get("NAME", ""), segredo.get("username"), segredo.get("password")))
        except Exception as erro:
            est["falhas"].append(f"Secrets {identificador}: {erro}")


def _preparar_rds(est):
    vizinhos = est["vizinhos"].get("AWS_DB_INSTANCE", [])
    if not vizinhos:
        return
    if not MYSQL_DISPONIVEL:
        est["falhas"].append("RDS: pymysql ausente (falta a layer)")
        return

    for vizinho in vizinhos:
        banco = vizinho.get("DB_NAME") or vizinho.get("NAME")
        endereco = (vizinho.get("ENDPOINT") or "").split(":")[0]
        if not endereco:
            est["falhas"].append(f"RDS {banco}: sem ENDPOINT no ambiente")
            continue

        usuario, senha = _credenciais_de(est, banco)
        try:
            conexao = pymysql.connect(
                host=endereco,
                user=usuario,
                password=senha,
                database=banco,
                charset="utf8mb4",
                cursorclass=pymysql.cursors.DictCursor,
                connect_timeout=5,
            )
            with conexao.cursor() as cursor:
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS exemplo ("
                    "id INT AUTO_INCREMENT, texto VARCHAR(4000) NOT NULL, PRIMARY KEY (id))"
                )
            conexao.commit()
            est["rds"].append((conexao, banco))
        except Exception as erro:
            est["falhas"].append(f"RDS {banco}: {erro}")


def _credenciais_de(est, banco):
    for nome, usuario, senha in est["segredos"]:
        if banco and banco in nome:
            return usuario, senha
    if est["segredos"]:
        return est["segredos"][0][1], est["segredos"][0][2]
    return "TypeNewUserName", "TypeNewPassword"


def _preparar_ec2(est):
    vizinhos = est["vizinhos"].get("AWS_INSTANCE", [])
    if not vizinhos:
        return
    for vizinho in vizinhos:
        nome = vizinho.get("NAME")
        try:
            cliente = boto3.client("ec2", region_name=_regiao_de(vizinho))
            resposta = cliente.describe_instances(Filters=[{"Name": "tag:Name", "Values": [nome]}])
            for reserva in resposta["Reservations"]:
                for instancia in reserva["Instances"]:
                    dns = instancia.get("PublicDnsName") or instancia.get("PrivateDnsName")
                    if dns:
                        est["ec2"].append((dns, nome))
                        break
        except Exception as erro:
            # ec2:DescribeInstances nao esta nas policies que o Struct8 gera por
            # conexao: sem uma policy escrita a mao, este bloco falha sempre.
            est["falhas"].append(f"EC2 {nome}: {erro}")


# ----------------------------------------------------------------------------
# Entrada: identificar a origem e extrair os itens
# ----------------------------------------------------------------------------


def identificar_origem(evento):
    registros = evento.get("Records") if isinstance(evento, dict) else None
    if registros:
        primeiro = registros[0]
        if "Sns" in primeiro:
            return "aws:sns"
        if primeiro.get("eventSource") == "aws:sqs":
            return "aws:sqs"
        if "s3" in primeiro:
            return "aws:s3"
        if "kinesis" in primeiro:
            return "aws:kinesis"
        if "dynamodb" in primeiro:
            return "aws:dynamodb"

    if not isinstance(evento, dict):
        return "API"
    if "CodePipeline.job" in evento:
        return "aws:codepipeline"
    if evento.get("source") == "aws.events":
        return "aws.events"

    contexto = evento.get("requestContext")
    if isinstance(contexto, dict) and "elb" in contexto:
        return "aws:elb"
    return "API"


def _truncar(texto):
    texto = str(texto)
    return texto if len(texto) <= LIMITE_DA_MENSAGEM else texto[:LIMITE_DA_MENSAGEM] + "...[truncado]"


def _resumir_payload(texto):
    """
    Dado de stream costuma ser JSON. O caso do CDC do DynamoDB ganha resumo
    proprio porque o envelope cru e ilegivel num log de teste -- o que interessa
    ali e a operacao e a chave, nao a imagem inteira do item.
    """
    try:
        dado = json.loads(texto)
    except (ValueError, TypeError):
        return _truncar(texto)

    if isinstance(dado, dict) and "dynamodb" in dado:
        tabela = dado.get("tableName", "?")
        operacao = dado.get("eventName", "?")
        chave = json.dumps(dado.get("dynamodb", {}).get("Keys", {}), ensure_ascii=False)
        return f"CDC {operacao} na tabela {tabela}, chave {chave}"

    return _truncar(json.dumps(dado, ensure_ascii=False))


def extrair_itens(evento, origem):
    """
    Devolve (itens, descricao). Cada item e (identificador, mensagem).

    O identificador so existe onde a origem entrega LOTE e aceita relatorio
    parcial de falha (fila e stream); nas demais e None. Origem de lote e
    percorrida inteira: ler so Records[0] descartaria ate 99 registros de um
    batch_size 100.
    """
    if origem == "aws:sns":
        registro = evento["Records"][0]["Sns"]
        topico = registro["TopicArn"].split(":")[-1]
        return [(None, registro.get("Message", ""))], f"SNS {topico}"

    if origem == "aws:sqs":
        fila = evento["Records"][0]["eventSourceARN"].split(":")[-1]
        itens = [(r.get("messageId"), r.get("body", "")) for r in evento["Records"]]
        return itens, f"SQS {fila} ({len(itens)} registro(s))"

    if origem in ("aws:kinesis", "aws:dynamodb"):
        return _itens_de_stream(evento, origem)

    if origem == "aws.events":
        regra = evento["resources"][0].split("/")[-1]
        return [(None, f"Evento de {regra}")], f"EventBridge {regra}"

    if origem == "aws:s3":
        return _itens_de_s3(evento)

    if origem == "aws:elb":
        alvo = evento["requestContext"]["elb"]["targetGroupArn"].split(":")[-1]
        return [(None, "Requisicao HTTP do ALB")], f"ALB {alvo}"

    if origem == "aws:codepipeline":
        return [(None, "Job " + evento["CodePipeline.job"]["id"])], "CodePipeline"

    return _itens_de_api(evento)


def _itens_de_stream(evento, origem):
    """
    Kinesis Data Streams e DynamoDB Streams tem a mesma forma de lote; o que
    muda e o campo do registro. O dado do Kinesis vem em base64 -- repassar sem
    decodificar mandaria a string codificada adiante, que "funciona" e nao
    prova nada.
    """
    campo = "kinesis" if origem == "aws:kinesis" else "dynamodb"
    itens = []
    nome = "?"

    for registro in evento.get("Records", []):
        arn = registro.get("eventSourceARN", "")
        if arn:
            nome = arn.split("/")[1] if "/" in arn else arn.split(":")[-1]

        if campo == "kinesis":
            bloco = registro.get("kinesis", {})
            identificador = bloco.get("sequenceNumber")
            bruto = base64.b64decode(bloco.get("data", ""))
            try:
                mensagem = _resumir_payload(bruto.decode("utf-8"))
            except UnicodeDecodeError:
                mensagem = f"<{len(bruto)} bytes nao-UTF8>"
        else:
            identificador = registro.get("dynamodb", {}).get("SequenceNumber")
            mensagem = _resumir_payload(json.dumps(registro, ensure_ascii=False))

        itens.append((identificador, mensagem))

    rotulo = "Kinesis" if campo == "kinesis" else "DynamoDB Stream"
    return itens, f"{rotulo} {nome} ({len(itens)} registro(s))"


def _itens_de_s3(evento):
    registro = evento["Records"][0]["s3"]
    balde = registro["bucket"]["name"]
    caminho = unquote(registro["object"]["key"]).replace("+", " ")
    tamanho = registro["object"].get("size", 0)

    if caminho.lower().endswith(".txt"):
        cliente = boto3.client("s3")
        corpo = com_xray(balde, cliente.get_object, Bucket=balde, Key=caminho)["Body"].read()
        mensagem = _truncar(corpo.decode("utf-8", errors="replace"))
    else:
        mensagem = f"Arquivo {caminho} nao e .txt"

    return [(None, mensagem)], f"S3 {balde}/{caminho} ({tamanho} bytes)"


def _itens_de_api(evento):
    if MODO_API == "PROXY":
        corpo = evento.get("body") or "{}"
        try:
            dado = json.loads(corpo) if isinstance(corpo, str) else corpo
            mensagem = str(dado.get("message", dado)) if isinstance(dado, dict) else str(dado)
        except ValueError as erro:
            mensagem = f"Corpo do proxy invalido: {erro}"
    else:
        mensagem = str(evento.get("message", evento)) if isinstance(evento, dict) else str(evento)

    return [(None, mensagem)], f"API (modo {MODO_API})"


# ----------------------------------------------------------------------------
# Saida: reenviar para todos os vizinhos
# ----------------------------------------------------------------------------


def espalhar(est, mensagem):
    """Envia a mensagem a cada vizinho. Devolve a lista de erros por destino."""
    erros = []
    vizinhos = est["vizinhos"]

    for vizinho in vizinhos.get("AWS_SQS_QUEUE", []):
        try:
            cliente = boto3.client("sqs", region_name=_regiao_de(vizinho))
            com_xray(vizinho["NAME"], cliente.send_message, QueueUrl=_url_da_fila(vizinho), MessageBody=mensagem)
        except Exception as erro:
            erros.append(f"SQS {vizinho.get('NAME')}: {erro}")

    for vizinho in vizinhos.get("AWS_SNS_TOPIC", []):
        try:
            cliente = boto3.client("sns", region_name=_regiao_de(vizinho))
            com_xray(
                vizinho["NAME"],
                cliente.publish,
                TopicArn=_arn_do_topico(vizinho),
                Message=json.dumps({"default": json.dumps(mensagem)}),
                MessageStructure="json",
            )
        except Exception as erro:
            erros.append(f"SNS {vizinho.get('NAME')}: {erro}")

    agora = datetime.datetime.now()

    for tabela, nome in est["tabelas"]:
        try:
            com_xray(
                nome,
                tabela.update_item,
                Key={"ID": "1"},
                UpdateExpression="SET Cont = if_not_exists(Cont, :zero) + :um",
                ExpressionAttributeValues={":um": 1, ":zero": 0},
            )
            expira = int((agora + datetime.timedelta(days=1)).timestamp())
            com_xray(
                nome,
                tabela.put_item,
                Item={"ID": f"{NOME_DA_LAMBDA}:{agora}", "Message": mensagem, "TTL": expira},
            )
        except Exception as erro:
            erros.append(f"DynamoDB {nome}: {erro}")

    for vizinho in vizinhos.get("AWS_KINESIS_STREAM", []):
        try:
            cliente = boto3.client("kinesis", region_name=_regiao_de(vizinho))
            com_xray(
                vizinho["NAME"],
                cliente.put_record,
                StreamName=vizinho["NAME"],
                Data=(mensagem + "\n").encode("utf-8"),
                # Chave de particao fixa por Lambda mantem a ordem do teste num
                # shard so. Com varios shards, trocar por algo variavel espalha.
                PartitionKey=NOME_DA_LAMBDA or "LambdaHub2",
            )
        except Exception as erro:
            erros.append(f"Kinesis {vizinho.get('NAME')}: {erro}")

    for vizinho in vizinhos.get("AWS_KINESIS_FIREHOSE_DELIVERY_STREAM", []):
        try:
            cliente = boto3.client("firehose", region_name=_regiao_de(vizinho))
            # A quebra de linha e o que separa os registros no arquivo que o
            # Firehose entrega no S3; sem ela o objeto sai com tudo concatenado.
            com_xray(
                vizinho["NAME"],
                cliente.put_record,
                DeliveryStreamName=vizinho["NAME"],
                Record={"Data": (mensagem + "\n").encode("utf-8")},
            )
        except Exception as erro:
            erros.append(f"Firehose {vizinho.get('NAME')}: {erro}")

    for vizinho in vizinhos.get("AWS_LAMBDA_FUNCTION", []):
        try:
            cliente = boto3.client("lambda", region_name=_regiao_de(vizinho))
            com_xray(
                vizinho["NAME"],
                cliente.invoke,
                FunctionName=vizinho["NAME"],
                InvocationType="Event",
                Payload=json.dumps({"message": mensagem, "source": "aws:lambda"}),
            )
        except Exception as erro:
            erros.append(f"Lambda {vizinho.get('NAME')}: {erro}")

    for vizinho in vizinhos.get("AWS_S3_BUCKET", []):
        try:
            cliente = boto3.client("s3", region_name=_regiao_de(vizinho))
            chave = f"{NOME_DA_LAMBDA}/{NOME_DA_LAMBDA}:{agora}.txt"
            com_xray(vizinho["NAME"], cliente.put_object, Bucket=vizinho["NAME"], Key=chave, Body=mensagem)
        except Exception as erro:
            erros.append(f"S3 {vizinho.get('NAME')}: {erro}")

    for vizinho in vizinhos.get("AWS_EFS_ACCESS_POINT", []):
        caminho = vizinho.get("PATH")
        if not caminho:
            continue
        try:
            with open(os.path.join(caminho, f"{NOME_DA_LAMBDA}:{agora}.txt"), "w") as arquivo:
                arquivo.write(mensagem)
        except Exception as erro:
            erros.append(f"EFS {caminho}: {erro}")

    for conexao, banco in est["rds"]:
        try:
            with conexao.cursor() as cursor:
                cursor.execute("INSERT INTO exemplo (texto) VALUES (%s)", (json.dumps(mensagem),))
            conexao.commit()
        except Exception as erro:
            erros.append(f"RDS {banco}: {erro}")

    for vizinho in vizinhos.get("AWS_SSM_PARAMETER", []):
        # LEITURA, nao escrita: a policy que o Struct8 gera para SSM concede
        # GetParameter/GetParameters. Um put_parameter aqui falharia por
        # permissao em todo diagrama que nao tenha uma policy escrita a mao.
        try:
            cliente = boto3.client("ssm", region_name=_regiao_de(vizinho))
            valor = com_xray(
                vizinho["NAME"], cliente.get_parameter, Name=vizinho["NAME"], WithDecryption=True
            )["Parameter"]["Value"]
            print(f"[SSM] {vizinho['NAME']} = {_truncar(valor)}")
        except Exception as erro:
            erros.append(f"SSM {vizinho.get('NAME')}: {erro}")

    corpo = json.dumps(mensagem).encode("utf-8")
    for dns, nome in est["ec2"]:
        try:
            conexao = http.client.HTTPConnection(dns, timeout=2)
            conexao.request("POST", f"/{nome}", body=corpo, headers={"Content-type": "application/json"})
            print(f"[EC2] {nome} respondeu {conexao.getresponse().status}")
            conexao.close()
        except Exception as erro:
            erros.append(f"EC2 {nome}: {erro}")

    for vizinho in vizinhos.get("AWS_CODEBUILD_PROJECT", []):
        try:
            cliente = boto3.client("codebuild", region_name=_regiao_de(vizinho))
            com_xray(
                vizinho["NAME"],
                cliente.start_build,
                projectName=vizinho["NAME"],
                environmentVariablesOverride=[{"name": "EVENT", "value": mensagem, "type": "PLAINTEXT"}],
            )
        except Exception as erro:
            erros.append(f"CodeBuild {vizinho.get('NAME')}: {erro}")

    return erros


# ----------------------------------------------------------------------------
# Handler
# ----------------------------------------------------------------------------

ORIGENS_EM_LOTE = ("aws:sqs", "aws:kinesis", "aws:dynamodb")


def lambda_handler(evento, contexto):
    print("Evento recebido:", json.dumps(evento)[:4000])

    _registrar_conta(contexto)

    est = estado()
    if est["falhas"]:
        print("[inicializacao] falhas:", est["falhas"])

    origem = identificar_origem(evento)
    try:
        itens, descricao = extrair_itens(evento, origem)
    except Exception as erro:
        print("Falha ao extrair o evento:", traceback.format_exc())
        return criar_resposta(origem, f"Evento de {origem} nao pode ser lido: {erro}", 400)

    print(f"Origem: {origem} -- {descricao}, {len(itens)} item(ns)")

    agora = datetime.datetime.now()
    reprovados = []
    ultima = ""

    for identificador, mensagem in itens:
        # Guarda de laco: o hub tambem manda para Lambdas, e uma cadeia que
        # volta nele mesmo se realimentaria para sempre.
        if NOME_DA_LAMBDA and NOME_DA_LAMBDA in mensagem:
            print("Laco detectado, item ignorado.")
            continue

        completa = f"Lambda: {NOME_DA_LAMBDA}. Source: {origem} ({descricao}). Date/Time: {agora}. <- {mensagem}"
        ultima = completa
        print("Enviando:", completa)

        erros = espalhar(est, completa)
        if erros:
            print(f"Erros no item {identificador}: {erros}")
            if identificador:
                reprovados.append(identificador)

    if origem == "aws:codepipeline":
        return processar_codepipeline(evento, evento["CodePipeline.job"]["id"])

    if origem in ORIGENS_EM_LOTE:
        # Contrato do function_response_types = ReportBatchItemFailures. A lista
        # vazia e a resposta de sucesso: sem ela, o mapeamento trata o lote
        # inteiro como falho e reprocessa tudo. No Kinesis o checkpoint volta
        # para o MENOR numero de sequencia reportado, entao tudo a partir dali
        # e reentregue.
        return {"batchItemFailures": [{"itemIdentifier": i} for i in reprovados]}

    return criar_resposta(origem, ultima or "Nenhum item processado")


def processar_codepipeline(evento, job_id):
    codepipeline = boto3.client("codepipeline")
    try:
        credenciais = evento["CodePipeline.job"]["data"]["artifactCredentials"]
        s3 = boto3.client(
            "s3",
            aws_access_key_id=credenciais["accessKeyId"],
            aws_secret_access_key=credenciais["secretAccessKey"],
            aws_session_token=credenciais["sessionToken"],
        )
        entradas = evento["CodePipeline.job"]["data"]["inputArtifacts"]
        saidas = evento["CodePipeline.job"]["data"]["outputArtifacts"]

        if entradas and saidas:
            origem = entradas[0]["location"]["s3Location"]
            if origem["objectKey"].endswith(".txt"):
                conteudo = s3.get_object(Bucket=origem["bucketName"], Key=origem["objectKey"])["Body"].read()
                destino = saidas[0]["location"]["s3Location"]
                s3.put_object(
                    Bucket=destino["bucketName"],
                    Key=destino["objectKey"],
                    Body=conteudo.decode("utf-8").upper().encode("utf-8"),
                )

        codepipeline.put_job_success_result(jobId=job_id)
        return {"statusCode": 200, "body": json.dumps({"status": "SUCCESS"})}
    except Exception as erro:
        codepipeline.put_job_failure_result(
            jobId=job_id, failureDetails={"type": "JobFailed", "message": str(erro)}
        )
        return {"statusCode": 500, "body": json.dumps({"status": "FAILED"})}


def criar_resposta(origem, mensagem, codigo=200):
    if origem == "aws:elb":
        return {
            "statusCode": codigo,
            "statusDescription": f"{codigo} OK",
            "isBase64Encoded": False,
            "headers": {"Content-Type": "text/html; charset=utf-8"},
            "body": mensagem,
        }

    if origem == "API":
        if MODO_API == "PROXY":
            return {
                "statusCode": codigo,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps(
                    {
                        "message": "Message processed",
                        "original_data": mensagem,
                        "timestamp": str(datetime.datetime.now()),
                    }
                ),
            }
        return mensagem

    return mensagem
