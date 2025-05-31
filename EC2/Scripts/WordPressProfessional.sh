#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.0.0-zero-touch-s3-fixed-dbname (UserData Env, Sudoers, MU-Plugin S3 Sync, DB Name from Env Var)

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.0.sh"
readonly SUDOERS_FILE_NAME="92-wp-s3sync-v2.0-sudo" # Nome do arquivo em /etc/sudoers.d/
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.0_env_vars.sh"

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.0.log"
S3_SYNC_LOG_FILE="/tmp/s3_mu_plugin_sync_v2.0.log"
PHP_TRIGGER_LOG_FILE="/tmp/s3_php_trigger_v2.0.log"

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
    "AWS_DB_INSTANCE_TARGET_NAME_0" # Crucial para o nome do DB
    "WPDOMAIN"
    "ACCOUNT"
    "AWS_EFS_ACCESS_POINT_TARGET_ID_0"
    "AWS_S3_BUCKET_TARGET_NAME_0" # Para S3 Sync
    # "AWS_CLOUDFRONT_DISTRIBUTION_ID_0" # Opcional
)

# --- Função de Auto-Instalação e Configuração do Sudoers ---
self_install_and_configure_sudoers() {
    echo "INFO (self_install): Iniciando auto-instalação e configuração do sudoers..."
    local current_script_path
    current_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    echo "INFO (self_install): Copiando script de '$current_script_path' para $THIS_SCRIPT_TARGET_PATH..."
    if ! cp "$current_script_path" "$THIS_SCRIPT_TARGET_PATH"; then
        echo "ERRO CRÍTICO (self_install): Falha ao copiar script para '$THIS_SCRIPT_TARGET_PATH'. Abortando."
        exit 1
    fi
    chmod +x "$THIS_SCRIPT_TARGET_PATH"
    echo "INFO (self_install): Script copiado e tornado executável em $THIS_SCRIPT_TARGET_PATH."

    local sudoers_entry_path="/etc/sudoers.d/$SUDOERS_FILE_NAME"
    local sudoers_content="$APACHE_USER ALL=(ALL) NOPASSWD: $THIS_SCRIPT_TARGET_PATH s3sync"
    echo "INFO (self_install): Configurando sudoers em $sudoers_entry_path para o usuário '$APACHE_USER'..."
    if echo "$sudoers_content" > "$sudoers_entry_path"; then
        chmod 0440 "$sudoers_entry_path"
        echo "INFO (self_install): Configuração do sudoers '$sudoers_entry_path' concluída."
    else
        echo "ERRO CRÍTICO (self_install): Falha ao escrever em $sudoers_entry_path. Verifique se o script está rodando como root. Abortando."
        exit 1
    fi
    echo "INFO (self_install): Auto-instalação concluída."
}

# --- Funções Auxiliares ---
mount_efs() {
    local efs_id=$1
    local mount_point_arg=$2
    local efs_ap_id="${AWS_EFS_ACCESS_POINT_TARGET_ID_0:-}"

    local max_retries=5
    local retry_delay_seconds=15
    local attempt_num=1

    echo "INFO: Tentando montar EFS '$efs_id' em '$mount_point_arg' via AP '$efs_ap_id' (até $max_retries tentativas)..."

    while [ $attempt_num -le $max_retries ]; do
        echo "INFO: Tentativa de montagem EFS: $attempt_num de $max_retries..."
        if mount | grep -q "on ${mount_point_arg} type efs"; then
            echo "INFO: EFS já está montado em '$mount_point_arg'."
            return 0
        fi

        sudo mkdir -p "$mount_point_arg"
        local mount_options="tls"
        local mount_source="$efs_id:/" # Formato para EFS ID (fs-xxxx)

        if [ -n "$efs_ap_id" ]; then
            mount_options="tls,accesspoint=$efs_ap_id"
            mount_source="$efs_id" # Para AP, a fonte é apenas o EFS ID
            echo "INFO: Usando Access Point '$efs_ap_id'."
        else
            echo "INFO: Não usando Access Point (AWS_EFS_ACCESS_POINT_TARGET_ID_0 não definido ou vazio)."
        fi

        if sudo timeout 30 mount -t efs -o "$mount_options" "$mount_source" "$mount_point_arg" -v; then
            echo "INFO: EFS montado com sucesso em '$mount_point_arg' na tentativa $attempt_num."
            if ! grep -q "${mount_point_arg} efs" /etc/fstab; then
                local fstab_mount_options="_netdev,${mount_options}"
                local fstab_entry="$mount_source $mount_point_arg efs $fstab_mount_options 0 0"
                echo "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null
                echo "INFO: Entrada adicionada ao /etc/fstab: '$fstab_entry'"
            fi
            return 0
        else
            echo "AVISO: Falha ao montar EFS na tentativa $attempt_num. Código de saída: $?"
            if [ $attempt_num -lt $max_retries ]; then
                echo "INFO: Aguardando $retry_delay_seconds segundos antes da próxima tentativa..."
                sleep $retry_delay_seconds
            fi
        fi
        attempt_num=$((attempt_num + 1))
    done

    echo "ERRO CRÍTICO: Falha ao montar EFS após $max_retries tentativas. Verifique logs, conectividade e config do AP/EFS."
    echo "DEBUG: Informações de rede (exemplo):"; ip addr
    echo "DEBUG: Últimas mensagens do kernel (dmesg):"; dmesg | tail -n 20
    exit 1
}

create_wp_config_template() {
    local target_file_on_efs="$1"
    local primary_wpdomain_for_fallback="$2"
    local db_name="$3" # Este agora virá diretamente de AWS_DB_INSTANCE_TARGET_NAME_0
    local db_user="$4"
    local db_password="$5"
    local db_host="$6"
    local temp_config_file
    temp_config_file=$(mktemp /tmp/wp-config.XXXXXX.php)
    sudo chmod 644 "$temp_config_file"
    trap 'rm -f "$temp_config_file"' RETURN

    echo "INFO: Criando wp-config.php em '$temp_config_file' para EFS '$target_file_on_efs', otimizado para CloudFront (fallback host: $primary_wpdomain_for_fallback)"
    if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then
        echo "ERRO: '$CONFIG_SAMPLE_ON_EFS' não encontrado. WP foi copiado?"
        exit 1
    fi
    sudo cp "$CONFIG_SAMPLE_ON_EFS" "$temp_config_file"

    SAFE_DB_NAME=$(echo "$db_name" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_USER=$(echo "$db_user" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(echo "$db_password" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_HOST=$(echo "$db_host" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$temp_config_file"
    sed -i "s/username_here/$SAFE_DB_USER/g" "$temp_config_file"
    sed -i "s/password_here/$SAFE_DB_PASSWORD/g" "$temp_config_file"
    sed -i "s/localhost/$SAFE_DB_HOST/g" "$temp_config_file"

    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -n "$SALT" ]; then
        TEMP_SALT_FILE_INNER=$(mktemp /tmp/salts.XXXXXX)
        sudo chmod 644 "$TEMP_SALT_FILE_INNER"
        echo "$SALT" >"$TEMP_SALT_FILE_INNER"
        # shellcheck disable=SC2016
        sed -i -e '/^define( *'\''AUTH_KEY'\''/d' -e '/^define( *'\''SECURE_AUTH_KEY'\''/d' \
            -e '/^define( *'\''LOGGED_IN_KEY'\''/d' -e '/^define( *'\''NONCE_KEY'\''/d' \
            -e '/^define( *'\''AUTH_SALT'\''/d' -e '/^define( *'\''SECURE_AUTH_SALT'\''/d' \
            -e '/^define( *'\''LOGGED_IN_SALT'\''/d' -e '/^define( *'\''NONCE_SALT'\''/d' "$temp_config_file"
        if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then
            sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE_INNER" "$temp_config_file"
        else
            cat "$TEMP_SALT_FILE_INNER" >>"$temp_config_file"
        fi
        rm -f "$TEMP_SALT_FILE_INNER"
        echo "INFO: SALTS configurados."
    else echo "ERRO: Falha ao obter SALTS."; fi

    PHP_DEFINES_BLOCK_CONTENT=$(cat <<EOPHP
// --- WordPress URL configuration for CloudFront ---
// Default to https as CloudFront will handle SSL termination.
\$site_scheme = 'https';

// Use X-Forwarded-Host if available, otherwise fallback to WPDOMAIN.
\$site_host = '$primary_wpdomain_for_fallback'; // Bash injects WPDOMAIN here
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) {
    \$hosts = explode(',', \$_SERVER['HTTP_X_FORWARDED_HOST']);
    \$site_host = trim(\$hosts[0]);
} elseif (!empty(\$_SERVER['HTTP_HOST'])) { // Fallback to HTTP_HOST
    \$site_host = \$_SERVER['HTTP_HOST'];
}

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

define('WP_HOME', \$site_scheme . '://' . \$site_host);
define('WP_SITEURL', \$site_scheme . '://' . \$site_host);
// --- End WordPress URL configuration ---

define('FS_METHOD', 'direct');

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
if (isset(\$_SERVER['HTTP_X_FORWARDED_SSL']) && \$_SERVER['HTTP_X_FORWARDED_SSL'] == 'on') {
    \$_SERVER['HTTPS'] = 'on';
}
EOPHP
)

    TEMP_DEFINES_FILE_INNER=$(mktemp /tmp/defines.XXXXXX)
    sudo chmod 644 "$TEMP_DEFINES_FILE_INNER"
    echo -e "\n$PHP_DEFINES_BLOCK_CONTENT" >"$TEMP_DEFINES_FILE_INNER"
    if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then
        sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE_INNER" "$temp_config_file"
    else
        cat "$TEMP_DEFINES_FILE_INNER" >>"$temp_config_file"
    fi
    rm -f "$TEMP_DEFINES_FILE_INNER"
    echo "INFO: Defines (incluindo URLs otimizadas para CloudFront) configurados."

    echo "INFO: Copiando '$temp_config_file' para '$target_file_on_efs' como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp "$temp_config_file" "$target_file_on_efs"; then
        echo "INFO: Arquivo '$target_file_on_efs' criado."
    else
        echo "ERRO CRÍTICO: Falha ao copiar para '$target_file_on_efs' como '$APACHE_USER'."
        exit 1
    fi
}

# --- Função: Sincronização de Estáticos para S3 ---
sync_static_to_s3() {
    echo "INFO ($(date)): Função sync_static_to_s3 iniciada..."
    local source_dir="$MOUNT_POINT"
    local s3_bucket="$AWS_S3_BUCKET_TARGET_NAME_0"
    local s3_prefix=""

    echo "INFO (sync_static_to_s3): Sincronizando de '$source_dir' para 's3://$s3_bucket/$s3_prefix'..."
    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then echo "ERRO (sync_static_to_s3): Diretório fonte '$source_dir' não definido ou não existe." ; return 1; fi
    if [ -z "$s3_bucket" ]; then echo "ERRO (sync_static_to_s3): Nome do bucket S3 (AWS_S3_BUCKET_TARGET_NAME_0) não está definido." ; return 1; fi

    local aws_cli_path
    aws_cli_path=$(command -v aws)
    if [ -z "$aws_cli_path" ]; then echo "ERRO (sync_static_to_s3): AWS CLI não encontrado."; return 1; fi

    "$aws_cli_path" configure set default.s3.max_concurrent_requests 20
    "$aws_cli_path" configure set default.s3.max_queue_size 10000

    declare -a include_patterns=(
        "wp-content/uploads/*"
        "wp-content/themes/*/*.css" "wp-content/themes/*/*.js" "wp-content/themes/*/*.jpg"
        "wp-content/themes/*/*.jpeg" "wp-content/themes/*/*.png" "wp-content/themes/*/*.gif"
        "wp-content/themes/*/*.svg" "wp-content/themes/*/*.webp" "wp-content/themes/*/*.ico"
        "wp-content/themes/*/*.woff" "wp-content/themes/*/*.woff2" "wp-content/themes/*/*.ttf"
        "wp-content/themes/*/*.eot" "wp-content/themes/*/*.otf"
        "wp-content/plugins/*/*.css" "wp-content/plugins/*/*.js" "wp-content/plugins/*/*.jpg"
        "wp-content/plugins/*/*.jpeg" "wp-content/plugins/*/*.png" "wp-content/plugins/*/*.gif"
        "wp-content/plugins/*/*.svg" "wp-content/plugins/*/*.webp" "wp-content/plugins/*/*.ico"
        "wp-content/plugins/*/*.woff" "wp-content/plugins/*/*.woff2"
        "wp-includes/js/*" "wp-includes/css/*" "wp-includes/images/*"
    )
    local sync_command_args=()
    sync_command_args+=("--exclude" "*")
    for pattern in "${include_patterns[@]}"; do sync_command_args+=("--include" "$pattern"); done
    sync_command_args+=("--delete")

    echo "INFO (sync_static_to_s3): Executando comando: $aws_cli_path s3 sync \"$source_dir\" \"s3://$s3_bucket/$s3_prefix\" ${sync_command_args[*]}"
    if "$aws_cli_path" s3 sync "$source_dir" "s3://$s3_bucket/$s3_prefix" "${sync_command_args[@]}"; then
        echo "INFO (sync_static_to_s3): Sincronização para S3 concluída com sucesso."
        # if [ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" ]; then
        #    echo "INFO (sync_static_to_s3): Invalidando cache do CloudFront '${AWS_CLOUDFRONT_DISTRIBUTION_ID_0}' para '/*'"
        #    "$aws_cli_path" cloudfront create-invalidation --distribution-id "$AWS_CLOUDFRONT_DISTRIBUTION_ID_0" --paths "/*"
        # fi
    else
        echo "ERRO (sync_static_to_s3): Falha na sincronização para S3. Verifique permissões do IAM Role e logs."
        return 1
    fi
    return 0
}

# --- Função: Criar MU-Plugin para S3 Sync Trigger ---
create_s3_sync_mu_plugin() {
    local mu_plugins_dir="$MOUNT_POINT/wp-content/mu-plugins"
    local mu_plugin_file="$mu_plugins_dir/auto-s3-sync-trigger-v2.0.php"
    local bash_script_to_call="$THIS_SCRIPT_TARGET_PATH"

    echo "INFO: Criando MU-Plugin para disparar sincronização S3..."
    if [ ! -d "$MOUNT_POINT/wp-content" ]; then echo "ERRO: Diretório '$MOUNT_POINT/wp-content' não encontrado." ; return 1; fi

    sudo mkdir -p "$mu_plugins_dir"
    sudo chown "$APACHE_USER":"$APACHE_USER" "$mu_plugins_dir"
    sudo chmod 775 "$mu_plugins_dir"

    # shellcheck disable=SC2016
    read -r -d '' PHP_MU_PLUGIN_CONTENT <<EOF
<?php
/**
 * MU-Plugin para disparar automaticamente a sincronização de arquivos estáticos para o S3.
 * Gerado por: wordpress_setup_v2.0.sh
 * Versão: 2.0
 */

if ( ! defined( 'ABSPATH' ) ) { exit; }

define('S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2', '${bash_script_to_call}');
define('S3_SYNC_PHP_TRIGGER_LOG_FOR_PHP_V2', '${PHP_TRIGGER_LOG_FILE}');

function s3_sync_php_log_message_v2(\$message) {
    \$timestamp = date('[Y-m-d H:i:s] ');
    if (is_writable(S3_SYNC_PHP_TRIGGER_LOG_FOR_PHP_V2) || (!file_exists(S3_SYNC_PHP_TRIGGER_LOG_FOR_PHP_V2) && is_writable(dirname(S3_SYNC_PHP_TRIGGER_LOG_FOR_PHP_V2)))) {
        file_put_contents(S3_SYNC_PHP_TRIGGER_LOG_FOR_PHP_V2, \$timestamp . \$message . PHP_EOL, FILE_APPEND);
    } else {
        error_log("S3 Sync PHP Log v2 (fallback): " . \$message);
    }
}

function trigger_s3_static_sync_from_php_hook_v2(\$caller_hook = 'unknown_hook') {
    if ( ! defined('S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2') || ! file_exists(S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2) ) {
        s3_sync_php_log_message_v2("S3 Sync ERRO: S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2 ('" . S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2 . "') não definido ou script não encontrado.");
        return;
    }
    \$command = 'sudo ' . S3_SYNC_BASH_SCRIPT_PATH_FOR_PHP_V2 . ' s3sync > /dev/null 2>&1 &';
    s3_sync_php_log_message_v2("S3 Sync: Disparado por '{\$caller_hook}'. Comando: {\$command}");
    shell_exec(\$command);
}

add_action('add_attachment', function() { trigger_s3_static_sync_from_php_hook_v2('add_attachment'); }, 10, 0);
add_action('edit_attachment', function(\$attachment_id) { trigger_s3_static_sync_from_php_hook_v2('edit_attachment'); }, 10, 1);
add_action('upgrader_process_complete', function(\$upgrader_object, \$options) {
    \$actions_to_sync = ['update', 'install'];
    if (isset(\$options['type']) && isset(\$options['action']) && in_array(\$options['action'], \$actions_to_sync)) {
        trigger_s3_static_sync_from_php_hook_v2("upgrader_process_complete_{type:{\$options['type']},action:{\$options['action']}}");
    }
}, 10, 2);
add_action('after_switch_theme', function() { trigger_s3_static_sync_from_php_hook_v2('after_switch_theme'); }, 10, 0);

s3_sync_php_log_message_v2("S3 Sync: MU-Plugin auto-s3-sync-trigger-v2.0.php carregado.");
EOF

    echo "INFO: Conteúdo do MU-Plugin definido. Tentando escrever em '$mu_plugin_file'..."
    echo "$PHP_MU_PLUGIN_CONTENT" | sudo tee "$mu_plugin_file" > /dev/null
    if [ $? -eq 0 ]; then
        echo "INFO: MU-Plugin '$mu_plugin_file' criado com sucesso."
        sudo chown "$APACHE_USER":"$APACHE_USER" "$mu_plugin_file"
        sudo chmod 644 "$mu_plugin_file"
        echo "INFO: Permissões do MU-Plugin ajustadas."
    else
        echo "ERRO: Falha ao criar MU-Plugin '$mu_plugin_file'."
        return 1
    fi
}

# --- Lógica Principal de Execução ---

# Argumento 's3sync': Chamado pelo MU-Plugin
if [ "$1" == "s3sync" ]; then
    exec > >(tee -a "${S3_SYNC_LOG_FILE}") 2>&1
    echo "INFO ($(date)): Chamada 's3sync' recebida pelo script $THIS_SCRIPT_TARGET_PATH..."
    if [ -f "$ENV_VARS_FILE" ]; then
        echo "INFO (s3sync call): Carregando variáveis de ambiente de $ENV_VARS_FILE"
        # shellcheck source=/dev/null
        source "$ENV_VARS_FILE"
    else
        echo "WARN (s3sync call): Arquivo de variáveis $ENV_VARS_FILE não encontrado. Sincronização pode falhar."
        MOUNT_POINT="${MOUNT_POINT:-/var/www/html}"
    fi
    sync_static_to_s3
    exit $?
fi

# --- Continuação do Script Principal de Setup (executado uma vez via UserData) ---
# Nota: O UserData já deve ter carregado as variáveis do /home/ec2-user/.env
# Não é necessário um `source /home/ec2-user/.env` aqui se o UserData já faz isso.

exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.0.0) ($(date)) ---"
echo "INFO: Script alvo para instalação: $THIS_SCRIPT_TARGET_PATH"
echo "INFO: Logging principal configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "ERRO CRÍTICO: A execução inicial deste script de setup precisa ser como root (ex: UserData)."
  exit 1
fi

self_install_and_configure_sudoers

echo "INFO: Verificando variáveis de ambiente essenciais (devem ter sido exportadas pelo UserData)..."
if [ -z "${ACCOUNT:-}" ]; then
    echo "INFO: ACCOUNT ID não fornecido, tentando obter via AWS STS..."
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT" ]; then
        echo "WARN: Falha ao obter ACCOUNT ID."
    else
        echo "INFO: ACCOUNT ID obtido: $ACCOUNT"
    fi
fi
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] && \
   [ -n "${ACCOUNT:-}" ] && \
   [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
else
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
    echo "WARN: Não foi possível construir o ARN completo do Secrets Manager."
fi

error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-}"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        if [ -z "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ]; then
            echo "ERRO: Variável '$var_name' (ou seu ARN construído) não definida ou vazia."
            error_found=1
        fi
    elif [ -z "$current_var_value" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    fi
done
if [ "$error_found" -eq 1 ]; then
    echo "ERRO CRÍTICO: Uma ou mais variáveis essenciais estão faltando. Abortando setup."
    exit 1
fi
echo "INFO: Domínio de Produção (WPDOMAIN): ${WPDOMAIN}"
echo "INFO: Bucket S3 para offload (AWS_S3_BUCKET_TARGET_NAME_0): ${AWS_S3_BUCKET_TARGET_NAME_0}"
echo "INFO: Nome do DB (AWS_DB_INSTANCE_TARGET_NAME_0): ${AWS_DB_INSTANCE_TARGET_NAME_0}"
echo "INFO: Verificação de variáveis essenciais concluída."

echo "INFO: Instalando pacotes..."
sudo yum update -y -q
sudo amazon-linux-extras install -y epel -q
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils
sudo amazon-linux-extras enable php7.4 -y -q # Considere php8.0+
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache
echo "INFO: Pacotes instalados."

mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

echo "INFO: Testando escrita no EFS como usuário '$EFS_OWNER_USER' (UID $EFS_OWNER_UID)..."
TEMP_EFS_TEST_FILE="$MOUNT_POINT/efs_write_test_owner_$(date +%s).txt"
if sudo -u "$EFS_OWNER_USER" touch "$TEMP_EFS_TEST_FILE"; then
    echo "INFO: Teste de escrita no EFS como '$EFS_OWNER_USER' SUCESSO."
    sudo -u "$EFS_OWNER_USER" rm "$TEMP_EFS_TEST_FILE"
else
    echo "ERRO CRÍTICO: Teste de escrita no EFS como '$EFS_OWNER_USER' FALHOU."
    ls -ld "$MOUNT_POINT"
    exit 1
fi

echo "INFO: Obtendo credenciais do RDS..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then echo "ERRO: Falha ao obter segredo RDS."; exit 1; fi

DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair creds RDS (username/password)."
    exit 1
fi

# Usar DIRETAMENTE a variável de ambiente AWS_DB_INSTANCE_TARGET_NAME_0 para o nome do DB
DB_NAME_TO_USE="$AWS_DB_INSTANCE_TARGET_NAME_0"
echo "INFO (DB Setup): Nome do banco de dados será: '$DB_NAME_TO_USE' (obtido de AWS_DB_INSTANCE_TARGET_NAME_0)"

# Adiciona um log de debug para a variável antes da checagem
echo "DEBUG (DB Setup): Verificando DB_NAME_TO_USE: '$DB_NAME_TO_USE'"
echo "DEBUG (DB Setup): Verificando AWS_DB_INSTANCE_TARGET_NAME_0 no ambiente atual: '$AWS_DB_INSTANCE_TARGET_NAME_0'"

if [ "$DB_NAME_TO_USE" == "null" ] || [ -z "$DB_NAME_TO_USE" ]; then
    echo "ERRO CRÍTICO: Nome do banco de dados (DB_NAME) não pôde ser determinado a partir de AWS_DB_INSTANCE_TARGET_NAME_0."
    echo "DEBUG (DB Setup): Valor atual de AWS_DB_INSTANCE_TARGET_NAME_0 no script: '$AWS_DB_INSTANCE_TARGET_NAME_0'"
    exit 1
fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
echo "INFO: Credenciais RDS extraídas (Usuário: $DB_USER, DB: $DB_NAME_TO_USE)."

echo "INFO: Verificando se WordPress já existe em '$MOUNT_POINT/wp-includes'..."
if [ -d "$MOUNT_POINT/wp-includes" ] && [ -f "$CONFIG_SAMPLE_ON_EFS" ]; then
    echo "WARN: WordPress já encontrado em '$MOUNT_POINT'. Pulando download."
else
    echo "INFO: WordPress não encontrado. Iniciando download..."
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    sudo mkdir -p "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    sudo chown "$(id -u):$(id -g)" "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    cd "$WP_DOWNLOAD_DIR"
    echo "INFO: Baixando WordPress para '$WP_DOWNLOAD_DIR'..."
    curl -sLO https://wordpress.org/latest.tar.gz || { echo "ERRO: Falha download WP."; exit 1; }
    echo "INFO: Extraindo WordPress em '$WP_FINAL_CONTENT_DIR'..."
    tar -xzf latest.tar.gz -C "$WP_FINAL_CONTENT_DIR" --strip-components=1 || { echo "ERRO: Falha extração WP."; exit 1; }
    rm latest.tar.gz
    echo "INFO: WordPress baixado e extraído para '$WP_FINAL_CONTENT_DIR'."
    echo "INFO: Copiando arquivos do WordPress de '$WP_FINAL_CONTENT_DIR' para '$MOUNT_POINT' como '$EFS_OWNER_USER'..."
    if sudo -u "$EFS_OWNER_USER" cp -aT "$WP_FINAL_CONTENT_DIR/" "$MOUNT_POINT/"; then
        echo "INFO: Arquivos do WordPress copiados para EFS."
    else
        echo "ERRO: Falha ao copiar arquivos do WordPress para '$MOUNT_POINT' como '$EFS_OWNER_USER'."
        ls -ld "$MOUNT_POINT"
        exit 1
    fi
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    echo "INFO: Limpeza dos diretórios de download/preparação concluída."
fi

echo "INFO: Salvando variáveis de ambiente essenciais para chamadas futuras do s3sync em '$ENV_VARS_FILE'..."
ENV_VARS_FILE_CONTENT="#!/bin/bash\n# Variáveis de ambiente para $THIS_SCRIPT_TARGET_PATH s3sync\n"
for var_name in "${essential_vars[@]}"; do
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        current_var_value_escaped=$(printf '%q' "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0")
        ENV_VARS_FILE_CONTENT+="export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=$current_var_value_escaped\n"
    else
        current_var_value_escaped=$(printf '%q' "${!var_name}")
        ENV_VARS_FILE_CONTENT+="export $var_name=$current_var_value_escaped\n"
    fi
done
ENV_VARS_FILE_CONTENT+="export MOUNT_POINT=$(printf '%q' "$MOUNT_POINT")\n"
ENV_VARS_FILE_CONTENT+="export APACHE_USER=$(printf '%q' "$APACHE_USER")\n"
if [ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" ]; then
    ENV_VARS_FILE_CONTENT+="export AWS_CLOUDFRONT_DISTRIBUTION_ID_0=$(printf '%q' "$AWS_CLOUDFRONT_DISTRIBUTION_ID_0")\n"
fi
echo -e "$ENV_VARS_FILE_CONTENT" | sudo tee "$ENV_VARS_FILE" > /dev/null
sudo chmod 644 "$ENV_VARS_FILE"
echo "INFO: Variáveis salvas em '$ENV_VARS_FILE'."

if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then
    echo "ERRO CRÍTICO: $CONFIG_SAMPLE_ON_EFS não encontrado."
    exit 1
fi
if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then
    echo "INFO: Arquivo '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando..."
    create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" \
        "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
else
    echo "WARN: Arquivo de configuração ativo '$ACTIVE_CONFIG_FILE_EFS' já existe."
fi

if [ -d "$MOUNT_POINT/wp-content" ]; then
    create_s3_sync_mu_plugin
else
    echo "AVISO: $MOUNT_POINT/wp-content não existe, pulando criação do mu-plugin de sync S3."
fi

echo "INFO: Criando health check em '$HEALTH_CHECK_FILE_PATH_EFS' como '$APACHE_USER'..."
HEALTH_CHECK_CONTENT="<?php http_response_code(200); header(\"Content-Type: text/plain; charset=utf-8\"); echo \"OK - WP Health Check - v2.0.0 - \" . date(\"Y-m-d\TH:i:s\Z\"); exit; ?>"
TEMP_HEALTH_CHECK_FILE=$(mktemp /tmp/healthcheck.XXXXXX.php)
sudo chmod 644 "$TEMP_HEALTH_CHECK_FILE"
echo "$HEALTH_CHECK_CONTENT" >"$TEMP_HEALTH_CHECK_FILE"
if sudo -u "$APACHE_USER" cp "$TEMP_HEALTH_CHECK_FILE" "$HEALTH_CHECK_FILE_PATH_EFS"; then
    echo "INFO: Health check criado."
else echo "ERRO: Falha ao criar health check como '$APACHE_USER'."; fi
rm -f "$TEMP_HEALTH_CHECK_FILE"

echo "INFO: Ajustando permissões finais em '$MOUNT_POINT' para o usuário '$APACHE_USER'..."
if sudo chown -R "$APACHE_USER":"$APACHE_USER" "$MOUNT_POINT"; then
    echo "INFO: Propriedade de '$MOUNT_POINT' definida para $APACHE_USER:$APACHE_USER."
else
    echo "WARN: Falha no chown -R $APACHE_USER:$APACHE_USER '$MOUNT_POINT'. Verificando GID."
    APACHE_GID=$(getent group "$APACHE_USER" | cut -d: -f3)
    CURRENT_GID=$(stat -c "%g" "$MOUNT_POINT")
    if [ "$CURRENT_GID" != "$APACHE_GID" ]; then
        echo "ERRO CRÍTICO: GID do '$MOUNT_POINT' ($CURRENT_GID) não é $APACHE_GID ($APACHE_USER) E chown falhou."
        ls -ld "$MOUNT_POINT"
    else
        echo "INFO: GID do '$MOUNT_POINT' é $APACHE_GID ($APACHE_USER). Permissões de grupo podem ser suficientes."
    fi
fi
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
if [ -f "$ACTIVE_CONFIG_FILE_EFS" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE_EFS"; fi
if [ -f "$HEALTH_CHECK_FILE_PATH_EFS" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH_EFS"; fi
echo "INFO: Permissões ajustadas."

echo "INFO: Configurando Apache..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf" # Não usado diretamente para config do WP
HTTPD_WP_CONF="/etc/httpd/conf.d/wordpress_v2.0.conf"

if [ ! -f "$HTTPD_WP_CONF" ]; then
    echo "INFO: Criando arquivo de configuração do Apache para WordPress em $HTTPD_WP_CONF"
    sudo tee "$HTTPD_WP_CONF" > /dev/null <<EOF
<Directory "${MOUNT_POINT}">
    AllowOverride All
    Require all granted
</Directory>

<IfModule mod_setenvif.c>
  SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on
</IfModule>
EOF
    echo "INFO: Arquivo $HTTPD_WP_CONF criado."
else
    # Garante que as diretivas estão presentes se o arquivo já existe
    if ! grep -q "AllowOverride All" "$HTTPD_WP_CONF"; then
        sudo sed -i '/<Directory "${MOUNT_POINT//\//\\/}">/a \    AllowOverride All' "$HTTPD_WP_CONF"
        echo "INFO: AllowOverride All adicionado a $HTTPD_WP_CONF existente."
    fi
    if ! grep -q "SetEnvIf X-Forwarded-Proto" "$HTTPD_WP_CONF"; then
         echo -e "\n<IfModule mod_setenvif.c>\n  SetEnvIf X-Forwarded-Proto \"^https\$\" HTTPS=on\n</IfModule>" | sudo tee -a "$HTTPD_WP_CONF" > /dev/null
        echo "INFO: SetEnvIf X-Forwarded-Proto adicionado a $HTTPD_WP_CONF existente."
    fi
    echo "INFO: $HTTPD_WP_CONF já existe, verificações/adições feitas."
fi

echo "INFO: Habilitando e reiniciando httpd e php-fpm..."
sudo systemctl enable httpd
sudo systemctl enable php-fpm
if ! sudo systemctl restart php-fpm; then
    echo "ERRO: Falha ao reiniciar php-fpm."
    sudo systemctl status php-fpm -l --no-pager
fi
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."
    sudo apachectl configtest
    sudo tail -n 50 /var/log/httpd/error_log
    exit 1
fi
sleep 3
if systemctl is-active --quiet httpd && systemctl is-active --quiet php-fpm; then
    echo "INFO: httpd e php-fpm ativos."
else
    echo "ERRO CRÍTICO: httpd ou php-fpm não ativos após reinício."
    sudo systemctl status httpd -l --no-pager ; sudo systemctl status php-fpm -l --no-pager
    sudo tail -n 50 /var/log/httpd/error_log
    exit 1
fi

echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v2.0.0) concluído! ($(date)) ---"
echo "INFO: WordPress configurado com S3 Sync MU-Plugin, usando DB Name de AWS_DB_INSTANCE_TARGET_NAME_0."
echo "INFO: Script instalado em: $THIS_SCRIPT_TARGET_PATH"
echo "INFO: Sudoers configurado em: /etc/sudoers.d/$SUDOERS_FILE_NAME"
echo "INFO: Variáveis para sync salvas em: $ENV_VARS_FILE"
echo "INFO: Logs do trigger PHP: $PHP_TRIGGER_LOG_FILE"
echo "INFO: Logs da execução do sync S3 (quando chamado pelo PHP): $S3_SYNC_LOG_FILE"
echo "INFO: Domínio primário esperado: https://${WPDOMAIN}"
echo "INFO: Health Check: /healthcheck.php (Ex: https://${WPDOMAIN}/healthcheck.php)"
echo "INFO: Log principal do setup: ${LOG_FILE}"
echo "INFO: =================================================="
exit 0
