# TerraBatch.py (Versão 2.2.0 - Completa e Unificada)
# Este script orquestra todo o processo de deploy do backend, incluindo
# a gestão de snapshots de artefatos e a execução do Terraform.
# Ele foi projetado para ser um único ponto de controle, substituindo o antigo Copy.py.

import os
import json
import logging
import subprocess
import sys
import boto3
import zipfile
import shutil
import requests
from botocore.exceptions import ClientError

# --- CONFIGURAÇÃO INICIAL E CONSTANTES ---
ARTIFACTS_DIR = '/tmp/artifacts'
SNAPSHOTS_DIR = '/tmp/snapshots'

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

# --- LEITURA DE VARIÁVEIS DE AMBIENTE E MANIFESTO ---
bucket_name = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
bucket_region = os.getenv('AWS_S3_BUCKET_TARGET_REGION_0')
build_id = os.getenv('CODEBUILD_BUILD_ID')
table_name = os.getenv('AWS_DYNAMODB_TABLE_TARGET_NAME_0')
dynamo_region = os.getenv('AWS_DYNAMODB_TABLE_TARGET_REGION_0')
user_id = os.getenv('USER_ID')
command = os.getenv('Command')

s3_client = boto3.client('s3', region_name=bucket_region)

if not all([bucket_name, command]):
    raise EnvironmentError("Variáveis de ambiente essenciais (AWS_S3_BUCKET_TARGET_NAME_0, Command) não foram encontradas.")

command_array = command.split(',')
command_type = command_array[0]
path = command_array[1] if len(command_array) > 1 else ''
logger.info(f"Comando: {command_type}, Caminho: {path}")

try:
    with open('List.txt', 'r', encoding='utf-8') as file:
        json_data = json.load(file)
    logger.info("Arquivo List.txt lido e parseado com sucesso.")
except Exception as err:
    logger.error(f"Erro crítico ao acessar ou processar List.txt: {err}")
    sys.exit(1)

Version = json_data.get("Version")
IsTest = json_data.get("IsTest", False)
Approved = json_data.get("Approved", False)

ArtifactsBucket = json_data.get("ArtifactsBucket")
if not ArtifactsBucket:
    logger.info("'ArtifactsBucket' não encontrado no List.txt. Usando fallback para a variável de ambiente 'AWS_S3_BUCKET_TARGET_NAME_0'.")
    ArtifactsBucket = bucket_name

# --- FUNÇÕES AUXILIARES COMPLETAS PARA GERENCIAMENTO DE ARTEFATOS ---

def _clear_dir(directory):
    """Limpa e recria um diretório de forma segura."""
    if os.path.exists(directory):
        shutil.rmtree(directory)
    os.makedirs(directory)
    logger.info(f"Diretório limpo e recriado: {directory}")

def _download_lambda_code(lambda_name, region, dest_path):
    """Baixa o código-fonte de uma função Lambda para um caminho local."""
    try:
        logger.info(f"Baixando código da Lambda '{lambda_name}' da região '{region}'...")
        lambda_client = boto3.client('lambda', region_name=region)
        response = lambda_client.get_function(FunctionName=lambda_name)
        code_url = response['Code']['Location']
        
        r = requests.get(code_url, stream=True)
        r.raise_for_status()
        
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        with open(dest_path, 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
        logger.info(f"Código da Lambda '{lambda_name}' salvo em '{dest_path}'.")
    except Exception as e:
        logger.error(f"Falha ao baixar código da Lambda '{lambda_name}': {e}")
        raise

def _sync_s3_to_local(bucket, region, dest_path):
    """Baixa o conteúdo de um bucket S3 para um diretório local."""
    try:
        logger.info(f"Sincronizando bucket S3 '{bucket}' para '{dest_path}'...")
        s3_resource = boto3.resource('s3', region_name=region)
        bucket_obj = s3_resource.Bucket(bucket)
        for obj in bucket_obj.objects.all():
            local_file_path = os.path.join(dest_path, obj.key)
            os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
            bucket_obj.download_file(obj.key, local_file_path)
        logger.info(f"Conteúdo do bucket S3 '{bucket}' sincronizado com sucesso.")
    except Exception as e:
        logger.error(f"Falha ao sincronizar bucket S3 '{bucket}': {e}")
        raise

def _create_snapshot():
    """Fase 1 (para 'test'): Coleta artefatos, cria e armazena um snapshot."""
    logger.info("--- FASE 1: INICIANDO CRIAÇÃO DO SNAPSHOT ---")
    if not all([Version, ArtifactsBucket]):
        raise ValueError("Para criar um snapshot, 'Version' deve estar no List.txt e o bucket de artefatos deve ser definido (via 'ArtifactsBucket' no List.txt ou via 'AWS_S3_BUCKET_TARGET_NAME_0').")

    _clear_dir(ARTIFACTS_DIR)
    
    for source_list in json_data.get("ListLambda", []):
        lambda_name, region, _ = source_list
        dest_path = os.path.join(ARTIFACTS_DIR, "lambdas", f"{lambda_name}.zip")
        _download_lambda_code(lambda_name, region, dest_path)
        
    for source_list in json_data.get("ListS3", []):
        bucket, region, _ = source_list
        dest_path = os.path.join(ARTIFACTS_DIR, "s3_content", bucket)
        _sync_s3_to_local(bucket, region, dest_path)

    _clear_dir(SNAPSHOTS_DIR)
    snapshot_basename = os.path.join(SNAPSHOTS_DIR, f'snapshot-{Version}')
    snapshot_filename = shutil.make_archive(snapshot_basename, 'zip', ARTIFACTS_DIR)
    s3_key = f'snapshots/{os.path.basename(snapshot_filename)}'
    
    logger.info(f"Enviando snapshot '{os.path.basename(snapshot_filename)}' para s3://{ArtifactsBucket}/{s3_key}")
    s3_client.upload_file(snapshot_filename, ArtifactsBucket, s3_key)
    logger.info("Snapshot enviado com sucesso.")

def _restore_snapshot():
    """Fase 1 (outros estágios): Baixa e descompacta um snapshot."""
    logger.info("--- FASE 1: INICIANDO RESTAURAÇÃO DO SNAPSHOT ---")
    if not all([Version, ArtifactsBucket]):
        raise ValueError("Para restaurar um snapshot, 'Version' deve estar no List.txt e o bucket de artefatos deve ser definido (via 'ArtifactsBucket' no List.txt ou via 'AWS_S3_BUCKET_TARGET_NAME_0').")

    _clear_dir(ARTIFACTS_DIR)
    _clear_dir(SNAPSHOTS_DIR)

    snapshot_filename = f'snapshot-{Version}.zip'
    s3_key = f'snapshots/{snapshot_filename}'
    local_snapshot_path = os.path.join(SNAPSHOTS_DIR, snapshot_filename)

    try:
        logger.info(f"Baixando snapshot de s3://{ArtifactsBucket}/{s3_key}")
        s3_client.download_file(ArtifactsBucket, s3_key, local_snapshot_path)
    except ClientError as e:
        if e.response['Error']['Code'] == '404':
            logger.error(f"ERRO CRÍTICO: Snapshot '{s3_key}' não encontrado no bucket '{ArtifactsBucket}'. Verifique a versão.")
        else:
            logger.error(f"Erro do S3 ao baixar o snapshot: {e}")
        raise

    logger.info(f"Descompactando '{snapshot_filename}' para '{ARTIFACTS_DIR}'...")
    with zipfile.ZipFile(local_snapshot_path, 'r') as zip_ref:
        zip_ref.extractall(ARTIFACTS_DIR)
    logger.info("Snapshot restaurado com sucesso.")

def _upload_s3_content():
    """Fase 3: Sincroniza o conteúdo do snapshot para os buckets de destino."""
    logger.info("--- FASE 3: INICIANDO UPLOAD DE CONTEÚDO PARA BUCKETS S3 ---")
    upload_tasks = json_data.get("ListS3Uploads", [])
    if not upload_tasks:
        logger.info("Nenhuma tarefa de upload de S3 definida em 'ListS3Uploads'. Pulando Fase 3.")
        return

    for task in upload_tasks:
        local_path = os.path.join(ARTIFACTS_DIR, task['local_path'])
        target_bucket = task['target_bucket_name']
        target_region = task['target_region']
        
        if not os.path.isdir(local_path):
            logger.warning(f"Diretório local para upload não encontrado: '{local_path}'. Pulando tarefa.")
            continue
            
        s3_resource = boto3.resource('s3', region_name=target_region)
        bucket_obj = s3_resource.Bucket(target_bucket)
        
        logger.info(f"Fazendo upload do conteúdo de '{local_path}' para o bucket s3://{target_bucket}")
        for root, _, files in os.walk(local_path):
            for filename in files:
                local_file = os.path.join(root, filename)
                relative_path = os.path.relpath(local_file, local_path)
                s3_key = relative_path.replace(os.sep, '/')
                
                try:
                    bucket_obj.upload_file(local_file, s3_key)
                except ClientError as e:
                    logger.error(f"Falha ao enviar arquivo '{local_file}' para s3://{target_bucket}/{s3_key}: {e}")
                    raise
    logger.info("Upload de conteúdo para S3 concluído.")

# --- FUNÇÃO PRINCIPAL DE ORQUESTRAÇÃO ---
def main():
    if command_type == "apply":
        try:
            if IsTest:
                _create_snapshot()
            else:
                _restore_snapshot()
            logger.info("FASE 1 (Preparação de Artefatos) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA CRÍTICA na Fase 1 (Preparação de Artefatos): {e}")
            sys.exit(1)

    logger.info("--- FASE 2: INICIANDO EXECUÇÃO DO TERRAFORM ---")
    if command_type == "destroy":
        states_to_process = json_data.get("ListStatesBlue", [])[::-1] if not IsTest else json_data.get("ListStates", [])[::-1]
    else:
        states_to_process = json_data.get("ListStates", [])
    logger.info(f"Estados a processar: {states_to_process}")
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for state_name in states_to_process:
        logger.info(f"================ Processando estado: {state_name} ================")
        state_dir = os.path.join("/tmp/states", state_name)
        os.makedirs(state_dir, exist_ok=True)

        for file_name in ['main.tf', 'terraform.lock.hcl']:
            try:
                s3_client.download_file(bucket_name, f"states/{state_name}/{file_name}", os.path.join(state_dir, file_name))
            except ClientError:
                if file_name == 'main.tf':
                    logger.error(f"main.tf para o estado '{state_name}' não encontrado. Abortando.")
                    sys.exit(1)
        
        if os.path.exists(os.path.join(state_dir, 'terraform.lock.hcl')):
            os.rename(os.path.join(state_dir, 'terraform.lock.hcl'), os.path.join(state_dir, '.terraform.lock.hcl'))

        env = os.environ.copy()
        env['STATE_NAME'] = state_name

        try:
            logger.info(f"Executando modify_main_tf.py para o estado: {state_name}")
            # Usamos cwd=state_dir para que o script encontre 'main.tf' facilmente
            result = subprocess.run(['python', os.path.join(script_dir, 'modify_main_tf.py')],
                                    cwd=state_dir, env=env, check=True, capture_output=True, text=True)
            logger.info(result.stdout)
        except subprocess.CalledProcessError as e:
            logger.error(f"modify_main_tf.py falhou para o estado {state_name}:\nSTDOUT:\n{e.stdout}\nSTDERR:\n{e.stderr}")
            sys.exit(1)

        try:
            logger.info(f"Executando InitTerraform.py para o estado: {state_name}")
            proc = subprocess.Popen(['python', os.path.join(script_dir, 'InitTerraform.py')],
                                    cwd=state_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in iter(proc.stdout.readline, ''):
                if line: logger.info(f"[{state_name}] {line.strip()}")
            proc.stdout.close()
            return_code = proc.wait()
            if return_code != 0: raise subprocess.CalledProcessError(return_code, proc.args)
        except subprocess.CalledProcessError as e:
            logger.error(f"InitTerraform.py falhou para o estado {state_name} com código de retorno {e.returncode}")
            sys.exit(1)

    logger.info("FASE 2 (Execução do Terraform) concluída com sucesso.")

    if command_type == "apply":
        try:
            _upload_s3_content()
            logger.info("FASE 3 (Povoamento da Infraestrutura) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA na Fase 3 (Povoamento da Infraestrutura): {e}")
            sys.exit(1)

    if not Approved and command_type == "destroy":
        logger.error("Comando 'destroy' recebido para uma versão 'green' não aprovada. Gerando falha para permitir 'Retry'.")
        sys.exit(1)

    logger.info("Processo de CI/CD do backend concluído com sucesso.")

if __name__ == "__main__":
    main()
