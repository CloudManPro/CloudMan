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
    :param dependency: Nome da dependência (ex.: 'whoosh')
    :param layer_name: Nome base da camada (ex.: 'whoosh_layer')
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
        env['HOME'] = '/tmp'  # Redefinir HOME para um diretório gravável
        # Definir diretório de cache do pip
        env['PIP_CACHE_DIR'] = '/tmp/pip-cache'

        # Criar o diretório de cache se não existir
        os.makedirs(env['PIP_CACHE_DIR'], exist_ok=True)
        print(
            f"Diretório de cache do pip configurado em: {env['PIP_CACHE_DIR']}")

        # Verificar a versão do pip
        pip_version = subprocess.run(
            [python_version, "-m", "pip", "--version"],
            capture_output=True,
            text=True,
            env=env
        )
        print("Versão do pip:", pip_version.stdout.strip())

        # Instalar a dependência no diretório
        print(
            f"Instalando {dependency} no diretório {site_packages_dir} para arquitetura {architecture}...")
        result = subprocess.run(
            [python_version, "-m", "pip", "install", dependency,
                "-t", site_packages_dir, "--no-cache-dir"],
            check=True,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env
        )
        print("Saída do pip install:", result.stdout.decode("utf-8"))
        if result.stderr:
            print("Erros do pip install:", result.stderr.decode("utf-8"))

        # Obter a versão do pacote instalado lendo os metadados diretamente
        dependency_version = get_installed_package_version(
            site_packages_dir, dependency)
        print(
            f"Versão instalada do pacote '{dependency}': {dependency_version}")

    except subprocess.CalledProcessError as e:
        error_message = e.stderr.decode(
            "utf-8") if e.stderr else "Erro desconhecido ao instalar dependências."
        print("Erro durante o pip install:", error_message)
        raise ValueError(f"Erro ao instalar '{dependency}': {error_message}")

    # Gerar o nome do arquivo dinamicamente
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

    # Limpeza: Remover o diretório temporário
    subprocess.run(["rm", "-rf", layer_dir], check=True)
    print(f"Diretório temporário removido: {layer_dir}")

    return zip_file_path, zip_file_name


def get_installed_package_version(site_packages_dir, dependency):
    """
    Obtém a versão instalada de uma dependência lendo os metadados diretamente.
    :param site_packages_dir: Diretório site-packages onde a dependência está instalada
    :param dependency: Nome da dependência
    :return: Versão do pacote instalado
    """
    try:
        # Listar todos os diretórios .dist-info
        dist_info_pattern = os.path.join(site_packages_dir, "*.dist-info")
        dist_info_dirs = glob.glob(dist_info_pattern)
        print(f"Diretórios .dist-info encontrados: {dist_info_dirs}")

        if not dist_info_dirs:
            raise ValueError(
                f"Nenhum diretório .dist-info encontrado em {site_packages_dir}")

        for dist_info_dir in dist_info_dirs:
            metadata_file = os.path.join(dist_info_dir, "METADATA")
            if not os.path.exists(metadata_file):
                print(f"Arquivo METADATA não encontrado em: {dist_info_dir}")
                continue

            with open(metadata_file, "r") as f:
                name = None
                version = None
                for line in f:
                    if line.startswith("Name:"):
                        name = line.split(":", 1)[1].strip()
                    elif line.startswith("Version:"):
                        version = line.split(":", 1)[1].strip()
                    if name and version:
                        break

            print(f"Pacote encontrado: {name}, Versão: {version}")
            if name and name.lower() == dependency.lower():
                if version:
                    return version
                else:
                    raise ValueError(
                        f"Versão não encontrada no METADATA para '{dependency}'.")

        raise ValueError(
            f"Diretório de metadados para '{dependency}' não encontrado.")

    except Exception as e:
        print(f"Erro ao obter a versão do pacote '{dependency}': {e}")
        raise ValueError(
            f"Erro ao obter a versão do pacote '{dependency}': {e}")


def upload_to_s3(zip_file, bucket_name, object_name):
    """
    Faz o upload do arquivo ZIP para o bucket S3.
    :param zip_file: Caminho para o arquivo ZIP
    :param bucket_name: Nome do bucket S3
    :param object_name: Nome do arquivo no S3
    """
    print(
        f"Fazendo upload do arquivo {zip_file} para o bucket {bucket_name} com o nome {object_name}...")
    s3_client = boto3.client('s3')
    try:
        s3_client.upload_file(zip_file, bucket_name, object_name)
        print(
            f"Arquivo {object_name} enviado com sucesso para o bucket {bucket_name}.")
    except Exception as e:
        print("Erro durante o upload para o S3:", e)
        raise ValueError(
            f"Erro ao enviar o arquivo para o bucket {bucket_name}: {e}")


def lambda_handler(event, context):
    """
    Handler principal para rodar na Lambda.
    """
    # Ler os parâmetros do evento
    dependency = event.get("dependency", "whoosh")  # Dependência padrão
    layer_name = event.get("layer_name", "generic_layer")  # Nome da camada
    # python_version_input pode ser usado para outras validações se necessário
    python_version_input = event.get("python_version")
    
    # Nome do bucket S3 obtido da variável de ambiente
    bucket_name = os.environ.get("AWS_S3_BUCKET_TARGET_NAME_0")

    print("Iniciando a execução da Lambda...")
    print(f"Parâmetros de entrada: {event}")

    if not bucket_name:
        error_msg = "A variável de ambiente 'AWS_S3_BUCKET_TARGET_NAME_0' não está definida."
        print(error_msg)
        return {
            "statusCode": 400,
            "message": error_msg
        }

    # Detectar a arquitetura do ambiente Lambda e definir a variável a ser utilizada
    runtime_architecture = platform.machine()
    print(f"Arquitetura detectada da Lambda: {runtime_architecture}")
    if runtime_architecture == "aarch64":
        architecture = "arm64"
    else:
        architecture = "x86_64"
    print(f"Arquitetura utilizada para o pacote: {architecture}")

    try:
        # Criar o arquivo ZIP com nome dinâmico, utilizando a arquitetura detectada
        zip_file_path, zip_file_name = create_layer_zip(dependency, layer_name, architecture)

        # Fazer upload para o bucket S3
        upload_to_s3(zip_file_path, bucket_name, zip_file_name)

        # Limpar o arquivo ZIP
        os.remove(zip_file_path)
        print("Arquivo ZIP removido após upload para o S3.")

        success_msg = f"Arquivo ZIP '{zip_file_name}' enviado para o bucket S3 '{bucket_name}' com sucesso!"
        print(success_msg)
        return {
            "statusCode": 200,
            "message": success_msg
        }

    except ValueError as ve:
        print(f"Erro: {ve}")
        return {
            "statusCode": 400,
            "message": str(ve)
        }
    except Exception as e:
        print(f"Erro inesperado: {e}")
        return {
            "statusCode": 500,
            "message": "Erro inesperado ao criar ou enviar o arquivo ZIP.",
            "error": str(e)
        }