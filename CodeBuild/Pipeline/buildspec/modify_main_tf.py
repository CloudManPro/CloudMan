import os
import re
import requests
import logging
import json

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


def modify_main_tf(file_path, repo, branch, copied_files):
    # Ler o conteúdo do arquivo main.tf
    with open(file_path, 'r') as file:
        content = file.read()

    # Encontrar todos os caminhos de arquivo local que começam com C:/Cloudman
    local_files = re.findall(r'C:/Cloudman[^"\\]*', content)

    if not local_files:
        logger.info("Nenhum 'local_file' encontrado no arquivo main.tf.")
    else:
        logger.info(f"Local files encontrados: {local_files}")

    for local_file in local_files:
        logger.info(f"Processando local_file: {local_file}")

        # Transformar o caminho para o formato /tmp/...
        relative_path = os.path.relpath(local_file, 'C:/Cloudman')
        # Garantir que o caminho seja dentro de /tmp
        local_tmp_path = os.path.join('/tmp', relative_path.lstrip('/\\'))
        logger.info(f"Local tmp path: {local_tmp_path}")

        # Certificar-se de que estamos trabalhando com um caminho permitido
        if not local_tmp_path.startswith('/tmp'):
            logger.error(f"Caminho fora de /tmp detectado: {local_tmp_path}")
            continue

        os.makedirs(os.path.dirname(local_tmp_path), exist_ok=True)

        # Verificar se o arquivo já foi copiado
        if local_file not in copied_files:
            # Ajuste: remover o prefixo 'cloudman' do caminho do GitHub
            github_file_path = relative_path.replace("\\", "/")

            # Remover a parte 'cloudman/' para refletir a estrutura correta do GitHub
            github_file_path = re.sub(r'^cloudman/', '', github_file_path)

            logger.info(
                f"Tentando baixar do GitHub: repo={repo}, branch={branch}, path={github_file_path}")
            try:
                download_file_from_github(
                    repo, github_file_path, branch, local_tmp_path)
                copied_files.add(local_file)
            except Exception as e:
                logger.error(f"Erro ao baixar o arquivo do GitHub: {e}")
                sys.exit(1)  # Sinalizar falha ao TerraBatch.py

        else:
            logger.info(f"Arquivo já copiado anteriormente: {local_file}")

        # Substituir todas as ocorrências do caminho local no arquivo main.tf
        if local_file in content:
            logger.info(
                f"Substituindo '{local_file}' por '{local_tmp_path}' no arquivo main.tf")
            content = content.replace(local_file, local_tmp_path)
        else:
            logger.warning(
                f"'{local_file}' não encontrado no conteúdo do main.tf para substituição.")

    # Escrever o conteúdo modificado de volta ao arquivo main.tf
    try:
        with open(file_path, 'w') as file:
            file.write(content)
        logger.info(f"Arquivo main.tf atualizado e salvo em: {file_path}")
    except Exception as e:
        logger.error(f"Erro ao salvar o arquivo main.tf: {e}")
        sys.exit(1)

    # Verificar se todos os arquivos foram copiados corretamente
    for local_file in local_files:
        relative_path = os.path.relpath(local_file, 'C:/Cloudman')
        local_tmp_path = os.path.join('/tmp', relative_path.lstrip('/\\'))
        if os.path.exists(local_tmp_path):
            logger.info(f"Arquivo confirmado: {local_tmp_path}")
        else:
            logger.error(f"Arquivo ausente: {local_tmp_path}")
            sys.exit(1)  # Sinalizar falha ao TerraBatch.py

    logger.info("Modificação do main.tf concluída com sucesso.")


def main():
    state_name = os.getenv('STATE_NAME')
    if not state_name:
        logger.error("A variável de ambiente 'STATE_NAME' não está definida.")
        sys.exit(1)

    repo = "CloudManPro/CloudMan"  # Repositório correto
    branch = "refs/heads/main"  # Branch com o formato correto

    terraform_dir = f'/tmp/states/{state_name}'
    main_tf_path = os.path.join(terraform_dir, 'main.tf')

    logger.info(
        f"Verificando a existência do arquivo main.tf em: {main_tf_path}")
    if not os.path.exists(main_tf_path):
        logger.error(
            f"O arquivo main.tf não foi encontrado em: {main_tf_path}")
        sys.exit(1)

    # Carregar os arquivos já copiados
    copied_files = load_copied_files()

    # Modificar o main.tf e atualizar os arquivos copiados
    modify_main_tf(main_tf_path, repo, branch, copied_files)

    # Salvar a lista atualizada de arquivos copiados
    save_copied_files(copied_files)

    logger.info("modify_main_tf.py concluído com sucesso.")


if __name__ == "__main__":
    main()
