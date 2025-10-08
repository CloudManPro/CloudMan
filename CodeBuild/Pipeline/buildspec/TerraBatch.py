# TerraBatch.py (Versão 10.0.0 - Lógica Unificada)
# Esta versão absorve completamente a funcionalidade do script 'modify_main_tf.py'.
# A modificação do arquivo main.tf agora é feita por uma função interna,
# que possui o contexto completo da execução (incluindo o nome do estado atual),
# resolvendo o bug de substituição de placeholder durante o 'terraform destroy'.

import os
import json
import logging
import subprocess
import sys
import boto3
import zipfile
import shutil
import requests
import re
from botocore.exceptions import ClientError
import hcl2

# --- CONFIGURAÇÃO INICIAL E CONSTANTES ---
ARTIFACTS_DIR = '/tmp/artifacts'
SNAPSHOTS_DIR = '/tmp/snapshots'

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()


# --- FUNÇÕES AUXILIARES (INCLUINDO AS MOVIDAS DO MODIFY_MAIN_TF.PY) ---


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
            'lambda': boto3.client('lambda', aws_access_key_id=credentials['AccessKeyId'], aws_secret_access_key=credentials['SecretAccessKey'], aws_session_token=credentials['SessionToken']),
            'ec2': boto3.client('ec2', aws_access_key_id=credentials['AccessKeyId'],aws_secret_access_key=credentials['SecretAccessKey'], aws_session_token=credentials['SessionToken'])
        }
    except ClientError as e:
        logger.error(f"FALHA CRÍTICA ao assumir a role: {e}"); raise

def _split_resource_name(full_name, is_test_env):
    """
    Divide um nome de recurso completo em 'nome base' e 'sufixo' de forma robusta.
    - Para ambientes de teste (is_test_env=True), o sufixo é a última parte após o hífen.
    - Para outros ambientes (is_test_env=False), o sufixo são as duas últimas partes.
    """
    parts = full_name.split('-')
    num_suffix_parts = 1 if is_test_env else 2
    if len(parts) <= num_suffix_parts:
        return '', f'-{full_name}'
    base_parts = parts[:-num_suffix_parts]
    suffix_parts = parts[-num_suffix_parts:]
    base_name = '-'.join(base_parts)
    suffix = f"-{'-'.join(suffix_parts)}"
    return base_name, suffix

def inject_assume_role(code, role_arn):
    """
    TAREFA 1: Injeta o bloco 'assume_role' no provedor 'aws'.
    """
    if not role_arn:
        logger.info("Nenhuma DYNAMIC_ASSUMABLE_ROLE_ARN encontrada. Pulando injeção de role.")
        return code
    
    logger.info(f"Tentando injetar bloco assume_role para: {role_arn}")
    assume_role_block = f'''
  assume_role {{
    role_arn     = "{role_arn}"
    session_name = "Terraform_Execution_Session"
  }}
'''
    provider_regex = r'(provider\s+(?:"aws"|aws)\s*\{)([\s\S]*?)(\})'
    if not re.search(provider_regex, code, flags=re.MULTILINE):
        logger.warning("Nenhum provider 'aws' encontrado no main.tf para injetar a role.")
        return code

    def add_assume_role(match):
        opening, body, closing = match.groups()
        if 'assume_role' in body:
            logger.info("Bloco 'assume_role' já existe no provider. Nenhuma alteração feita.")
            return match.group(0)
        logger.info("Bloco 'assume_role' injetado com sucesso no provider 'aws'.")
        return f"{opening}{body}{assume_role_block}{closing}"

    return re.sub(provider_regex, add_assume_role, code, flags=re.MULTILINE)



import os
import re
import logging

# Presume-se que as seguintes variáveis e o logger já existem no escopo do seu script:
# logger = logging.getLogger()
# ARTIFACTS_DIR = '/tmp/artifacts'
# def inject_assume_role(content, role_arn): ...
# def _split_resource_name(full_name, is_test_env): ...

def _modify_and_prepare_main_tf(state_dir, state_name, manifest_data, role_arn_to_assume, is_test_env, command_type):
    """
    VERSÃO FINAL E ROBUSTA: Processa o main.tf dinamicamente, usando substituição de
    placeholders complexos. Esta versão foi corrigida para usar o nome completo do
    recurso do manifesto na construção dos placeholders, garantindo que a busca
    funcione corretamente em todos os ambientes (test, prod, etc.).
    """
    main_tf_path = os.path.join(state_dir, 'main.tf')
    logger.info(f"Processando '{main_tf_path}' para o comando '{command_type}'.")

    try:
        with open(main_tf_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        logger.error(f"FALHA CRÍTICA ao ler o arquivo HCL '{main_tf_path}'. Erro: {e}", exc_info=True)
        raise

    # Injeção de role (sem alterações)
    content = inject_assume_role(content, role_arn_to_assume)

    try:
        if command_type == 'destroy':
            logger.info(f"[{state_name}/destroy-optimize] Otimizando HCL para destruição...")
            dummy_zip_path = "/tmp/dummy_artifact.zip"
            os.makedirs('/tmp', exist_ok=True)
            with open(dummy_zip_path, 'w') as f: f.write('dummy')
            
            # Substitui todos os filenames de artefatos por um dummy
            content = re.sub(r'filename\s*=\s*"Change_CloudMan_%\&*_File_Name_.*"',
                             f'filename = "{dummy_zip_path}"',
                             content, flags=re.MULTILINE)
            logger.info("  -> [destroy] Filenames de Lambdas/UserData alterados para dummy.")
            
            # Remove completamente todas as linhas de source_code_hash
            content = re.sub(r'^\s*source_code_hash\s*=\s*"Change_CloudMan_%\&*_Hash_.*"\n?',
                             '',
                             content, flags=re.MULTILINE)
            logger.info("  -> [destroy] Linhas de source_code_hash removidas.")
            
        else: # Lógica para 'apply'
            logger.info(f"[{state_name}/apply] Modificando HCL para aplicação...")
            _, target_suffix = _split_resource_name(state_name, is_test_env=is_test_env)

            # 1. Garante 'force_destroy: true' para buckets S3
            content = re.sub(r'(\bforce_destroy\s*=\s*)false',
                             r'\1true',
                             content)
            logger.info("  -> [apply] Garantido 'force_destroy: true' para buckets S3 marcados.")

            # 2. Processar Lambdas
            for lambda_manifest in manifest_data.get("ListLambda", []):
                # --- [ CORREÇÃO CIRÚRGICA ] ---
                # Usa o nome COMPLETO do manifesto (ex: "Function-test") para construir o placeholder.
                resource_name_from_manifest = lambda_manifest[0]
                
                # A função split ainda é usada para construir o nome do ARQUIVO de destino.
                base_name_for_path, _ = _split_resource_name(resource_name_from_manifest, is_test_env)
                
                placeholder_filename = f'"Change_CloudMan_%&*_File_Name_{resource_name_from_manifest}"'
                placeholder_hash = f'"Change_CloudMan_%&*_Hash_{resource_name_from_manifest}"'
                # --- [ FIM DA CORREÇÃO ] ---

                # O resto da lógica agora funciona, pois os placeholders correspondem ao HCL.
                new_path = os.path.join(ARTIFACTS_DIR, "lambdas", f"{base_name_for_path}{target_suffix}.zip").replace("\\", "/")
                new_hash_expression = f'filebase64sha256("{new_path}")'
                
                content = content.replace(placeholder_filename, f'"{new_path}"')
                content = content.replace(placeholder_hash, new_hash_expression)
                
                logger.info(f"  -> [apply] Artefato da Lambda '{resource_name_from_manifest}' atualizado para '{new_path}'.")

            # 3. Processar UserData de EC2 e Launch Templates
            ec2_items = manifest_data.get("ListEC2", []) + manifest_data.get("ListLaunchTemplate", [])
            for ec2_manifest in ec2_items:
                # Aplicando a mesma lógica de correção aqui
                resource_name_from_manifest = ec2_manifest[0]
                base_name_for_path, _ = _split_resource_name(resource_name_from_manifest, is_test_env)

                new_path = os.path.join(ARTIFACTS_DIR, "ec2_userdata", f"{base_name_for_path}{target_suffix}.sh").replace("\\", "/")
                new_file_expr = f'${{file("{new_path}")}}'
                
                placeholder_userdata = f'"Change_CloudMan_%&*_File_Name_{resource_name_from_manifest}"'
                content = content.replace(placeholder_userdata, f'"{new_file_expr}"')
                logger.info(f"  -> [apply] UserData de '{resource_name_from_manifest}' atualizado para '{new_path}'.")

        # Sobrescreve o arquivo main.tf com o conteúdo final modificado
        with open(main_tf_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        logger.info(f"[{state_name}/modify] Arquivo '{main_tf_path}' modificado com sucesso.")

    except Exception as e:
        logger.error(f"FALHA CRÍTICA ao processar o HCL para o estado '{state_name}'. Erro: {e}", exc_info=True)
        raise

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
ec2_client = boto3_clients.get('ec2')
Version = json_data.get("Version"); IsTest = json_data.get("IsTest", False)
ArtifactsBucket = json_data.get("ArtifactsBucket") or os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
print("PAssou aqui")

# --- FUNÇÕES COMPLETAS DE GERENCIAMENTO DE ARTEFATOS (Sem alterações) ---
def _clear_dir(directory):
    if os.path.exists(directory): shutil.rmtree(directory)
    os.makedirs(directory)

def _log_directory_contents(directory_path, header):
    logger.info(f"--- {header} ---")
    if not os.path.exists(directory_path):
        logger.warning(f"O diretório '{directory_path}' não existe.")
        return
    file_list = [os.path.relpath(os.path.join(root, name), directory_path) for root, _, files in os.walk(directory_path) for name in files]
    if not file_list: logger.warning(f"O diretório '{directory_path}' está vazio.")
    else:
        for f in sorted(file_list): logger.info(f"  - {f}")
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
    """
    Sincroniza o conteúdo de um bucket S3 para um diretório local,
    preservando os metadados essenciais (como ContentType) em arquivos .metadata.json.
    """
    try:
        logger.info(f"Iniciando sincronização do bucket S3 '{bucket}' para '{dest_path}'.")
        paginator = s3_client.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket)

        object_count = 0
        for page in pages:
            if 'Contents' not in page:
                continue
            for obj in page['Contents']:
                object_key = obj['Key']
                if object_key.endswith('/'):
                    continue
                
                local_file_path = os.path.join(dest_path, object_key)
                os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
                
                # Passo 1: Baixar o arquivo (sem alteração)
                s3_client.download_file(bucket, object_key, local_file_path)
                
                # --- [MODIFICAÇÃO INÍCIO] ---
                # Passo 2: Obter e salvar os metadados do objeto
                try:
                    metadata_response = s3_client.head_object(Bucket=bucket, Key=object_key)
                    metadata_to_save = {}
                    
                    # Lista de metadados HTTP que queremos preservar
                    headers_to_preserve = [
                        'ContentType', 'CacheControl', 'ContentDisposition', 
                        'ContentEncoding', 'ContentLanguage'
                    ]

                    for header in headers_to_preserve:
                        if header in metadata_response:
                            metadata_to_save[header] = metadata_response[header]
                    
                    # Salva os metadados se algum foi encontrado
                    if metadata_to_save:
                        metadata_file_path = local_file_path + ".metadata.json"
                        with open(metadata_file_path, 'w', encoding='utf-8') as f:
                            json.dump(metadata_to_save, f)
                        # logger.info(f"  -> Metadados para '{object_key}' salvos.")

                except ClientError as e:
                    logger.warning(f"Não foi possível obter metadados para o objeto '{object_key}': {e}")
                # --- [MODIFICAÇÃO FIM] ---

                object_count += 1
        
        if object_count > 0:
            logger.info(f"Sucesso! {object_count} objetos do bucket S3 '{bucket}' foram sincronizados para '{dest_path}'.")
        else:
            logger.warning(f"O bucket S3 '{bucket}' está vazio ou não contém objetos para sincronizar.")
            os.makedirs(dest_path, exist_ok=True)

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code")
        logger.error(f"Erro de cliente Boto3 ao sincronizar o bucket '{bucket}' (Código: {error_code}): {e}")
        raise
    except Exception as e:
        logger.error(f"Falha inesperada ao sincronizar bucket S3 '{bucket}': {e}")
        raise

def _create_snapshot():
    logger.info("--- FASE 1: INICIANDO CRIAÇÃO DO SNAPSHOT (MODO GENÉRICO) ---")
    if not all([Version, ArtifactsBucket]):
        raise ValueError("'Version' e 'ArtifactsBucket' são obrigatórios.")
    _clear_dir(ARTIFACTS_DIR)
    dev_suffix = '-dev'

    # --- Lógica para Lambda (sem alterações) ---
    for source_list in json_data.get("ListLambda", []):
        name_from_manifest, region, _ = source_list
        base_name, _ = _split_resource_name(name_from_manifest, is_test_env=True)
        source_name_for_download = f"{base_name}{dev_suffix}"
        generic_artifact_name = f"{base_name}.zip"
        logger.info(f"Mapeando fonte Lambda: '{name_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando como: '{generic_artifact_name}'")
        _download_lambda_code(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "lambdas", generic_artifact_name))

    # --- Lógica para S3 (sem alterações) ---
    for source_list in json_data.get("ListS3", []):
        bucket_from_manifest, region, *_ = source_list 
        base_bucket_name, _ = _split_resource_name(bucket_from_manifest, is_test_env=True)
        source_name_for_download = f"{base_bucket_name}{dev_suffix}"
        logger.info(f"Mapeando fonte S3: '{bucket_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando em: '{base_bucket_name}'")
        _sync_s3_to_local(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "s3_content", base_bucket_name))
        
    # --- [MODIFICAÇÃO CIRÚRGICA] ---
    # Adiciona o processamento de artefatos de UserData chamando a nova função auxiliar.
    try:
        _process_and_save_ec2_artifacts()
    except Exception as e:
        # A exceção já é logada dentro da função auxiliar, aqui apenas alertamos sobre a falha no processo geral.
        logger.error(f"Falha crítica durante o processamento de artefatos de UserData. O snapshot pode estar incompleto. Erro: {e}")
        # Descomente a linha abaixo para interromper a execução se a coleta de UserData for absolutamente crítica.
        # raise
    # --- [FIM DA MODIFICAÇÃO] ---

    _log_directory_contents(ARTIFACTS_DIR, "Arquivos genéricos coletados para inclusão no snapshot")
    
    # --- Lógica de empacotamento e upload (sem alterações) ---
    _clear_dir(SNAPSHOTS_DIR)
    snapshot_basename = os.path.join(SNAPSHOTS_DIR, f'backup_{Version}')
    snapshot_filename = shutil.make_archive(snapshot_basename, 'zip', ARTIFACTS_DIR)
    
    CopyArtifactS3Path = f"CopyArtifacts/{PipelineName}/{Version}"
    backup_object_key = f"{CopyArtifactS3Path}/{os.path.basename(snapshot_filename)}"
    
    logger.info(f"Enviando snapshot para s3://{ArtifactsBucket}/{backup_object_key}")
    s3_client.upload_file(snapshot_filename, ArtifactsBucket, backup_object_key)
    logger.info("Snapshot enviado com sucesso.")

def _restore_snapshot():
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
    logger.info("Iniciando a fase de contextualização de artefatos para o estágio atual...")
    source_state_list = None
    if command_type == 'destroy' and not IsTest:
        logger.info("Comando 'destroy' em ambiente não-teste. Usando 'ListStatesBlue' como fonte.")
        source_state_list = json_data.get("ListStatesBlue", [])
    else:
        logger.info(f"Comando '{command_type}'. Usando 'ListStates' como fonte.")
        source_state_list = json_data.get("ListStates", [])
    if not source_state_list:
        logger.warning("A lista de estados de destino está vazia. Nenhum artefato será contextualizado.")
        return
    representative_state_name = source_state_list[0]
    _, target_suffix = _split_resource_name(representative_state_name, is_test_env=IsTest)
    logger.info(f"Sufixo de destino determinado: '{target_suffix}'")

    # Lógica para Lambdas (sem alteração)
    lambdas_path = os.path.join(ARTIFACTS_DIR, "lambdas")
    if os.path.exists(lambdas_path):
        for lambda_manifest in json_data.get("ListLambda", []):
            base_name, _ = _split_resource_name(lambda_manifest[0], is_test_env=IsTest)
            source_file = os.path.join(lambdas_path, f"{base_name}.zip")
            target_file = os.path.join(lambdas_path, f"{base_name}{target_suffix}.zip")
            if os.path.exists(source_file):
                logger.info(f"Contextualizando Lambda para '{command_type}': Renomeando '{source_file}' para '{target_file}'")
                os.rename(source_file, target_file)

    # Lógica para S3 (sem alteração)
    s3_content_path = os.path.join(ARTIFACTS_DIR, "s3_content")
    if os.path.exists(s3_content_path):
        for s3_manifest in json_data.get("ListS3", []):
            base_name_from_manifest, *_ = s3_manifest
            base_name, _ = _split_resource_name(base_name_from_manifest, is_test_env=IsTest)
            source_dir = os.path.join(s3_content_path, base_name)
            target_dir = os.path.join(s3_content_path, f"{base_name}{target_suffix}")
            if os.path.exists(source_dir):
                logger.info(f"Contextualizando S3 para '{command_type}': Renomeando '{source_dir}' para '{target_dir}'")
                os.rename(source_dir, target_dir)

    # --- NOVO BLOCO PARA CONTEXTUALIZAR EC2 USERDATA ---
    ec2_userdata_path = os.path.join(ARTIFACTS_DIR, "ec2_userdata")
    if os.path.exists(ec2_userdata_path):
        ec2_items = json_data.get("ListEC2", []) + json_data.get("ListLaunchTemplate", [])
        for ec2_manifest in ec2_items:
            base_name, _ = _split_resource_name(ec2_manifest[0], is_test_env=IsTest)
            source_file = os.path.join(ec2_userdata_path, f"{base_name}.sh")
            target_file = os.path.join(ec2_userdata_path, f"{base_name}{target_suffix}.sh")
            if os.path.exists(source_file):
                logger.info(f"Contextualizando UserData para '{command_type}': Renomeando '{source_file}' para '{target_file}'")
                os.rename(source_file, target_file)

    _log_directory_contents(ARTIFACTS_DIR, "Arquivos restaurados e contextualizados para o estágio atual")
    logger.info("Contextualização de artefatos concluída.")

def _upload_s3_content():
    """
    Faz upload do conteúdo S3 local para os respectivos buckets de destino,
    reaplicando metadados salvos a partir de arquivos .metadata.json.
    """
    logger.info("--- FASE 3: INICIANDO UPLOAD DE CONTEÚDO PARA BUCKETS S3 ---")
    s3_content_base_path = os.path.join(ARTIFACTS_DIR, "s3_content")

    if not os.path.isdir(s3_content_base_path):
        logger.warning("Diretório 's3_content' não encontrado. Pulando upload para S3.")
        return

    for target_list in json_data.get("ListS3", []):
        target_bucket_name, target_region, *_ = target_list
        local_path = os.path.join(s3_content_base_path, target_bucket_name)

        if not os.path.isdir(local_path):
            logger.info(f"Nenhum conteúdo local encontrado em '{local_path}' para o bucket '{target_bucket_name}'. Pulando.")
            continue
            
        logger.info(f"Fazendo upload de '{local_path}' para s3://{target_bucket_name}")
        
        upload_client = s3_client
        if s3_client.meta.region_name != target_region:
            logger.warning(f"O cliente S3 foi inicializado na região '{s3_client.meta.region_name}', mas o upload é para '{target_region}'.")

        for root, _, files in os.walk(local_path):
            for filename in files:
                # --- [MODIFICAÇÃO INÍCIO] ---
                # Ignora os arquivos de metadados para não fazer upload deles
                if filename.endswith(".metadata.json"):
                    continue
                # --- [MODIFICAÇÃO FIM] ---

                local_file = os.path.join(root, filename)
                s3_key = os.path.relpath(local_file, local_path).replace(os.sep, '/')
                
                # --- [MODIFICAÇÃO INÍCIO] ---
                # Procura pelo arquivo de metadados correspondente e o carrega
                extra_args = {}
                metadata_file = local_file + ".metadata.json"
                if os.path.exists(metadata_file):
                    try:
                        with open(metadata_file, 'r', encoding='utf-8') as f:
                            extra_args = json.load(f)
                        logger.info(f"  -> Metadados encontrados para '{s3_key}', aplicando: {extra_args}")
                    except json.JSONDecodeError:
                        logger.warning(f"Arquivo de metadados '{metadata_file}' está corrompido. Upload será feito sem metadados extras.")
                # --- [MODIFICAÇÃO FIM] ---

                try:
                    # Adiciona o parâmetro ExtraArgs na chamada de upload
                    upload_client.upload_file(local_file, target_bucket_name, s3_key, ExtraArgs=extra_args)
                except ClientError as e:
                    logger.error(f"Falha ao fazer upload de '{local_file}' para 's3://{target_bucket_name}/{s3_key}': {e}")

    logger.info("Upload de conteúdo para S3 concluído.")

# Adicionar esta nova função junto com as outras funções auxiliares

def _upload_s3_content_for_state(current_state_name):
    """
    NOVA FUNÇÃO: Faz upload do conteúdo S3 APENAS para buckets associados
    ao estado do Terraform que acabou de ser executado.
    """
    logger.info(f"--- Verificando conteúdo S3 para upload após o estado '{current_state_name}' ---")
    s3_content_base_path = os.path.join(ARTIFACTS_DIR, "s3_content")

    # Passo 1: Filtrar a lista de S3 para encontrar apenas os que pertencem ao estado atual
    s3_targets_for_this_state = []
    for target_list in json_data.get("ListS3", []):
        # A nova lógica requer 4 elementos, sendo o último o nome do estado
        if len(target_list) >= 4 and target_list[3] == current_state_name:
            s3_targets_for_this_state.append(target_list)

    # Passo 2: Se nenhum bucket corresponde a este estado, não fazer nada e sair
    if not s3_targets_for_this_state:
        logger.info(f"Nenhum bucket S3 associado ao estado '{current_state_name}'. Nenhum upload necessário nesta etapa.")
        return

    logger.info(f"Encontrado(s) {len(s3_targets_for_this_state)} bucket(s) para popular após o estado '{current_state_name}'.")

    # Passo 3: Executar a lógica de upload (copiada da função original) para cada bucket encontrado
    for target_list in s3_targets_for_this_state:
        # Desempacota a lista de forma segura, ignorando elementos extras
        target_bucket_name, target_region, *_ = target_list
        # O sufixo do ambiente já foi aplicado durante a fase de contextualização
        local_path = os.path.join(s3_content_base_path, target_bucket_name)

        if not os.path.isdir(local_path):
            logger.info(f"Nenhum conteúdo local encontrado em '{local_path}' para o bucket '{target_bucket_name}'. Pulando.")
            continue
            
        logger.info(f"Fazendo upload de '{local_path}' para s3://{target_bucket_name}")
        
        # A lógica de upload abaixo é idêntica à da função _upload_s3_content()
        upload_client = s3_client
        if s3_client.meta.region_name != target_region:
            logger.warning(f"O cliente S3 foi inicializado na região '{s3_client.meta.region_name}', mas o upload é para '{target_region}'.")

        for root, _, files in os.walk(local_path):
            for filename in files:
                if filename.endswith(".metadata.json"):
                    continue

                local_file = os.path.join(root, filename)
                s3_key = os.path.relpath(local_file, local_path).replace(os.sep, '/')
                
                extra_args = {}
                metadata_file = local_file + ".metadata.json"
                if os.path.exists(metadata_file):
                    try:
                        with open(metadata_file, 'r', encoding='utf-8') as f:
                            extra_args = json.load(f)
                        logger.info(f"  -> Metadados encontrados para '{s3_key}', aplicando: {extra_args}")
                    except json.JSONDecodeError:
                        logger.warning(f"Arquivo de metadados '{metadata_file}' está corrompido. Upload será feito sem metadados extras.")
                try:
                    upload_client.upload_file(local_file, target_bucket_name, s3_key, ExtraArgs=extra_args)
                except ClientError as e:
                    logger.error(f"Falha ao fazer upload de '{local_file}' para 's3://{target_bucket_name}/{s3_key}': {e}")

    logger.info(f"Upload de conteúdo S3 para o estado '{current_state_name}' concluído.")

def _process_and_save_ec2_artifacts():
    """
    Processa as listas 'ListEC2' e 'ListLaunchTemplate' do manifesto.
    Busca os user_data de forma otimizada, limpa-os e salva como artefatos locais.
    (VERSÃO COM LOGS DE DEPURAÇÃO DETALHADOS PARA LAUNCH TEMPLATES)
    """
    logger.info("Iniciando processamento de artefatos de UserData (EC2 e Launch Templates)...")
    if 'ec2' not in boto3_clients:
        logger.error("Cliente Boto3 para EC2 não foi inicializado. Verifique a função get_boto3_clients_with_assumed_role.")
        raise RuntimeError("EC2 client not available.")
    
    ec2_client = boto3_clients['ec2']
    dev_suffix = '-dev'
    userdata_dir = os.path.join(ARTIFACTS_DIR, "ec2_userdata")
    os.makedirs(userdata_dir, exist_ok=True)

    # --- Parte 1: Instâncias EC2 (Lógica inalterada) ---
    ec2_sources = json_data.get("ListEC2", [])
    if ec2_sources:
        source_names_for_download = [f"{_split_resource_name(s[0], is_test_env=True)[0]}{dev_suffix}" for s in ec2_sources]
        logger.info(f"Buscando instâncias EC2 com tags Name: {source_names_for_download}")
        try:
            response = ec2_client.describe_instances(Filters=[{'Name': 'tag:Name', 'Values': source_names_for_download}])
            tag_to_instance_id = {}
            for res in response.get('Reservations', []):
                for inst in res.get('Instances', []):
                    if inst.get('State', {}).get('Name') not in ['terminated', 'shutting-down']:
                        for tag in inst.get('Tags', []):
                            if tag['Key'] == 'Name':
                                tag_to_instance_id[tag['Value']] = inst['InstanceId']
                                break
            for source_list in ec2_sources:
                base_name, _ = _split_resource_name(source_list[0], is_test_env=True)
                source_name = f"{base_name}{dev_suffix}"
                instance_id = tag_to_instance_id.get(source_name)
                if not instance_id:
                    logger.warning(f"Nenhuma instância EC2 ativa encontrada para a tag '{source_name}'. Pulando.")
                    continue
                result = ec2_client.describe_instance_attribute(InstanceId=instance_id, Attribute='userData')
                if 'UserData' in result and 'Value' in result['UserData']:
                    import base64
                    decoded_userdata = base64.b64decode(result['UserData']['Value']).decode('utf-8')
                    variables_block_regex = r'# --- BEGIN CLOUDMAN VARIABLES ---\n.*?# --- END CLOUDMAN VARIABLES ---\n'
                    cleaned_script = re.sub(variables_block_regex, '', decoded_userdata, flags=re.DOTALL).strip()
                    artifact_path = os.path.join(userdata_dir, f"{base_name}.sh")
                    with open(artifact_path, 'w', encoding='utf-8') as f: f.write(cleaned_script)
                    logger.info(f"  -> Artefato do UserData (EC2) para '{base_name}' salvo em '{artifact_path}'.")
        except Exception as e:
            logger.error(f"Ocorreu um erro durante o processamento em lote das instâncias EC2: {e}")

    # --- Parte 2: Launch Templates (Lógica de logs de depuração adicionada) ---
    lt_sources = json_data.get("ListLaunchTemplate", [])
    for source_list in lt_sources:
        base_name, _ = _split_resource_name(source_list[0], is_test_env=True)
        source_name_for_download = f"{base_name}{dev_suffix}"
        
        try:
            logger.info(f"Buscando Launch Template com tag Name: {source_name_for_download}")
            response_lt = ec2_client.describe_launch_templates(Filters=[{'Name': 'tag:Name', 'Values': [source_name_for_download]}])
            
            if not response_lt.get('LaunchTemplates'):
                logger.warning(f"Nenhum Launch Template encontrado para a tag '{source_name_for_download}'. Pulando.")
                continue

            lt_id = response_lt['LaunchTemplates'][0]['LaunchTemplateId']
            
            # [LOG DE DEPURAÇÃO 1] Confirma que o template foi encontrado e qual versão será buscada.
            logger.info(f"Launch Template encontrado com ID: {lt_id}. Buscando versão '$Default'...")
            response_version = ec2_client.describe_launch_template_versions(LaunchTemplateId=lt_id, Versions=['$Default'])
            
            # [LOG DE DEPURAÇÃO 2] Imprime a resposta completa da API para análise.
            import pprint
            logger.info(f"RESPOSTA COMPLETA DA API 'describe_launch_template_versions':\n{pprint.pformat(response_version)}")

            # Lógica de verificação mais robusta para evitar erros e logar o ponto de falha.
            if 'LaunchTemplateVersions' in response_version and response_version['LaunchTemplateVersions']:
                version_data = response_version['LaunchTemplateVersions'][0]
                
                if 'LaunchTemplateData' in version_data and 'UserData' in version_data['LaunchTemplateData']:
                    import base64
                    encoded_userdata = version_data['LaunchTemplateData']['UserData']
                    decoded_userdata = base64.b64decode(encoded_userdata).decode('utf-8')
                    
                    variables_block_regex = r'# --- BEGIN CLOUDMAN VARIABLES ---\n.*?# --- END CLOUDMAN VARIABLES ---\n'
                    cleaned_script = re.sub(variables_block_regex, '', decoded_userdata, flags=re.DOTALL).strip()

                    artifact_path = os.path.join(userdata_dir, f"{base_name}.sh")
                    with open(artifact_path, 'w', encoding='utf-8') as f: f.write(cleaned_script)
                    logger.info(f"  -> Artefato do UserData (Launch Template) para '{base_name}' salvo em '{artifact_path}'.")
                else:
                    # [LOG DE DEPURAÇÃO 3] Informa que o UserData não foi encontrado na resposta.
                    logger.warning(f"A versão Default do Launch Template '{lt_id}' foi encontrada, mas NÃO contém o campo 'UserData'. O artefato não será criado.")
            else:
                # [LOG DE DEPURAÇÃO 4] Informa que a API não retornou nenhuma versão.
                logger.warning(f"A API não retornou nenhuma versão para o Launch Template '{lt_id}'.")

        except Exception as e:
            # [LOG DE DEPURAÇÃO 5] Captura e exibe o erro completo, incluindo erros de permissão.
            logger.error(f"FALHA CRÍTICA ao processar o Launch Template '{source_name_for_download}'. Erro detalhado:", exc_info=True)

# --- FUNÇÃO PRINCIPAL DE ORQUESTRAÇÃO (VERSÃO REATORADA) ---
def main():
    # --- FASE 1: Preparação de Artefatos (Sem alterações) ---
    if command_type in ["apply", "destroy"]:
        try:
            if command_type == "apply" and IsTest:
                _create_snapshot()
            else:
                _restore_snapshot()
            _contextualize_artifacts()
            logger.info("FASE 1 (Preparação de Artefatos) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA CRÍTICA na Fase 1. A execução será interrompida. Erro: {e}", exc_info=True)
            sys.exit(1)

    # --- FASE 2: Execução do Terraform (com lógica de upload integrada) ---
    logger.info("--- FASE 2: INICIANDO EXECUÇÃO DO TERRAFORM ---")
    states_to_process = (json_data.get("ListStatesBlue", [])[::-1] if not IsTest else json_data.get("ListStates", [])[::-1]) if command_type == "destroy" else json_data.get("ListStates", [])
    script_dir = os.path.dirname(os.path.abspath(__file__))
    s3_bucket_for_tf_files = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')

    for state_name in states_to_process:
        logger.info(f"================ Processando estado: {state_name} ================")
        state_dir = os.path.join("/tmp/states", state_name)
        os.makedirs(state_dir, exist_ok=True)
        
        # Download dos arquivos do Terraform (sem alterações)
        for file_name in ['main.tf', 'terraform.lock.hcl']:
            try: s3_client.download_file(s3_bucket_for_tf_files, f"states/{state_name}/{file_name}", os.path.join(state_dir, file_name))
            except ClientError:
                if file_name == 'main.tf': logger.error(f"main.tf para '{state_name}' não encontrado. Abortando."); sys.exit(1)
        if os.path.exists(os.path.join(state_dir, 'terraform.lock.hcl')):
            os.rename(os.path.join(state_dir, 'terraform.lock.hcl'), os.path.join(state_dir, '.terraform.lock.hcl'))
        
        # Modificação do main.tf (sem alterações)
        try:
            _modify_and_prepare_main_tf(
                state_dir=state_dir,
                state_name=state_name,
                manifest_data=json_data,
                role_arn_to_assume=DYNAMIC_ASSUMABLE_ROLE_ARN,
                is_test_env=IsTest,
                command_type=command_type
            )
        except Exception as e:
            logger.error(f"Falha crítica ao modificar o main.tf para {state_name}: {e}", exc_info=True); sys.exit(1)

        # Execução do Terraform via script auxiliar (sem alterações)
        try:
            logger.info(f"Executando InitTerraform.py para o estado '{state_name}'...")
            env = os.environ.copy()
            env['STATE_NAME'] = state_name
            env['MANIFEST_JSON'] = json.dumps(json_data) 
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

        # ### INÍCIO DA MODIFICAÇÃO DA ORQUESTRAÇÃO ###
        # Após a execução bem-sucedida do Terraform, chamamos a nova função de upload
        # que atuará de forma inteligente, apenas para o estado atual.
        if command_type == "apply":
            try:
                _upload_s3_content_for_state(state_name)
            except Exception as e:
                logger.error(f"FALHA ao fazer upload de conteúdo S3 para o estado '{state_name}': {e}", exc_info=True)
                sys.exit(1)
        # ### FIM DA MODIFICAÇÃO DA ORQUESTRAÇÃO ###

    logger.info("FASE 2 (Execução do Terraform) concluída com sucesso.")

    # ### MODIFICAÇÃO FINAL ###
    # A antiga FASE 3, que fazia o upload de TUDO no final, foi removida.
    # A lógica agora acontece de forma incremental dentro do loop da FASE 2.
    # if command_type == "apply":
    #     try:
    #         _upload_s3_content()
    #         logger.info("FASE 3 (Povoamento da Infraestrutura) concluída com sucesso.")
    #     except Exception as e:
    #         logger.error(f"FALHA na Fase 3: {e}", exc_info=True); sys.exit(1)

    # Verificações finais (sem alterações)
    if not json_data.get("Approved", False) and command_type == "destroy":
        logger.error("Comando 'destroy' recebido para versão não aprovada. Gerando falha para 'Retry'."); sys.exit(1)

    logger.info("Processo de CI/CD do backend concluído com sucesso.")

if __name__ == "__main__":
    main()

