import os
import json
import boto3
import re
import logging
import subprocess
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuração do logger
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Lista para manter o rastreamento de arquivos já copiados
copied_files = set()

# Função para apagar arquivos de um prefixo em um bucket S3


def delete_files_with_prefix(bucket_name, prefix):
    s3 = boto3.resource('s3')
    bucket = s3.Bucket(bucket_name)

    # Apaga todos os objetos com o prefixo fornecido
    bucket.objects.filter(Prefix=prefix).delete()
    logger.info(
        f"Todos os arquivos sob o prefixo {prefix} foram apagados do bucket {bucket_name}.")


# Função para listar arquivos em um bucket S3
def list_s3_files(bucket_name, prefix):
    s3_client = boto3.client('s3')
    try:
        response = s3_client.list_objects_v2(Bucket=bucket_name, Prefix=prefix)
        if 'Contents' in response:
            for item in response['Contents']:
                logger.info(f"Arquivo no S3: {item['Key']}")
        else:
            logger.info("Nenhum arquivo encontrado no S3.")
    except Exception as e:
        logger.error(f"Erro ao listar arquivos no S3: {e}")

# Função para listar arquivos em um diretório local


def list_directory_files(directory):
    logger.info(f"Listando arquivos no diretório: {directory}")
    for root, dirs, files in os.walk(directory):
        for name in files:
            logger.info(f"Arquivo: {os.path.join(root, name)}")
        for name in dirs:
            logger.info(f"Diretório: {os.path.join(root, name)}")

# Função para sincronizar o lockfile do Terraform do S3 para o diretório local


def sync_lockfile_from_s3(state_name, bucket_name, local_dir_path):
    local_lockfile_path = os.path.join(local_dir_path, '.terraform.lock.hcl')
    s3_lockfile_path = f"states/{state_name}/terraform.lock.hcl"
    s3_client = boto3.client('s3')

    # Listar arquivos no S3 antes da sincronização
    list_s3_files(bucket_name, s3_lockfile_path)

    logger.info(f"Sincronizando lockfile do S3 para {local_lockfile_path}")
    try:
        s3_client.download_file(
            bucket_name, s3_lockfile_path, local_lockfile_path)
        logger.info(f"Lockfile {s3_lockfile_path} sincronizado com sucesso.")
    except Exception as e:
        logger.error(f"Erro ao sincronizar o lockfile {s3_lockfile_path}: {e}")

    # Listar arquivos locais após a sincronização
    list_directory_files(local_dir_path)

# Função para sincronizar o lockfile do Terraform do diretório local para o S3


def sync_lockfile_to_s3(state_name, bucket_name, local_dir_path):
    local_lockfile_path = os.path.join(local_dir_path, '.terraform.lock.hcl')
    s3_lockfile_path = f"states/{state_name}/terraform.lock.hcl"
    s3_client = boto3.client('s3')

    # Listar arquivos locais antes do upload
    list_directory_files(local_dir_path)

    logger.info(
        f"Sincronizando lockfile {local_lockfile_path} de volta para o S3.")
    try:
        s3_client.upload_file(local_lockfile_path,
                              bucket_name, s3_lockfile_path)
        logger.info(f"Lockfile {s3_lockfile_path} sincronizado com sucesso.")
    except Exception as e:
        logger.error(
            f"Erro ao sincronizar o lockfile {local_lockfile_path} de volta para o S3: {e}")

# Função para copiar uma função Lambda e salvar no diretório temporário


def copy_lambda_function(source_lambda_name, source_region, target_lambda_name, target_region, bucket_name, is_test, PipelineName):
    source_client = boto3.client('lambda', region_name=source_region)
    target_client = boto3.client('lambda', region_name=target_region)
    s3_client = boto3.client('s3')

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
        zip_file_path = '/tmp/lambda_code.zip'
        with open(zip_file_path, 'wb') as f:
            f.write(response.content)

        logger.info(
            f"Código da Lambda {source_lambda_name} baixado com sucesso")

        if is_test:
            # Salvar o código baixado no diretório temporário no bucket
            temp_s3_path = f"temp/{PipelineName}/{target_lambda_name}.zip"
            s3_client.upload_file(zip_file_path, bucket_name, temp_s3_path)
            logger.info(
                f"Código da Lambda {source_lambda_name} salvo temporariamente em {temp_s3_path} no bucket {bucket_name}")

        # Atualizar a Lambda de destino com o código baixado
        with open(zip_file_path, 'rb') as f:
            target_client.update_function_code(
                FunctionName=target_lambda_name, ZipFile=f.read())
        logger.info(
            f"Código da Lambda {target_lambda_name} atualizado com sucesso")
        # Limpar o arquivo temporário
        os.remove(zip_file_path)
        logger.info(f"Arquivo temporário removido: {zip_file_path}")
    except Exception as e:
        logger.error(
            f"Erro ao copiar a Lambda {source_lambda_name} para {target_lambda_name}: {e}")
# Função para copiar um objeto S3 e salvar no diretório temporário


def copy_s3_bucket(s3_client, source_bucket_name, target_bucket_name, bucket_name, PipelineName, is_test):
    try:
        logger.info(
            f"Iniciando a cópia do conteúdo de {source_bucket_name}")
        # Listar todos os objetos no bucket de origem
        response = s3_client.list_objects_v2(Bucket=source_bucket_name)
        objects = response.get('Contents', [])
        for obj in objects:
            obj_key = obj['Key']
            if is_test:
                # Copiar o objeto para o diretório temporário no bucket destino
                temp_s3_path = f"temp/{PipelineName}/{target_bucket_name}/{obj_key}"
                s3_client.copy({'Bucket': source_bucket_name,
                               'Key': obj_key}, bucket_name, temp_s3_path)
                logger.info(
                    f"Objeto {obj_key} copiado para o caminho temporário {temp_s3_path} no bucket {bucket_name}")
            # Copiar o objeto diretamente para o bucket destino
            s3_client.copy({'Bucket': source_bucket_name,
                            'Key': obj_key}, target_bucket_name, obj_key)
            logger.info(
                f"Objeto {obj_key} copiado com sucesso para {target_bucket_name}")
    except Exception as e:
        logger.error(
            f"Erro ao copiar o conteúdo do bucket {source_bucket_name}: {e}")

# Função para executar comandos do Terraform


def execute_terraform_command(command_type):
    max_attempts = 2
    attempt = 0
    while attempt < max_attempts:
        try:
            attempt += 1
            logger.info(
                f"Tentativa {attempt} de executar 'terraform {command_type}'...")
            process = subprocess.Popen(
                ["terraform", command_type, "-input=false", "-auto-approve"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            # Exibe a saída em tempo real
            for line in iter(process.stdout.readline, ''):
                if line:
                    logger.info(line.strip())
            process.stdout.close()
            return_code = process.wait()
            if return_code == 0:
                logger.info(
                    f"'terraform {command_type}' executado com sucesso.")
                break  # Sai do loop se a execução for bem-sucedida
            else:
                raise subprocess.CalledProcessError(return_code, process.args)
        except subprocess.CalledProcessError as e:
            logger.error(f"Erro ao executar 'terraform {command_type}': {e}")
            logger.error(e.output)
            if attempt < max_attempts:
                logger.info(
                    "Tentando novamente com 'terraform init' antes da nova tentativa...")
                run_terraform_init()
            else:
                logger.error(
                    f"Falhou após {max_attempts} tentativas. Abortando.")
                sys.exit(1)  # Falha após exceder o número de tentativas


def run_terraform_init():
    process = subprocess.Popen(
        ["terraform", "init", "-reconfigure"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )

    for line in iter(process.stdout.readline, ''):
        if line:
            logger.info(line.strip())

    process.stdout.close()
    return_code = process.wait()

    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, process.args)

    logger.info("'terraform init' executado com sucesso.")

# Função para modificar e baixar arquivos do S3


def modify_and_download_files(file_path, s3_bucket):
    with open(file_path, 'r') as file:
        content = file.read()

    local_files = re.findall(r'C:/[^"]+', content)

    s3_client = boto3.client('s3')

    for local_file in local_files:
        relative_path = os.path.relpath(local_file, 'C:/')
        local_tmp_path = os.path.join('/tmp', relative_path)
        os.makedirs(os.path.dirname(local_tmp_path), exist_ok=True)

        if local_file not in copied_files:
            s3_key = relative_path.replace("\\", "/")
            try:
                s3_client.download_file(s3_bucket, s3_key, local_tmp_path)
                copied_files.add(local_file)
            except Exception as e:
                logger.error(
                    f"Erro ao baixar o arquivo do S3 (bucket={s3_bucket}, key={s3_key}): {e}")

        content = content.replace(local_file, local_tmp_path)

    with open(file_path, 'w') as file:
        file.write(content)

# Função para processar e executar comandos Terraform em arquivos do S3


def download_and_process_files(bucket_name, json_data, command_type, is_test):
    logger.info(
        f"Iniciando o processamento dos arquivos para o bucket: {bucket_name} com o path: '/states/'")

    s3 = boto3.client('s3')

    for state_name in json_data:
        logger.info(f"Processando estado: {state_name}")
        s3_path = f"states/{state_name}/"

        local_dir_path = os.path.join(os.getcwd(), state_name)
        os.makedirs(local_dir_path, exist_ok=True)

        sync_lockfile_from_s3(state_name, bucket_name, local_dir_path)

        file_name = "main.tf"
        s3_file_path = os.path.join(s3_path, file_name)
        local_file_path = os.path.join(local_dir_path, file_name)

        try:
            logger.info(f"Baixando {s3_file_path} de {bucket_name}...")
            s3.download_file(bucket_name, s3_file_path, local_file_path)
            logger.info(f"Download de {file_name} concluído com sucesso.")

            modify_and_download_files(local_file_path, bucket_name)

            os.chdir(local_dir_path)
            execute_terraform_command(command_type)
            os.chdir('..')

            sync_lockfile_to_s3(state_name, bucket_name, local_dir_path)

        except Exception as err:
            logger.error(f"Erro ao acessar o arquivo {file_name}: {err}")


bucket_name = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
logger.info(f"Nome do bucket obtido da variável de ambiente: {bucket_name}")

if not bucket_name:
    raise EnvironmentError(
        "Variável de ambiente 'AWS_S3_BUCKET_TARGET_NAME_0' não encontrada.")

command = os.getenv('Command')
logger.info(f"Comando obtido da variável de ambiente: {command}")

if not command:
    raise EnvironmentError("Variável de ambiente 'Command' não encontrada.")

command_array = command.split(',')
command_type = command_array[0]
path = command_array[1]
logger.info(f"Tipo de comando: {command_type}, Caminho: {path}")

# Extrair a segunda parte do path
path_parts = path.split('/')
PipelineName = path_parts[1] if len(path_parts) > 1 else ''
CurrentStageName = path_parts[2] if len(path_parts) > 1 else ''
local_file_path = os.path.join(os.getcwd(), 'List.txt')

try:
    with open(local_file_path, 'r', encoding='utf-8') as file:
        file_content = file.read()
    json_data = json.loads(file_content)
except Exception as err:
    logger.error(f"Erro ao acessar ou processar o arquivo List.txt: {err}")
    json_data = []
logger.info("json_data", json_data)
ListStates = json_data.get("ListStates", [])
ListStatesBlue = json_data.get("ListStatesBlue", [])
Approved = json_data.get("Approved", False)
IsTest = json_data.get("IsTest", False)
NextTestStageName = json_data.get("NextTestStageName", False)
IsNextTest = NextTestStageName == CurrentStageName
lambda_list = json_data.get("ListLambda", [])
s3_list = json_data.get("ListS3", [])
logger.info(f"Lists: {ListStates} {ListStatesBlue} {IsTest}")

if command_type == "destroy":
    if IsTest:
        logger.info(f"Inverteu lista")
        ListStates.reverse()
    else:
        ListStates = ListStatesBlue
        ListStates.reverse()

logger.info(f"Conteúdo de List.txt convertido em JSON:\n{ListStates}")

if len(ListStates) > 0:
    download_and_process_files(bucket_name, ListStates, command_type, IsTest)

if command_type == "destroy":
    if Approved:
        if IsNextTest:
            # Apagar todos os arquivos do diretório temp/PipelineName
            temp_prefix = "temp"
            delete_files_with_prefix(bucket_name, f"temp/{PipelineName}")
    else:
        logger.info("Intentional error in the build: test was rejected")
        sys.exit(1)

if command_type == "apply":
    if IsNextTest:
        # Copiar os arquivos do diretório temp/PipelineName ao invés das cópias da lambda ou S3 fonte
        temp_prefix = "temp"
        logger.info(
            f"Copiando arquivos do prefixo temporário {temp_prefix}/{PipelineName} para o destino.")
        # Processar ListLambda
        for pair in lambda_list:
            if len(pair) == 2:
                source_lambda_name, source_region, source_account_id = pair[0]
                target_lambda_name, target_region, target_account_id = pair[1]
                # Usando a região do source
                s3_client = boto3.client('s3', region_name=source_region)
                # Usando o nome do source
                temp_s3_path = f"temp/{PipelineName}/{source_lambda_name}.zip"

                # Baixar do prefixo temporário e aplicar na Lambda de destino
                temp_file_path = '/tmp/temp_lambda_code.zip'
                s3_client.download_file(
                    bucket_name, temp_s3_path, temp_file_path)
                with open(temp_file_path, 'rb') as f:
                    target_client = boto3.client(
                        'lambda', region_name=target_region)
                    target_client.update_function_code(
                        FunctionName=target_lambda_name, ZipFile=f.read())
                logger.info(
                    f"Código da Lambda {target_lambda_name} atualizado com sucesso a partir do prefixo temporário.")
                # Limpar o arquivo temporário
                os.remove(temp_file_path)
            else:
                logger.warning(
                    f"Par inválido encontrado em ListLambda: {pair}")
        # Processar ListS3
        for pair in s3_list:
            if len(pair) == 2:
                source_bucket_name, source_region, source_account_id = pair[0]
                target_bucket_name, target_region, target_account_id = pair[1]

                # Usando a região do source
                s3_client = boto3.client('s3', region_name=source_region)

                # Definir o prefixo temporário
                temp_s3_path = f"temp/{PipelineName}/{source_bucket_name}"

                # Listar todos os objetos no prefixo temporário
                response = s3_client.list_objects_v2(
                    Bucket=bucket_name, Prefix=temp_s3_path)
                objects = response.get('Contents', [])

                for obj in objects:
                    obj_key = obj['Key']

                    # Definir o caminho do objeto na raiz do bucket de destino
                    target_key = obj_key.replace(temp_s3_path + '/', '', 1)

                    # Copiar o objeto para o bucket de destino
                    copy_source = {'Bucket': bucket_name, 'Key': obj_key}
                    s3_client.copy(copy_source, target_bucket_name, target_key)
                    logger.info(
                        f"Objeto {obj_key} copiado com sucesso do prefixo temporário para a raiz do bucket {target_bucket_name}.")
            else:
                logger.warning(f"Par inválido encontrado em s3_list: {pair}")
    else:
        logger.info(
            "Executando o comando 'apply' e processando ListLambda e ListS3")
        temp_prefix = "temp"
        # Processar ListLambda
        logger.info(
            f"Iniciando processamento de ListLambda com {len(lambda_list)} pares")
        for pair in lambda_list:
            if len(pair) == 2:
                source = pair[0]
                target = pair[1]
                source_lambda_name, source_region, source_account_id = source
                target_lambda_name, target_region, target_account_id = target
                copy_lambda_function(source_lambda_name, source_region,
                                     target_lambda_name, target_region, bucket_name, IsTest, PipelineName)
            else:
                logger.warning(
                    f"Par inválido encontrado em ListLambda: {pair}")
        # Processar ListS3
        logger.info(
            f"Iniciando processamento de ListS3 com {len(s3_list)} pares")
        for pair in s3_list:
            if len(pair) == 2:
                source = pair[0]
                target = pair[1]
                source_bucket_name, source_region, source_account_id = source
                target_bucket_name, target_region, target_account_id = target
                copy_s3_bucket(boto3.client('s3', region_name=source_region),
                               source_bucket_name, target_bucket_name, bucket_name, PipelineName, IsTest)
            else:
                logger.warning(f"Par inválido encontrado em ListS3: {pair}")
