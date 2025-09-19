# modify_main_tf.py (Versão 2.0.1 - Com injeção de Role ARN)
import os
import re
import requests
import logging
import json
import sys  # Adicionado para sys.exit

# Configure o logger
logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

# Definir o caminho para armazenar o estado dos arquivos copiados
COPIED_FILES_PATH = '/tmp/copied_files.json'


def load_copied_files():
    """
    Carrega a lista de arquivos já copiados a partir de um arquivo JSON.
    Se o arquivo não existir, retorna um conjunto vazio.
    """
    if os.path.exists(COPIED_FILES_PATH):
        try:
            with open(COPIED_FILES_PATH, 'r') as f:
                copied = set(json.load(f))
                logger.info(
                    f"Carregados {len(copied)} arquivos copiados anteriormente.")
                return copied
        except Exception as e:
            logger.error(f"Erro ao carregar {COPIED_FILES_PATH}: {e}")
            return set()
    else:
        logger.info("Nenhum arquivo copiado anteriormente encontrado.")
        return set()


def save_copied_files(copied_files):
    """
    Salva a lista de arquivos copiados em um arquivo JSON.
    """
    try:
        with open(COPIED_FILES_PATH, 'w') as f:
            json.dump(list(copied_files), f)
        logger.info(
            f"Salvo {len(copied_files)} arquivos copiados em {COPIED_FILES_PATH}.")
    except Exception as e:
        logger.error(f"Erro ao salvar {COPIED_FILES_PATH}: {e}")


def download_file_from_github(repo, file_path, branch, local_path):
    """
    Baixa um arquivo específico do GitHub.
    :param repo: O repositório no formato 'usuario/repositorio'.
    :param file_path: Caminho do arquivo no repositório.
    :param branch: A branch do repositório (ex: 'refs/heads/main').
    :param local_path: Caminho local onde o arquivo será salvo.
    """
    # Ajustar o formato do URL com 'refs/heads' para a branch
    url = f"https://raw.githubusercontent.com/{repo}/{branch}/{file_path}"
    logger.info(f"Baixando {file_path} de {url}")

    response = requests.get(url)

    if response.status_code == 200:
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        with open(local_path, 'wb') as file:
            file.write(response.content)
        logger.info(f"Arquivo baixado e salvo em: {local_path}")
    else:
        logger.error(
            f"Erro ao baixar arquivo do GitHub: {response.status_code} - {response.text}")
        raise Exception(
            f"Erro ao baixar arquivo do GitHub: {response.status_code} - {response.text}")


# --- INÍCIO DA SEÇÃO DE LÓGICA ADAPTADA DO ExecTerraform ---
def inject_assume_role(code, role_arn):
    """
    Injeta o bloco 'assume_role' em todos os provedores 'aws' encontrados no código.
    Esta lógica foi adaptada diretamente da função LoadFiles da Lambda ExecTerraform.
    """
    if not role_arn:
        logger.info("Nenhuma Role ARN encontrada na variável de ambiente DYNAMIC_ASSUMABLE_ROLE_ARN. Pulando injeção.")
        return code

    logger.info(f"Role ARN detectada. Iniciando injeção do bloco assume_role para: {role_arn}")

    # Bloco 'assume_role' que será injetado
    assume_role_block = f'''
  assume_role {{
    role_arn     = "{role_arn}"
    session_name = "Cloudman_CodeBuild_CrossAccount_Session"
  }}
'''
    # Expressão regular robusta para encontrar todos os blocos de provedor 'aws'
    provider_regex = r'(provider\s+(?:"aws"|aws)\s*\{)([\s\S]*?)(\})'
    all_providers = re.findall(provider_regex, code, flags=re.MULTILINE)

    modified_code = code

    if not all_providers:
        logger.warning("Nenhum provedor 'aws' encontrado. Injetando um provedor padrão no início do arquivo.")
        # Se nenhum provedor existe, adiciona um no topo do arquivo.
        provider_config_to_inject = f'''
# Provedor padrão injetado pelo modify_main_tf.py para execução cross-account
provider "aws" {{
  {assume_role_block}
}}
'''
        modified_code = provider_config_to_inject + "\n\n" + modified_code
    else:
        logger.info(f"{len(all_providers)} provedor(es) 'aws' encontrado(s). Processando...")
        # Itera, modifica e substitui cada provedor encontrado
        for opening, body, closing in all_providers:
            original_block_text = f"{opening}{body}{closing}"
            
            # Reconstrói o bloco, injetando 'assume_role' antes do '}' final
            modified_block_text = f"{opening}{body}{assume_role_block}{closing}"
            
            # Substitui o bloco original exato pela sua versão modificada
            modified_code = modified_code.replace(original_block_text, modified_block_text)
            logger.info("Bloco de provedor substituído com sucesso.")

    return modified_code
# --- FIM DA SEÇÃO DE LÓGICA ADAPTADA ---


def modify_terraform_file(file_path, repo, branch, copied_files, role_arn):
    """
    Função principal que aplica todas as modificações necessárias no arquivo Terraform.
    """
    # Ler o conteúdo do arquivo main.tf
    with open(file_path, 'r') as file:
        content = file.read()

    # PASSO 1: Injetar a configuração 'assume_role' (NOVA FUNCIONALIDADE)
    content = inject_assume_role(content, role_arn)

    # PASSO 2: Tratar caminhos de arquivos locais (FUNCIONALIDADE EXISTENTE)
    local_files = re.findall(r'C:/Cloudman[^"\\]*', content)

    if not local_files:
        logger.info("Nenhum 'local_file' (C:/Cloudman/...) encontrado no arquivo main.tf.")
    else:
        logger.info(f"Local files encontrados: {local_files}")

    for local_file in local_files:
        logger.info(f"Processando local_file: {local_file}")
        relative_path = os.path.relpath(local_file, 'C:/Cloudman')
        local_tmp_path = os.path.join('/tmp', relative_path.lstrip('/\\'))
        logger.info(f"Local tmp path: {local_tmp_path}")

        if not local_tmp_path.startswith('/tmp'):
            logger.error(f"Caminho fora de /tmp detectado: {local_tmp_path}")
            continue

        os.makedirs(os.path.dirname(local_tmp_path), exist_ok=True)

        if local_file not in copied_files:
            github_file_path = relative_path.replace("\\", "/")
            github_file_path = re.sub(r'^cloudman/', '', github_file_path)

            logger.info(
                f"Tentando baixar do GitHub: repo={repo}, branch={branch}, path={github_file_path}")
            try:
                download_file_from_github(
                    repo, github_file_path, branch, local_tmp_path)
                copied_files.add(local_file)
            except Exception as e:
                logger.error(f"Erro ao baixar o arquivo do GitHub: {e}")
                sys.exit(1)
        else:
            logger.info(f"Arquivo já copiado anteriormente: {local_file}")

        if local_file in content:
            logger.info(
                f"Substituindo '{local_file}' por '{local_tmp_path}' no arquivo main.tf")
            content = content.replace(local_file, local_tmp_path)
        else:
            logger.warning(
                f"'{local_file}' não encontrado no conteúdo do main.tf para substituição.")
      logger.info("======================================================")
      logger.info("--- CONTEÚDO FINAL DO main.tf ANTES DE SALVAR ---")
      print(content) # Usamos print() para uma saída limpa, sem formatação do logger
      logger.info("--- FIM DO CONTEÚDO FINAL ---")
      logger.info("======================================================")

    # Escrever o conteúdo final (com ambas as modificações) de volta ao arquivo
    try:
        with open(file_path, 'w') as file:
            file.write(content)
        logger.info(f"Arquivo main.tf atualizado e salvo em: {file_path}")
    except Exception as e:
        logger.error(f"Erro ao salvar o arquivo main.tf: {e}")
        sys.exit(1)

    logger.info("Modificação do main.tf concluída com sucesso.")


def main():
    state_name = os.getenv('STATE_NAME')
    if not state_name:
        logger.error("A variável de ambiente 'STATE_NAME' não está definida.")
        sys.exit(1)

    # Nova Lógica: Ler a variável de ambiente para a role cross-account
    role_arn_to_assume = os.getenv('DYNAMIC_ASSUMABLE_ROLE_ARN')

    repo = "CloudManPro/CloudMan"
    branch = "refs/heads/main"

    terraform_dir = f'/tmp/states/{state_name}'
    main_tf_path = os.path.join(terraform_dir, 'main.tf')

    logger.info(
        f"Verificando a existência do arquivo main.tf em: {main_tf_path}")
    if not os.path.exists(main_tf_path):
        logger.error(
            f"O arquivo main.tf não foi encontrado em: {main_tf_path}")
        sys.exit(1)

    copied_files = load_copied_files()

    # Modificar o main.tf, passando o role_arn para ser injetado
    modify_terraform_file(main_tf_path, repo, branch, copied_files, role_arn_to_assume)

    save_copied_files(copied_files)

    logger.info("modify_main_tf.py concluído com sucesso.")


if __name__ == "__main__":
    main()


