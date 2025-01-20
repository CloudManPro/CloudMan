import os
import subprocess
import sys
import boto3
import logging
import time
from botocore.exceptions import ClientError
import threading  # Import necessário para a thread de falha

# Configure o logger com nível WARNING por padrão
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()
user_id = os.getenv('USER_ID')
state_name = os.getenv('STATE_NAME')
command = os.getenv('COMMAND')
build_id = os.getenv('CODEBUILD_BUILD_ID')
s3_bucket = os.getenv('AWS_S3_BUCKET_SOURCE_NAME_0')
s3_prefix = f"states/{state_name}/"
table_name = os.getenv('AWS_DYNAMODB_TABLE_TARGET_NAME_0')
dynamo_region = os.getenv('AWS_DYNAMODB_TABLE_TARGET_REGION_0')
dynamodb = boto3.resource('dynamodb', region_name=dynamo_region)
if table_name:
    table = dynamodb.Table(table_name)
s3_client = boto3.client('s3')
logger.info(f"InitTerraform command: {command}")

ALLOWED_FILES = [
    '.terraform.lock.hcl',
    'terraform.tfstate',
    'terraform.tfstate.backup',
    '.terraform/terraform.tfstate'
]

MIN_TTL_SECONDS = 2400  # 24 horas


def should_upload(file_path):
    """Verifica se o arquivo está na lista permitida."""
    relative_path = os.path.relpath(file_path, start='/tmp/states')
    for allowed_file in ALLOWED_FILES:
        if relative_path.endswith(allowed_file):
            return True
    return False


def upload_files_to_s3(local_dir, bucket, s3_prefix):
    """Faz upload de arquivos permitidos para o S3."""
    for root, dirs, files in os.walk(local_dir):
        for file in files:
            local_path = os.path.join(root, file)
            if should_upload(local_path):
                relative_path = os.path.relpath(local_path, local_dir)
                s3_path = os.path.join(
                    s3_prefix, relative_path).replace("\\", "/")
                try:
                    logger.info(
                        f"Enviando {local_path} para s3://{bucket}/{s3_path}")
                    s3_client.upload_file(local_path, bucket, s3_path)
                except ClientError as e:
                    logger.error(f"Erro ao enviar {local_path} para S3: {e}")
                    sys.exit(1)


def delete_s3_prefix(bucket, prefix):
    """Deleta todos os objetos dentro de um prefixo específico no S3."""
    logger.info(f"Iniciando deleção de s3://{bucket}/{prefix}")
    paginator = s3_client.get_paginator('list_objects_v2')
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            if 'Contents' in page:
                objects_to_delete = [{'Key': obj['Key']}
                                     for obj in page['Contents']]
                if objects_to_delete:
                    logger.info(f"Deletando objetos: {objects_to_delete}")
                    s3_client.delete_objects(
                        Bucket=bucket,
                        Delete={'Objects': objects_to_delete}
                    )
        logger.info(f"Deleção concluída para s3://{bucket}/{prefix}")
    except ClientError as e:
        logger.error(f"Erro ao deletar objetos no S3: {e}")
        sys.exit(1)


def delete_dynamodb_entry(bucket, state_name):
    """Deleta a entrada no DynamoDB referente ao estado destruído."""
    # Construir a LockID conforme o padrão fornecido
    # Exemplo: s3-cloudman-terraform-backend-us-east-2/states/State10/State10.tfstate-md5
    lock_id = f"{bucket}/states/{state_name}/{state_name}.tfstate-md5"
    try:
        if table_name:
            response = table.delete_item(
                Key={
                    'LockID': lock_id
                }
            )
            logger.info(f"Entrada no DynamoDB deletada com sucesso: {lock_id}")
    except ClientError as e:
        logger.error(f"Erro ao deletar entrada no DynamoDB: {e}")


def set_executable_permissions(directory):
    """Define permissões executáveis para os arquivos no diretório .terraform."""
    for root, dirs, files in os.walk(directory):
        for file in files:
            file_path = os.path.join(root, file)
            if 'terraform-provider' in file:
                logger.info(
                    f"Definindo permissões executáveis para {file_path}")
                os.chmod(file_path, 0o755)


def run_terraform_init(working_dir):
    """Executa 'terraform init -reconfigure'."""
    command = ["terraform", "init", "-reconfigure"]
    logger.info("Executando 'terraform init -reconfigure'...")
    result = subprocess.run(command, cwd=working_dir,
                            capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"Erro ao inicializar o Terraform: {result.stderr}")
        raise Exception("Falha na inicialização do Terraform")
    logger.info("Terraform inicializado com sucesso.")


def run_terraform_command(command, working_dir):
    """Executa comandos do Terraform e exibe a saída em tempo real."""
    base_command = ["terraform", command, "-no-color"]
    if command in ["apply", "destroy"]:
        base_command.append("-auto-approve")

    logger.info(f"Executando o comando Terraform: {' '.join(base_command)}")

    # Verifica se a falha deve ser injetada
    trigger_failure = os.getenv('TRIGGER_FAILURE', 'false').lower() == 'true'
    if trigger_failure and command in ["apply", "destroy"]:
        logger.info(
            "Modo de falha ativado. Falha será injetada após iniciar o comando Terraform.")

        def fail_after_delay():
            delay_seconds = 5  # Tempo antes de injetar a falha
            logger.info(
                f"Thread de falha iniciará em {delay_seconds} segundos.")
            time.sleep(delay_seconds)
            logger.error("Falha simulada para teste de robustez.")
            os._exit(1)  # Força o encerramento imediato do processo

        threading.Thread(target=fail_after_delay, daemon=True).start()

    proc = subprocess.Popen(base_command, cwd=working_dir,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    # Exibe a saída em tempo real
    for line in iter(proc.stdout.readline, ''):
        if line:
            logger.info(line.strip())

    proc.stdout.close()
    return_code = proc.wait()

    if return_code != 0:
        logger.error(
            f"Erro ao executar {command} com código de retorno {return_code}")
        return False

    logger.info(f"Comando {command} executado com sucesso.")
    return True


def register_build_in_dynamodb(build_id, s3_path):
    """Registra BuildID e S3Path no DynamoDB com TTL."""
    ttl = int(time.time()) + \
        MIN_TTL_SECONDS  # TTL definido para 24 horas no futuro
    try:
        if table_name:
            response = table.put_item(
                Item={
                    'LockID': build_id,
                    'S3Path': s3_path,
                    'TTL': ttl  # Atributo TTL
                }
            )
            logger.info(f"Registro no DynamoDB bem-sucedido: {response}")
    except ClientError as e:
        logger.error(f"Erro ao registrar no DynamoDB: {e}")


def main():

    logger.info(
        f"Parâmetros recebidos: user_id={user_id}, state_name={state_name}, command={command}, build_id={build_id}")

    # Registrar o BuildID no DynamoDB com TTL
    register_build_in_dynamodb(build_id, f"s3://{s3_bucket}/{s3_prefix}")

    # Diretório de trabalho do Terraform
    work_dir = f'/tmp/states/{state_name}'

    if not os.path.exists(work_dir):
        logger.error(f"Diretório de trabalho não encontrado: {work_dir}")
        sys.exit(1)

    # Define permissões executáveis para os provedores do Terraform
    set_executable_permissions(os.path.join(work_dir, '.terraform'))

    # Inicializar o Terraform
    try:
        run_terraform_init(work_dir)
    except Exception as e:
        logger.error(f"Erro ao inicializar o Terraform: {e}")

    # Executar o comando Terraform especificado
    command_success = run_terraform_command(command, work_dir)
    if not command_success:
        logger.error(f"Erro ao executar {command}")
        sys.exit(1)

    logger.info("Execução do Terraform finalizada com sucesso.")

    # Se o comando for 'destroy', deletar a pasta correspondente no S3 e a entrada no DynamoDB
    if command == "destroy":
        delete_s3_prefix(s3_bucket, s3_prefix)
        delete_dynamodb_entry(s3_bucket, state_name)
    # else:
    #    # Fazer upload dos arquivos necessários para o S3
    #    upload_files_to_s3(work_dir, s3_bucket, s3_prefix)


if __name__ == "__main__":
    main()
