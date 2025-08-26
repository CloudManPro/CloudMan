import os
import subprocess
import zipfile
import boto3
import sys
import platform
import glob


def create_layer_zip(dependency, layer_name, architecture="x86_64"):
    """
    Gera um arquivo ZIP para uma Lambda Layer com nome dinâmico, baseado na versão do Python da Lambda.
    :param dependency: Nomes das dependências separadas por espaço (ex.: 'PyJWT cryptography')
    :param layer_name: Nome base da camada (ex.: 'PyJWTLayer')
    :param architecture: Arquitetura da Lambda Layer (x86_64 ou arm64)
    :return: Caminho para o arquivo ZIP gerado e nome dinâmico do arquivo
    """
    # Detectar a versão do Python em execução
    python_version = f"python{sys.version_info.major}.{sys.version_info.minor}"
    print(f"Versão do Python detectada: {python_version}")

    # Diretórios para preparar a camada
    layer_dir = f"/tmp/{layer_name}"
    python_dir = os.path.join(layer_dir, "python")
    site_packages_dir = os.path.join(
        python_dir, "lib", python_version, "site-packages")

    # Certifique-se de que o diretório está limpo
    if os.path.exists(layer_dir):
        print(f"Removendo diretório existente: {layer_dir}")
        subprocess.run(["rm", "-rf", layer_dir], check=True)

    os.makedirs(site_packages_dir, exist_ok=True)
    print(f"Diretório site-packages criado em: {site_packages_dir}")

    try:
        # Configurar variáveis de ambiente para o pip
        env = os.environ.copy()
        env['HOME'] = '/tmp'
        env['PIP_CACHE_DIR'] = '/tmp/pip-cache'
        os.makedirs(env['PIP_CACHE_DIR'], exist_ok=True)

        # O pip lida nativamente com múltiplos pacotes separados por espaço.
        # Dividimos a string em uma lista para o comando subprocess.
        dependencies_to_install = dependency.split()
        
        # Instalar as dependências no diretório
        print(f"Instalando {dependencies_to_install} no diretório {site_packages_dir}...")
        
        # Construir o comando do pip
        pip_command = [
            python_version, "-m", "pip", "install",
            *dependencies_to_install,  # Desempacota a lista de dependências
            "-t", site_packages_dir,
            "--no-cache-dir"
        ]

        result = subprocess.run(
            pip_command,
            check=True,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env
        )
        print("Saída do pip install:", result.stdout.decode("utf-8"))
        if result.stderr:
            print("Erros do pip install:", result.stderr.decode("utf-8"))

        # --- AJUSTE PRINCIPAL AQUI ---
        # Usa apenas o primeiro pacote da lista para determinar a versão para o nome do arquivo.
        main_dependency = dependencies_to_install[0]
        dependency_version = get_installed_package_version(
            site_packages_dir, main_dependency)
        print(
            f"Versão do pacote principal '{main_dependency}' para nomeação do arquivo: {dependency_version}")

    except subprocess.CalledProcessError as e:
        error_message = e.stderr.decode("utf-8") if e.stderr else "Erro desconhecido ao instalar dependências."
        print("Erro durante o pip install:", error_message)
        raise ValueError(f"Erro ao instalar '{dependency}': {error_message}")

    # Gerar o nome do arquivo dinamicamente com base no pacote principal
    zip_file_name = f"{layer_name}-{dependency_version}-{python_version}-{architecture}.zip"
    zip_file_path = f"/tmp/{zip_file_name}"

    # Compactar o diretório python em um arquivo ZIP
    print(f"Compactando os arquivos em {zip_file_path}...")
    with zipfile.ZipFile(zip_file_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(layer_dir):
            for file in files:
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, layer_dir)
                zipf.write(file_path, arcname)
    print(f"ZIP gerado com sucesso: {zip_file_path}")

    # Limpeza
    subprocess.run(["rm", "-rf", layer_dir], check=True)
    print(f"Diretório temporário removido: {layer_dir}")

    return zip_file_path, zip_file_name


def get_installed_package_version(site_packages_dir, dependency_name):
    """
    Obtém a versão instalada de uma dependência lendo os metadados diretamente.
    :param site_packages_dir: Diretório site-packages onde a dependência está instalada
    :param dependency_name: Nome da dependência (um único nome)
    :return: Versão do pacote instalado
    """
    try:
        dist_info_pattern = os.path.join(site_packages_dir, "*.dist-info")
        dist_info_dirs = glob.glob(dist_info_pattern)
        print(f"Diretórios .dist-info encontrados: {dist_info_dirs}")

        if not dist_info_dirs:
            raise ValueError(f"Nenhum diretório .dist-info encontrado em {site_packages_dir}")

        # Normaliza o nome da dependência para comparação (ex: PyJWT -> pyjwt)
        normalized_dependency_name = dependency_name.lower().replace('-', '_')

        for dist_info_dir in dist_info_dirs:
            metadata_file = os.path.join(dist_info_dir, "METADATA")
            if not os.path.exists(metadata_file):
                continue

            with open(metadata_file, "r") as f:
                name = None
                version = None
                for line in f:
                    if line.startswith("Name:"):
                        name = line.split(":", 1)[1].strip().lower().replace('-', '_')
                    elif line.startswith("Version:"):
                        version = line.split(":", 1)[1].strip()
                    if name and version:
                        break
            
            if name == normalized_dependency_name:
                return version

        raise ValueError(f"Diretório de metadados para '{dependency_name}' não encontrado.")

    except Exception as e:
        print(f"Erro ao obter a versão do pacote '{dependency_name}': {e}")
        raise ValueError(f"Erro ao obter a versão do pacote '{dependency_name}': {e}")


def upload_to_s3(zip_file, bucket_name, object_name):
    """
    Faz o upload do arquivo ZIP para o bucket S3.
    """
    print(f"Fazendo upload do arquivo {zip_file} para o bucket {bucket_name} com o nome {object_name}...")
    s3_client = boto3.client('s3')
    try:
        s3_client.upload_file(zip_file, bucket_name, object_name)
        print(f"Arquivo {object_name} enviado com sucesso para o bucket {bucket_name}.")
    except Exception as e:
        print("Erro durante o upload para o S3:", e)
        raise ValueError(f"Erro ao enviar o arquivo para o bucket {bucket_name}: {e}")


def lambda_handler(event, context):
    """
    Handler principal para rodar na Lambda.
    """
    dependency = event.get("dependency")
    layer_name = event.get("layer_name")
    bucket_name = os.environ.get("AWS_S3_BUCKET_TARGET_NAME_0")

    print("Iniciando a execução da Lambda...")
    print(f"Parâmetros de entrada: {event}")
    
    if not all([dependency, layer_name, bucket_name]):
        error_msg = "Parâmetros 'dependency', 'layer_name' ou variável de ambiente 'AWS_S3_BUCKET_TARGET_NAME_0' estão faltando."
        print(error_msg)
        return {"statusCode": 400, "message": error_msg}

    # Detectar a arquitetura do ambiente Lambda
    runtime_architecture = platform.machine()
    architecture = "arm64" if runtime_architecture == "aarch64" else "x86_64"
    print(f"Arquitetura detectada da Lambda: {runtime_architecture} -> Usando: {architecture}")

    try:
        zip_file_path, zip_file_name = create_layer_zip(dependency, layer_name, architecture)
        upload_to_s3(zip_file_path, bucket_name, zip_file_name)
        os.remove(zip_file_path)

        success_msg = f"Arquivo ZIP '{zip_file_name}' enviado para o bucket S3 '{bucket_name}' com sucesso!"
        print(success_msg)
        return {"statusCode": 200, "message": success_msg}

    except ValueError as ve:
        print(f"Erro: {ve}")
        return {"statusCode": 400, "message": str(ve)}
    except Exception as e:
        print(f"Erro inesperado: {e}")
        return {"statusCode": 500, "message": "Erro inesperado ao criar ou enviar o arquivo ZIP.", "error": str(e)}