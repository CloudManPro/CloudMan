#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.5 (Baseado na v1.4, Tenta silenciar mais yum/extras, adiciona notas sobre user-data)
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
if [ -f "/home/ec2-user/.env" ]; then
    echo "INFO: Arquivo /home/ec2-user/.env encontrado. Carregando variáveis..."
    set -a
    # shellcheck source=/dev/null
    source /home/ec2-user/.env
    set +a
    echo "INFO: Variáveis do .env carregadas e exportadas para este shell."
else
    echo "WARN: Arquivo /home/ec2-user/.env não encontrado. Confiando nas variáveis de ambiente herdadas/exportadas pelo script pai."
fi

# --- Verificação de Variáveis Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
essential_vars=(
    "NAME"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    else
        if [[ "$var_name" != *"SECRET"* && "$var_name" != *"PASSWORD"* && "$var_name" != *"USER"* && "$var_name" != *"ARN"* && "$var_name" != *"REGION"* ]]; then # Evita logar infos sensíveis
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
echo "INFO: Iniciando instalação de pacotes via YUM (modo extra silencioso)..."
# Adicionado > /dev/null para suprimir stdout do yum (listas de pacotes, etc.)
# stderr (erros, mensagens de lock) ainda deve ser capturado pelo log principal.
sudo yum install -y -q httpd jq epel-release aws-cli mysql amazon-efs-utils > /dev/null # MODIFICADO: Adicionado > /dev/null

# Habilita o repositório do Amazon Linux Extra para PHP 7.4
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4 (modo extra silencioso)..."
# Adicionado &> /dev/null para suprimir stdout E stderr (lista de tópicos) DESTE comando.
sudo amazon-linux-extras enable php7.4 -y &> /dev/null # MODIFICADO: Alterado para &> /dev/null

# Instala PHP 7.4 e módulos - Adicionado > /dev/null
echo "INFO: Instalando PHP 7.4 e módulos (modo extra silencioso)..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap > /dev/null # MODIFICADO: Adicionado > /dev/null
echo "INFO: Instalação de pacotes de pré-requisitos concluída."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando e iniciando o Apache (httpd)..."
sudo systemctl start httpd
sudo systemctl enable httpd
echo "INFO: Serviço httpd iniciado e habilitado."

# --- Recuperação de Segredos (DB Credentials) ---
echo "INFO: Recuperando credenciais do banco de dados do Secrets Manager..."
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
SECRET_REGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0

if ! command -v aws &>/dev/null || ! command -v jq &>/dev/null; then
    echo "ERRO: Comandos 'aws' ou 'jq' não encontrados no PATH. Instalação falhou?"
    exit 1
fi

echo "INFO: Tentando obter segredo (ARN: ...${SECRET_NAME_ARN: -20}) da região '$SECRET_REGION'..." # Log parcial do ARN
if ! SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME_ARN" --query 'SecretString' --output text --region "$SECRET_REGION"); then
    echo "ERRO: Falha ao executar 'aws secretsmanager get-secret-value'. Verifique ARN, região e permissões IAM."
    exit 1
fi
if [ -z "$SECRET_STRING_VALUE" ]; then
    echo "ERRO: AWS CLI retornou valor vazio do segredo '$SECRET_NAME_ARN'."
    exit 1
fi
echo "INFO: Segredo bruto obtido com sucesso."

echo "INFO: Extraindo username e password do JSON do segredo..."
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo."
    echo "DEBUG: Segredo parcial: $(echo "$SECRET_STRING_VALUE" | cut -c 1-50)..."
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas com sucesso (Usuário: $DB_USER)."

# --- Montagem do EFS ---
echo "INFO: Iniciando montagem do EFS..."
EFS_ID=$AWS_EFS_FILE_SYSTEM_TARGET_ID_0
MOUNT_POINT="/var/www/html"

echo "INFO: Garantindo que o ponto de montagem '$MOUNT_POINT' exista..."
sudo mkdir -p "$MOUNT_POINT"

echo "INFO: Tentando montar EFS '$EFS_ID' em '$MOUNT_POINT'..."
if ! sudo mount -t efs -o tls "$EFS_ID:/" "$MOUNT_POINT"; then
    echo "ERRO: Falha ao montar EFS '$EFS_ID' em '$MOUNT_POINT'. Verifique ID, Mount Targets, Security Groups (NFS 2049) e Permissões IAM."
    exit 1
fi
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERRO: 'mount' retornou sucesso, mas '$MOUNT_POINT' não é um ponto de montagem válido!"
    exit 1
fi
echo "INFO: EFS '$EFS_ID' montado com sucesso em '$MOUNT_POINT'."

# --- Download e Configuração do WordPress ---
WP_DIR_TEMP="/tmp/wordpress-latest"
mkdir -p "$WP_DIR_TEMP"
cd "$WP_DIR_TEMP"

echo "INFO: Baixando a versão mais recente do WordPress (modo silencioso)..."
wget -q https://wordpress.org/latest.tar.gz # -q já é eficaz aqui
if [ ! -f "latest.tar.gz" ]; then
    echo "ERRO: Falha ao baixar WordPress (latest.tar.gz não encontrado)."
    exit 1
fi

echo "INFO: Extraindo WordPress..."
tar -xzf latest.tar.gz # Saída do tar é mínima, geralmente ok
if [ ! -d "wordpress" ]; then
    echo "ERRO: Diretório 'wordpress' não encontrado após extração."
    exit 1
fi

echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS) (modo menos verboso)..."
sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/" # -a (sem -v) é eficaz
cd /tmp
rm -rf "$WP_DIR_TEMP"
echo "INFO: Arquivos do WordPress movidos e diretório temporário limpo."

# --- Configuração do wp-config.php ---
CONFIG_FILE="$MOUNT_POINT/wp-config.php"
echo "INFO: Configurando $CONFIG_FILE..."
if [ ! -f "$MOUNT_POINT/wp-config-sample.php" ]; then
    echo "ERRO: wp-config-sample.php não encontrado em '$MOUNT_POINT'."
    exit 1
fi
sudo cp "$MOUNT_POINT/wp-config-sample.php" "$CONFIG_FILE"

RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)
echo "DEBUG: Usando Endpoint Address para DB_HOST: $ENDPOINT_ADDRESS"

echo "INFO: Substituindo placeholders de DB no $CONFIG_FILE..."
sudo sed -i "s#database_name_here#$DBNAME#" "$CONFIG_FILE"
sudo sed -i "s#username_here#$DB_USER#" "$CONFIG_FILE"
sudo sed -i "s#password_here#$DB_PASSWORD#" "$CONFIG_FILE"
sudo sed -i "s#localhost#$ENDPOINT_ADDRESS#" "$CONFIG_FILE"

echo "INFO: Obtendo e configurando chaves de segurança (SALTS) no $CONFIG_FILE (modo silencioso)..."
SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/) # -sL é eficaz
if [ -z "$SALT" ]; then
    echo "ERRO: Falha ao obter SALTS da API do WordPress."
else
    echo "INFO: Removendo/Inserindo SALTS..." # Mensagem consolidada
    sudo sed -i "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" "$CONFIG_FILE"
    MARKER_LINE='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
    ESCAPED_SALT=$(echo "$SALT" | sed -e 's/[\/&]/\\&/g')
    # shellcheck disable=SC2001
    sudo sed -i "/$MARKER_LINE/i\\
$ESCAPED_SALT
" "$CONFIG_FILE"
    echo "INFO: SALTS configurados com sucesso."
fi

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'direct' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHOD', 'direct' );"
MARKER_LINE='/* That*'\''*s all, stop editing! Happy publishing. */'
if [ -f "$CONFIG_FILE" ]; then
    if sudo grep -q "define( *'FS_METHOD' *, *'direct' *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido." # Mais curto
    else
        echo "INFO: Inserindo FS_METHOD 'direct'..." # Mais curto
        sudo sed -i "/$MARKER_LINE/i\\
$FS_METHOD_LINE
" "$CONFIG_FILE"
        echo "INFO: FS_METHOD 'direct' adicionado." # Mais curto
    fi
else
    echo "WARN: $CONFIG_FILE não encontrado para adicionar FS_METHOD."
fi

echo "INFO: Configuração final do wp-config.php concluída."

# --- Ajuste de Permissões ---
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_POINT'..."
sudo chown -R apache:apache "$MOUNT_POINT"
echo "INFO: Definindo permissões base (755 dirs, 644 files)..."
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;

WP_CONTENT_DIR="$MOUNT_POINT/wp-content"
if [ -d "$WP_CONTENT_DIR" ]; then
    echo "INFO: Ajustando permissões wp-content (775 dirs, 664 files)..."
    sudo find "$WP_CONTENT_DIR" -type d -exec chmod 775 {} \;
    sudo find "$WP_CONTENT_DIR" -type f -exec chmod 664 {} \;
    UPLOAD_DIR="$WP_CONTENT_DIR/uploads"
    echo "INFO: Garantindo diretório de uploads ($UPLOAD_DIR)..."
    sudo mkdir -p "$UPLOAD_DIR"
    sudo chown -R apache:apache "$UPLOAD_DIR"
    sudo chmod 775 "$UPLOAD_DIR"
else
    echo "WARN: Diretório '$WP_CONTENT_DIR' não encontrado."
fi

if [ -f "$CONFIG_FILE" ]; then
    echo "INFO: Protegendo $CONFIG_FILE (chmod 660)..."
    sudo chmod 660 "$CONFIG_FILE"
fi
echo "INFO: Ajuste de permissões concluído."

# --- Reiniciar Apache ---
echo "INFO: Reiniciando o Apache..."
sudo systemctl restart httpd # Saída é mínima, ok
echo "INFO: Apache reiniciado."

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup concluído com sucesso! ($(date)) ---"
echo "INFO: Acesse o IP/DNS da instância para finalizar a instalação via navegador."
echo "INFO: Log completo (com menos verbosidade) em: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
