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
import time
import mimetypes

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


# Função para copiar um objeto S3 preservando metadados
def copy_s3_object(s3_client, source_bucket_name, target_bucket_name, obj_key):
    try:
        logger.info(
            f"Iniciando cópia do objeto {obj_key} de {source_bucket_name} para {target_bucket_name}")

        # Obter os metadados do objeto de origem
        head_object = s3_client.head_object(
            Bucket=source_bucket_name, Key=obj_key)
        metadata = head_object.get('Metadata', {})
        content_type = head_object.get('ContentType')

        copy_source = {'Bucket': source_bucket_name, 'Key': obj_key}

        # Preparar ExtraArgs para preservar os metadados
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


# Função para baixar o código de uma Lambda
def download_lambda_code(target_lambda_name, source_region, backup_dir):
    source_client = boto3.client('lambda', region_name=source_region)
    try:
        logger.info(
            f"Baixando código da Lambda {target_lambda_name} da região {source_region}")
        response = source_client.get_function(FunctionName=target_lambda_name)
        code_url = response['Code']['Location']
        response = requests.get(code_url)
        logger.info(
            f"Código da Lambda {target_lambda_name} baixado com sucesso")

        # Identificar o nome original da Lambda (assumindo que 'target_lambda_name' já é o nome de destino)
        source_lambda_name = get_source_name(
            target_lambda_name, is_test_stage=True)

        # Salvar o nome original no mapeamento
        mapping = {}
        mapping_path = os.path.join(backup_dir, "lambda_mapping.json")
        if os.path.exists(mapping_path):
            with open(mapping_path, 'r') as map_file:
                mapping = json.load(map_file)

        mapping[target_lambda_name] = source_lambda_name

        with open(mapping_path, 'w') as map_file:
            json.dump(mapping, map_file, indent=4)
        logger.info(f"Mapeamento salvo em {mapping_path}")

        # Salvar o conteúdo no diretório Lambdas com o nome original
        backup_lambda_path = f"Lambdas/{source_lambda_name}.zip"
        return (backup_lambda_path, response.content, source_lambda_name)
    except Exception as e:
        logger.error(
            f"Erro ao baixar código da Lambda {target_lambda_name}: {e}")
        return None


# Função para baixar um objeto S3 e salvar metadados
def download_s3_object(bucket_name, obj_key, s3_client, backup_dir):
    try:
        logger.info(f"Baixando objeto {obj_key} do bucket {bucket_name}")
        response = s3_client.get_object(Bucket=bucket_name, Key=obj_key)
        content = response['Body'].read()
        logger.info(f"Objeto {obj_key} baixado com sucesso")

        # Obter metadados do objeto
        metadata = response.get('Metadata', {})
        content_type = response.get('ContentType')

        # Remover o sufixo do bucket para salvar no backup
        stripped_bucket_name = strip_suffix(bucket_name)
        backup_s3_path = f"S3/{stripped_bucket_name}/{obj_key}"

        # Salvar o conteúdo no backup
        target_path = os.path.join(backup_dir, backup_s3_path)
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        with open(target_path, 'wb') as f:
            f.write(content)
        logger.info(f"Objeto S3 salvo em {target_path}")

        # Salvar metadados em um arquivo JSON
        metadata_path = f"{target_path}.metadata.json"
        with open(metadata_path, 'w') as meta_file:
            json.dump({
                'ContentType': content_type,
                'Metadata': metadata
            }, meta_file)
        logger.info(f"Metadados do objeto {obj_key} salvos em {metadata_path}")

        return True
    except Exception as e:
        logger.error(
            f"Erro ao baixar objeto {obj_key} do bucket {bucket_name}: {e}")
        return False


# Função para criar um arquivo ZIP de uma pasta
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


# Função para extrair um arquivo ZIP
def extract_zip(zip_path, extract_to):
    """
    Extrai o conteúdo do arquivo ZIP para o diretório especificado.
    """
    try:
        logger.info(f"Extraindo arquivo ZIP {zip_path} para {extract_to}")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            zip_ref.extractall(extract_to)
        logger.info(
            f"Arquivo ZIP {zip_path} extraído com sucesso para {extract_to}")
        return True
    except Exception as e:
        logger.error(f"Erro ao extrair o arquivo ZIP {zip_path}: {e}")
        return False


# Função para fazer upload de um arquivo ZIP para o S3
def upload_to_s3_in_memory(s3_client, bucket_name, object_key, zip_buffer):
    try:
        logger.info(
            f"Fazendo upload do arquivo ZIP para s3://{bucket_name}/{object_key}")
        s3_client.upload_fileobj(zip_buffer, bucket_name, object_key)
        logger.info(
            f"Arquivo ZIP enviado com sucesso para s3://{bucket_name}/{object_key}")
    except Exception as e:
        logger.error(f"Erro ao fazer upload do arquivo ZIP para S3: {e}")


# Função para fazer upload do código de uma Lambda com tentativas de retry
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
            wait_time = 2 ** attempt  # Espera exponencial
            logger.warning(
                f"ResourceConflictException ao atualizar a Lambda {target_lambda_name}: {e}. Tentando novamente em {wait_time} segundos...")
            time.sleep(wait_time)
        except Exception as e:
            logger.error(
                f"Erro ao fazer upload do código para a Lambda {target_lambda_name}: {e}")
            break  # Para outras exceções, não tentar novamente
    logger.error(
        f"Falha ao atualizar a Lambda {target_lambda_name} após {max_retries} tentativas.")


# Função para fazer upload de objetos S3 a partir do backup, preservando metadados
def upload_s3_from_backup(extracted_backup_dir, target_s3):
    logger.info("Iniciando a função 'upload_s3_from_backup'.")

    if len(target_s3) != 3:
        logger.warning(f"Par inválido encontrado em ListS3: {target_s3}")
        return

    target_bucket_name, target_region, target_account_id = target_s3
    stripped_bucket_name = strip_two_suffixes(target_bucket_name)
    backup_s3_path = f"S3/{stripped_bucket_name}"
    backup_s3_full_path = os.path.join(extracted_backup_dir, backup_s3_path)

    if not os.path.exists(backup_s3_full_path):
        logger.warning(
            f"Diretório de backup para o bucket S3 '{stripped_bucket_name}' não existe em '{backup_s3_full_path}'. Upload será ignorado.")
        return

    try:
        s3_client = boto3.client('s3', region_name=target_region)
        logger.info(
            f"Cliente S3 inicializado para a região '{target_region}'.")
    except Exception as e:
        logger.error(
            f"Falha ao inicializar o cliente S3 para a região '{target_region}': {e}")
        return

    for root, dirs, files in os.walk(backup_s3_full_path):
        for file in files:
            if file.endswith('.metadata.json'):
                continue  # Ignorar arquivos de metadados
            file_path = os.path.join(root, file)
            relative_path = os.path.relpath(
                file_path, start=backup_s3_full_path)
            obj_key = relative_path.replace(os.path.sep, '/')

            # Obter Content-Type e Metadados do arquivo de metadados correspondente
            metadata_file_path = f"{file_path}.metadata.json"
            if os.path.exists(metadata_file_path):
                with open(metadata_file_path, 'r') as meta_file:
                    metadata = json.load(meta_file)
                content_type = metadata.get(
                    'ContentType', 'binary/octet-stream')
                extra_args = {
                    'ContentType': content_type,
                    'Metadata': metadata.get('Metadata', {})
                }
            else:
                # Se não houver arquivo de metadados, usar mimetypes
                content_type, _ = mimetypes.guess_type(file_path)
                if content_type is None:
                    content_type = 'binary/octet-stream'
                extra_args = {'ContentType': content_type}

            logger.info(
                f"Iniciando upload do objeto '{obj_key}' para o bucket '{target_bucket_name}' com Content-Type '{extra_args.get('ContentType')}'.")

            try:
                with open(file_path, 'rb') as data:
                    s3_client.upload_fileobj(
                        data,
                        target_bucket_name,
                        obj_key,
                        ExtraArgs=extra_args
                    )
                logger.info(
                    f"Objeto '{obj_key}' enviado com sucesso para o bucket '{target_bucket_name}'.")
            except Exception as e:
                logger.error(
                    f"Erro ao enviar o objeto '{obj_key}' para o bucket '{target_bucket_name}': {e}")
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
                executor.submit(download_lambda_code, target_lambda[0], target_lambda[1], backup_dir): target_lambda for target_lambda in lambda_list if isinstance(target_lambda, list) and len(target_lambda) == 3
            }
            # Armazenar mapeamento de Lambda base para conteúdo do ZIP
            lambda_backup_mapping = {}
            for future in as_completed(future_to_lambda):
                result = future.result()
                if result:
                    backup_lambda_path, content, source_name = result
                    # Salvar o conteúdo no diretório Lambdas com o nome original
                    target_path = os.path.join(backup_dir, backup_lambda_path)
                    os.makedirs(os.path.dirname(target_path), exist_ok=True)
                    with open(target_path, 'wb') as f:
                        f.write(content)
                    logger.info(f"Arquivo Lambda salvo em {target_path}")
                    # Mapear o nome de destino para o conteúdo do ZIP
                    lambda_backup_mapping[source_name] = content

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

            futures = []
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
                                futures.append(executor.submit(
                                    download_s3_object, target_bucket_name, obj_key, s3_client, backup_dir))

            # Aguardar a conclusão de todas as tarefas
            for future in as_completed(futures):
                future.result()  # Levanta exceções, se houver

        # Verificar se a pasta de backup não está vazia antes de criar o ZIP
        if os.listdir(lambdas_dir) or os.listdir(s3_dir):
            logger.info(
                "Pasta de backup não está vazia. Criando e enviando arquivo ZIP.")
            # Criar arquivo ZIP da pasta de backup
            zip_buffer = create_zip_of_folder(backup_dir)

            if zip_buffer:
                # Definir chave do objeto no bucket de backup
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

                # Obter o nome original da Lambda a partir do mapeamento
                # Carregar o mapeamento de Lambdas
                mapping_path = os.path.join(backup_dir, "lambda_mapping.json")
                if os.path.exists(mapping_path):
                    with open(mapping_path, 'r') as map_file:
                        lambda_mapping = json.load(map_file)
                    logger.info(
                        f"Mapeamento de Lambdas carregado de {mapping_path}")
                else:
                    logger.error(
                        f"Arquivo de mapeamento {mapping_path} não encontrado. Upload das Lambdas será ignorado.")
                    lambda_mapping = {}

                source_lambda_name = lambda_mapping.get(target_lambda_name)
                if source_lambda_name:
                    # Caminho do arquivo ZIP correspondente
                    zip_file_path = os.path.join(
                        backup_dir, "Lambdas", f"{source_lambda_name}.zip")
                    if os.path.exists(zip_file_path):
                        with open(zip_file_path, 'rb') as f:
                            zip_content = f.read()
                        # Fazer upload para a Lambda de destino com lógica de retry
                        upload_lambda_code(
                            target_lambda_name, target_region, zip_content)
                    else:
                        logger.warning(
                            f"Arquivo de backup {zip_file_path} não encontrado para a Lambda {target_lambda_name}. Upload será ignorado.")
                else:
                    logger.warning(
                        f"Não foi encontrado o mapeamento para a Lambda {target_lambda_name}. Upload será ignorado.")
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
        try:
            s3_backup_client.download_file(
                backup_bucket_name, backup_object_key, backup_zip_path)
            download_success = True
            logger.info(
                f"Arquivo ZIP de backup baixado com sucesso de s3://{backup_bucket_name}/{backup_object_key}")
        except Exception as e:
            logger.error(
                f"Falha ao baixar o arquivo ZIP de backup de s3://{backup_bucket_name}/{backup_object_key}: {e}")
            download_success = False

        if download_success:
            # Extrair o arquivo ZIP de backup
            extract_success = extract_zip(backup_zip_path, restore_dir)

            if extract_success:
                # Restaurar Lambdas
                logger.info(
                    "Iniciando restauração das Lambdas a partir do backup.")
                # Carregar novamente o mapeamento de backup após extrair
                lambda_backup_mapping = {}
                mapping_path = os.path.join(restore_dir, "lambda_mapping.json")
                if os.path.exists(mapping_path):
                    with open(mapping_path, 'r') as map_file:
                        lambda_backup_mapping = json.load(map_file)
                    logger.info(
                        f"Mapeamento de Lambdas carregado de {mapping_path}")
                else:
                    logger.error(
                        f"Arquivo de mapeamento {mapping_path} não encontrado. Restauração das Lambdas será ignorada.")

                # Fazer upload para as Lambdas de destino
                logger.info(
                    "Iniciando upload das Lambdas de destino a partir do backup.")
                for target_lambda in lambda_list:
                    if isinstance(target_lambda, list) and len(target_lambda) == 3:
                        target_lambda_name, target_region, target_account_id = target_lambda

                        # Obter o nome original da Lambda a partir do mapeamento
                        source_lambda_name = lambda_backup_mapping.get(
                            target_lambda_name)
                        if source_lambda_name:
                            # Caminho do arquivo ZIP correspondente
                            zip_file_path = os.path.join(
                                restore_dir, "Lambdas", f"{source_lambda_name}.zip")
                            if os.path.exists(zip_file_path):
                                with open(zip_file_path, 'rb') as f:
                                    zip_content = f.read()
                                # Fazer upload para a Lambda de destino com lógica de retry
                                upload_lambda_code(
                                    target_lambda_name, target_region, zip_content)
                            else:
                                logger.warning(
                                    f"Arquivo de backup {zip_file_path} não encontrado para a Lambda {target_lambda_name}. Upload será ignorado.")
                        else:
                            logger.warning(
                                f"Não foi encontrado o mapeamento para a Lambda {target_lambda_name}. Upload será ignorado.")
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
