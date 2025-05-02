#!/bin/bash
# Example WordPress Installation Script (WordPressProfessional.sh)
# This script is downloaded and executed by the EC2 user-data script.
# It assumes it runs as root.

# --- Configuration ---
# Redirect stdout and stderr to a specific log file for this script
LOG_FILE="/var/log/wordpress-setup.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

set -e # Exit immediately if a command exits with a non-zero status
set -o pipefail # Ensure pipeline failures are reported

# --- Environment Variables (Expected to be Exported by User-Data) ---
# These should be loaded from .env or instance environment by the user-data script
# Example variables (MAKE SURE THESE ARE SET!)
DB_NAME="${DB_NAME:-wordpress_db}"
DB_USER="${DB_USER:-wp_user}"
DB_PASSWORD="${DB_PASSWORD:-changeme}" # VERY IMPORTANT: Use a strong password, preferably from Secrets Manager
DB_HOST="${DB_HOST:-localhost}"        # Or RDS endpoint
WP_HOME="${WP_HOME:-http://your_domain_or_ip}" # Public URL
WP_SITEURL="${WP_SITEURL:-http://your_domain_or_ip}" # Public URL

# Web server configuration
WEB_ROOT="/var/www/html"
WEBSERVER_USER="apache" # For Amazon Linux 2 (httpd)
# WEBSERVER_USER="www-data" # For Ubuntu/Debian (apache2/nginx)
WEBSERVER_GROUP="apache" # For Amazon Linux 2
# WEBSERVER_GROUP="www-data" # For Ubuntu/Debian

# --- Functions ---
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - INFO: $1"
}

log_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - WARN: $1"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - ERRO: $1" >&2
}

check_variable() {
  local var_name="$1"
  # Using indirect expansion to get the value of the variable named by var_name
  if [ -z "${!var_name}" ]; then
    log_error "Variável de ambiente essencial '$var_name' não está definida. Verifique o script user-data e o arquivo .env (se aplicável)."
    exit 1
  fi
}

# --- Main Setup Logic ---
log_info "=================================================="
log_info "--- Iniciando Script WordPress Setup v2.1 (Example Template) ($(date)) ---"
log_info "Log principal em: $LOG_FILE"
log_info "Usuário atual: $(whoami)"
log_info "Diretório atual: $(pwd)"
log_info "=================================================="

# Attempt to source .env again JUST IN CASE it wasn't exported (belt and suspenders)
# Note: The user-data script should ideally handle exporting correctly.
ENV_FILE="/home/ec2-user/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Arquivo $ENV_FILE encontrado. Recarregando variáveis (apenas para este script)..."
    # Source variables without exporting them globally again
    source "$ENV_FILE"
    log_info "Variáveis do .env recarregadas localmente."
fi

log_info "Verificando variáveis de ambiente essenciais..."
check_variable "DB_NAME"
check_variable "DB_USER"
check_variable "DB_PASSWORD"
check_variable "DB_HOST"
check_variable "WP_HOME"
check_variable "WP_SITEURL"
log_info "Variáveis essenciais verificadas."

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!! ATTENTION: Your original error was near line 53.           !!!
# !!! Check YOUR script around this area for the syntax error    !!!
# !!! involving '('. For example, maybe you had something like:  !!!
# !!!   if [ some_condition ( ] ; then ...                      !!!
# !!!   my_array= ( value1 value2 )                            !!!
# !!! Find and fix the specific issue in YOUR code.              !!!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# The line number counter starts from #!/bin/bash at the top.
# This comment block itself adds lines, so line 53 in *this template*
# might not correspond exactly to line 53 in *your original script*.
# Use a text editor that shows line numbers on your original script.

log_info "Atualizando pacotes do sistema..."
yum update -y
log_info "Pacotes atualizados."

log_info "Instalando dependências: Web Server (httpd), PHP, MySQL client..."
# Amazon Linux 2 specific packages
yum install -y httpd wget php php-mysqlnd php-fpm php-gd php-mbstring php-xml mariadb105 # Using MariaDB client

# For different OS (e.g., Ubuntu):
# apt update
# apt install -y apache2 wget php libapache2-mod-php php-mysql php-gd php-mbstring php-xml mysql-client

log_info "Dependências instaladas."

log_info "Iniciando e habilitando serviços (httpd)..."
systemctl start httpd
systemctl enable httpd
# systemctl start php-fpm # If using PHP-FPM with Apache event/worker or Nginx
# systemctl enable php-fpm
log_info "Serviços iniciados e habilitados."

log_info "Criando diretório web root se não existir..."
mkdir -p "$WEB_ROOT"
cd /tmp # Move to /tmp for downloading

log_info "Baixando WordPress..."
wget https://wordpress.org/latest.tar.gz
if [ $? -ne 0 ]; then
    log_error "Falha ao baixar WordPress."
    exit 1
fi
log_info "WordPress baixado."

log_info "Extraindo WordPress para $WEB_ROOT..."
tar -xzf latest.tar.gz -C "$WEB_ROOT" --strip-components=1
if [ $? -ne 0 ]; then
    log_error "Falha ao extrair WordPress."
    rm -f latest.tar.gz # Clean up download
    exit 1
fi
rm -f latest.tar.gz # Clean up download
log_info "WordPress extraído."

log_info "Configurando wp-config.php..."
cd "$WEB_ROOT"
# Use wp-config-sample.php as a template
cp wp-config-sample.php wp-config.php

# Set database details in wp-config.php
sed -i "s/database_name_here/$DB_NAME/g" wp-config.php
sed -i "s/username_here/$DB_USER/g" wp-config.php
sed -i "s/password_here/$DB_PASSWORD/g" wp-config.php
sed -i "s/localhost/$DB_HOST/g" wp-config.php

# Set WordPress address and site URL (optional but good practice)
echo "define('WP_HOME', '$WP_HOME');" >> wp-config.php
echo "define('WP_SITEURL', '$WP_SITEURL');" >> wp-config.php

# Set unique authentication keys and salts
log_info "Gerando chaves e salts para wp-config.php..."
SALT_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
if [ -n "$SALT_KEYS" ]; then
    # Remove placeholder lines
    START_MARKER="define( 'AUTH_KEY',"
    END_MARKER="define( 'NONCE_SALT',"
    sed -i "/$START_MARKER/,/$END_MARKER/{//!d}" wp-config.php
    # Insert new keys before the line "* That's all, stop editing!"
    sed -i "/\* That's all, stop editing!/i $SALT_KEYS" wp-config.php
    log_info "Chaves e salts definidos."
else
    log_warn "Não foi possível obter chaves e salts da API do WordPress. Use o gerador online e adicione manualmente se necessário."
fi

log_info "wp-config.php configurado."

log_info "Ajustando permissões de arquivos e diretórios..."
# Set ownership to the webserver user/group
chown -R $WEBSERVER_USER:$WEBSERVER_GROUP "$WEB_ROOT"

# Set standard directory and file permissions
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;

# Secure wp-config.php (sometimes recommended, check WordPress hardening guides)
chmod 600 "$WEB_ROOT/wp-config.php"

log_info "Permissões ajustadas."

# Optional: Database Creation (Only if DB is local and user has privileges)
# Usually better to pre-create the DB and user in RDS or manually.
# log_info "Tentando criar banco de dados e usuário (ignorar erros se já existir)..."
# mysql -h "$DB_HOST" -u root -p'ROOT_PASSWORD' -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" || log_warn "Não foi possível criar BD (pode já existir)."
# mysql -h "$DB_HOST" -u root -p'ROOT_PASSWORD' -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';" || log_warn "Não foi possível criar usuário (pode já existir)."
# mysql -h "$DB_HOST" -u root -p'ROOT_PASSWORD' -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';" || log_warn "Não foi possível conceder privilégios."
# mysql -h "$DB_HOST" -u root -p'ROOT_PASSWORD' -e "FLUSH PRIVILEGES;" || log_warn "Não foi possível fazer flush privileges."
# log_info "Operações de banco de dados concluídas (ou tentadas)."

log_info "Reiniciando o servidor web para aplicar mudanças..."
systemctl restart httpd
# systemctl restart apache2 # for Ubuntu/Debian
log_info "Servidor web reiniciado."

log_info "=================================================="
log_info "--- Script WordPress Setup Concluído ---"
log_info "Acesse seu site em: $WP_HOME"
log_info "Pode ser necessário concluir a instalação via navegador."
log_info "=================================================="

exit 0
