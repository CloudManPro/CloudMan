import boto3
import os
import json
import logging
import requests
import io
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
import shutil
import tempfile
import time  # Necessário para implementar delays

# Configuração do logger com nível DEBUG e formato detalhado
logging.basicConfig(level=logging.DEBUG,
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


def strip_suffix(name):
    """
    Remove todos os caracteres após e incluindo o último "-"
    Exemplo:
        's3-cloudman-test' -> 's3-cloudman'
        'nome-teste-test' -> 'nome-teste'
        'nome-test' -> 'nome'
    """
    if '-' in name:
        return name.rsplit('-', 1)[0]
    return name


def strip_two_suffixes(name):
    """
    Remove os dois últimos sufixos separados por '-' do nome.
    Exemplo:
        's3-cloudman1-alpha-2' -> 's3-cloudman1'
        'nome-function-beta-3' -> 'nome-function'
    """
    parts = name.split('-')
    if len(parts) >= 3:
        return '-'.join(parts[:-2])
    return name  # Retorna o nome original se não houver sufixos suficientes


def get_source_name(target_name, is_test_stage=True):
    """
    Obtém o nome da fonte adicionando o sufixo '-dev' ao nome base.
    Remove um ou dois sufixos dependendo do stage.
    """
    if is_test_stage:
        base_name = strip_suffix(target_name)
    else:
        base_name = strip_two_suffixes(target_name)
    return f"{base_name}-dev"


# Função para copiar o código de uma Lambda para outra
def copy_lambda_function(source_lambda_name, source_region, target_lambda_name, target_region, account_id):
    source_client = boto3.client('lambda', region_name=source_region)
    target_client = boto3.client('lambda', region_name=target_region)

    try:
        logger.info(
            f"Iniciando a cópia da Lambda {source_lambda_name} (região {source_region}) para {target_lambda_name} (região {target_region})")

        # Obter o código da Lambda de origem
        response = source_client.get_function(FunctionName=source_lambda_name)
        code_url = response['Code']['Location']

        logger.info(
            f"URL para download do código da Lambda {source_lambda_name}: {code_url}")

        # Baixar o código fonte
        response = requests.get(code_url)
        zip_content = response.content

        logger.info(
            f"Código da Lambda {source_lambda_name} baixado com sucesso")

        # Atualizar a Lambda de destino com o código baixado
        target_client.update_function_code(
            FunctionName=target_lambda_name,
            ZipFile=zip_content
        )

        logger.info(
            f"Código da Lambda {target_lambda_name} atualizado com sucesso")
    except Exception as e:
        logger.error(
            f"Erro ao copiar a Lambda {source_lambda_name} para {target_lambda_name}: {e}")


# Função para copiar um objeto S3
def copy_s3_object(s3_client, source_bucket_name, target_bucket_name, obj_key):
    try:
        logger.info(
            f"Iniciando cópia do objeto {obj_key} de {source_bucket_name} para {target_bucket_name}")

        # Get the source object's metadata
        head_object = s3_client.head_object(
            Bucket=source_bucket_name, Key=obj_key)
        metadata = head_object.get('Metadata', {})
        content_type = head_object.get('ContentType')

        copy_source = {'Bucket': source_bucket_name, 'Key': obj_key}

        # Prepare ExtraArgs
        extra_args = {
            'MetadataDirective': 'REPLACE',
            'ContentType': content_type,
            'Metadata': metadata
        }

        s3_client.copy(copy_source, target_bucket_name,
                       obj_key, ExtraArgs=extra_args)

        logger.info(
            f"Objeto {obj_key} copiado com sucesso para {target_bucket_name}")
    except Exception as e:
        logger.error(
            f"Erro ao copiar o arquivo {obj_key} do bucket {source_bucket_name} para {target_bucket_name}: {e}")


# Função para sincronizar buckets S3 com operações paralelas
def sync_s3_buckets(source_bucket_name, target_bucket_name, region, max_workers=10):
    s3_client = boto3.client('s3', region_name=region)
    logger.info(
        f"Iniciando sincronização do bucket {source_bucket_name} para {target_bucket_name} na região {region} com {max_workers} workers")

    try:
        # Criar um ThreadPoolExecutor para operações paralelas
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = []
            paginator = s3_client.get_paginator('list_objects_v2')
            for page in paginator.paginate(Bucket=source_bucket_name):
                logger.info(
                    f"Processando página de objetos do bucket {source_bucket_name}")
                for obj in page.get('Contents', []):
                    obj_key = obj['Key']
                    if obj_key.endswith('/'):
                        logger.debug(
                            f"Objeto {obj_key} é um diretório. Pulando.")
                        continue  # Ignorar diretórios
                    logger.info(
                        f"Agendando cópia do objeto {obj['Key']} de {source_bucket_name} para {target_bucket_name}")
                    futures.append(executor.submit(
                        copy_s3_object, s3_client, source_bucket_name, target_bucket_name, obj['Key']))

            # Aguardar a conclusão de todas as tarefas
            for future in as_completed(futures):
                try:
                    future.result()  # Levanta exceções, se houver
                except Exception as e:
                    logger.error(f"Erro durante a execução paralela: {e}")

        logger.info(
            f"Sincronização do bucket {source_bucket_name} para {target_bucket_name} concluída.")
    except Exception as e:
        logger.error(
            f"Erro ao sincronizar o bucket {source_bucket_name} para {target_bucket_name}: {e}")


# Funções auxiliares para o processo de backup em 'test'


def download_lambda_code(target_lambda_name, source_region):
    """
    Baixa o código da Lambda de destino e salva sem o sufixo.
    """
    source_client = boto3.client('lambda', region_name=source_region)
    try:
        logger.info(
            f"Baixando código da Lambda {target_lambda_name} da região {source_region}")
        response = source_client.get_function(FunctionName=target_lambda_name)
        code_url = response['Code']['Location']
        response = requests.get(code_url)
        logger.info(
            f"Código da Lambda {target_lambda_name} baixado com sucesso")
        # Salvar o nome sem sufixo no backup
        stripped_name = strip_suffix(target_lambda_name)
        backup_lambda_path = f"Lambdas/{stripped_name}.zip"
        return (backup_lambda_path, response.content, stripped_name)
    except Exception as e:
        logger.error(
            f"Erro ao baixar código da Lambda {target_lambda_name}: {e}")
        return None


def download_s3_object(bucket_name, obj_key):
    """
    Baixa um objeto S3 e salva no caminho sem sufixo no backup.
    """
    try:
        logger.info(f"Baixando objeto {obj_key} do bucket {bucket_name}")
        # Ajustar região conforme necessário
        s3_client = boto3.client('s3', region_name='us-east-1')
        response = s3_client.get_object(Bucket=bucket_name, Key=obj_key)
        content = response['Body'].read()
        logger.info(f"Objeto {obj_key} baixado com sucesso")
        # Remover o sufixo do bucket para salvar no backup
        stripped_bucket_name = strip_suffix(bucket_name)
        backup_s3_path = f"S3/{stripped_bucket_name}/{obj_key}"
        return (backup_s3_path, content)
    except Exception as e:
        logger.error(
            f"Erro ao baixar objeto {obj_key} do bucket {bucket_name}: {e}")
        return None


def create_zip_of_folder(folder_path):
    try:
        logger.info(f"Criando arquivo ZIP da pasta {folder_path}")
        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for root, dirs, files in os.walk(folder_path):
                for file in files:
                    file_path = os.path.join(root, file)
                    # Adicionar o arquivo ao zip com o caminho relativo
                    arcname = os.path.relpath(file_path, start=folder_path)
                    zipf.write(file_path, arcname)
        zip_buffer.seek(0)
        logger.info(f"Arquivo ZIP da pasta {folder_path} criado com sucesso")
        return zip_buffer
    except Exception as e:
        logger.error(f"Erro ao criar arquivo ZIP da pasta {folder_path}: {e}")
        return None


def upload_to_s3_in_memory(s3_client, bucket_name, object_key, zip_buffer):
    try:
        logger.info(
            f"Fazendo upload do arquivo ZIP para s3://{bucket_name}/{object_key}")
        s3_client.upload_fileobj(zip_buffer, bucket_name, object_key)
        logger.info(
            f"Arquivo ZIP enviado com sucesso para s3://{bucket_name}/{object_key}")
    except Exception as e:
        logger.error(f"Erro ao fazer upload do arquivo ZIP para S3: {e}")


def upload_lambda_code(target_lambda_name, target_region, zip_content, max_retries=5):
    target_client = boto3.client('lambda', region_name=target_region)
    attempt = 0
    while attempt < max_retries:
        try:
            logger.info(
                f"Fazendo upload do código para a Lambda {target_lambda_name} na região {target_region} (Tentativa {attempt + 1})")
            target_client.update_function_code(
                FunctionName=target_lambda_name,
                ZipFile=zip_content
            )
            logger.info(
                f"Código da Lambda {target_lambda_name} atualizado com sucesso")
            return  # Saia da função se o upload for bem-sucedido
        except target_client.exceptions.ResourceConflictException as e:
            attempt += 1
            wait_time = 2 ** attempt  # Espera exponencial: 2, 4, 8, 16, 32 segundos
            logger.warning(
                f"ResourceConflictException ao atualizar a Lambda {target_lambda_name}: {e}. Tentando novamente em {wait_time} segundos...")
            time.sleep(wait_time)
        except Exception as e:
            logger.error(
                f"Erro ao fazer upload do código para a Lambda {target_lambda_name}: {e}")
            break  # Para outras exceções, não tentar novamente
    logger.error(
        f"Falha ao atualizar a Lambda {target_lambda_name} após {max_retries} tentativas.")


# Novas Funções para Restauração


def download_backup_zip(s3_client, backup_bucket_name, backup_object_key, download_path):
    """
    Baixa o arquivo ZIP de backup do bucket S3 para um caminho local.
    """
    try:
        logger.info(
            f"Baixando arquivo de backup {backup_object_key} do bucket {backup_bucket_name} para {download_path}")
        s3_client.download_file(
            backup_bucket_name, backup_object_key, download_path)
        logger.info(
            f"Arquivo de backup baixado com sucesso para {download_path}")
        return True
    except Exception as e:
        logger.error(
            f"Erro ao baixar o arquivo de backup {backup_object_key} do bucket {backup_bucket_name}: {e}")
        return False


def extract_zip(zip_path, extract_to):
    """
    Extrai o conteúdo do arquivo ZIP para o diretório especificado.
    """
    try:
        logger.info(f"Extraindo arquivo ZIP {zip_path} para {extract_to}")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(extract_to)
        logger.info(f"Arquivo ZIP extraído com sucesso para {extract_to}")
        return True
    except Exception as e:
        logger.error(f"Erro ao extrair o arquivo ZIP {zip_path}: {e}")
        return False


def upload_lambda_from_backup(lambda_backup_mapping, target_lambda_name, target_region):
    """
    Faz upload do código ZIP da Lambda a partir do backup para a Lambda de destino.
    """
    stripped_lambda_name = strip_two_suffixes(target_lambda_name)
    zip_content = lambda_backup_mapping.get(stripped_lambda_name)
    if zip_content:
        upload_lambda_code(target_lambda_name, target_region, zip_content)
    else:
        logger.warning(
            f"Não foi encontrado o arquivo ZIP para a Lambda {stripped_lambda_name}. Upload para a Lambda {target_lambda_name} será ignorado.")


def upload_s3_from_backup(extracted_backup_dir, target_s3):
    """
    Faz upload dos objetos S3 a partir do backup para o bucket de destino.

    Logs adicionais foram adicionados para melhorar a depuração, incluindo:
    - Nomes dos buckets de origem e destino
    - Caminhos completos dos arquivos de backup
    - Chaves dos objetos S3
    - Informações sobre cada etapa do processo de upload
    """
    logger.info("Iniciando a função 'upload_s3_from_backup'.")

    # Validação da estrutura de target_s3
    if len(target_s3) != 3:
        logger.warning(f"Par inválido encontrado em ListS3: {target_s3}")
        return

    target_bucket_name, target_region, target_account_id = target_s3
    logger.debug(
        f"Desempacotado target_s3: bucket='{target_bucket_name}', region='{target_region}', account_id='{target_account_id}'")

    # Remover os dois últimos sufixos do bucket de destino para localizar o backup
    stripped_bucket_name = strip_two_suffixes(target_bucket_name)
    backup_s3_path = f"S3/{stripped_bucket_name}"
    logger.debug(f"Nome do bucket sem sufixos: '{stripped_bucket_name}'")
    logger.debug(f"Caminho de backup S3: '{backup_s3_path}'")

    # Caminho completo no backup
    backup_s3_full_path = os.path.join(extracted_backup_dir, backup_s3_path)
    logger.debug(
        f"Caminho completo do backup S3 no sistema de arquivos local: '{backup_s3_full_path}'")

    # Verificar se o diretório de backup existe
    if not os.path.exists(backup_s3_full_path):
        logger.warning(
            f"Diretório de backup para o bucket S3 '{stripped_bucket_name}' não existe em '{backup_s3_full_path}'. Upload será ignorado.")
        return

    # Inicializar o cliente S3 para a região de destino
    try:
        s3_client = boto3.client('s3', region_name=target_region)
        logger.info(
            f"Cliente S3 inicializado para a região '{target_region}'.")
    except Exception as e:
        logger.error(
            f"Falha ao inicializar o cliente S3 para a região '{target_region}': {e}")
        return

    # Iterar sobre todos os objetos no diretório de backup S3
    logger.info(
        f"Iniciando iteração sobre os objetos no diretório de backup S3: '{backup_s3_full_path}'")
    for root, dirs, files in os.walk(backup_s3_full_path):
        for file in files:
            file_path = os.path.join(root, file)
            logger.debug(f"Arquivo encontrado no backup: '{file_path}'")

            # Determinar a chave do objeto S3
            relative_path = os.path.relpath(
                file_path, start=backup_s3_full_path)
            obj_key = relative_path.replace(os.path.sep, '/')
            logger.debug(f"Caminho relativo do arquivo: '{relative_path}'")
            logger.debug(f"Chave do objeto S3 para upload: '{obj_key}'")

            # Log detalhado antes do upload
            logger.info(
                f"Iniciando upload do objeto '{obj_key}' para o bucket '{target_bucket_name}'.")
            logger.debug(
                f"Caminho completo do arquivo local para upload: '{file_path}'")

            try:
                with open(file_path, 'rb') as data:
                    s3_client.upload_fileobj(data, target_bucket_name, obj_key)
                logger.info(
                    f"Objeto '{obj_key}' enviado com sucesso para o bucket '{target_bucket_name}'.")
                logger.debug(f"Upload concluído para o objeto '{obj_key}'.")
            except Exception as e:
                logger.error(
                    f"Erro ao enviar o objeto '{obj_key}' para o bucket '{target_bucket_name}': {e}")
                logger.debug(f"Detalhes do erro: {e}")
                # Opcional: Registrar stack trace completo para erros críticos
                logger.exception(
                    f"Exceção ao enviar o objeto '{obj_key}': {e}")

    logger.info("Função 'upload_s3_from_backup' finalizada.")


# Caminho para o arquivo List.txt
local_file_path = os.path.join(os.getcwd(), 'List.txt')

# Leitura do arquivo List.txt
try:
    with open(local_file_path, 'r', encoding='utf-8') as file:
        file_content = file.read()
    json_data = json.loads(file_content)
    logger.info(f"Arquivo List.txt lido com sucesso")
except Exception as err:
    logger.error(f"Erro ao acessar ou processar o arquivo List.txt: {err}")
    json_data = {}

# Extração das informações do JSON
IsTest = json_data.get("IsTest", False)
Version = json_data.get("Version")
command = os.getenv('Command')
if command:
    command_array = command.split(',')
    command_type = command_array[0]
    path = command_array[1] if len(command_array) > 1 else ''
    logger.info(f"Command type: {command_type}, Path: {path}")
    path_parts = path.split('/')
    PipelineName = path_parts[1] if len(path_parts) > 1 else ''
    CurrentStageName = path_parts[2] if len(path_parts) > 2 else ''
    CopyArtifactS3Path = f"/CopyArtifact/{PipelineName}/{Version}"
    logger.info(
        f"PipelineName: {PipelineName}, CurrentStageName: {CurrentStageName}, CopyArtifactS3Path: {CopyArtifactS3Path}")
else:
    logger.warning("Variável de ambiente 'Command' não está definida.")
    CurrentStageName = ''
    CopyArtifactS3Path = ''

# Definir lambda_list e s3_list fora dos blocos condicionais
lambda_list = json_data.get("ListLambda", [])
s3_list = json_data.get("ListS3", [])

# Processar ListLambda e ListS3
if CurrentStageName.lower() == "test":
    logger.info("CurrentStageName é 'test'. Iniciando processo de backup.")

    # Processar ListLambda
    logger.info(
        f"Iniciando processamento de ListLambda com {len(lambda_list)} recursos")

    for target_lambda in lambda_list:
        if isinstance(target_lambda, list) and len(target_lambda) == 3:
            target_lambda_name, target_region, target_account_id = target_lambda

            # Identificar o nome da fonte
            source_lambda_name = get_source_name(
                target_lambda_name, is_test_stage=True)

            # Realizar a cópia da Lambda de fonte para destino
            copy_lambda_function(source_lambda_name, target_region,
                                 target_lambda_name, target_region, target_account_id)
        else:
            logger.warning(
                f"Formato inválido encontrado em ListLambda: {target_lambda}")

    # Processar ListS3
    logger.info(
        f"Iniciando processamento de ListS3 com {len(s3_list)} buckets")

    for target_s3 in s3_list:
        if isinstance(target_s3, list) and len(target_s3) == 3:
            target_bucket_name, target_region, target_account_id = target_s3

            # Identificar o nome da fonte
            source_bucket_name = get_source_name(
                target_bucket_name, is_test_stage=True)

            # Sincronizar buckets S3 de fonte para destino
            sync_s3_buckets(source_bucket_name,
                            target_bucket_name, target_region)
        else:
            logger.warning(
                f"Formato inválido encontrado em ListS3: {target_s3}")

    # Processo de Backup
    backup_bucket_name = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
    backup_bucket_region = os.getenv('AWS_S3_BUCKET_TARGET_REGION_0')
    s3_backup_client = boto3.client(
        's3', region_name=backup_bucket_region)

    # Criar um diretório temporário para armazenar os arquivos de backup
    with tempfile.TemporaryDirectory() as backup_dir:
        logger.info(f"Diretório temporário para backup criado: {backup_dir}")

        # Diretórios para Lambdas e S3
        lambdas_dir = os.path.join(backup_dir, "Lambdas")
        s3_dir = os.path.join(backup_dir, "S3")
        os.makedirs(lambdas_dir, exist_ok=True)
        os.makedirs(s3_dir, exist_ok=True)

        # Baixar códigos das Lambdas
        logger.info("Baixando códigos das Lambdas para backup.")
        with ThreadPoolExecutor(max_workers=10) as executor:
            future_to_lambda = {
                executor.submit(download_lambda_code, target_lambda[0], target_lambda[1]): target_lambda for target_lambda in lambda_list if isinstance(target_lambda, list) and len(target_lambda) == 3
            }
            # Armazenar mapeamento de Lambda base para conteúdo do ZIP
            lambda_backup_mapping = {}
            for future in as_completed(future_to_lambda):
                result = future.result()
                if result:
                    backup_lambda_path, content, stripped_name = result
                    # Salvar o conteúdo no diretório Lambdas
                    target_path = os.path.join(backup_dir, backup_lambda_path)
                    os.makedirs(os.path.dirname(target_path), exist_ok=True)
                    with open(target_path, 'wb') as f:
                        f.write(content)
                    logger.info(f"Arquivo Lambda salvo em {target_path}")
                    # Mapear o nome base da Lambda para o conteúdo do ZIP
                    lambda_backup_mapping[stripped_name] = content

        # Baixar objetos S3
        logger.info("Baixando objetos S3 para backup.")
        with ThreadPoolExecutor(max_workers=10) as executor:
            # Coletar todos os clientes S3 por região para reutilização
            region_to_s3_client = {}
            for target_s3 in s3_list:
                if isinstance(target_s3, list) and len(target_s3) == 3:
                    target_region = target_s3[1]
                    if target_region not in region_to_s3_client:
                        region_to_s3_client[target_region] = boto3.client(
                            's3', region_name=target_region)

            future_to_s3 = {}
            for target_s3 in s3_list:
                if isinstance(target_s3, list) and len(target_s3) == 3:
                    target_bucket_name, target_region, target_account_id = target_s3

                    s3_client = region_to_s3_client.get(target_region)
                    if s3_client:
                        paginator = s3_client.get_paginator('list_objects_v2')
                        for page in paginator.paginate(Bucket=target_bucket_name):
                            for obj in page.get('Contents', []):
                                obj_key = obj['Key']
                                if obj_key.endswith('/'):
                                    logger.debug(
                                        f"Objeto {obj_key} é um diretório. Pulando.")
                                    continue  # Ignorar diretórios
                                # Remover o sufixo do bucket de destino para armazenar no backup
                                stripped_bucket_name = strip_suffix(
                                    target_bucket_name)
                                backup_s3_path = f"S3/{stripped_bucket_name}/{obj_key}"
                                future = executor.submit(
                                    download_s3_object, target_bucket_name, obj_key)
                                future_to_s3[future] = backup_s3_path

            for future in as_completed(future_to_s3):
                result = future.result()
                if result:
                    backup_s3_path, content = result
                    # Salvar o conteúdo no diretório S3 com caminho sem sufixo
                    target_path = os.path.join(backup_dir, backup_s3_path)
                    os.makedirs(os.path.dirname(target_path), exist_ok=True)
                    with open(target_path, 'wb') as f:
                        f.write(content)
                    logger.info(f"Objeto S3 salvo em {target_path}")

        # Verificar se a pasta de backup não está vazia antes de criar o ZIP
        if os.listdir(lambdas_dir) or os.listdir(s3_dir):
            logger.info(
                "Pasta de backup não está vazia. Criando e enviando arquivo ZIP.")
            # Criar arquivo ZIP da pasta de backup
            zip_buffer = create_zip_of_folder(backup_dir)

            if zip_buffer:
                # Definir chave do objeto no bucket de backup
                # Supondo que o formato de CopyArtifactS3Path seja "/CopyArtifact/PipelineName/Version"
                # Extraindo prefixo
                clean_path = CopyArtifactS3Path.lstrip('/')
                backup_object_key = f"{clean_path}/backup_{Version}.zip"

                # Fazer upload do ZIP para S3
                upload_to_s3_in_memory(
                    s3_backup_client, backup_bucket_name, backup_object_key, zip_buffer)
            else:
                logger.error(
                    "Falha ao criar o arquivo ZIP em memória. Backup não será enviado.")
        else:
            logger.info(
                "Pasta de backup está vazia. Nenhum arquivo será enviado.")

        # Fazer upload das Lambdas de destino com lógica de retry
        logger.info(
            "Iniciando upload das Lambdas de destino a partir do backup.")

        # Iterar sobre as lambdas para fazer upload
        for target_lambda in lambda_list:
            if isinstance(target_lambda, list) and len(target_lambda) == 3:
                target_lambda_name, target_region, target_account_id = target_lambda

                # Obter o conteúdo do ZIP do backup usando o nome base
                stripped_name = strip_two_suffixes(target_lambda_name)
                zip_content = lambda_backup_mapping.get(stripped_name)
                if zip_content:
                    # Fazer upload para a Lambda de destino com lógica de retry
                    upload_lambda_code(target_lambda_name,
                                       target_region, zip_content)
                else:
                    logger.warning(
                        f"Não foi encontrado o arquivo ZIP para a Lambda {stripped_name}. Upload para a Lambda {target_lambda_name} será ignorado.")
            else:
                logger.warning(
                    f"Formato inválido encontrado em ListLambda: {target_lambda}")

        logger.info("Upload das Lambdas de destino concluído.")

else:
    logger.info(
        "CurrentStageName não é 'test'. Iniciando processo de restauração a partir do backup.")

    # Definir variáveis para restauração
    backup_bucket_name = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
    backup_bucket_region = os.getenv('AWS_S3_BUCKET_TARGET_REGION_0')
    s3_backup_client = boto3.client(
        's3', region_name=backup_bucket_region)

    # Caminho local para baixar o arquivo ZIP de backup
    with tempfile.TemporaryDirectory() as restore_dir:
        backup_zip_path = os.path.join(restore_dir, 'backup.zip')
        logger.info(
            f"Diretório temporário para restauração criado: {restore_dir}")

        # Definir chave do objeto do backup
        clean_path = CopyArtifactS3Path.lstrip('/')
        backup_object_key = f"{clean_path}/backup_{Version}.zip"

        # Baixar o arquivo ZIP de backup
        download_success = download_backup_zip(
            s3_backup_client, backup_bucket_name, backup_object_key, backup_zip_path)

        if download_success:
            # Extrair o arquivo ZIP de backup
            extract_success = extract_zip(backup_zip_path, restore_dir)

            if extract_success:
                # Restaurar Lambdas
                logger.info(
                    "Iniciando restauração das Lambdas a partir do backup.")
                # Carregar novamente o mapeamento de backup após extrair
                # Neste contexto, assumimos que os arquivos ZIP das Lambdas estão em restore_dir/Lambdas/
                lambda_backup_mapping = {}
                lambdas_backup_path = os.path.join(restore_dir, "Lambdas")
                if os.path.exists(lambdas_backup_path):
                    for file in os.listdir(lambdas_backup_path):
                        if file.endswith('.zip'):
                            lambda_name = file.replace('.zip', '')
                            file_path = os.path.join(lambdas_backup_path, file)
                            with open(file_path, 'rb') as f:
                                content = f.read()
                            lambda_backup_mapping[lambda_name] = content
                            logger.info(
                                f"Arquivo Lambda {file} carregado para restauração.")
                else:
                    logger.warning(
                        f"Nenhum arquivo Lambda encontrado no backup.")

                # Fazer upload para as Lambdas de destino
                logger.info(
                    "Iniciando upload das Lambdas de destino a partir do backup.")
                for target_lambda in lambda_list:
                    if isinstance(target_lambda, list) and len(target_lambda) == 3:
                        target_lambda_name, target_region, target_account_id = target_lambda

                        # Obter o conteúdo do ZIP do backup usando o nome base
                        stripped_name = strip_two_suffixes(target_lambda_name)
                        zip_content = lambda_backup_mapping.get(stripped_name)
                        if zip_content:
                            # Fazer upload para a Lambda de destino com lógica de retry
                            upload_lambda_code(
                                target_lambda_name, target_region, zip_content)
                        else:
                            logger.warning(
                                f"Não foi encontrado o arquivo ZIP para a Lambda {stripped_name}. Upload para a Lambda {target_lambda_name} será ignorado.")
                    else:
                        logger.warning(
                            f"Formato inválido encontrado em ListLambda: {target_lambda}")

                logger.info("Restauração das Lambdas concluída.")

                # Restaurar S3
                logger.info(
                    "Iniciando restauração dos objetos S3 a partir do backup.")
                for target_s3 in s3_list:
                    if isinstance(target_s3, list) and len(target_s3) == 3:
                        # Restaurar objetos S3 para o bucket de destino
                        upload_s3_from_backup(restore_dir, target_s3)
                    else:
                        logger.warning(
                            f"Formato inválido encontrado em ListS3: {target_s3}")

                logger.info("Restauração dos objetos S3 concluída.")
            else:
                logger.error(
                    "Falha ao extrair o arquivo ZIP de backup. Restauração abortada.")
        else:
            logger.error(
                "Falha ao baixar o arquivo ZIP de backup. Restauração abortada.")

    logger.info("Processo de restauração concluído.")

logger.info("Script finalizado.")
