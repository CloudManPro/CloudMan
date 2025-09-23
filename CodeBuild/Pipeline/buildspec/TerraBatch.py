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
            'lambda': boto3.client('lambda', aws_access_key_id=credentials['AccessKeyId'], aws_secret_access_key=credentials['SecretAccessKey'], aws_session_token=credentials['SessionToken'])
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
    (Função movida do antigo modify_main_tf.py)
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

def _modify_and_prepare_main_tf(state_dir, state_name, manifest_data, role_arn_to_assume, is_test_env):
    """
    Modifica o arquivo main.tf em memória antes da execução do Terraform.
    Esta função absorve e corrige a lógica do antigo script modify_main_tf.py.
    """
    main_tf_path = os.path.join(state_dir, 'main.tf')
    logger.info(f"Processando arquivo de configuração: {main_tf_path}")

    with open(main_tf_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # ETAPA 1: Injetar a role (lógica movida)
    content = inject_assume_role(content, role_arn_to_assume)

    # ETAPA 2: Substituir os placeholders (lógica movida e corrigida)
    lambdas_from_manifest = manifest_data.get("ListLambda", [])
    if not lambdas_from_manifest:
        logger.info(f"[{state_name}/modify] Nenhuma Lambda listada no manifesto. Pulando substituição de placeholders.")
    else:
        logger.info(f"[{state_name}/modify] Iniciando substituição de placeholders para o estado '{state_name}'...")
        # Extrai o sufixo do estado atual (ex: '-prod-3')
        _, target_suffix = _split_resource_name(state_name, is_test_env=is_test_env)

        for lambda_info in lambdas_from_manifest:
            manifest_lambda_name = lambda_info[0]
            # Extrai o nome base da lambda do manifesto (ex: 'LPipe1')
            base_name, _ = _split_resource_name(manifest_lambda_name, is_test_env=is_test_env)
            
            # **A CORREÇÃO PRINCIPAL**: Constrói o nome completo do recurso alvo usando o contexto do estado atual
            target_full_name = f"{base_name}{target_suffix}"
            
            logger.info(f"[{state_name}/modify] Mapeando: {manifest_lambda_name} -> {target_full_name}")

            placeholder_to_find = f"Change_File_Name_{target_full_name}"
            new_artifact_path = os.path.join(ARTIFACTS_DIR, "lambdas", f"{target_full_name}.zip").replace("\\", "/")
            
            string_to_find_filename = f'"{placeholder_to_find}"'
            replacement_string_filename = f'"{new_artifact_path}"'
            string_to_find_hash = f'filebase64sha256("{placeholder_to_find}")'
            replacement_string_hash = f'filebase64sha256("{new_artifact_path}")'

            original_content = content
            content = content.replace(string_to_find_filename, replacement_string_filename)
            content = content.replace(string_to_find_hash, replacement_string_hash)
            
            if original_content == content:
                 logger.warning(f"  -> Nenhum placeholder '{placeholder_to_find}' encontrado para a Lambda '{target_full_name}'.")
            else:
                 logger.info(f"  -> Placeholders para '{target_full_name}' substituídos com sucesso.")
    
    logger.info(f"--- CONTEÚDO FINAL DO main.tf PARA O ESTADO {state_name} ---")
    # Para evitar logs muito longos, podemos imprimir apenas algumas linhas
    for i, line in enumerate(content.splitlines()):
        if i < 15: # Imprime as primeiras 15 linhas
            logger.info(line)
        elif i == 15:
            logger.info("...")
            break
    logger.info("------------------------------------------------------")

    with open(main_tf_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    logger.info(f"[{state_name}/modify] Arquivo '{main_tf_path}' processado e salvo com sucesso.")


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
    logger.info("--- FASE 1: INICIANDO CRIAÇÃO DO SNAPSHOT (MODO GENÉRICO) ---")
    if not all([Version, ArtifactsBucket]): raise ValueError("'Version' e 'ArtifactsBucket' são obrigatórios.")
    _clear_dir(ARTIFACTS_DIR)
    dev_suffix = '-dev'
    for source_list in json_data.get("ListLambda", []):
        name_from_manifest, region, _ = source_list
        base_name, _ = _split_resource_name(name_from_manifest, is_test_env=True)
        source_name_for_download = f"{base_name}{dev_suffix}"
        generic_artifact_name = f"{base_name}.zip"
        logger.info(f"Mapeando fonte Lambda: '{name_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando como: '{generic_artifact_name}'")
        _download_lambda_code(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "lambdas", generic_artifact_name))
    for source_list in json_data.get("ListS3", []):
        bucket_from_manifest, region, _ = source_list
        base_bucket_name, _ = _split_resource_name(bucket_from_manifest, is_test_env=True)
        source_name_for_download = f"{base_bucket_name}{dev_suffix}"
        logger.info(f"Mapeando fonte S3: '{bucket_from_manifest}' -> Baixando de: '{source_name_for_download}' -> Salvando em: '{base_bucket_name}'")
        _sync_s3_to_local(source_name_for_download, region, os.path.join(ARTIFACTS_DIR, "s3_content", base_bucket_name))
    _log_directory_contents(ARTIFACTS_DIR, "Arquivos genéricos coletados para inclusão no snapshot")
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
    lambdas_path = os.path.join(ARTIFACTS_DIR, "lambdas")
    if os.path.exists(lambdas_path):
        for lambda_manifest in json_data.get("ListLambda", []):
            base_name, _ = _split_resource_name(lambda_manifest[0], is_test_env=IsTest)
            source_file = os.path.join(lambdas_path, f"{base_name}.zip")
            target_file = os.path.join(lambdas_path, f"{base_name}{target_suffix}.zip")
            if os.path.exists(source_file):
                logger.info(f"Contextualizando para '{command_type}': Renomeando '{source_file}' para '{target_file}'")
                os.rename(source_file, target_file)
    s3_content_path = os.path.join(ARTIFACTS_DIR, "s3_content")
    if os.path.exists(s3_content_path):
        for s3_manifest in json_data.get("ListS3", []):
            base_name, _ = _split_resource_name(s3_manifest[0], is_test_env=IsTest)
            source_dir = os.path.join(s3_content_path, base_name)
            target_dir = os.path.join(s3_content_path, f"{base_name}{target_suffix}")
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
        if not os.path.isdir(local_path): continue
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
        
        # ### INÍCIO DA MODIFICAÇÃO CIRÚRGICA ###
        # A chamada ao subprocesso 'modify_main_tf.py' foi REMOVIDA
        # e substituída por uma chamada de função interna.
        try:
            _modify_and_prepare_main_tf(
                state_dir=state_dir,
                state_name=state_name,
                manifest_data=json_data,
                role_arn_to_assume=DYNAMIC_ASSUMABLE_ROLE_ARN,
                is_test_env=IsTest
            )
        except Exception as e:
            logger.error(f"Falha crítica ao modificar o main.tf para {state_name}: {e}", exc_info=True); sys.exit(1)
        # ### FIM DA MODIFICAÇÃO CIRÚRGICA ###

        try:
            logger.info(f"Executando InitTerraform.py para o estado '{state_name}'...")
            env = os.environ.copy() # Passa o ambiente para o subprocesso
            env['STATE_NAME'] = state_name
            # O MANIFEST_JSON não é mais necessário para o InitTerraform, mas pode ser mantido por compatibilidade
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

    logger.info("FASE 2 (Execução do Terraform) concluída com sucesso.")

    if command_type == "apply":
        try:
            _upload_s3_content()
            logger.info("FASE 3 (Povoamento da Infraestrutura) concluída com sucesso.")
        except Exception as e:
            logger.error(f"FALHA na Fase 3: {e}", exc_info=True); sys.exit(1)

    if not json_data.get("Approved", False) and command_type == "destroy":
        logger.error("Comando 'destroy' recebido para versão não aprovada. Gerando falha para 'Retry'."); sys.exit(1)

    logger.info("Processo de CI/CD do backend concluído com sucesso.")

if __name__ == "__main__":
    main()
