# Copy.py 1.0.0
import boto3
import os
import json
import logging
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuração do logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
        zip_file_path = '/tmp/lambda_code.zip'
        with open(zip_file_path, 'wb') as f:
            f.write(response.content)

        logger.info(
            f"Código da Lambda {source_lambda_name} baixado com sucesso")

        # Atualizar a Lambda de destino com o código baixado
        with open(zip_file_path, 'rb') as f:
            target_client.update_function_code(
                FunctionName=target_lambda_name,
                ZipFile=f.read()
            )

        logger.info(
            f"Código da Lambda {target_lambda_name} atualizado com sucesso")

        # Limpar o arquivo temporário
        os.remove(zip_file_path)

        logger.info(f"Arquivo temporário removido: {zip_file_path}")
    except Exception as e:
        logger.error(
            f"Erro ao copiar a Lambda {source_lambda_name} para {target_lambda_name}: {e}")

# Função para copiar um objeto S3


def copy_s3_object(s3_client, source_bucket_name, target_bucket_name, obj_key):
    try:
        logger.info(
            f"Iniciando cópia do objeto {obj_key} de {source_bucket_name} para {target_bucket_name}")

        copy_source = {'Bucket': source_bucket_name, 'Key': obj_key}
        s3_client.copy(copy_source, target_bucket_name, obj_key)

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
    json_data = []

# Processar ListLambda
lambda_list = json_data.get("ListLambda", [])
logger.info(
    f"Iniciando processamento de ListLambda com {len(lambda_list)} pares")

for pair in lambda_list:
    if len(pair) == 2:
        source = pair[0]
        target = pair[1]

        source_lambda_name, source_region, source_account_id = source
        target_lambda_name, target_region, target_account_id = target

        copy_lambda_function(source_lambda_name, source_region,
                             target_lambda_name, target_region, source_account_id)
    else:
        logger.warning(f"Par inválido encontrado em ListLambda: {pair}")

# Processar ListS3
s3_list = json_data.get("ListS3", [])
logger.info(f"Iniciando processamento de ListS3 com {len(s3_list)} pares")

for pair in s3_list:
    if len(pair) == 2:
        source = pair[0]
        target = pair[1]

        source_bucket_name, source_region, source_account_id = source
        target_bucket_name, target_region, target_account_id = target

        sync_s3_buckets(source_bucket_name, target_bucket_name, source_region)
    else:
        logger.warning(f"Par inválido encontrado em ListS3: {pair}")

