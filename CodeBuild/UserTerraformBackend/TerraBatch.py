import os
import json
import logging
import subprocess
import sys
import boto3

# Configure the main logger
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

# Initialize AWS clients


# Read environment variables
bucket_name = os.getenv('AWS_S3_BUCKET_TARGET_NAME_0')
bucket_region = os.getenv('AWS_S3_BUCKET_TARGET_REGION_0')
s3_client = boto3.client('s3', region_name=bucket_region)

build_id = os.getenv('CODEBUILD_BUILD_ID')
table_name = os.getenv('AWS_DYNAMODB_TABLE_TARGET_NAME_0')
dynamo_region = os.getenv('AWS_DYNAMODB_TABLE_TARGET_REGION_0')
user_id = os.getenv('USER_ID')

# Check environment variables
if not bucket_name:
    raise EnvironmentError("Variable 'AWS_S3_BUCKET_TARGET_NAME_0' not found.")

command = os.getenv('Command')
if not command:
    raise EnvironmentError("Variable 'Command' not found.")

command_array = command.split(',')
command_type = command_array[0]
path = command_array[1] if len(command_array) > 1 else ''
logger.info(f"Command type: {command_type}, Path: {path}")
path_parts = path.split('/')
PipelineName = path_parts[1] if len(path_parts) > 1 else ''
CurrentStageName = path_parts[2] if len(path_parts) > 2 else ''

# Get the directory where the current script is located
script_dir = os.path.dirname(os.path.abspath(__file__))

# Read List.txt
local_file_path = os.path.join(os.getcwd(), 'List.txt')
try:
    with open(local_file_path, 'r', encoding='utf-8') as file:
        file_content = file.read()
    json_data = json.loads(file_content)
    logger.info(f"Arquivo List.txt lido com sucesso")
except Exception as err:
    logger.error(f"Error accessing or processing List.txt: {err}")
    json_data = {}

ListStates = json_data.get("ListStates", [])
ListStatesBlue = json_data.get("ListStatesBlue", [])
Approved = json_data.get("Approved", False)
IsTest = json_data.get("IsTest", False)
NextTestStageName = json_data.get("NextTestStageName", "")
IsNextTest = NextTestStageName == CurrentStageName


def main():
    if command_type == "destroy":
        states_to_process = ListStates[::-
                                       1] if IsTest else ListStatesBlue[::-1]
    else:
        states_to_process = ListStates

    logger.info(f"States to process: {states_to_process}")

    # Set environment variables that remain constant
    os.environ['COMMAND'] = command_type  # Ensure COMMAND is set
    os.environ['AWS_S3_BUCKET_SOURCE_NAME_0'] = bucket_name
    os.environ['CODEBUILD_BUILD_ID'] = build_id if build_id else ''
    os.environ['AWS_DYNAMODB_TABLE_TARGET_NAME_0'] = table_name
    os.environ['AWS_DYNAMODB_TABLE_TARGET_REGION_0'] = dynamo_region
    os.environ['USER_ID'] = user_id if user_id else ''

    # Create a separate logger for InitTerraform.py output without timestamp
    init_logger = logging.getLogger('InitTerraformLogger')
    init_logger.setLevel(logging.INFO)

    # Create handler for init_logger without timestamp
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(message)s')
    handler.setFormatter(formatter)
    init_logger.addHandler(handler)

    # Create a separate logger for modify_main_tf.py output without timestamp
    modify_logger = logging.getLogger('ModifyMainTfLogger')
    modify_logger.setLevel(logging.INFO)

    # Create handler for modify_logger without timestamp
    modify_handler = logging.StreamHandler()
    modify_formatter = logging.Formatter('%(message)s')
    modify_handler.setFormatter(modify_formatter)
    modify_logger.addHandler(modify_handler)

    for state_name in states_to_process:
        logger.info(f"Processing state: {state_name}")

        # Create the necessary directory
        state_dir = os.path.join("/tmp/states", state_name)
        os.makedirs(state_dir, exist_ok=True)

        # Download necessary files from S3
        s3_prefix = f"states/{state_name}/"
        files_to_download = ['main.tf', 'terraform.lock.hcl']

        for file_name in files_to_download:
            s3_key = f"{s3_prefix}{file_name}"
            local_file_path = os.path.join(state_dir, file_name)
            try:
                s3_client.download_file(bucket_name, s3_key, local_file_path)
                logger.info(f"Downloaded {s3_key} to {local_file_path}")
            except Exception as e:
                logger.warning(f"Could not download {s3_key}: {e}")
                if file_name == 'main.tf':
                    logger.error(f"'main.tf' is essential. Exiting.")
                    sys.exit(1)

        # Rename terraform.lock.hcl to .terraform.lock.hcl if it exists
        lockfile_path = os.path.join(state_dir, 'terraform.lock.hcl')
        dot_lockfile_path = os.path.join(state_dir, '.terraform.lock.hcl')
        if os.path.isfile(lockfile_path):
            os.rename(lockfile_path, dot_lockfile_path)
            logger.info(f"Renamed {lockfile_path} to {dot_lockfile_path}")

        # Update only the STATE_NAME environment variable
        os.environ['STATE_NAME'] = state_name

        # Verify that main.tf exists
        main_tf_path = os.path.join(state_dir, 'main.tf')
        if not os.path.isfile(main_tf_path):
            logger.error(f"'main.tf' not found at {main_tf_path}")
            sys.exit(1)

        # Call modify_main_tf.py and capture output in real-time
        try:
            logger.info(f"Calling modify_main_tf.py for state: {state_name}")
            modify_main_tf_path = os.path.join(script_dir, 'modify_main_tf.py')
            process = subprocess.Popen(
                ['python', modify_main_tf_path, state_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                cwd=script_dir  # Run from the script directory
            )
            # Read and log output in real-time
            for stdout_line in iter(process.stdout.readline, ""):
                if stdout_line:
                    modify_logger.info(stdout_line.strip())
            process.stdout.close()
            return_code = process.wait()
            if return_code != 0:
                logger.error(
                    f"modify_main_tf.py failed for state {state_name} with return code {return_code}")
                sys.exit(1)
            logger.info(
                f"modify_main_tf.py executed successfully for state: {state_name}")
        except Exception as e:
            logger.error(
                f"Error executing modify_main_tf.py for state {state_name}: {e}")
            sys.exit(1)

        # Call InitTerraform.py and capture output in real-time
        try:
            logger.info(f"Calling InitTerraform.py for state: {state_name}")
            init_terraform_path = os.path.join(script_dir, 'InitTerraform.py')
            process = subprocess.Popen(
                ['python', init_terraform_path, state_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                cwd=script_dir  # Run from the script directory
            )
            # Read and log output in real-time
            for stdout_line in iter(process.stdout.readline, ""):
                if stdout_line:
                    init_logger.info(stdout_line.strip())
            process.stdout.close()
            return_code = process.wait()
            if return_code != 0:
                logger.error(
                    f"InitTerraform.py failed for state {state_name} with return code {return_code}")
                sys.exit(1)
            logger.info(
                f"InitTerraform.py executed successfully for state: {state_name}")
        except Exception as e:
            logger.error(
                f"Error executing InitTerraform.py for state {state_name}: {e}")
            sys.exit(1)

    if command_type == "apply":
        logger.info(
            "Comando 'apply' detectado. Iniciando execução de Copy.py para copiar recursos.")
        try:
            # Definir o caminho para Copy.py (assumindo que está no mesmo diretório que o script atual)
            copy_script_path = os.path.join(script_dir, 'Copy.py')

            if not os.path.isfile(copy_script_path):
                logger.error(
                    f"Copy.py não encontrado no caminho: {copy_script_path}")
                sys.exit(1)

            # Executar Copy.py como um subprocesso
            process = subprocess.Popen(
                ['python', copy_script_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )

            # Ler e registrar a saída de Copy.py em tempo real
            for stdout_line in iter(process.stdout.readline, ""):
                if stdout_line:
                    logger.info(f"Copy.py: {stdout_line.strip()}")

            process.stdout.close()
            return_code = process.wait()

            if return_code != 0:
                logger.error(
                    f"Copy.py falhou com o código de retorno {return_code}")
                sys.exit(1)

            logger.info("Copy.py executado com sucesso.")
        except Exception as e:
            logger.error(f"Erro ao executar Copy.py: {e}")
            sys.exit(1)
    # **Fim da Adição da Chamada para Copy.py**

    if not Approved and command_type == "destroy":
        logger.info(
            f"Gerando erro para o poder se fazer retry no CodePipeline devido a não aprovação da última versão (green).")
        sys.exit(1)


if __name__ == "__main__":
    main()
