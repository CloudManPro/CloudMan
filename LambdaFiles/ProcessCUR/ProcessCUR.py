import json
import boto3
import csv
import io
import os
import gzip
import re
import urllib.parse
from decimal import Decimal, InvalidOperation
from datetime import datetime, timedelta, timezone

# --- Constantes e Configuração ---
RESOURCE_TAG_KEY = os.environ.get('RESOURCE_TAG_KEY', 'resourceTags/user:Name')
COST_COLUMN = 'lineItem/UnblendedCost'
PRODUCT_COLUMN = 'lineItem/ProductCode'
USAGE_TYPE_COLUMN = 'lineItem/UsageType'
USAGE_START_DATE_COLUMN = 'lineItem/UsageStartDate'
USAGE_ACCOUNT_COLUMN = 'lineItem/UsageAccountId'

# BUG CORRIGIDO (custo de IPv4 público perdido em "Untagged"): a AWS cobra
# endereços IPv4 públicos sob o produto "AmazonVPC", ligado ao ENI/EIP que
# efetivamente carrega o IP -- não ao recurso que "usa" esse IP (ex. um ALB).
# Essa linha de custo quase nunca vem com a cost-allocation tag do recurso
# dono, então sempre caía em "Untagged" e se perdia. O CUR já é gerado com
# `additional_schema_elements = ["RESOURCES"]` (ver Terraform), então a
# coluna abaixo já existe no CSV -- só não estava sendo lida.
RESOURCE_ID_COLUMN = 'lineItem/ResourceId'
UNTAGGABLE_PRODUCT_CODE = 'AmazonVPC'
UNTAGGABLE_USAGE_TYPE_PATTERN = 'PublicIPv4'

CUR_BUCKET_NAME_FALLBACK = os.environ.get('AWS_S3_BUCKET_NAME_0') or os.environ.get('AWS_S3_BUCKET_TARGET_NAME_0')
CONSOLIDATED_BUCKET_NAME = os.environ.get('AWS_S3_BUCKET_TARGET_NAME_0') or CUR_BUCKET_NAME_FALLBACK
CONSOLIDATED_KEY = os.getenv("CONSOLIDATED_KEY", "consolidated-costs/daily_costs_by_tag.json")

# Alterado padrão de retenção diária para 60 dias (para comportar a comparação de 30 dias anteriores)
DAYS_TO_RETAIN_ENV = os.getenv("DAYS_TO_RETAIN", "60")
MONTHS_TO_RETAIN_ENV = os.getenv("MONTHS_TO_RETAIN", "24")

try:
    DAYS_TO_RETAIN = int(DAYS_TO_RETAIN_ENV)
    if DAYS_TO_RETAIN <= 0:
        DAYS_TO_RETAIN = 60
except ValueError:
    DAYS_TO_RETAIN = 60

try:
    MONTHS_TO_RETAIN = int(MONTHS_TO_RETAIN_ENV)
    if MONTHS_TO_RETAIN <= 0:
        MONTHS_TO_RETAIN = 24
except ValueError:
    MONTHS_TO_RETAIN = 24

s3_client = boto3.client('s3')
# Novos clientes -- só leitura (Describe*), usados exclusivamente pra
# resolver o dono real de um ENI/EIP não tagueado (ver resolve_untagged_resource_name).
ec2_client = boto3.client('ec2')
elbv2_client = boto3.client('elbv2')

def decimal_default(obj):
    if isinstance(obj, Decimal): return str(obj)
    raise TypeError(f"Object of type {obj.__class__.__name__} is not JSON serializable")


DATE_FORMAT = '%Y-%m-%d'


def _parse_date(date_str):
    """Converte uma chave 'YYYY-MM-DD' em `date`. Retorna None quando a chave não
    é uma data válida -- inclusive o literal "UnknownDate" que versões anteriores
    gravavam quando faltava `lineItem/UsageStartDate`."""
    try:
        return datetime.strptime(date_str, DATE_FORMAT).date()
    except (ValueError, TypeError):
        return None


def _first_day_of_month(month_str):
    """Converte uma chave 'YYYY-MM' no `date` do dia 1. None se não for um mês
    válido -- serve também para detectar o mês "Unknown" legado."""
    try:
        return datetime.strptime(f"{month_str}-01", DATE_FORMAT).date()
    except (ValueError, TypeError):
        return None


def _to_decimal(value):
    """Decimal tolerante: valores já consolidados voltam do JSON como string, e um
    campo ausente ou corrompido não pode derrubar a consolidação inteira."""
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal('0.0')


def _daily_window(consolidated_data, structure_keys):
    """Devolve `(data_mais_antiga, data_mais_recente)` presentes nas estruturas
    diárias informadas (formato `{chave: {YYYY-MM-DD: {...}}}`).

    A data mais antiga é o que define se um mês pode ou não ser reconsolidado: se
    o diário só começa no dia 18 de um mês, a soma dos dias sobreviventes NÃO é o
    total daquele mês -- ver `rebuild_monthly_costs`."""
    oldest = None
    newest = None

    for structure_key in structure_keys:
        for dates_dict in consolidated_data.get(structure_key, {}).values():
            for date_str in dates_dict.keys():
                parsed = _parse_date(date_str)
                if parsed is None:
                    continue
                if oldest is None or parsed < oldest:
                    oldest = parsed
                if newest is None or parsed > newest:
                    newest = parsed

    return oldest, newest


def load_consolidated_data(bucket, key):
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        print(f"Successfully loaded existing consolidated file from s3://{bucket}/{key}")
        data = json.loads(content)

        # --- Compatibilidade e Migração Retroativa ---
        if "costs_by_tag_and_date" in data:
            print("Migrating deprecated 'costs_by_tag_and_date' structure to split layout.")
            data["daily_costs"] = data.pop("costs_by_tag_and_date")

        if "daily_costs" not in data:
            data["daily_costs"] = {}
        if "monthly_costs" not in data:
            data["monthly_costs"] = {}
        # NOVO: índice secundário por resourceId (ARN/ENI/EIP), só populado
        # pra linhas SEM tag de custo -- ver process_single_csv_file. Permite
        # o frontend achar custo real de recursos importados que nunca
        # ganharam a cost-allocation tag na AWS, casando pelo ARN salvo no
        # próprio nó em vez da tag.
        if "resources_by_id" not in data:
            data["resources_by_id"] = {}
        # NOVO: agregado mensal do índice por resourceId. Sem ele, o custo de
        # todo recurso SEM cost-allocation tag -- justamente o caso que
        # `resources_by_id` existe para cobrir -- era apagado na poda dos
        # DAYS_TO_RETAIN dias e não sobrava nada no histórico.
        if "monthly_resources_by_id" not in data:
            data["monthly_resources_by_id"] = {}
        if "metadata" not in data:
            data["metadata"] = {}

        return data
    except s3_client.exceptions.NoSuchKey:
        print(f"Consolidated file not found at s3://{bucket}/{key}. Initializing new structure.")
        return {
            "metadata": {
                "description": f"Daily costs (last {DAYS_TO_RETAIN} days) and monthly costs (last {MONTHS_TO_RETAIN} months) aggregated by tag '{RESOURCE_TAG_KEY}'.",
                "tag_key_used": RESOURCE_TAG_KEY,
                "days_retained": DAYS_TO_RETAIN,
                "months_retained": MONTHS_TO_RETAIN,
                "last_processed_cur_date": None,
                "last_processed_assembly_id": None,
                "last_updated_timestamp_utc": None,
                "currency_code": None
            },
            "daily_costs": {},
            "monthly_costs": {},
            "resources_by_id": {},
            "monthly_resources_by_id": {}
        }
    except Exception as e:
        print(f"ERROR: Failed to load consolidated data from s3://{bucket}/{key}. Error: {e}")
        raise

def save_consolidated_data(bucket, key, data):
    try:
        json_string = json.dumps(data, indent=2, default=decimal_default)
        s3_client.put_object(Bucket=bucket, Key=key, Body=json_string.encode('utf-8'), ContentType='application/json')
        print(f"Successfully saved updated consolidated file to s3://{bucket}/{key}")
    except Exception as e:
        print(f"ERROR: Failed to save consolidated data to s3://{bucket}/{key}. Error: {e}")
        raise

def read_manifest_file(bucket, key):
    try:
        print(f"Reading manifest file: s3://{bucket}/{key}")
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        return json.loads(content)
    except Exception as e:
        print(f"ERROR: Failed to read manifest file: {e}")
        raise


def _get_name_tag(tags):
    """Extrai a tag 'Name' de uma lista de tags no formato [{'Key':..,'Value':..}, ...]
    (formato comum a EC2/ELBv2/NAT Gateway). Retorna None se não achar."""
    for t in (tags or []):
        if t.get('Key') == 'Name':
            return t.get('Value')
    return None


def _resolve_via_eni(eni_id):
    """Resolve a tag 'Name' do recurso DONO de um ENI (eni-...) sem tag
    própria no CUR -- caso típico de IP público de EC2 ou de um Load
    Balancer (o ALB/NLB não expõe um ENI "seu" diretamente pro usuário,
    mas a AWS gerencia ENIs internos com uma Description identificável)."""
    resp = ec2_client.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
    interfaces = resp.get('NetworkInterfaces', [])
    if not interfaces:
        return None
    eni = interfaces[0]

    # Caso 1: ENI pertence diretamente a uma instância EC2 (IP público
    # atribuído à própria instância) -- pega a tag Name da instância.
    instance_id = eni.get('Attachment', {}).get('InstanceId')
    if instance_id:
        tags_resp = ec2_client.describe_tags(
            Filters=[
                {'Name': 'resource-id', 'Values': [instance_id]},
                {'Name': 'key', 'Values': ['Name']}
            ]
        )
        for t in tags_resp.get('Tags', []):
            if t.get('Key') == 'Name':
                return t.get('Value')
        return None

    # Caso 2: ENI gerenciado por um Load Balancer -- a Description vem no
    # formato "ELB app/<lb-name>/<id>" (ALB) ou "ELB net/<lb-name>/<id>" (NLB).
    # NOTA: <lb-name> aqui é o nome "cru" do recurso na AWS, que pode não
    # bater com a tag lógica ("Name") usada no resto do app -- por isso
    # resolvemos o ARN e buscamos a tag Name de verdade, em vez de usar o
    # nome cru direto.
    description = eni.get('Description', '')
    match = re.search(r'ELB (?:app|net)/([^/]+)/', description)
    if match:
        lb_name = match.group(1)
        try:
            lb_resp = elbv2_client.describe_load_balancers(Names=[lb_name])
            lbs = lb_resp.get('LoadBalancers', [])
            if lbs:
                lb_arn = lbs[0]['LoadBalancerArn']
                tags_resp = elbv2_client.describe_tags(ResourceArns=[lb_arn])
                for td in tags_resp.get('TagDescriptions', []):
                    name = _get_name_tag(td.get('Tags'))
                    if name:
                        return name
        except Exception as e:
            print(f"WARN: Falha ao resolver Load Balancer '{lb_name}' a partir do ENI '{eni_id}': {e}")

    return None


def _resolve_via_eip(allocation_id):
    """Resolve a tag 'Name' do recurso DONO de um Elastic IP (eipalloc-...)
    sem tag própria -- caso típico do IP público de um NAT Gateway."""
    resp = ec2_client.describe_addresses(AllocationIds=[allocation_id])
    addresses = resp.get('Addresses', [])
    if not addresses:
        return None
    address = addresses[0]

    # Caso mais comum: EIP associado a um NAT Gateway.
    network_interface_id = address.get('NetworkInterfaceId')
    if network_interface_id:
        nat_resp = ec2_client.describe_nat_gateways(
            Filter=[{'Name': 'network-interface-id', 'Values': [network_interface_id]}]
        )
        for nat in nat_resp.get('NatGateways', []):
            name = _get_name_tag(nat.get('Tags'))
            if name:
                return name

    # Fallback: a própria EIP pode estar tagueada diretamente.
    return _get_name_tag(address.get('Tags'))


def resolve_untagged_resource_name(resource_id, cache):
    """Tenta descobrir a tag 'Name' do recurso DONO de um resourceId de rede
    (ENI ou EIP) que não veio com tag própria no CUR -- caso típico do IPv4
    público, cobrado sob AmazonVPC mas usado por outro recurso (ALB, NAT
    Gateway, EC2). Retorna None se não conseguir resolver -- nesse caso a
    linha cai em "Untagged", exatamente o comportamento de antes desta
    correção (nunca quebra o processamento por causa disso).

    `cache` é um dict compartilhado entre TODOS os arquivos CSV de um mesmo
    manifesto -- o mesmo ENI/EIP costuma se repetir em várias linhas/dias,
    evita bater na API da AWS de novo pro mesmo resourceId."""
    if resource_id in cache:
        return cache[resource_id]

    resolved_name = None
    try:
        if resource_id.startswith('eni-'):
            resolved_name = _resolve_via_eni(resource_id)
        elif resource_id.startswith('eipalloc-'):
            resolved_name = _resolve_via_eip(resource_id)
    except Exception as e:
        print(f"WARN: Falha ao resolver resourceId '{resource_id}': {e}")

    cache[resource_id] = resolved_name
    return resolved_name


def _accumulate_cost_entry(target_dict, key_value, usage_date, product_code, usage_key, cost):
    """Soma `cost` na estrutura padrão `{key_value: {date: {TotalUnblendedCost,
    CostsByProduct}}}`, criando os níveis que faltarem. Compartilhado entre o
    índice por TAG e o índice novo por resourceId -- mesmo formato, evita
    duplicar a lógica de acumulação duas vezes."""
    if key_value not in target_dict:
        target_dict[key_value] = {}
    if usage_date not in target_dict[key_value]:
        target_dict[key_value][usage_date] = {
            "TotalUnblendedCost": Decimal('0.0'),
            "CostsByProduct": {}
        }

    target_dict[key_value][usage_date]['TotalUnblendedCost'] += cost

    costs_by_product = target_dict[key_value][usage_date]['CostsByProduct']
    if product_code not in costs_by_product:
        costs_by_product[product_code] = {}
    costs_by_usage = costs_by_product[product_code]
    if usage_key not in costs_by_usage:
        costs_by_usage[usage_key] = Decimal('0.0')
    costs_by_usage[usage_key] += cost


def process_single_csv_file(bucket_name, object_key, fallback_date, resource_name_cache):
    daily_costs_by_tag = {}
    # NOVO: índice secundário por resourceId, só preenchido pra linhas que
    # ficam SEM tag (ver loop abaixo) -- ver comentário em load_consolidated_data.
    daily_costs_by_resource_id = {}
    currency_code = None
    body = None
    text_stream = None

    print(f"Processing data part: s3://{bucket_name}/{object_key}")

    try:
        s3_object = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        body = s3_object['Body']
        is_gzipped = object_key.lower().endswith('.gz')

        if is_gzipped:
            gzip_stream = gzip.GzipFile(fileobj=body)
            text_stream = io.TextIOWrapper(gzip_stream, encoding='utf-8', errors='replace')
        else:
            text_stream = io.TextIOWrapper(body, encoding='utf-8', errors='replace')

        csv_reader = csv.DictReader(text_stream)
        processed_rows = 0
        skipped_undated_rows = 0
        currency_found = False

        for row in csv_reader:
            processed_rows += 1

            if not currency_found and processed_rows <= 10:
                currency_code_found = row.get('lineItem/CurrencyCode', row.get('pricing/currency'))
                if currency_code_found:
                    currency_code = currency_code_found
                    currency_found = True

            # BUG CORRIGIDO ("UnknownDate" imortal): quando a coluna faltava E o
            # fallback vinha vazio, a linha era gravada sob a data literal
            # "UnknownDate". Nenhuma das duas podas conseguia removê-la (o
            # strptime falhava e caía num `continue`; na poda mensal
            # "Unknown" < "2024-08" é False), então a entrada ficava presa no
            # JSON para sempre e ainda criava um mês "Unknown" no consolidado.
            # Agora só entram datas válidas -- o resto é contado e descartado.
            raw_usage_date = row.get(USAGE_START_DATE_COLUMN)
            usage_date = raw_usage_date[:10] if raw_usage_date and len(raw_usage_date) >= 10 else None
            if usage_date is not None and _parse_date(usage_date) is None:
                usage_date = None
            if usage_date is None:
                usage_date = fallback_date

            product_code = row.get(PRODUCT_COLUMN) or 'UnknownProduct'
            usage_type = row.get(USAGE_TYPE_COLUMN) or 'UnknownUsageType'
            # Lido incondicionalmente (não só no caso do IPv4) -- precisa
            # estar disponível pro índice novo por resourceId logo abaixo,
            # pra QUALQUER linha que acabe sem tag, não só a de IPv4.
            resource_id = row.get(RESOURCE_ID_COLUMN)

            tag_value = row.get(RESOURCE_TAG_KEY)
            if not tag_value:
                # BUG CORRIGIDO: custo de IPv4 público (cobrado sob AmazonVPC,
                # ligado ao ENI/EIP, não ao recurso que o usa) sempre caía
                # aqui em "Untagged" -- perdido pra sempre, mesmo sendo custo
                # real do ALB/NAT/EC2 dono do IP. Resolve o dono via API da
                # AWS, processado perto do dia real (preserva o histórico com
                # muito mais precisão do que reconstruir depois a partir da
                # config atual do recurso).
                if (
                    resource_id
                    and product_code == UNTAGGABLE_PRODUCT_CODE
                    and UNTAGGABLE_USAGE_TYPE_PATTERN in usage_type
                ):
                    resolved_name = resolve_untagged_resource_name(resource_id, resource_name_cache)
                    tag_value = resolved_name or "Untagged"
                else:
                    tag_value = "Untagged"

            cost_str = row.get(COST_COLUMN)
            try:
                cost = Decimal(cost_str) if cost_str else Decimal('0.0')
            except (InvalidOperation, TypeError):
                cost = Decimal('0.0')

            if cost == Decimal('0.0'):
                continue

            # Linha com custo real mas sem nenhuma data utilizável (nem a da
            # coluna, nem o fallback do manifesto). Sem data ela não pertence a
            # dia nem a mês nenhum -- contabiliza e descarta, em vez de poluir a
            # estrutura com uma chave que nunca sai de lá.
            if usage_date is None:
                skipped_undated_rows += 1
                continue

            # Captura a conta ativa correspondente ao uso
            active_account = row.get(USAGE_ACCOUNT_COLUMN) or 'UnknownAccount'
            usage_key = f"{usage_type}@{active_account}"

            _accumulate_cost_entry(daily_costs_by_tag, tag_value, usage_date, product_code, usage_key, cost)

            # NOVO: linha ainda SEM tag (recurso importado sem cost-allocation
            # tag na AWS, ou resolução de IPv4 acima não achou dono) mas COM
            # resourceId -- indexa também por resourceId, pro frontend poder
            # casar pelo ARN salvo no nó quando a busca por tag falhar.
            if tag_value == "Untagged" and resource_id:
                _accumulate_cost_entry(
                    daily_costs_by_resource_id, resource_id, usage_date, product_code, usage_key, cost
                )

        print(f"Finished parsing part. Total rows scanned: {processed_rows}.")
        if skipped_undated_rows:
            print(
                f"WARN: {skipped_undated_rows} linha(s) com custo foram descartadas por não terem "
                f"data utilizável ({USAGE_START_DATE_COLUMN} ausente e sem fallback do manifesto)."
            )
        return daily_costs_by_tag, daily_costs_by_resource_id, currency_code

    except Exception as e:
        print(f"Error parsing file part {object_key}: {e}")
        return {}, {}, None
    finally:
        if text_stream and not text_stream.closed:
            try: text_stream.close()
            except Exception: pass
        if body and hasattr(body, 'close') and not body.closed:
             try: body.close()
             except Exception: pass

def merge_batch_into_temp(temp_dict, csv_costs, touched_months):
    """Mescla o lote de UM arquivo CSV (`csv_costs`, no formato
    `{key: {date: {...}}}`) no acumulador temporário do manifesto inteiro.
    Compartilhada entre o índice por TAG e o índice novo por resourceId --
    mesma lógica de mesclagem, só o dicionário-alvo muda."""
    for key_value, dates_dict in csv_costs.items():
        if key_value not in temp_dict:
            temp_dict[key_value] = {}
        for d_str, day_data in dates_dict.items():
            touched_months.add(d_str[:7])  # Captura formato YYYY-MM
            if d_str not in temp_dict[key_value]:
                temp_dict[key_value][d_str] = day_data
            else:
                existing_total = temp_dict[key_value][d_str]["TotalUnblendedCost"]
                new_total = day_data["TotalUnblendedCost"]
                temp_dict[key_value][d_str]["TotalUnblendedCost"] = existing_total + new_total

                for prod_code, prod_data in day_data["CostsByProduct"].items():
                    if prod_code not in temp_dict[key_value][d_str]["CostsByProduct"]:
                        temp_dict[key_value][d_str]["CostsByProduct"][prod_code] = prod_data
                    else:
                        for usage_type, cost_val in prod_data.items():
                            existing_val = temp_dict[key_value][d_str]["CostsByProduct"][prod_code].get(usage_type, Decimal('0.0'))
                            temp_dict[key_value][d_str]["CostsByProduct"][prod_code][usage_type] = existing_val + cost_val


def prune_daily_structure(consolidated_data, structure_key, cutoff_date):
    """Remove datas mais velhas que `cutoff_date` de
    `consolidated_data[structure_key]` (formato `{key: {date: {...}}}`),
    removendo também chaves que ficarem vazias. Compartilhada entre
    `daily_costs` (por tag) e `resources_by_id` (novo, por resourceId) --
    mesma janela de retenção de 60 dias pros dois. Retorna quantas datas
    foram removidas."""
    removed_count = 0
    malformed_count = 0
    empty_keys = []
    structure = consolidated_data.setdefault(structure_key, {})

    for key_value in list(structure.keys()):
        dates_to_delete = []
        date_data = structure[key_value]

        for date_str in date_data.keys():
            data_date = _parse_date(date_str)
            if data_date is None:
                # Chave que não é data -- o "UnknownDate" gravado por versões
                # anteriores. O `except ValueError: continue` de antes a deixava
                # presa no arquivo para sempre, crescendo a cada execução.
                dates_to_delete.append(date_str)
                malformed_count += 1
                continue
            if data_date < cutoff_date:
                dates_to_delete.append(date_str)

        for date_to_delete in dates_to_delete:
            del structure[key_value][date_to_delete]
            removed_count += 1

        if not structure[key_value]:
            empty_keys.append(key_value)

    for key_to_delete in empty_keys:
        del structure[key_to_delete]

    if malformed_count:
        print(f"Removed {malformed_count} malformed (non-date) entries from '{structure_key}'.")

    return removed_count


def prune_monthly_structure(consolidated_data, structure_key, cutoff_month_str):
    """Remove de `consolidated_data[structure_key]` (formato
    `{chave: {YYYY-MM: {...}}}`) os meses anteriores a `cutoff_month_str`, além de
    chaves de mês malformadas -- o mês "Unknown" legado nunca era removido porque
    a comparação de string `"Unknown" < "2024-08"` é False. Retorna quantos meses
    foram removidos."""
    removed_count = 0
    empty_keys = []
    structure = consolidated_data.setdefault(structure_key, {})

    for key_value in list(structure.keys()):
        months_to_delete = []

        for month_str in structure[key_value].keys():
            if _first_day_of_month(month_str) is None or month_str < cutoff_month_str:
                months_to_delete.append(month_str)

        for month_to_delete in months_to_delete:
            del structure[key_value][month_to_delete]
            removed_count += 1

        if not structure[key_value]:
            empty_keys.append(key_value)

    for key_to_delete in empty_keys:
        del structure[key_to_delete]

    return removed_count


def rebuild_monthly_costs(consolidated_data, daily_key, monthly_key, window_start):
    """Consolida a estrutura diária `daily_key` na estrutura mensal `monthly_key`.

    Duas correções em relação à versão que reconstruía apenas os meses presentes
    no manifesto recém-processado (`touched_months`):

    1. Varre TODOS os meses presentes no diário, não só os "tocados" agora. Antes,
       um mês só virava mensal se a Lambda tivesse rodado com sucesso durante ele
       -- diário que já estava no arquivo (deploy posterior, execução que falhou,
       CUR que mudou de prefixo) nunca era consolidado e simplesmente sumia na
       poda dos DAYS_TO_RETAIN dias.

    2. Só sobrescreve um mês já consolidado quando o mês INTEIRO ainda está no
       diário (`window_start` <= dia 1 do mês). Antes, qualquer manifesto que
       tocasse um mês fechado -- um crédito/refund com UsageStartDate antigo, um
       reprocessamento manual via `object_key`, um manifesto parcial -- reescrevia
       o total mensal com a soma apenas dos dias sobreviventes da janela,
       truncando o histórico em definitivo. Era essa a razão real de
       DAYS_TO_RETAIN ter subido de 30 para 60: com 30 dias a janela corta o mês
       anterior ao meio, e um único toque o reescrevia com menos da metade do
       valor. Com a guarda abaixo, 30 dias volta a ser uma configuração válida.

    Um mês parcial que ainda NÃO tem consolidado nenhum é gravado assim mesmo
    (perder o dado seria pior), porém marcado com `"Partial": true`, para o
    consumidor saber que aquele total não cobre o mês inteiro.

    O mês corrente é sempre "completo" no sentido usado aqui: `window_start` é
    anterior ao dia 1, então ele é reconsolidado a cada entrega do CUR e vai
    acumulando até fechar -- que é o comportamento desejado.
    """
    daily = consolidated_data.get(daily_key, {})
    monthly = consolidated_data.setdefault(monthly_key, {})
    stats = {"rebuilt": 0, "preserved": 0, "partial": 0}

    for key_value, dates_dict in daily.items():
        months_present = set()
        for date_str in dates_dict.keys():
            if _parse_date(date_str) is not None:
                months_present.add(date_str[:7])

        for month_str in sorted(months_present):
            month_dates = {d: val for d, val in dates_dict.items() if d.startswith(month_str)}
            if not month_dates:
                continue

            first_day = _first_day_of_month(month_str)
            month_is_complete = (
                window_start is not None
                and first_day is not None
                and first_day >= window_start
            )

            # Mês parcial que já tem consolidado: o valor histórico é mais
            # confiável do que a soma dos dias que sobraram na janela.
            if not month_is_complete and month_str in monthly.get(key_value, {}):
                stats["preserved"] += 1
                continue

            total_unblended = Decimal('0.0')
            products = {}

            for day_data in month_dates.values():
                total_unblended += _to_decimal(day_data.get("TotalUnblendedCost", "0.0"))

                for prod_code, prod_data in day_data.get("CostsByProduct", {}).items():
                    prod_entry = products.setdefault(prod_code, {})
                    for usage_key, cost_val in prod_data.items():
                        prod_entry[usage_key] = prod_entry.get(usage_key, Decimal('0.0')) + _to_decimal(cost_val)

            month_entry = {
                "TotalUnblendedCost": str(total_unblended),
                "CostsByProduct": {
                    p: {uk: str(c) for uk, c in uk_dict.items()}
                    for p, uk_dict in products.items()
                }
            }
            if not month_is_complete:
                month_entry["Partial"] = True
                stats["partial"] += 1

            # `setdefault` só aqui: criar a chave antes (como a versão anterior
            # fazia no topo do laço) enchia o JSON de dicionários vazios para
            # toda tag que nunca teve mês consolidado.
            monthly.setdefault(key_value, {})[month_str] = month_entry
            stats["rebuilt"] += 1

    return stats

def lambda_handler(event, context):
    print(f"Lambda execution started. Received event: {json.dumps(event)}")

    manifest_key = None
    cur_bucket_name = None

    try:
        if 'Records' in event and isinstance(event['Records'], list) and event['Records'] and 's3' in event['Records'][0]:
            s3_event = event['Records'][0]['s3']
            cur_bucket_name = s3_event['bucket']['name']
            manifest_key = urllib.parse.unquote_plus(s3_event['object']['key'], encoding='utf-8')
        elif isinstance(event, dict) and 'object_key' in event:
            manifest_key = event['object_key']
            if CUR_BUCKET_NAME_FALLBACK:
                cur_bucket_name = CUR_BUCKET_NAME_FALLBACK
            else:
                return {'statusCode': 500, 'body': 'Configuration Error: Fallback bucket env var missing.'}
        else:
            return {'statusCode': 400, 'body': 'Invalid event structure.'}
    except Exception as e:
         return {'statusCode': 400, 'body': f'Error parsing S3 event: {str(e)}'}

    consolidated_bucket = CONSOLIDATED_BUCKET_NAME
    if not consolidated_bucket:
        return {'statusCode': 500, 'body': 'Configuration Error: Target bucket env var missing.'}

    # 1. Carregar arquivo de Manifesto (.json)
    try:
        manifest = read_manifest_file(cur_bucket_name, manifest_key)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to parse manifest: {str(e)}'}

    assembly_id = manifest.get("assemblyId", "UnknownAssembly")
    report_keys = manifest.get("reportKeys", [])

    # Captura o ID da conta pagadora do manifesto
    payer_account_id = manifest.get("payerAccountId", "UnknownAccount")


    if not report_keys:
        print("WARNING: No report keys to process inside the manifest.")
        return {'statusCode': 200, 'body': 'No report keys found.'}

    processing_date_str = None
    match = re.search(r'(\d{8})T\d{6}Z', assembly_id)
    if match:
        try:
            processing_date_str = datetime.strptime(match.group(1), '%Y%m%d').strftime('%Y-%m-%d')
        except ValueError:
            pass

    # Segundo fallback de data: o billingPeriod do próprio manifesto
    # ("20260801T000000.000Z"). Sem ele, uma linha sem lineItem/UsageStartDate
    # num manifesto cujo assemblyId não casa com o regex acima ficava sem data
    # nenhuma -- e a versão anterior a gravava como "UnknownDate", entrada que
    # nenhuma das podas conseguia remover.
    if not processing_date_str:
        billing_start = (manifest.get("billingPeriod") or {}).get("start") or ""
        billing_match = re.match(r'(\d{4})(\d{2})(\d{2})', str(billing_start))
        if billing_match:
            processing_date_str = f"{billing_match.group(1)}-{billing_match.group(2)}-{billing_match.group(3)}"
            print(f"INFO: assemblyId sem data utilizável; usando billingPeriod.start ({processing_date_str}) como fallback.")

    # 2. Processar e agrupar novos dados diários em lote
    temp_aggregated_costs = {}
    # NOVO: acumulador temporário do índice por resourceId (só linhas sem tag).
    temp_aggregated_resource_costs = {}
    final_currency_code = None
    touched_months = set()
    # Compartilhado entre TODOS os arquivos CSV deste manifesto -- ver
    # resolve_untagged_resource_name.
    resource_name_cache = {}

    for csv_key in report_keys:
        csv_costs, csv_resource_costs, csv_currency = process_single_csv_file(
            cur_bucket_name, csv_key, processing_date_str, resource_name_cache
        )
        if csv_currency:
            final_currency_code = csv_currency

        # `touched_months` hoje serve só para log: a consolidação mensal varre
        # todos os meses presentes no diário, não apenas os deste manifesto --
        # ver rebuild_monthly_costs.
        merge_batch_into_temp(temp_aggregated_costs, csv_costs, touched_months)
        merge_batch_into_temp(temp_aggregated_resource_costs, csv_resource_costs, touched_months)

    # Serializar decimais temporários para float/string
    daily_costs_data = json.loads(json.dumps(temp_aggregated_costs, default=decimal_default))
    resource_costs_data = json.loads(json.dumps(temp_aggregated_resource_costs, default=decimal_default))

    # 3. Carregar dados consolidados existentes do S3
    try:
        consolidated_data = load_consolidated_data(consolidated_bucket, CONSOLIDATED_KEY)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to load consolidated data: {str(e)}'}

    # 4. Mesclar novos dados na estrutura "daily_costs"
    daily_key = 'daily_costs'
    updated_tags_count = 0
    for tag_value, dates_dict in daily_costs_data.items():
        if tag_value not in consolidated_data[daily_key]:
            consolidated_data[daily_key][tag_value] = {}
        for date_str, day_data in dates_dict.items():
            consolidated_data[daily_key][tag_value][date_str] = day_data
        updated_tags_count += 1

    # NOVO: mesma mesclagem pro índice novo "resources_by_id".
    resources_key = 'resources_by_id'
    monthly_key = 'monthly_costs'
    monthly_resources_key = 'monthly_resources_by_id'
    for resource_id_value, dates_dict in resource_costs_data.items():
        if resource_id_value not in consolidated_data[resources_key]:
            consolidated_data[resources_key][resource_id_value] = {}
        for date_str, day_data in dates_dict.items():
            consolidated_data[resources_key][resource_id_value][date_str] = day_data

    # 5. Determinar a janela diária realmente presente no arquivo -------------
    # `window_start` é a data mais antiga que AINDA está no diário (antes da poda
    # deste ciclo) -- é ela que diz se um mês pode ser reconsolidado sem truncar
    # o histórico. `reference_date` continua sendo a mais recente, base das podas.
    window_start, reference_date = _daily_window(consolidated_data, (daily_key, resources_key))

    if reference_date is None:
        reference_date = datetime.now(timezone.utc).date()
        print(f"Reference date falling back to current date: {reference_date}")
    else:
        print(f"Reference date for pruning: {reference_date} (daily window starts at {window_start})")

    # 6. Consolidar os meses das DUAS estruturas diárias ----------------------
    # Antes só o índice por tag era consolidado, e só para os meses do manifesto
    # atual. O índice por resourceId não tinha agregação mensal nenhuma: era
    # acumulado dia a dia e apagado na poda dos DAYS_TO_RETAIN dias, então o
    # custo de todo recurso SEM cost-allocation tag -- recurso importado, IPv4
    # público cujo dono não foi resolvido -- desaparecia por completo.
    print(f"Months present in this manifest: {sorted(touched_months)}")
    monthly_stats = rebuild_monthly_costs(consolidated_data, daily_key, monthly_key, window_start)
    resource_monthly_stats = rebuild_monthly_costs(
        consolidated_data, resources_key, monthly_resources_key, window_start
    )
    print(f"Monthly rebuild by tag: {monthly_stats}")
    print(f"Monthly rebuild by resourceId: {resource_monthly_stats}")

    # 7. Podar dados diários antigos -- mesma janela nos dois índices.
    print(f"Starting pruning of daily data older than {DAYS_TO_RETAIN} days...")
    cutoff_date = reference_date - timedelta(days=DAYS_TO_RETAIN)
    dates_removed_count = prune_daily_structure(consolidated_data, daily_key, cutoff_date)
    resource_dates_removed_count = prune_daily_structure(consolidated_data, resources_key, cutoff_date)
    print(f"Pruned {dates_removed_count} daily_costs entries and {resource_dates_removed_count} resources_by_id entries.")

    # 8. Podar agregados mensais antigos (mais velhos que MONTHS_TO_RETAIN meses)
    ref_year = reference_date.year
    ref_month = reference_date.month
    cutoff_year = ref_year - (MONTHS_TO_RETAIN // 12)
    cutoff_month = ref_month - (MONTHS_TO_RETAIN % 12)
    if cutoff_month <= 0:
        cutoff_month += 12
        cutoff_year -= 1
    cutoff_month_str = f"{cutoff_year:04d}-{cutoff_month:02d}"

    print(f"Starting pruning of monthly aggregates older than {cutoff_month_str}...")
    months_removed_count = prune_monthly_structure(consolidated_data, monthly_key, cutoff_month_str)
    resource_months_removed_count = prune_monthly_structure(
        consolidated_data, monthly_resources_key, cutoff_month_str
    )
    print(f"Pruned {months_removed_count} monthly_costs entries and {resource_months_removed_count} monthly_resources_by_id entries.")

    # Atualizar Metadados Globais do JSON
    consolidated_data.setdefault('metadata', {})
    consolidated_data['metadata']['last_processed_cur_date'] = processing_date_str
    consolidated_data['metadata']['last_processed_assembly_id'] = assembly_id
    consolidated_data['metadata']['last_updated_timestamp_utc'] = datetime.now(timezone.utc).isoformat(timespec='seconds') + 'Z'
    consolidated_data['metadata']['days_retained'] = DAYS_TO_RETAIN
    consolidated_data['metadata']['months_retained'] = MONTHS_TO_RETAIN
    if final_currency_code:
        consolidated_data['metadata']['currency_code'] = final_currency_code

    # Salvar o JSON Consolidado Final
    try:
        save_consolidated_data(consolidated_bucket, CONSOLIDATED_KEY, consolidated_data)
    except Exception as e:
        return {'statusCode': 500, 'body': f'Failed to save: {str(e)}'}

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Consolidated cost data updated successfully.',
            'tags_updated': updated_tags_count,
            'resource_ids_updated': len(resource_costs_data),
            'daily_dates_removed': dates_removed_count,
            'resource_dates_removed': resource_dates_removed_count,
            'monthly_records_removed': months_removed_count,
            'resource_monthly_records_removed': resource_months_removed_count,
            'monthly_rebuild_by_tag': monthly_stats,
            'monthly_rebuild_by_resource_id': resource_monthly_stats
        })
    }