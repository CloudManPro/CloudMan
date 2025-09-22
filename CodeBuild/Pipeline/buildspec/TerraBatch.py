# TerraBatch.py (Versão 9.0.0 - Lógica de Sufixo Composto)
# Implementa a regra final onde o sufixo de contextualização para ambientes
# não-teste (ex: prod) é construído dinamicamente combinando o nome do
# estágio (CurrentStageName) e a versão (Version do List.txt).

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

# --- FUNÇÃO AUXILIAR PARA ASSUMIR A ROLE ---
def get_boto3_clients_with_assumed_role(role_arn, session_name="TerraBatchSession"):
    """Assume uma IAM Role e retorna um dicionário de clientes Boto3 com credenciais temporárias."""
    if not role_arn:
        logger.warning("Variável de ambiente para role dinâmica não definida. Usando as credenciais do ambiente padrão.")
        return {'s3': boto3.client('s3'), 'lambda': boto3.client('lambda')}
    try:
        logger.info(f"Assumindo a role especificada em 'DYNAMIC_ASSUMABLE_ROLE_ARN': {role_arn}")
        sts_client = boto3.client('sts')
        response = sts_client.assume_role(RoleArn=role_arn, RoleSessionName=session_name)
        credentials = response['Credentials']
        logger.info(f"Role assumida com sucesso. A sessão expira em: {credentials['Expiration']}")
        return {
            's3': boto3.client('s3', aws_access_key_id=credentials['AccessKeyId'], aws_secret_access_key=credentials['SecretAccessKey'], aws_session_token=credentials['SessionToken']),
            'lambda': boto3.client('lambda', aws_access_key_id=credentials['AccessKeyId'], aws_secret_access_key=credentials['SecretAccessKey'], aws_session_token=credentials['SessionToken'])
        }
    except ClientError as e:
        logger.error(f"FALHA CRÍTICA ao assumir a role: {e}"); raise

# --- LEITURA DE VARIÁVEIS DE AMBIENTE E MANIFESTO ---
command_array = (os.getenv('Command') or '').split(',')
command_type = command_array[0]
path = command_array[1] if len(command_array) > 1 else ''
path_parts = path.split('/')
PipelineName = path_parts[1] if len(path_parts) > 1 else 'UnknownPipeline'
CurrentStageName = path_parts[2] if len(path_parts) > 2 else 'UnknownStage'
logger.info(f"Comando: {command_type}, Pipeline: {PipelineName}, Estágio: {CurrentStageName}")
try:
    with open('List.txt', 'r', encoding='utf-8') as file: json_data = json.load(file)
    logger.info(f"Conteúdo do List.txt lido com sucesso:\n{json.dumps(json_data, indent=2)}")
except Exception as err:
    logger.error(f"Erro crítico ao acessar ou processar List.txt: {err}"); sys.exit(1)

# --- INICIALIZAÇÃO E ASSUNÇÃO DE ROLE ---
DYNAMIC_ASSUMABLE_ROLE_ARN = os.getenv('DYNAMIC_ASSUMABLE_ROLE_ARN')
boto3_clients = get_boto3_clients_with_assumed_role(DYNAMIC_ASSUMABLE_ROLE_ARN)
s3_client = boto3_clients['s3']; lambda_client = boto3_clients['lambda']
Version = json_data.get("Version"); IsTest = json_data.get("IsTest", False)
ArtifactsBucket = json_data.get("ArtifactsBucket") or os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')

def _split_resource_name(full_name, is_test_env):
    """
    Divide um nome de recurso completo em 'nome base' e 'sufixo' de forma robusta.

    A lógica opera "de trás para frente" para lidar com nomes que podem
    conter múltiplos hífens no nome base.

    - Para ambientes de teste (is_test_env=True), o sufixo é a última parte após o hífen.
    - Para outros ambientes (is_test_env=False), o sufixo são as duas últimas partes.

    Args:
        full_name (str): O nome completo do recurso (ex: "MeuProjeto-VerPipe1-prod-1").
        is_test_env (bool): True se o ambiente de destino for 'test'.

    Returns:
        tuple: Uma tupla contendo (str: nome_base, str: sufixo).
               Exemplos:
               _split_resource_name("LPipe1-test", True) -> ("LPipe1", "-test")
               _split_resource_name("MeuProjeto-VerPipe1-prod-1", False) -> ("MeuProjeto-VerPipe1", "-prod-1")
    """
    parts = full_name.split('-')
    
    # Determina quantos componentes do final da string formam o sufixo
    num_suffix_parts = 1 if is_test_env else 2
    
    # Validação para nomes mais curtos que o esperado (ex: "prod-1")
    if len(parts) <= num_suffix_parts:
        return '', f'-{full_name}'

    # Separa as partes do nome base e do sufixo
    base_parts = parts[:-num_suffix_parts]
    suffix_parts = parts[-num_suffix_parts:]
    
    # Reconstrói as strings
    base_name = '-'.join(base_parts)
    suffix = f"-{'-'.join(suffix_parts)}"
    
    return base_name, suffix

# --- FUNÇÕES COMPLETAS DE GERENCIAMENTO DE ARTEFATOS ---
def _clear_dir(directory):
    if os.path.exists(directory): shutil.rmtree(directory)
    os.makedirs(directory)

def _log_directory_contents(directory_path, header):
    """Função auxiliar para listar o conteúdo de um diretório nos logs."""
    logger.info(f"--- {header} ---")
    if not os.path.exists(directory_path):
        logger.warning(f"O diretório '{directory_path}' não existe.")
        logger.info("-------------------------------------------")
        return
        
    file_list = [os.path.relpath(os.path.join(root, name), directory_path) for root, _, files in os.walk(directory_path) for name in files]
    if not file_list:
        logger.warning(f"O diretório '{directory_path}' está vazio.")
    else:
        for f in sorted(file_list):
            logger.info(f"  - {f}")
    logger.info("-------------------------------------------")

def _download_lambda_code(lambda_name, region, dest_path):
    try:
        response = lambda_client.get_function(FunctionName=lambda_name)
        code_url = response['Code']['Location']
        r = requests.get(code_url, stream=True); r.raise_for_status()
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        with open(dest_path, 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192): f.write(chunk)
        logger.info(f"Código da Lambda '{lambda_name}' salvo em '{dest_path}'.")
    except Exception as e:
        logger.error(f"Falha ao baixar código da Lambda '{lambda_name}': {e}"); raise

def _sync_s3_to_local(bucket, region, dest_path):
    try:
        s3_resource = boto3.resource('s3', region_name=region,
                                     aws_access_key_id=s3_client.meta.credentials.access_key,
                                     aws_secret_access_key=s3_client.meta.credentials.secret_key,
                                     aws_session_token=s3_client.meta.credentials.token)
        bucket_obj = s3_resource.Bucket(bucket)
        for obj in bucket_obj.objects.all():
            local_file_path = os.path.join(dest_path, obj.key)
            os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
            bucket_obj.download_file(obj.key, local_file_path)
        logger.info(f"Conteúdo do bucket S3 '{bucket}' sincronizado para '{dest_path}'.")
    except Exception as e:
        logger.error(f"Falha ao sincronizar bucket S3 '{bucket}': {e}"); raise

def _create_snapshot():
    """
    Cria o snapshot. Responsabilidade: Baixar código da fonte '-dev' e salvar
    localmente com nomes GENÉRICOS (sem sufixo). Depois, compacta e envia para o S3.
    Esta função é chamada apenas por 'apply' no estágio de 'test'.
    """
    logger.info("--- FASE 1: INICIANDO CRIAÇÃO DO SNAPSHOT (MODO GENÉRICO) ---")
    if not all([Version, ArtifactsBucket]): raise ValueError("'Version' e 'ArtifactsBucket' são obrigatórios.")
    _clear_dir(ARTIFACTS_DIR)
    
    dev_suffix = '-dev'
    
    # Processa Lambdas
    for source_list in json_data.get("ListLambda", []):
        name_from_manifest, region, _ = source_list
        
        # ###################### INÍCIO DA ALTERAÇÃO CIRÚRGICA ######################
        # Usa a função auxiliar para extrair o nome base de forma robusta.
        # Como _create_snapshot só roda em 'test', passamos is_test_env=True.
        base_name, _ = _split_resource_name(name_from_manifest, is_test_env=True)
        # ####################### FIM DA ALTERAÇÃO CIRÚRGICA #######################

        source_name_for_download = f"{base_name}{dev_suffix}"
        generic_artifact_name = f"{base_name}.zip"
        
        logger.info(f"Mapeando fonte Lambda: '{name_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando como: '{generic_artifact_name}'")
        _download_lambda_code(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "lambdas", generic_artifact_name))
    
    # Processa conteúdo S3
    for source_list in json_data.get("ListS3", []):
        bucket_from_manifest, region, _ = source_list
        
        # ###################### INÍCIO DA ALTERAÇÃO CIRÚRGICA ######################
        # Aplica a mesma lógica robusta para os nomes dos buckets S3.
        base_bucket_name, _ = _split_resource_name(bucket_from_manifest, is_test_env=True)
        # ####################### FIM DA ALTERAÇÃO CIRÚRGICA #######################
        
        source_name_for_download = f"{base_bucket_name}{dev_suffix}"
        
        logger.info(f"Mapeando fonte S3: '{bucket_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando em: '{base_bucket_name}'")
        _sync_s3_to_local(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "s3_content", base_bucket_name))
        
    _log_directory_contents(ARTIFACTS_DIR, "Arquivos genéricos coletados para inclusão no snapshot")
    if not any(os.scandir(ARTIFACTS_DIR)): logger.warning("Nenhum artefato foi coletado para o snapshot.")
    
    _clear_dir(SNAPSHOTS_DIR)
    snapshot_basename = os.path.join(SNAPSHOTS_DIR, f'backup_{Version}')
    snapshot_filename = shutil.make_archive(snapshot_basename, 'zip', ARTIFACTS_DIR)
    CopyArtifactS3Path = f"CopyArtifacts/{PipelineName}/{Version}"
    backup_object_key = f"{CopyArtifactS3Path}/{os.path.basename(snapshot_filename)}"
    
    logger.info(f"Enviando snapshot para s3://{ArtifactsBucket}/{backup_object_key}")
    s3_client.upload_file(snapshot_filename, ArtifactsBucket, backup_object_key)
    logger.info("Snapshot enviado com sucesso.")

def _restore_snapshot():
    """
    Restaura o snapshot. Responsabilidade: Baixar o snapshot genérico do S3 e
    extraí-lo localmente. Os arquivos no disco estarão com nomes genéricos.
    """
    logger.info("--- FASE 1: INICIANDO RESTAURAÇÃO DO SNAPSHOT (MODO GENÉRICO) ---")
    if not all([Version, ArtifactsBucket]):
        raise ValueError("'Version' (do List.txt) e 'ArtifactsBucket' são obrigatórios.")
    
    _clear_dir(ARTIFACTS_DIR); _clear_dir(SNAPSHOTS_DIR)

    snapshot_filename = f'backup_{Version}.zip'
    artifact_path_base = f"CopyArtifacts/{PipelineName}/{Version}"
    backup_object_key = f"{artifact_path_base}/{snapshot_filename}"
    local_snapshot_path = os.path.join(SNAPSHOTS_DIR, snapshot_filename)
    
    try:
        logger.info(f"Tentando baixar snapshot de: s3://{ArtifactsBucket}/{backup_object_key}")
        s3_client.download_file(ArtifactsBucket, backup_object_key, local_snapshot_path)
    except ClientError as e:
        if e.response['Error']['Code'] == '404':
            logger.error(f"ERRO CRÍTICO: Snapshot '{backup_object_key}' não encontrado no S3.")
        raise

    with zipfile.ZipFile(local_snapshot_path, 'r') as zip_ref: zip_ref.extractall(ARTIFACTS_DIR)
    _log_directory_contents(ARTIFACTS_DIR, "Arquivos genéricos restaurados do snapshot")
    logger.info("Snapshot restaurado com sucesso.")


def _contextualize_artifacts():
    """
    Contextualiza os artefatos. Renomeia os arquivos GENÉRICOS no disco,
    adicionando o sufixo correto para o estágio e comando atuais.

    - Para 'apply', usa 'ListStates' para determinar o sufixo "Green".
    - Para 'destroy' (em ambiente não-teste), usa 'ListStatesBlue' para
      determinar o sufixo "Blue" a ser removido.
    """
    logger.info("Iniciando a fase de contextualização de artefatos para o estágio atual...")


    
    # 1. Determinar qual lista de estados usar como fonte para o sufixo.
    source_state_list = None
    source_list_name_for_logs = ""

    if command_type == 'destroy' and not IsTest:
        logger.info("Comando 'destroy' em ambiente não-teste. Usando 'ListStatesBlue' como fonte.")
        source_state_list = json_data.get("ListStatesBlue", [])
        source_list_name_for_logs = "ListStatesBlue"
    else:
        logger.info(f"Comando '{command_type}'. Usando 'ListStates' como fonte.")
        source_state_list = json_data.get("ListStates", [])
        source_list_name_for_logs = "ListStates"

    # Se a lista de destino estiver vazia (ex: primeiro destroy), não há nada a fazer.
    if not source_state_list:
        logger.warning(f"A lista de estados de destino '{source_list_name_for_logs}' está vazia. Nenhum artefato será contextualizado.")
        return

    # 2. Extrair o sufixo de destino do primeiro item da lista escolhida.
    representative_state_name = source_state_list[0]
    _, target_suffix = _split_resource_name(representative_state_name, is_test_env=IsTest)
    logger.info(f"Sufixo de destino determinado a partir de '{source_list_name_for_logs}': '{target_suffix}'")

    # 3. Iterar sobre os artefatos definidos no manifesto para renomeá-los.
    # Processa Lambdas
    lambdas_path = os.path.join(ARTIFACTS_DIR, "lambdas")
    if os.path.exists(lambdas_path):
        for lambda_manifest in json_data.get("ListLambda", []):
            name_in_manifest = lambda_manifest[0]
            # Extrai o nome base do artefato a partir de sua definição no manifesto.
            base_name, _ = _split_resource_name(name_in_manifest, is_test_env=IsTest)
            
            source_file = os.path.join(lambdas_path, f"{base_name}.zip")
            
            # Constrói o nome de destino final usando o nome base e o sufixo correto.
            final_target_name = f"{base_name}{target_suffix}"
            target_file = os.path.join(lambdas_path, f"{final_target_name}.zip")
            
            if os.path.exists(source_file):
                logger.info(f"Contextualizando para '{command_type}': Renomeando '{source_file}' para '{target_file}'")
                os.rename(source_file, target_file)
            else:
                logger.warning(f"Artefato genérico '{source_file}' não encontrado para renomear.")

    # Processa conteúdo S3 (aplicando a mesma lógica)
    s3_content_path = os.path.join(ARTIFACTS_DIR, "s3_content")
    if os.path.exists(s3_content_path):
        for s3_manifest in json_data.get("ListS3", []):
            name_in_manifest = s3_manifest[0]
            base_name, _ = _split_resource_name(name_in_manifest, is_test_env=IsTest)
            
            source_dir = os.path.join(s3_content_path, base_name)
            final_target_name = f"{base_name}{target_suffix}"
            target_dir = os.path.join(s3_content_path, final_target_name)
            
            if os.path.exists(source_dir):
                logger.info(f"Contextualizando S3 para '{command_type}': Renomeando '{source_dir}' para '{target_dir}'")
                os.rename(source_dir, target_dir)
    
    _log_directory_contents(ARTIFACTS_DIR, "Arquivos restaurados e contextualizados para o estágio atual")
    logger.info("Contextualização de artefatos concluída.")

    
def _upload_s3_content():
    logger.info("--- FASE 3: INICIANDO UPLOAD DE CONTEÚDO PARA BUCKETS S3 ---")
    for target_list in json_data.get("ListS3", []):
        target_bucket_name, target_region, _ = target_list
        local_path = os.path.join(ARTIFACTS_DIR, "s3_content", target_bucket_name)
        if not os.path.isdir(local_path): logger.warning(f"Diretório de conteúdo '{local_path}' não encontrado. Pulando upload."); continue
        s3_resource = boto3.resource('s3', region_name=target_region,
                                     aws_access_key_id=s3_client.meta.credentials.access_key,
                                     aws_secret_access_key=s3_client.meta.credentials.secret_key,
                                     aws_session_token=s3_client.meta.credentials.token)
        bucket_obj = s3_resource.Bucket(target_bucket_name)
        logger.info(f"Fazendo upload de '{local_path}' para s3://{target_bucket_name}")
        for root, _, files in os.walk(local_path):
            for filename in files:
                local_file = os.path.join(root, filename)
                s3_key = os.path.relpath(local_file, local_path).replace(os.sep, '/')
                bucket_obj.upload_file(local_file, s3_key)
    logger.info("Upload de conteúdo para S3 concluído.")

# --- FUNÇÃO PRINCIPAL DE ORQUESTRAÇÃO ---
def main():
    manifest_json_string = json.dumps(json_data)

    if command_type in ["apply", "destroy"]:
        try:
            # Lógica principal de preparação de artefatos
            if command_type == "apply" and IsTest:
                # Caso especial: Cria o snapshot genérico E prepara o ambiente local
                _create_snapshot()
            else:
                # Outros casos: Restaura o snapshot genérico do S3
                _restore_snapshot()

            # Em todos os casos, após ter os arquivos genéricos localmente,
            # eles precisam ser contextualizados para o estágio atual.
            _contextualize_artifacts()

            logger.info("FASE 1 (Preparação de Artefatos) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA CRÍTICA na Fase 1. A execução será interrompida. Erro: {e}")
            sys.exit(1)

    logger.info("--- FASE 2: INICIANDO EXECUÇÃO DO TERRAFORM ---")
    states_to_process = (json_data.get("ListStatesBlue", [])[::-1] if not IsTest else json_data.get("ListStates", [])[::-1]) if command_type == "destroy" else json_data.get("ListStates", [])
    script_dir = os.path.dirname(os.path.abspath(__file__))
    s3_bucket_for_tf_files = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')

    for state_name in states_to_process:
        logger.info(f"================ Processando estado: {state_name} ================")
        state_dir = os.path.join("/tmp/states", state_name)
        os.makedirs(state_dir, exist_ok=True)
        
        for file_name in ['main.tf', 'terraform.lock.hcl']:
            try: s3_client.download_file(s3_bucket_for_tf_files, f"states/{state_name}/{file_name}", os.path.join(state_dir, file_name))
            except ClientError:
                if file_name == 'main.tf': logger.error(f"main.tf para '{state_name}' não encontrado. Abortando."); sys.exit(1)
        if os.path.exists(os.path.join(state_dir, 'terraform.lock.hcl')):
            os.rename(os.path.join(state_dir, 'terraform.lock.hcl'), os.path.join(state_dir, '.terraform.lock.hcl'))
        
        env = os.environ.copy()
        env['STATE_NAME'] = state_name
        env['MANIFEST_JSON'] = manifest_json_string
        if DYNAMIC_ASSUMABLE_ROLE_ARN:
            env['DYNAMIC_ASSUMABLE_ROLE_ARN'] = DYNAMIC_ASSUMABLE_ROLE_ARN
        
        try:
            logger.info(f"Executando modify_main_tf.py para o estado '{state_name}'...")
            proc_modify = subprocess.Popen([sys.executable, os.path.join(script_dir, 'modify_main_tf.py')],
                                           cwd=state_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True, encoding='utf-8', errors='replace')
            for line in iter(proc_modify.stdout.readline, ''):
                if line:
                    logger.info(f"[{state_name}/modify] {line.strip()}")
            proc_modify.stdout.close()
            return_code = proc_modify.wait()
            if return_code != 0:
                raise subprocess.CalledProcessError(return_code, proc_modify.args)
        except subprocess.CalledProcessError as e:
            logger.error(f"modify_main_tf.py falhou para {state_name} com código {e.returncode}"); sys.exit(1)
        
        try:
            logger.info(f"Executando InitTerraform.py para o estado '{state_name}'...")
            proc_init = subprocess.Popen([sys.executable, os.path.join(script_dir, 'InitTerraform.py')],
                                         cwd=state_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         text=True, encoding='utf-8', errors='replace')
            for line in iter(proc_init.stdout.readline, ''):
                if line:
                    print(f"[{state_name}/terraform] {line.strip()}", flush=True)
            proc_init.stdout.close()
            if proc_init.wait() != 0:
                raise subprocess.CalledProcessError(proc_init.returncode, proc_init.args)
        except subprocess.CalledProcessError as e:
            logger.error(f"InitTerraform.py falhou para {state_name} com código {e.returncode}"); sys.exit(1)

    logger.info("FASE 2 (Execução do Terraform) concluída com sucesso.")

    if command_type == "apply":
        try:
            _upload_s3_content()
            logger.info("FASE 3 (Povoamento da Infraestrutura) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA na Fase 3: {e}"); sys.exit(1)

    if not json_data.get("Approved", False) and command_type == "destroy":
        logger.error("Comando 'destroy' recebido para versão não aprovada. Gerando falha para 'Retry'."); sys.exit(1)

    logger.info("Processo de CI/CD do backend concluído com sucesso.")

if __name__ == "__main__":
    main()
