#!/bin/bash

# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.1
# Descrição: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Destinado a ser executado por um script de user data que baixa este do S3.

# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos

LOG_FILE="/var/log/wordpress-setup.log"
# Redireciona toda a saída (stdout e stderr) para o arquivo de log E para o console/cloud-init-output.log
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup ($(date)) ---"
echo "INFO: Log principal em: ${LOG_FILE}"
echo "INFO: Usuário atual: $(whoami)"
echo "INFO: Diretório atual: $(pwd)"
echo "INFO: =================================================="

# --- Carregamento de Variáveis de Ambiente ---
# Tenta carregar do .env como um fallback ou garantia, embora deva herdar do script pai (user_data).
if [ -f "/home/ec2-user/.env" ]; then
    echo "INFO: Arquivo /home/ec2-user/.env encontrado. Carregando variáveis..."
    set -a # Exportar automaticamente as variáveis lidas do .env
    # shellcheck source=/dev/null # Ignora aviso do ShellCheck sobre não encontrar o arquivo estaticamente
    source /home/ec2-user/.env
    set +a # Desabilitar exportação automática após o source
    echo "INFO: Variáveis do .env carregadas e exportadas para este shell."
else
    echo "WARN: Arquivo /home/ec2-user/.env não encontrado. Confiando nas variáveis de ambiente herdadas/exportadas pelo script pai."
fi

# --- Verificação de Variáveis Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
essential_vars=(
    "NAME"                            # Nome da instância/configuração
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" # ARN do segredo do DB
    "AWS_DB_INSTANCE_TARGET_NAME_0"   # Nome do banco de dados (schema)
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0" # Região do segredo
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0" # Endpoint completo do RDS (host:porta)
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0" # ID do EFS
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    # Usando indireção de variável ${!var_name} para obter o valor
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não está definida ou está vazia!"
        error_found=1
    else
        # Logar variáveis não sensíveis para confirmação
        if [[ "$var_name" != *"SECRET"* && "$var_name" != *"PASSWORD"* && "$var_name" != *"USER"* ]]; then
             echo "DEBUG: Variável $var_name = ${!var_name}"
        fi
    fi
done

if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Falha na verificação de variáveis essenciais. Verifique o .env ou a exportação do script pai. Saindo."
    exit 1
fi
echo "INFO: Verificação de variáveis essenciais concluída com sucesso."

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM..."
# Nota: 'sudo yum update -y' foi REMOVIDO - cloud-init geralmente cuida disso.

# Instala httpd, jq, epel, aws-cli, mysql client (para testes), efs utils
# O 'epel-release' é necessário para o 'jq' em algumas versões mais antigas do AL2
sudo yum install -y httpd jq epel-release aws-cli mysql amazon-efs-utils

# Habilita o repositório do Amazon Linux Extra para PHP 7.4
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4..."
sudo amazon-linux-extras enable php7.4 -y # Adicionado -y para não ser interativo

# Instala PHP 7.4 e módulos comuns/necessários para WordPress
echo "INFO: Instalando PHP 7.4 e módulos..."
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap

echo "INFO: Instalação de pacotes de pré-requisitos concluída."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando e iniciando o Apache (httpd)..."
# Garante que o serviço inicie agora e no boot
sudo systemctl start httpd
sudo systemctl enable httpd
echo "INFO: Serviço httpd iniciado e habilitado."

# --- Recuperação de Segredos (DB Credentials) ---
echo "INFO: Recuperando credenciais do banco de dados do Secrets Manager..."
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0 # Nome do schema/DB

# Verifica se AWS CLI e JQ estão disponíveis (double check)
if ! command -v aws &> /dev/null || ! command -v jq &> /dev/null; then
    echo "ERRO: Comandos 'aws' ou 'jq' não encontrados no PATH após a tentativa de instalação. Saindo."
    exit 1
fi

echo "INFO: Tentando obter segredo '$SECRET_NAME_ARN' da região '$SECRETREGION'..."
# Adiciona tratamento de erro para o comando AWS CLI
if ! SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME_ARN" --query 'SecretString' --output text --region "$SECRETREGION"); then
    echo "ERRO: Falha ao executar 'aws secretsmanager get-secret-value'. Verifique ARN, região e permissões IAM (secretsmanager:GetSecretValue) para o Role da instância."
    exit 1
fi

if [ -z "$SOURCE_NAME_VALUE" ]; then
    echo "ERRO: Comando AWS CLI executado, mas retornou um valor vazio do segredo '$SECRET_NAME_ARN'."
    exit 1
fi
echo "INFO: Segredo bruto obtido com sucesso."

echo "INFO: Extraindo username e password do JSON do segredo..."
# Assume que o segredo é um JSON com chaves "username" e "password"
DB_USER=$(echo "$SOURCE_NAME_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SOURCE_NAME_VALUE" | jq -r .password)

# Verificação robusta se a extração funcionou
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo. Verifique o formato exato do JSON em '$SECRET_NAME_ARN'."
    echo "DEBUG: Conteúdo parcial do segredo (primeiros 50 chars): $(echo "$SOURCE_NAME_VALUE" | cut -c 1-50)..." # Log parcial para debug
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas com sucesso (Usuário: $DB_USER)."
# NUNCA FAÇA LOG DA SENHA!

# --- Montagem do EFS ---
echo "INFO: Iniciando montagem do EFS..."
EFS_ID=$AWS_EFS_FILE_SYSTEM_TARGET_ID_0
MOUNT_POINT="/var/www/html" # Diretório padrão do Apache que será montado sobre o EFS

echo "INFO: Garantindo que o ponto de montagem '$MOUNT_POINT' exista..."
sudo mkdir -p "$MOUNT_POINT"

echo "INFO: Tentando montar EFS '$EFS_ID' em '$MOUNT_POINT'..."
# Usa o helper amazon-efs-utils que lida com TLS etc. Monta a raiz do EFS.
if ! sudo mount -t efs -o tls "$EFS_ID:/" "$MOUNT_POINT"; then
    echo "ERRO: Falha ao montar EFS '$EFS_ID' em '$MOUNT_POINT'."
    echo "ERRO: Verifique se o EFS ID está correto, se os Mount Targets existem na AZ da instância, se os Security Groups permitem NFS (porta 2049) da instância para os Mount Targets, e se o IAM Role tem permissões de EFS (e.g., elasticfilesystem:ClientMount)."
    exit 1
fi

# Verifica se a montagem foi realmente bem-sucedida
if ! mountpoint -q "$MOUNT_POINT"; then
  echo "ERRO: Comando 'mount' retornou sucesso, mas '$MOUNT_POINT' não é um ponto de montagem válido!"
  exit 1
fi
echo "INFO: EFS '$EFS_ID' montado com sucesso em '$MOUNT_POINT'."

# --- Download e Configuração do WordPress ---
WP_DIR_TEMP="/tmp/wordpress-latest" # Diretório temporário para download e extração
mkdir -p "$WP_DIR_TEMP"
cd "$WP_DIR_TEMP"
echo "INFO: Baixando a versão mais recente do WordPress para '$WP_DIR_TEMP'..."
wget https://wordpress.org/latest.tar.gz
if [ ! -f "latest.tar.gz" ]; then
    echo "ERRO: Falha ao baixar WordPress (latest.tar.gz não encontrado)."
    exit 1
fi

echo "INFO: Extraindo WordPress..."
tar -xzf latest.tar.gz
if [ ! -d "wordpress" ]; then
    echo "ERRO: Diretório 'wordpress' não encontrado após extração."
    exit 1
fi

echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS)..."
# Move o *conteúdo* do diretório wordpress para o ponto de montagem
# Usar rsync é mais robusto para copiar, especialmente se houver arquivos existentes
sudo rsync -av --remove-source-files wordpress/ "$MOUNT_POINT/"
# Se preferir mv (cuidado se o destino não estiver vazio):
# sudo mv wordpress/* "$MOUNT_POINT/"

# Limpa o diretório temporário
cd /tmp
rm -rf "$WP_DIR_TEMP"
echo "INFO: Arquivos do WordPress movidos e diretório temporário limpo."

# --- Configuração do wp-config.php ---
cd "$MOUNT_POINT" # Muda para o diretório raiz do WordPress no EFS
echo "INFO: Configurando wp-config.php em '$MOUNT_POINT'..."

if [ ! -f "wp-config-sample.php" ]; then
    echo "ERRO: wp-config-sample.php não encontrado em '$MOUNT_POINT'. A cópia do WordPress falhou?"
    exit 1
fi

# Copia o arquivo de exemplo
sudo cp wp-config-sample.php wp-config.php

# Extrai o endereço do host do endpoint (removendo a porta)
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)
echo "DEBUG: Usando Endpoint Address para DB_HOST: $ENDPOINT_ADDRESS"

# Substitui os placeholders no wp-config.php
echo "INFO: Substituindo placeholders de DB no wp-config.php..."
sudo sed -i "s/database_name_here/$DBNAME/g" wp-config.php
sudo sed -i "s/username_here/$DB_USER/g" wp-config.php
sudo sed -i "s/password_here/$DB_PASSWORD/g" wp-config.php # Cuidado com caracteres especiais na senha - considere escapar
sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/g" wp-config.php

# Adiciona/Substitui as chaves de segurança (SALTS) - MUITO IMPORTANTE!
echo "INFO: Obtendo e configurando chaves de segurança (SALTS) no wp-config.php..."
SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
if [ -z "$SALT" ]; then
    echo "WARN: Falha ao obter SALTS da API do WordPress. Usando placeholders (menos seguro)."
else
    # Remove as linhas de definição de salt existentes (do define até o ponto-e-vírgula)
    sudo sed -i '/define( *'\''AUTH_KEY'\''/d' wp-config.php
    sudo sed -i '/define( *'\''SECURE_AUTH_KEY'\''/d' wp-config.php
    sudo sed -i '/define( *'\''LOGGED_IN_KEY'\''/d' wp-config.php
    sudo sed -i '/define( *'\''NONCE_KEY'\''/d' wp-config.php
    sudo sed -i '/define( *'\''AUTH_SALT'\''/d' wp-config.php
    sudo sed -i '/define( *'\''SECURE_AUTH_SALT'\''/d' wp-config.php
    sudo sed -i '/define( *'\''LOGGED_IN_SALT'\''/d' wp-config.php
    sudo sed -i '/define( *'\''NONCE_SALT'\''/d' wp-config.php

    # Insere os novos salts antes da linha '*/' ou '$table_prefix'
    MARKER_LINE="\/\* That's all, stop editing! Happy publishing. \*\/"
    # Alternativamente, use: MARKER_LINE="\$table_prefix"
    # Escapa barras no SALT para o sed
    ESCAPED_SALT=$(echo "$SALT" | sed 's/[\/&]/\\&/g')
    sudo sed -i "/$MARKER_LINE/i $ESCAPED_SALT" wp-config.php
    echo "INFO: SALTS configurados com sucesso."
fi

echo "INFO: Configuração do wp-config.php concluída."

# --- Ajuste de Permissões ---
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_POINT'..."
# Define o usuário/grupo apache como proprietário de tudo
sudo chown -R apache:apache "$MOUNT_POINT"

# Define permissões mais específicas (recomendado pelo WordPress)
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \; # Diretórios: rwxr-xr-x
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \; # Arquivos: rw-r--r--

# Permite que o WordPress gerencie o wp-config.php se necessário (opcional, menos seguro)
# sudo chmod 660 "$MOUNT_POINT/wp-config.php"

# Permite escrita no diretório de uploads
if [ -d "$MOUNT_POINT/wp-content/uploads" ]; then
    echo "INFO: Ajustando permissões para wp-content/uploads..."
    sudo chmod -R 775 "$MOUNT_POINT/wp-content/uploads" # Permite escrita pelo grupo (apache)
fi

echo "INFO: Permissões ajustadas."

# --- Reiniciar Apache ---
echo "INFO: Reiniciando o Apache para aplicar todas as alterações..."
sudo systemctl restart httpd
echo "INFO: Apache reiniciado."

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup concluído com sucesso! ($(date)) ---"
echo "INFO: Acesse o IP público ou DNS da instância para finalizar a instalação do WordPress pelo navegador."
echo "INFO: =================================================="

exit 0
