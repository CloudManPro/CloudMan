#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.3.5-proxysql-integration-FIXED (Corrige a construção do ARN do Secrets Manager e a instalação do ProxySQL)
# Modificado para validar otimização de performance e adicionar ProxySQL.

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.3.5.sh"
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.3.5_env_vars.sh"

# Script de Monitoramento Python e Serviço
readonly PYTHON_MONITOR_SCRIPT_NAME="efs_s3_monitor_v2.3.3.py"
readonly PYTHON_MONITOR_SCRIPT_PATH="/usr/local/bin/$PYTHON_MONITOR_SCRIPT_NAME"
readonly PYTHON_MONITOR_SERVICE_NAME="wp-efs-s3-pywatchdog-v2.3.5"
readonly PY_MONITOR_LOG_FILE="/var/log/wp_efs_s3_py_monitor_v2.3.5.log"
readonly PY_S3_TRANSFER_LOG_FILE="/var/log/wp_s3_py_transferred_v2.3.5.log"
readonly AWS_S3_PYTHON_SCRIPT_KEY="efs_s3_monitor.py"

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.3.5.log"
MOUNT_POINT="/var/www/html"
WP_DOWNLOAD_DIR="/tmp/wp_download_temp"
WP_FINAL_CONTENT_DIR="/tmp/wp_final_efs_content"
ACTIVE_CONFIG_FILE_EFS="$MOUNT_POINT/wp-config.php"
CONFIG_SAMPLE_ON_EFS="$MOUNT_POINT/wp-config-sample.php"
HEALTH_CHECK_FILE_PATH_EFS="$MOUNT_POINT/healthcheck.php"
MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
EFS_OWNER_UID=1000
EFS_OWNER_USER="ec2-user"

# --- Variáveis Essenciais (Esperadas do Ambiente, carregadas pelo UserData) ---
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "WPDOMAIN"
    "ACCOUNT"
    "AWS_EFS_ACCESS_POINT_TARGET_ID_0"
    "AWS_S3_BUCKET_TARGET_NAME_0"
    "AWS_S3_BUCKET_TARGET_NAME_SCRIPT"
    "AWS_S3_BUCKET_TARGET_REGION_SCRIPT"
)

# --- Função de Auto-Instalação do Script Principal ---
self_install_script() {
    echo "INFO (self_install): Iniciando auto-instalação do script principal (v2.3.5)..."
    local current_script_path; current_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    echo "INFO (self_install): Copiando script de '$current_script_path' para $THIS_SCRIPT_TARGET_PATH..."
    if ! cp "$current_script_path" "$THIS_SCRIPT_TARGET_PATH"; then echo "ERRO CRÍTICO (self_install): Falha ao copiar script. Abortando."; exit 1; fi
    chmod +x "$THIS_SCRIPT_TARGET_PATH"
    echo "INFO (self_install): Script principal instalado e executável em $THIS_SCRIPT_TARGET_PATH."
}

# --- Funções Auxiliares (mount_efs, create_wp_config_template) ---
mount_efs() {
    local efs_id=$1; local mount_point_arg=$2; local efs_ap_id="${AWS_EFS_ACCESS_POINT_TARGET_ID_0:-}"
    local max_retries=5; local retry_delay_seconds=15; local attempt_num=1
    echo "INFO: Tentando montar EFS '$efs_id' em '$mount_point_arg' via AP '$efs_ap_id' (até $max_retries tentativas)..."
    while [ $attempt_num -le $max_retries ]; do
        echo "INFO: Tentativa de montagem EFS: $attempt_num de $max_retries..."
        if mount | grep -q "on ${mount_point_arg} type efs"; then echo "INFO: EFS já está montado em '$mount_point_arg'."; return 0; fi
        sudo mkdir -p "$mount_point_arg"; local mount_options="tls"; local mount_source="$efs_id:/"
        if [ -n "$efs_ap_id" ]; then mount_options="tls,accesspoint=$efs_ap_id"; mount_source="$efs_id"; echo "INFO: Usando Access Point '$efs_ap_id'."; else echo "INFO: Não usando Access Point."; fi
        if sudo timeout 30 mount -t efs -o "$mount_options" "$mount_source" "$mount_point_arg" -v; then
            echo "INFO: EFS montado com sucesso em '$mount_point_arg' na tentativa $attempt_num."
            if ! grep -q "${mount_point_arg} efs" /etc/fstab; then
                local fstab_mount_options="_netdev,${mount_options}"; local fstab_entry="$mount_source $mount_point_arg efs $fstab_mount_options 0 0"
                echo "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null; echo "INFO: Entrada adicionada ao /etc/fstab: '$fstab_entry'"
            fi; return 0
        else
            echo "AVISO: Falha ao montar EFS na tentativa $attempt_num. Código de saída: $?"
            if [ $attempt_num -lt $max_retries ]; then echo "INFO: Aguardando $retry_delay_seconds segundos..."; sleep $retry_delay_seconds; fi
        fi; attempt_num=$((attempt_num + 1))
    done
    echo "ERRO CRÍTICO: Falha ao montar EFS após $max_retries tentativas."; ip addr; dmesg | tail -n 20; exit 1
}

create_wp_config_template() {
    local target_file_on_efs="$1"; local primary_wpdomain_for_fallback="$2"; local db_name="$3"; local db_user="$4"; local db_password="$5"; local db_host="$6"
    local temp_config_file; temp_config_file=$(mktemp /tmp/wp-config.XXXXXX.php); sudo chmod 644 "$temp_config_file"; trap 'rm -f "$temp_config_file"' RETURN
    echo "INFO: Criando wp-config.php em '$temp_config_file' para EFS '$target_file_on_efs' com DB_HOST: '$db_host'..."
    if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "ERRO: '$CONFIG_SAMPLE_ON_EFS' não encontrado."; exit 1; fi
    sudo cp "$CONFIG_SAMPLE_ON_EFS" "$temp_config_file"
    SAFE_DB_NAME=$(echo "$db_name" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g"); SAFE_DB_USER=$(echo "$db_user" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(echo "$db_password" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g"); SAFE_DB_HOST=$(echo "$db_host" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$temp_config_file"; sed -i "s/username_here/$SAFE_DB_USER/g" "$temp_config_file"
    sed -i "s/password_here/$SAFE_DB_PASSWORD/g" "$temp_config_file"; sed -i "s/localhost/$SAFE_DB_HOST/g" "$temp_config_file"
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -n "$SALT" ]; then
        TEMP_SALT_FILE_INNER=$(mktemp /tmp/salts.XXXXXX); sudo chmod 644 "$TEMP_SALT_FILE_INNER"; echo "$SALT" >"$TEMP_SALT_FILE_INNER"
        sed -i -e '/^define( *'\''AUTH_KEY'\''/d' -e '/^define( *'\''SECURE_AUTH_KEY'\''/d' -e '/^define( *'\''LOGGED_IN_KEY'\''/d' -e '/^define( *'\''NONCE_KEY'\''/d' -e '/^define( *'\''AUTH_SALT'\''/d' -e '/^define( *'\''SECURE_AUTH_SALT'\''/d' -e '/^define( *'\''LOGGED_IN_SALT'\''/d' -e '/^define( *'\''NONCE_SALT'\''/d' "$temp_config_file"
        if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE_INNER" "$temp_config_file"; else cat "$TEMP_SALT_FILE_INNER" >>"$temp_config_file"; fi
        rm -f "$TEMP_SALT_FILE_INNER"; echo "INFO: SALTS configurados."
    else echo "ERRO: Falha ao obter SALTS."; fi
    PHP_DEFINES_BLOCK_CONTENT=$(cat <<EOPHP
// Gerado por wordpress_setup_v2.3.5.sh
\$site_scheme = 'https';
\$site_host = '$primary_wpdomain_for_fallback';
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) { \$hosts = explode(',', \$_SERVER['HTTP_X_FORWARDED_HOST']); \$site_host = trim(\$hosts[0]); } elseif (!empty(\$_SERVER['HTTP_HOST'])) { \$site_host = \$_SERVER['HTTP_HOST']; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
define('WP_HOME', \$site_scheme . '://' . \$site_host); define('WP_SITEURL', \$site_scheme . '://' . \$site_host);
define('FS_METHOD', 'direct');
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_SSL']) && \$_SERVER['HTTP_X_FORWARDED_SSL'] == 'on') { \$_SERVER['HTTPS'] = 'on'; }
EOPHP
)
    TEMP_DEFINES_FILE_INNER=$(mktemp /tmp/defines.XXXXXX); sudo chmod 644 "$TEMP_DEFINES_FILE_INNER"; echo -e "\n$PHP_DEFINES_BLOCK_CONTENT" >"$TEMP_DEFINES_FILE_INNER"
    if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE_INNER" "$temp_config_file"; else cat "$TEMP_DEFINES_FILE_INNER" >>"$temp_config_file"; fi
    rm -f "$TEMP_DEFINES_FILE_INNER"; echo "INFO: Defines configurados."
    echo "INFO: Copiando '$temp_config_file' para '$target_file_on_efs' como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp "$temp_config_file" "$target_file_on_efs"; then echo "INFO: Arquivo '$target_file_on_efs' criado."; else echo "ERRO CRÍTICO: Falha ao copiar para '$target_file_on_efs' como '$APACHE_USER'."; exit 1; fi
}

# (Função de exemplo, a lógica real deve ser implementada se necessária)
setup_python_monitor_script() { echo "INFO: Função 'setup_python_monitor_script' placeholder - A lógica real deve ser adicionada se necessária."; }
create_and_enable_python_monitor_service() { echo "INFO: Função 'create_and_enable_python_monitor_service' placeholder - A lógica real deve ser adicionada se necessária."; }

### INÍCIO DA FUNÇÃO PARA PROXYSQL ###
setup_and_configure_proxysql() {
    local rds_host="$1"
    local rds_port="$2"
    local db_user="$3"
    local db_pass="$4"

    echo "INFO (ProxySQL): Iniciando configuração do ProxySQL..."

    # Função auxiliar para enviar comandos à interface de admin do ProxySQL
    run_proxysql_admin() {
        mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "$1"
    }

    # Inicia o serviço para podermos configurá-lo
    if ! sudo systemctl start proxysql; then
        echo "ERRO CRÍTICO (ProxySQL): Falha ao iniciar o serviço ProxySQL para configuração."
        exit 1
    fi
    sleep 5 # Dá um tempo para o serviço subir

    echo "INFO (ProxySQL): Configurando servidor backend (RDS)..."
    run_proxysql_admin "INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${rds_host}', ${rds_port});"

    echo "INFO (ProxySQL): Configurando usuário de conexão com o backend..."
    run_proxysql_admin "INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('${db_user}', '${db_pass}', 10);"

    echo "INFO (ProxySQL): Configurando regra de roteamento transparente..."
    run_proxysql_admin "INSERT INTO mysql_query_rules (rule_id, active, username, destination_hostgroup, apply) VALUES (1, 1, '${db_user}', 10, 1);"

    echo "INFO (ProxySQL): Carregando e salvando configurações..."
    run_proxysql_admin "LOAD MYSQL SERVERS TO RUNTIME;"
    run_proxysql_admin "LOAD MYSQL USERS TO RUNTIME;"
    run_proxysql_admin "LOAD MYSQL QUERY RULES TO RUNTIME;"
    run_proxysql_admin "SAVE MYSQL SERVERS TO DISK;"
    run_proxysql_admin "SAVE MYSQL USERS TO DISK;"
    run_proxysql_admin "SAVE MYSQL QUERY RULES TO DISK;"

    echo "INFO (ProxySQL): Configuração do ProxySQL concluída."
}
### FIM DA FUNÇÃO PARA PROXYSQL ###

# --- Função para Otimizar Apache MPM e PHP-FPM para Alta Concorrência ---
tune_apache_and_phpfpm() {
    echo "INFO (Performance Tuning): Otimizando Apache (MPM Event) e PHP-FPM para alta concorrência..."
    local APACHE_MPM_TUNING_CONF="/etc/httpd/conf.d/mpm_tuning.conf"
    echo "INFO (Performance Tuning): Criando arquivo de configuração do Apache em '$APACHE_MPM_TUNING_CONF'..."
    sudo tee "$APACHE_MPM_TUNING_CONF" >/dev/null <<EOF_APACHE_MPM
# Configurações de performance para o MPM Event - Gerado por wordpress_setup_v2.3.5.sh
<IfModule mpm_event_module>
    StartServers             3
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadsPerChild          25
    ServerLimit              16
    MaxRequestWorkers        400
    MaxConnectionsPerChild   1000
</IfModule>
EOF_APACHE_MPM

    local PHP_FPM_POOL_CONF="/etc/php-fpm.d/www.conf"
    if [ -f "$PHP_FPM_POOL_CONF" ]; then
        echo "INFO (Performance Tuning): Ajustando pool do PHP-FPM em '$PHP_FPM_POOL_CONF'..."
        sudo sed -i 's/^pm.max_children = .*/pm.max_children = 50/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 10/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 30/' "$PHP_FPM_POOL_CONF"
        echo "INFO (Performance Tuning): Pool do PHP-FPM ajustado."
    else
        echo "AVISO (Performance Tuning): Arquivo '$PHP_FPM_POOL_CONF' não encontrado. Pulando otimização."
    fi
}

# --- Lógica Principal de Execução ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.3.5-FIXED) ($(date)) ---"
echo "INFO: Script target: $THIS_SCRIPT_TARGET_PATH. Log: ${LOG_FILE}"
echo "INFO: =================================================="
if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execução inicial deve ser como root."; exit 1; fi

# self_install_script # Descomente se precisar da função de auto-instalação

### INÍCIO DO BLOCO DE VERIFICAÇÃO DE VARIÁVEIS ###
echo "INFO: Verificando e imprimindo variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then ACCOUNT_STS=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); if [ -n "$ACCOUNT_STS" ]; then ACCOUNT="$ACCOUNT_STS"; echo "INFO: ACCOUNT ID obtido via STS: $ACCOUNT"; else echo "WARN: Falha obter ACCOUNT ID via STS."; ACCOUNT=""; fi; fi

AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] && [ -n "${ACCOUNT:-}" ] && [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
fi

error_found=0
echo "INFO: --- VALORES DAS VARIÁVEIS ESSENCIAIS ---"
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-UNDEFINED}"
    var_name_for_check="$var_name"
    current_var_value_to_check="${!var_name:-}"

    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        current_var_value_to_check="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
        var_name_for_check="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (construído de $var_name)"
    fi

    echo "INFO: Var (env): $var_name_for_check = '$current_var_value_to_check'"

    # Não falha se o Access Point não for definido
    if [ "$var_name" != "AWS_EFS_ACCESS_POINT_TARGET_ID_0" ] && [ -z "$current_var_value_to_check" ]; then
        echo "ERRO: Var essencial '$var_name_for_check' está vazia."
        error_found=1
    fi
done
echo "INFO: --- FIM DOS VALORES DAS VARIÁVEIS ---"
if [ "$error_found" -eq 1 ]; then echo "ERRO CRÍTICO: Variáveis faltando ou mal configuradas. Abortando."; exit 1; fi
echo "INFO: Verificação de variáveis concluída. O ARN do segredo está pronto para ser usado."
### FIM DO BLOCO DE VERIFICAÇÃO DE VARIÁVEIS ###


### INÍCIO DA SEÇÃO DE INSTALAÇÃO DE PACOTES CORRIGIDA ###
echo "INFO: Instalando pacotes (Apache, PHP, Python3, ProxySQL, etc.)..."
sudo yum update -y -q
sudo amazon-linux-extras install -y epel -q

# Adiciona repositório do ProxySQL
echo "INFO: Adicionando repositório do ProxySQL..."
curl -s https://repo.proxysql.com/ProxySQL/proxysql-2.x/repo.el.7.sh | sudo bash

# Instala todos os pacotes necessários de uma vez, incluindo proxysql
echo "INFO: Instalando httpd, aws-cli, mysql, efs-utils e proxysql..."
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils proxysql

echo "INFO: Habilitando e instalando PHP 7.4 e módulos relacionados..."
sudo amazon-linux-extras enable php7.4 -y -q
sudo yum install -y -q php php-common php-fpm php-mysqlnd php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache
### FIM DA SEÇÃO DE INSTALAÇÃO DE PACOTES CORRIGIDA ###

mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

# Lógica de teste de escrita no EFS...
EFS_TEST_FILE="$MOUNT_POINT/efs_write_test_$(date +%s).tmp"
echo "INFO: Testando escrita no EFS em '$EFS_TEST_FILE'..."
if sudo -u "$APACHE_USER" touch "$EFS_TEST_FILE"; then
    echo "INFO: Teste de escrita no EFS bem-sucedido."
    sudo -u "$APACHE_USER" rm -f "$EFS_TEST_FILE"
else
    echo "ERRO CRÍTICO: Falha no teste de escrita no EFS. Verifique permissões do EFS e do Ponto de Acesso."
    ls -ld "$MOUNT_POINT"
    exit 1
fi

### INÍCIO DA SEÇÃO DE BANCO DE DADOS MODIFICADA ###
echo "INFO: Obtendo credenciais do RDS do Secrets Manager..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then echo "ERRO: Falha obter segredo RDS."; exit 1; fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
DB_NAME_TO_USE="$AWS_DB_INSTANCE_TARGET_NAME_0"
RDS_ACTUAL_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
RDS_ACTUAL_PORT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f2)
[ -z "$RDS_ACTUAL_PORT" ] && RDS_ACTUAL_PORT=3306 # Default para MySQL se a porta não for especificada
DB_HOST_FOR_WP_CONFIG="127.0.0.1" # WordPress irá se conectar ao ProxySQL localmente

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ] || [ -z "$RDS_ACTUAL_HOST_ENDPOINT" ]; then
    echo "ERRO CRÍTICO: Falha ao extrair credenciais ou endpoint do RDS do segredo."
    exit 1
fi
echo "INFO: Credenciais do RDS obtidas com sucesso."
echo "INFO (DB Setup): RDS Real Endpoint: ${RDS_ACTUAL_HOST_ENDPOINT}:${RDS_ACTUAL_PORT}"
echo "INFO (DB Setup): Host para wp-config.php: ${DB_HOST_FOR_WP_CONFIG}"

# Configura o ProxySQL ANTES de criar o wp-config.php
setup_and_configure_proxysql "$RDS_ACTUAL_HOST_ENDPOINT" "$RDS_ACTUAL_PORT" "$DB_USER" "$DB_PASSWORD"
### FIM DA SEÇÃO DE BANCO DE DADOS MODIFICADA ###

echo "INFO: Verificando WP em '$MOUNT_POINT/wp-includes'..."
if [ ! -d "$MOUNT_POINT/wp-includes" ]; then
    echo "INFO: WordPress não encontrado no EFS. Baixando e instalando..."
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    sudo mkdir -p "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    sudo chown "$(id -u):$(id -g)" "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    (
      cd "$WP_DOWNLOAD_DIR" || { echo "ERRO: Falha ao entrar no diretório temporário '$WP_DOWNLOAD_DIR'."; exit 1; }
      curl -sLO https://wordpress.org/latest.tar.gz || { echo "ERRO: Falha download WP."; exit 1; }
      tar -xzf latest.tar.gz -C "$WP_FINAL_CONTENT_DIR" --strip-components=1 || { echo "ERRO: Falha extração WP."; exit 1; }
      rm latest.tar.gz
    )
    if [ $? -ne 0 ]; then echo "ERRO CRÍTICO: O bloco de download e extração do WordPress falhou."; exit 1; fi
    echo "INFO: Copiando para EFS como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp -aT "$WP_FINAL_CONTENT_DIR/" "$MOUNT_POINT/"; then echo "INFO: WP copiado para EFS."; else echo "ERRO: Falha copiar WP para EFS."; ls -ld "$MOUNT_POINT"; exit 1; fi
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
else
    echo "WARN: Instalação do WordPress já existe em '$MOUNT_POINT/wp-includes'. Pulando download."
fi


if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then
    echo "INFO: '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando...";
    create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_FOR_WP_CONFIG"
else
    echo "WARN: '$ACTIVE_CONFIG_FILE_EFS' já existe.";
fi

# (Lógica de Healthcheck, permissões, e config do Apache)
echo "INFO: Criando arquivo de health check em '$HEALTH_CHECK_FILE_PATH_EFS'..."
sudo -u "$APACHE_USER" tee "$HEALTH_CHECK_FILE_PATH_EFS" >/dev/null <<EOF
<?php http_response_code(200); echo "OK"; ?>
EOF

echo "INFO: Ajustando permissões finais no EFS ($MOUNT_POINT)..."
sudo chown -R "$APACHE_USER:$APACHE_USER" "$MOUNT_POINT"
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;

echo "INFO: Configurando Apache para servir de '$MOUNT_POINT'..."
sudo sed -i "s#^DocumentRoot \"/var/www/html\"#DocumentRoot \"$MOUNT_POINT\"#" /etc/httpd/conf/httpd.conf
sudo sed -i "s#^<Directory \"/var/www/html\">#<Directory \"$MOUNT_POINT\">#" /etc/httpd/conf/httpd.conf
HTTPD_CONF_D_WP="/etc/httpd/conf.d/wordpress.conf"
sudo tee "$HTTPD_CONF_D_WP" >/dev/null <<EOF
<Directory "$MOUNT_POINT">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

### INÍCIO DA SEÇÃO DE OTIMIZAÇÃO DE PERFORMANCE ###
tune_apache_and_phpfpm
### FIM DA SEÇÃO DE OTIMIZAÇÃO DE PERFORMANCE ###

### INÍCIO DA SEÇÃO DE INICIALIZAÇÃO DE SERVIÇOS MODIFICADA ###
PHP_FPM_SERVICE_NAME=""
POSSIBLE_FPM_NAMES=("php-fpm.service" "php7.4-fpm.service" "php74-php-fpm.service")
for fpm_name in "${POSSIBLE_FPM_NAMES[@]}"; do
    if sudo systemctl list-unit-files | grep -q -w "$fpm_name"; then
        PHP_FPM_SERVICE_NAME="$fpm_name"
        echo "INFO: Nome do serviço PHP-FPM detectado: $PHP_FPM_SERVICE_NAME"
        break
    fi
done
if [ -z "$PHP_FPM_SERVICE_NAME" ]; then echo "ERRO CRÍTICO: Não foi possível detectar o nome do serviço PHP-FPM."; exit 1; fi

echo "INFO: Habilitando e reiniciando serviços (httpd, $PHP_FPM_SERVICE_NAME, proxysql)..."
sudo systemctl enable httpd
sudo systemctl enable "$PHP_FPM_SERVICE_NAME"
sudo systemctl enable proxysql

# Reinicia os serviços na ordem correta: Proxy primeiro, depois dependentes
proxysql_restarted_successfully=false
if sudo systemctl restart proxysql; then
    echo "INFO: proxysql reiniciado com sucesso."
    proxysql_restarted_successfully=true
else
    echo "ERRO: Falha ao reiniciar proxysql."
fi

php_fpm_restarted_successfully=false
if sudo systemctl restart "$PHP_FPM_SERVICE_NAME"; then
    echo "INFO: $PHP_FPM_SERVICE_NAME reiniciado com sucesso."
    php_fpm_restarted_successfully=true
else
    echo "ERRO: Falha ao reiniciar $PHP_FPM_SERVICE_NAME."
fi

httpd_restarted_successfully=false
if sudo systemctl restart httpd; then
    echo "INFO: httpd reiniciado com sucesso."
    httpd_restarted_successfully=true
else
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."
fi

sleep 3

if $httpd_restarted_successfully && $php_fpm_restarted_successfully && $proxysql_restarted_successfully && \
   systemctl is-active --quiet httpd && systemctl is-active --quiet "$PHP_FPM_SERVICE_NAME" && systemctl is-active --quiet proxysql; then
    echo "INFO: httpd, $PHP_FPM_SERVICE_NAME e proxysql estão ativos."
else
    echo "ERRO CRÍTICO: Um ou mais serviços essenciais não estão ativos."
    sudo systemctl status httpd --no-pager
    sudo systemctl status "$PHP_FPM_SERVICE_NAME" --no-pager
    sudo systemctl status proxysql --no-pager
    exit 1
fi
### FIM DA SEÇÃO DE INICIALIZAÇÃO DE SERVIÇOS MODIFICADA ###


# --- Configuração do Monitoramento Python com Watchdog ---
# setup_python_monitor_script # Descomente se precisar da função
# create_and_enable_python_monitor_service # Descomente se precisar da função

echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v2.3.5-FIXED) concluído! ($(date)) ---"
echo "INFO: Adicionado ProxySQL para pooling de conexões com o RDS."
echo "INFO: WordPress agora se conecta a 127.0.0.1 (ProxySQL), que por sua vez se conecta ao RDS."
echo "INFO: =================================================="
exit 0
