#!/bin/bash
# WordPress Installation Script (WordPressProfessional.sh v2.4 - Debugging Salts Loop)
# Adds detailed logging inside the salt insertion loop and temporarily disables set -e there.

# --- Configuration ---
LOG_FILE="/var/log/wordpress-setup.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

set -e # Enable exit on error globally initially
set -o pipefail

# --- Environment Variables ---
DB_NAME="${DB_NAME:-wordpress_db}"
DB_USER="${DB_USER:-wp_user}"
DB_PASSWORD="${DB_PASSWORD:-changeme}"
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
log_info "--- Iniciando Script WordPress Setup v2.4 (Debug Salts Loop) ($(date)) ---"
log_info "Log principal em: $LOG_FILE"
# ... (rest of initial setup logs) ...

# --- Environment File Handling ---
ENV_FILE="/home/ec2-user/.env"
if [ -f "$ENV_FILE" ]; then
    log_info "Arquivo $ENV_FILE encontrado. Recarregando variáveis localmente..."
    source "$ENV_FILE"
    log_info "Variáveis do .env recarregadas localmente."
fi

# --- Variable Checks ---
log_info "Verificando variáveis de ambiente essenciais..."
check_variable "DB_NAME"; check_variable "DB_USER"; check_variable "DB_PASSWORD";
check_variable "DB_HOST"; check_variable "WP_HOME"; check_variable "WP_SITEURL";
log_info "Variáveis essenciais verificadas."

# --- System Updates and Dependency Installation ---
log_info "Atualizando pacotes do sistema..."
yum update -y
log_info "Instalando dependências: httpd, php, mariadb-client, curl, wget..."
yum install -y httpd wget php php-mysqlnd php-fpm php-gd php-mbstring php-xml mariadb105 curl
log_info "Dependências instaladas."

# --- Service Management ---
log_info "Iniciando e habilitando serviços (httpd)..."
systemctl start httpd
systemctl enable httpd
log_info "Serviços iniciados e habilitados."

# --- WordPress Download and Extraction ---
log_info "Criando diretório web root se não existir: $WEB_ROOT"
mkdir -p "$WEB_ROOT"
cd /tmp
log_info "Baixando WordPress..."
wget https://wordpress.org/latest.tar.gz
log_info "WordPress baixado."
log_info "Extraindo WordPress para $WEB_ROOT..."
tar -xzf latest.tar.gz -C "$WEB_ROOT" --strip-components=1
rm -f latest.tar.gz
log_info "WordPress extraído."

# --- wp-config.php Setup ---
log_info "Configurando wp-config.php..."
cd "$WEB_ROOT"
cp wp-config-sample.php wp-config.php

log_info "Definindo detalhes do banco de dados..."
# Standard sed, ensure DB_PASSWORD doesn't contain '/'
sed -i "s/database_name_here/$DB_NAME/g" wp-config.php
sed -i "s/username_here/$DB_USER/g" wp-config.php
sed -i "s/password_here/$DB_PASSWORD/g" wp-config.php
sed -i "s/localhost/$DB_HOST/g" wp-config.php
log_info "Detalhes do banco de dados definidos."

log_info "Definindo WP_HOME e WP_SITEURL..."
printf "\ndefine('WP_HOME', '%s');" "$WP_HOME" >> wp-config.php
printf "\ndefine('WP_SITEURL', '%s');\n" "$WP_SITEURL" >> wp-config.php
log_info "WP_HOME e WP_SITEURL definidos."

# --- Salt/Key Insertion (DEBUGGING VERSION) ---
log_info "Gerando chaves e salts para wp-config.php..."
SALT_KEYS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

if [ -z "$SALT_KEYS" ]; then
    log_error "NÃO FOI POSSÍVEL OBTER CHAVES E SALTS da API do WordPress. Abortando!"
    exit 1
fi

# --- DEBUG: Log the raw keys obtained ---
log_info "DEBUG: Conteúdo bruto de SALT_KEYS obtido:"
echo "$SALT_KEYS" # This will log the multi-line keys
log_info "--- Fim do conteúdo bruto de SALT_KEYS ---"
# --- End DEBUG ---

log_info "Removendo placeholders de chaves/salts..."
start_marker="define( 'AUTH_KEY',"
end_marker="define( 'NONCE_SALT',"
insertion_point_marker="\\\* That's all, stop editing!"

start_line=$(grep -n "$start_marker" wp-config.php | cut -d: -f1 || echo "")
end_line=$(grep -n "$end_marker" wp-config.php | cut -d: -f1 || echo "")

if [ -n "$start_line" ] && [ -n "$end_line" ] && [ "$start_line" -le "$end_line" ]; then
    sed -i "${start_line},${end_line}d" wp-config.php
    log_info "Placeholders removidos (linhas $start_line a $end_line)."
else
    log_warn "Não foi possível encontrar/remover placeholders. Verifique wp-config.php."
fi

log_info "Inserindo novas chaves e salts linha por linha (DEBUG MODE - set -e temporarily disabled)..."
# --- DEBUG: Disable exit on error temporarily ---
set +e
# --- End DEBUG ---

local line_num=0
local total_lines=$(echo "$SALT_KEYS" | wc -l)
local loop_failed=false
local overall_sed_exit_code=0 # Track if any sed command failed

while IFS= read -r line || [ -n "$line" ]; do
  ((line_num++))
  log_info "DEBUG Loop: Processando linha $line_num/$total_lines"
  log_info "DEBUG Loop: Linha bruta: [$line]" # Log the raw line

  # Escape potential problematic characters for sed
  line_escaped=$(echo "$line" | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/&/\\\&/g')
  log_info "DEBUG Loop: Linha escapada: [$line_escaped]" # Log the escaped line

  # Execute the sed command to insert the line
  sed -i "/$insertion_point_marker/i $line_escaped" wp-config.php
  local sed_exit_code=$? # Capture exit code immediately

  log_info "DEBUG Loop: sed exit code para linha $line_num: $sed_exit_code" # Log the exit code

  if [ $sed_exit_code -ne 0 ]; then
    log_error "DEBUG Loop: FALHA no comando sed para a linha $line_num! Código de saída: $sed_exit_code"
    loop_failed=true
    overall_sed_exit_code=$sed_exit_code # Store the first non-zero exit code
    # Continue loop because set -e is off, but log the error
  fi
done <<< "$SALT_KEYS"

# --- DEBUG: Re-enable exit on error ---
set -e
log_info "DEBUG MODE: set -e re-enabled."
# --- End DEBUG ---

# Check if any failure occurred during the loop
if $loop_failed; then
  log_error "ERRO CRÍTICO: Falha(s) ocorreram durante a inserção das chaves/salts. Verifique os logs DEBUG acima. Abortando!"
  exit $overall_sed_exit_code # Exit with the specific sed error code
else
  log_info "Chaves e salts inseridos com sucesso."
fi
# --- End of Salt/Key Insertion ---

log_info "wp-config.php configurado."

# --- Permissions ---
log_info "Ajustando permissões de arquivos e diretórios..."
chown -R $WEBSERVER_USER:$WEBSERVER_GROUP "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;
chmod 600 "$WEB_ROOT/wp-config.php"
log_info "Permissões ajustadas."

# --- Webserver Restart ---
log_info "Reiniciando o servidor web..."
systemctl restart httpd
log_info "Servidor web reiniciado."

# --- Completion Message ---
log_info "=================================================="
log_info "--- Script WordPress Setup Concluído (v2.4 Debug Run) ---"
log_info "Acesse seu site em: $WP_HOME"
log_info "Verifique /var/log/wordpress-setup.log para detalhes e logs de DEBUG."
log_info "=================================================="

exit 0
