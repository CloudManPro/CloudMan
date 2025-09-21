# modify_main_tf.py (Versão 3.0.0 - Simplificada e Alinhada com TerraBatch Unificado)
import os
import re
import logging
import sys

# --- CONFIGURAÇÃO ---
# Diretório padrão onde o TerraBatch.py prepara os artefatos
ARTIFACTS_DIR = '/tmp/artifacts'

# Padrão de caminho de desenvolvimento a ser substituído
DEV_PATH_PREFIX = 'C:/Cloudman/'

# Configurar o logger
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

# --- LÓGICA DE INJEÇÃO DE ROLE (FUNCIONALIDADE PRESERVADA) ---
def inject_assume_role(code, role_arn):
    """
    Injeta o bloco 'assume_role' em todos os provedores 'aws' encontrados no código.
    Esta funcionalidade crítica para cross-account foi mantida intacta.
    """
    if not role_arn:
        logger.info("Nenhuma Role ARN para assume_role foi fornecida. Pulando injeção.")
        return code

    logger.info(f"Role ARN detectada. Injetando bloco assume_role para: {role_arn}")

    assume_role_block = f'''
  assume_role {{
    role_arn     = "{role_arn}"
    session_name = "Cloudman_CodeBuild_CrossAccount_Session"
  }}
'''
    provider_regex = r'(provider\s+(?:"aws"|aws)\s*\{)([\s\S]*?)(\})'
    
    # Se nenhum provedor 'aws' for encontrado, injeta um provedor padrão.
    if not re.search(provider_regex, code, flags=re.MULTILINE):
        logger.warning("Nenhum provedor 'aws' encontrado. Injetando um provedor padrão no início do arquivo.")
        provider_config_to_inject = f'''
provider "aws" {{{assume_role_block}}}
'''
        return provider_config_to_inject + "\n\n" + code
    
    # Se provedores 'aws' existem, modifica cada um deles.
    def add_assume_role_to_provider(match):
        opening, body, closing = match.groups()
        # Evita adicionar o bloco se ele já existir
        if 'assume_role' in body:
            return match.group(0)
        return f"{opening}{body}{assume_role_block}{closing}"

    modified_code = re.sub(provider_regex, add_assume_role_to_provider, code, flags=re.MULTILINE)
    logger.info("Bloco(s) de provedor 'aws' atualizado(s) com assume_role.")
    return modified_code

# --- FUNÇÃO PRINCIPAL DE MODIFICAÇÃO ---
def modify_terraform_file(file_path, role_arn):
    """
    Aplica todas as modificações necessárias no arquivo Terraform:
    1. Injeta a configuração 'assume_role' para execução cross-account.
    2. Mapeia os caminhos de arquivos de desenvolvimento para os caminhos locais do CodeBuild.
    """
    logger.info(f"Processando arquivo: {file_path}")
    
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            content = file.read()
    except FileNotFoundError:
        logger.error(f"Arquivo não encontrado: {file_path}")
        sys.exit(1)

    # PASSO 1: Injetar a configuração 'assume_role' (FUNCIONALIDADE PRESERVADA)
    content = inject_assume_role(content, role_arn)

    # PASSO 2: Mapear caminhos de arquivos (LÓGICA SIMPLIFICADA)
    # Função auxiliar para ser usada com re.sub
    def path_replacer(match):
        # O caminho completo encontrado, ex: "C:/Cloudman/lambdas/my_func.zip"
        full_dev_path = match.group(0)
        
        # Remove o prefixo para obter o caminho relativo, ex: "lambdas/my_func.zip"
        relative_path = full_dev_path.replace(DEV_PATH_PREFIX, '')
        
        # Constrói o novo caminho absoluto dentro do ambiente do CodeBuild
        new_path = os.path.join(ARTIFACTS_DIR, relative_path).replace("\\", "/")
        
        logger.info(f"Mapeando caminho: '{full_dev_path}' -> '{new_path}'")
        return new_path

    # Usa regex para encontrar e substituir todos os caminhos de desenvolvimento
    # O padrão busca pelo prefixo seguido de qualquer caractere exceto aspas
    dev_path_pattern = f'{re.escape(DEV_PATH_PREFIX)}[^"]*'
    content, num_replacements = re.subn(dev_path_pattern, path_replacer, content)

    if num_replacements > 0:
        logger.info(f"{num_replacements} caminho(s) de desenvolvimento foram remapeados.")
    else:
        logger.info("Nenhum caminho de desenvolvimento encontrado para remapear.")
    
    # Salva o conteúdo modificado de volta no arquivo
    try:
        with open(file_path, 'w', encoding='utf-8') as file:
            file.write(content)
        logger.info(f"Arquivo '{file_path}' atualizado e salvo com sucesso.")
    except Exception as e:
        logger.error(f"Erro ao salvar o arquivo '{file_path}': {e}")
        sys.exit(1)


def main():
    """
    Ponto de entrada do script. Lê variáveis de ambiente e inicia o processo de modificação.
    """
    # O TerraBatch.py define o CWD, então podemos referenciar 'main.tf' diretamente.
    main_tf_path = 'main.tf' 

    # Lê a role ARN da variável de ambiente (se existir)
    role_arn_to_assume = os.getenv('DYNAMIC_ASSUMABLE_ROLE_ARN')

    if not os.path.exists(main_tf_path):
        logger.error(f"O arquivo 'main.tf' não foi encontrado no diretório de trabalho atual: {os.getcwd()}")
        sys.exit(1)

    modify_terraform_file(main_tf_path, role_arn_to_assume)

    logger.info("modify_main_tf.py concluído com sucesso.")


if __name__ == "__main__":
    main()
