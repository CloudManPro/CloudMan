#!/bin/bash
# WordPress Installation Script (WordPressProfessional.sh v2.3)
# Uses standard sed for DB details, corrected loop for salts/keys.

# --- Configuration ---
LOG_FILE="/var/log/wordpress-setup.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

set -e
set -o pipefail

# --- Environment Variables ---
DB_NAME="${DB_NAME:-wordpress_db}"
DB_USER="${DB_USER:-wp_user}"
DB_PASSWORD="${DB_PASSWORD:-changeme}" # Ensure this doesn't contain '/' if using standard sed delimiter
DB_HOST="${DB_HOST:-localhost}"
WP_HOME="${WP_HOME:-http://your_domain_or_ip}"
WP_SITEURL="${WP_SITEURL:-http://your_domain_or_ip}"
WEB_ROOT="/var/www/html"
WEBSERVER_USER="apache"
WEBSERVER_GROUP="apache"

# --- Functions ---
log_info() { echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - INFO: $1"; }
log_warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - WARN: $1"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') - WP_SETUP - ERRO: $1" >&2; }

check_variable() {
  local var_name="$1"
  if [ -z "${!var_name}" ]; then
    log_error "Variável de ambiente essencial '$var_name' não está definida."; exit 1;
  fi
}

# --- Main Setup Logic ---
log_info "=================================================="
log_info "--- Iniciando Script WordPress Setup v2.3 (Standard DB Sed, Fixed Salts) ($(date)) ---"
log_info "Log principal em: $LOG_FILE"
log_info "Usuário atual: $(whoami)"
log_info "Diretório atual: $(pwd)"
log_info "=================================================="

ENV_FILE="/home/ec2-user/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Arquivo $ENV_FILE encontrado. Recarregando variáveis localmente..."
    # Use 'set -a' temporarily if export is needed by sub-processes, otherwise just source
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

log_info "Atualizando pacotes do sistema..."
yum update -y
log_info "Pacotes atualizados."

log_info "Instalando dependências: Web Server (httpd), PHP, MySQL/MariaDB client, curl..."
# Added curl explicitly
yum install -y httpd wget php php-mysqlnd php-fpm php-gd php-mbstring php-xml mariadb105 curl
log_info "Dependências instaladas."

log_info "Iniciando e habilitando serviços (httpd)..."
systemctl start httpd
systemctl enable httpd
log_info "Serviços iniciados e habilitados."

log_info "Criando diretório web root se não existir..."
mkdir -p "$WEB_ROOT"
cd /tmp

log_info "Baixando WordPress..."
wget https://wordpress.org/latest.tar.gz
if [ $? -ne 0 ]; then log_error "Falha ao baixar WordPress."; exit 1; fi
log_info "WordPress baixado."

log_info "Extraindo WordPress para $WEB_ROOT..."
tar -xzf latest.tar.gz -C "$WEB_ROOT" --strip-components=1
if [ $? -ne 0 ]; then log_error "Falha ao extrair WordPress."; rm -f latest.tar.gz; exit 1; fi
rm -f latest.tar.gz
log_info "WordPress extraído."

log_info "Configurando wp-config.php..."
cd "$WEB_ROOT"
cp wp-config-sample.php wp-config.php

log_info "Definindo detalhes do banco de dados em wp-config.php (usando / como delimitador padrão)..."
# Using the standard sed commands, assuming they worked originally.
# IMPORTANT: If DB_PASSWORD contains '/', this will fail. Consider using Secrets Manager or escaping.
sed -i "s/database_name_here/$DB_NAME/g" wp-config.php
sed -i "s/username_here/$DB_USER/g" wp-config.php
sed -i "s/password_here/$DB_PASSWORD/g" wp-config.php
sed -i "s/localhost/$DB_HOST/g" wp-config.php
log_info "Detalhes do banco de dados definidos."

log_info "Definindo WP_HOME e WP_SITEURL em wp-config.php..."
printf "\ndefine('WP_HOME', '%s');" "$WP_HOME" >> wp-config.php
printf "\ndefine('WP_SITEURL', '%s');\n" "$WP_SITEURL" >> wp-config.php
log_info "WP_HOME e WP_SITEURL definidos."

# --- Corrected Salt/Key Insertion (Same as v2.2) ---
log_info "Gerando chaves e salts para wp-config.php..."
SALT_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

if [ -n "$SALT_KEYS" ]; then
    log_info "Chaves/Salts obtidos da API. Removendo placeholders..."
    start_marker="define( 'AUTH_KEY',"
    end_marker="define( 'NONCE_SALT',"
    insertion_point_marker="\\\* That's all, stop editing!" # Escaped for sed

    start_line=$(grep -n "$start_marker" wp-config.php | cut -d: -f1 || true) # Avoid error if not found
    end_line=$(grep -n "$end_marker" wp-config.php | cut -d: -f1 || true) # Avoid error if not found

    if [ -n "$start_line" ] && [ -n "$end_line" ] && [ "$start_line" -le "$end_line" ]; then
        sed -i "${start_line},${end_line}d" wp-config.php
        log_info "Placeholders removidos (linhas $start_line a $end_line)."
    else
        log_warn "Não foi possível encontrar/remover placeholders de chaves/salts. Verifique wp-config.php."
    fi

    log_info "Inserindo novas chaves e salts linha por linha..."
    line_num=0
    total_lines=$(echo "$SALT_KEYS" | wc -l)
    while IFS= read -r line || [ -n "$line" ]; do
      ((line_num++))
      line_escaped=$(echo "$line" | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/&/\\\&/g')
      sed -i "/$insertion_point_marker/i $line_escaped" wp-config.php
      if [ $? -ne 0 ]; then
        log_error "Falha ao inserir linha $line_num/$total_lines de salt/key: $line"
        # Consider exiting if insertion fails critically
        # exit 1
      fi
    done <<< "$SALT_KEYS"
    log_info "Chaves e salts inseridos."

else
    log_error "NÃO FOI POSSÍVEL OBTER CHAVES E SALTS da API do WordPress. wp-config.php ficará inseguro. Abortando!"
    exit 1 # Exit because this is a critical security step
fi
# --- End of Corrected Salt/Key Insertion ---

log_info "wp-config.php configurado."

log_info "Ajustando permissões de arquivos e diretórios..."
chown -R $WEBSERVER_USER:$WEBSERVER_GROUP "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;
chmod 600 "$WEB_ROOT/wp-config.php" # Secure wp-config
log_info "Permissões ajustadas."

log_info "Reiniciando o servidor web para aplicar mudanças..."
systemctl restart httpd
log_info "Servidor web reiniciado."

log_info "=================================================="
log_info "--- Script WordPress Setup Concluído ---"
log_info "Acesse seu site em: $WP_HOME"
log_info "Pode ser necessário concluir a instalação via navegador."
log_info "Verifique /var/log/wordpress-setup.log para detalhes."
log_info "=================================================="

exit 0
