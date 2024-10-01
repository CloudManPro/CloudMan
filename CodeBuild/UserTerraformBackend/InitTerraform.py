import os
import subprocess
import sys
import logging

# Configure o logger
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()


def run_terraform_init(working_dir, reconfigure=False):
    """Executa 'terraform init' para inicializar o Terraform, com a opção de reconfigurar."""
    command = ["terraform", "init"]
    if reconfigure:
        command.append("-reconfigure")

    result = subprocess.run(command, cwd=working_dir,
                            capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"Erro ao inicializar o Terraform: {result.stderr}")
        if "reconfigure" in result.stderr and not reconfigure:
            logger.info(
                "Detectada necessidade de reconfiguração. Tentando novamente com '-reconfigure'.")
            return run_terraform_init(working_dir, reconfigure=True)
        raise Exception("Falha na inicialização do Terraform")
    logger.info("Terraform inicializado com sucesso")


# Configuração do logger
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def run_terraform_command(command, working_dir):
    """Executa um comando Terraform, captura e exibe a saída em tempo real."""
    base_command = ["terraform", command, "-no-color"]
    if command in ["apply", "destroy"]:
        base_command.append("-auto-approve")

    proc = subprocess.Popen(base_command, cwd=working_dir,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    # Exibe a saída em tempo real
    for line in iter(proc.stdout.readline, ''):
        if line:
            logger.info(line.strip())

    proc.stdout.close()
    return_code = proc.wait()

    # Verifica o código de retorno
    if return_code != 0:
        logger.error(
            f"Falha ao executar {command} com código de retorno {return_code}")
        return False

    return True


def main():
    user_id = os.getenv('USER_ID')
    state_name = os.getenv('STATE_NAME')
    command = os.getenv('COMMAND')
    logger.info(
        f"Parâmetros recebidos: user_id={user_id}, state_name={state_name}, command={command}")

    # Diretório de trabalho do CodeBuild
    work_dir = '/tmp'
    terraform_dir = os.path.join(work_dir, 'states', state_name)

    if not os.path.exists(terraform_dir):
        logger.error(f"Diretório Terraform não encontrado: {terraform_dir}")
        sys.exit(1)

    # Tentar executar o comando Terraform diretamente
    if not run_terraform_command(command, terraform_dir):
        logger.info(
            "Erro detectado. Executando terraform init e tentando novamente...")

        # Se falhar, inicializar o Terraform e tentar novamente
        try:
            run_terraform_init(terraform_dir)
            if not run_terraform_command(command, terraform_dir):
                logger.info("Tentando novamente após reconfiguração...")
                run_terraform_init(terraform_dir, reconfigure=True)
                if not run_terraform_command(command, terraform_dir):
                    logger.error(
                        f"Falha ao executar {command} mesmo após terraform init com reconfiguração")
                    sys.exit(1)
        except Exception as e:
            logger.error(f"Erro fatal ao tentar inicializar o Terraform: {e}")
            sys.exit(1)

    logger.info("Execução do Terraform finalizada")
    sys.stdout.flush()  # Garante que tudo foi impresso antes de finalizar


if __name__ == "__main__":
    main()
