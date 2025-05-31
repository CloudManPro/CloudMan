#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.2.0-zero-touch-s3-inotify (UserData Env, Inotify S3 Sync, DB Name from Env Var, Var Logging)

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.2.0.sh"
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.2.0_env_vars.sh"

# Script de Monitoramento Inotify e Serviço
readonly INOTIFY_MONITOR_SCRIPT_PATH="/usr/local/bin/wp_efs_s3_inotify_monitor_v2.2.0.sh"
readonly INOTIFY_SERVICE_NAME="wp-efs-s3-sync-inotify-v2.2.0" # Nome do serviço versionado
readonly INOTIFY_MONITOR_LOG_FILE="/var/log/wp_efs_s3_inotify_monitor_v2.2.0.log"

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.2.0.log"
S3_SYNC_LOG_FILE="/tmp/s3_sync_v2.2.0.log" # Log específico da função s3_sync (chamada pelo inotify)

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
    "AWS_EFS_ACCESS_POINT_TARGET_ID_0" # Pode ser opcional, mas incluído para verificação
    "AWS_S3_BUCKET_TARGET_NAME_0"    # Para S3 Sync
    # "AWS_CLOUDFRONT_DISTRIBUTION_ID_0" # Opcional
)

# --- Função de Auto-Instalação do Script Principal ---
self_install_script() {
    echo "INFO (self_install): Iniciando auto-instalação do script principal (v2.2.0)..."
    local current_script_path
    current_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    echo "INFO (self_install): Copiando script de '$current_script_path' para $THIS_SCRIPT_TARGET_PATH..."
    if ! cp "$current_script_path" "$THIS_SCRIPT_TARGET_PATH"; then
        echo "ERRO CRÍTICO (self_install): Falha ao copiar script para '$THIS_SCRIPT_TARGET_PATH'. Abortando."
        exit 1
    fi
    chmod +x "$THIS_SCRIPT_TARGET_PATH"
    echo "INFO (self_install): Script principal instalado e tornado executável em $THIS_SCRIPT_TARGET_PATH."
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
    echo "INFO: Criando wp-config.php em '$temp_config_file' para EFS '$target_file_on_efs'..."
    if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "ERRO: '$CONFIG_SAMPLE_ON_EFS' não encontrado."; exit 1; fi
    sudo cp "$CONFIG_SAMPLE_ON_EFS" "$temp_config_file"
    SAFE_DB_NAME=$(echo "$db_name" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g"); SAFE_DB_USER=$(echo "$db_user" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(echo "$db_password" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g"); SAFE_DB_HOST=$(echo "$db_host" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$temp_config_file"; sed -i "s/username_here/$SAFE_DB_USER/g" "$temp_config_file"
    sed -i "s/password_here/$SAFE_DB_PASSWORD/g" "$temp_config_file"; sed -i "s/localhost/$SAFE_DB_HOST/g" "$temp_config_file"
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -n "$SALT" ]; then
        TEMP_SALT_FILE_INNER=$(mktemp /tmp/salts.XXXXXX); sudo chmod 644 "$TEMP_SALT_FILE_INNER"; echo "$SALT" >"$TEMP_SALT_FILE_INNER"
        # shellcheck disable=SC2016
        sed -i -e '/^define( *'\''AUTH_KEY'\''/d' -e '/^define( *'\''SECURE_AUTH_KEY'\''/d' -e '/^define( *'\''LOGGED_IN_KEY'\''/d' -e '/^define( *'\''NONCE_KEY'\''/d' -e '/^define( *'\''AUTH_SALT'\''/d' -e '/^define( *'\''SECURE_AUTH_SALT'\''/d' -e '/^define( *'\''LOGGED_IN_SALT'\''/d' -e '/^define( *'\''NONCE_SALT'\''/d' "$temp_config_file"
        if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE_INNER" "$temp_config_file"; else cat "$TEMP_SALT_FILE_INNER" >>"$temp_config_file"; fi
        rm -f "$TEMP_SALT_FILE_INNER"; echo "INFO: SALTS configurados."
    else echo "ERRO: Falha ao obter SALTS."; fi
    PHP_DEFINES_BLOCK_CONTENT=$(cat <<EOPHP
// Gerado por wordpress_setup_v2.2.0.sh
\$site_scheme = 'https';
\$site_host = '$primary_wpdomain_for_fallback';
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) { \$hosts = explode(',', \$_SERVER['HTTP_X_FORWARDED_HOST']); \$site_host = trim(\$hosts[0]); } elseif (!empty(\$_SERVER['HTTP_HOST'])) { \$site_host = \$_SERVER['HTTP_HOST']; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
define('WP_HOME', \$site_scheme . '://' . \$site_host); define('WP_SITEURL', \$site_scheme . '://' . \$site_host);
define('FS_METHOD', 'direct');
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_SSL']) && \$_SERVER['HTTP_X_FORWARDED_SSL'] == 'on') { \$_SERVER['HTTPS'] = 'on'; }
EOPHP
) # Fim do EOPHP deve estar sozinho na linha
    TEMP_DEFINES_FILE_INNER=$(mktemp /tmp/defines.XXXXXX); sudo chmod 644 "$TEMP_DEFINES_FILE_INNER"; echo -e "\n$PHP_DEFINES_BLOCK_CONTENT" >"$TEMP_DEFINES_FILE_INNER"
    if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE_INNER" "$temp_config_file"; else cat "$TEMP_DEFINES_FILE_INNER" >>"$temp_config_file"; fi
    rm -f "$TEMP_DEFINES_FILE_INNER"; echo "INFO: Defines configurados."
    echo "INFO: Copiando '$temp_config_file' para '$target_file_on_efs' como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp "$temp_config_file" "$target_file_on_efs"; then echo "INFO: Arquivo '$target_file_on_efs' criado."; else echo "ERRO CRÍTICO: Falha ao copiar para '$target_file_on_efs' como '$APACHE_USER'."; exit 1; fi
}

# --- Função: Sincronização de Estáticos para S3 (Chamada pelo Inotify Monitor) ---
sync_static_to_s3() {
    # Redireciona a saída desta função para seu próprio log quando chamada.
    exec >> "${S3_SYNC_LOG_FILE}" 2>&1
    echo "INFO ($(date)): Função sync_static_to_s3 (v2.2.0) iniciada..."

    # As variáveis MOUNT_POINT e AWS_S3_BUCKET_TARGET_NAME_0 devem ser carregadas
    # do ENV_VARS_FILE pelo script que chama esta função (inotify monitor ou este script via s3sync arg)
    local source_dir="$MOUNT_POINT"
    local s3_bucket="$AWS_S3_BUCKET_TARGET_NAME_0"
    local s3_prefix=""

    echo "INFO (sync): Sincronizando de '$source_dir' para 's3://$s3_bucket/$s3_prefix'..."
    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then echo "ERRO (sync): Diretório fonte '$source_dir' inválido." ; return 1; fi
    if [ -z "$s3_bucket" ]; then echo "ERRO (sync): Bucket S3 não definido." ; return 1; fi

    local aws_cli_path; aws_cli_path=$(command -v aws)
    if [ -z "$aws_cli_path" ]; then echo "ERRO (sync): AWS CLI não encontrado."; return 1; fi

    "$aws_cli_path" configure set default.s3.max_concurrent_requests 20
    "$aws_cli_path" configure set default.s3.max_queue_size 10000

    declare -a include_patterns=( "wp-content/uploads/*" "wp-content/themes/*/*.css" "wp-content/themes/*/*.js" "wp-content/themes/*/*.jpg" "wp-content/themes/*/*.jpeg" "wp-content/themes/*/*.png" "wp-content/themes/*/*.gif" "wp-content/themes/*/*.svg" "wp-content/themes/*/*.webp" "wp-content/themes/*/*.ico" "wp-content/themes/*/*.woff" "wp-content/themes/*/*.woff2" "wp-content/themes/*/*.ttf" "wp-content/themes/*/*.eot" "wp-content/themes/*/*.otf" "wp-content/plugins/*/*.css" "wp-content/plugins/*/*.js" "wp-content/plugins/*/*.jpg" "wp-content/plugins/*/*.jpeg" "wp-content/plugins/*/*.png" "wp-content/plugins/*/*.gif" "wp-content/plugins/*/*.svg" "wp-content/plugins/*/*.webp" "wp-content/plugins/*/*.ico" "wp-content/plugins/*/*.woff" "wp-content/plugins/*/*.woff2" "wp-includes/js/*" "wp-includes/css/*" "wp-includes/images/*" )
    local sync_command_args=(); sync_command_args+=("--exclude" "*"); for pattern in "${include_patterns[@]}"; do sync_command_args+=("--include" "$pattern"); done; sync_command_args+=("--delete")

    echo "INFO (sync): Comando: $aws_cli_path s3 sync \"$source_dir\" \"s3://$s3_bucket/$s3_prefix\" ${sync_command_args[*]}"
    if "$aws_cli_path" s3 sync "$source_dir" "s3://$s3_bucket/$s3_prefix" "${sync_command_args[@]}"; then
        echo "INFO (sync): Sincronização S3 OK."
        # if [ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" ]; then "$aws_cli_path" cloudfront create-invalidation --distribution-id "$AWS_CLOUDFRONT_DISTRIBUTION_ID_0" --paths "/*"; fi
    else echo "ERRO (sync): Falha na sincronização S3."; return 1; fi
    echo "INFO ($(date)): Função sync_static_to_s3 concluída."
    return 0
}

# --- Função para Criar o Script de Monitoramento Inotify ---
create_inotify_monitor_script() {
    echo "INFO: Criando script de monitoramento inotify em $INOTIFY_MONITOR_SCRIPT_PATH..."

    # Conteúdo do script de monitoramento
    # As variáveis $THIS_SCRIPT_TARGET_PATH, $ENV_VARS_FILE, $MOUNT_POINT, $INOTIFY_MONITOR_LOG_FILE
    # são expandidas pelo shell aqui ao criar o script.
    cat > "$INOTIFY_MONITOR_SCRIPT_PATH" <<EOF_INOTIFY_SCRIPT
#!/bin/bash
# Script de monitoramento de EFS para S3 Sync usando inotifywait
# Gerado por: $THIS_SCRIPT_TARGET_PATH

readonly WORDPRESS_SETUP_SCRIPT="$THIS_SCRIPT_TARGET_PATH"
readonly MONITOR_DIR_BASE="$MOUNT_POINT" # Base para wp-content
readonly WP_CONTENT_DIR="\$MONITOR_DIR_BASE/wp-content"
readonly LOG_FILE_INOTIFY="$INOTIFY_MONITOR_LOG_FILE"
readonly ENV_VARS_FOR_SETUP_SCRIPT="$ENV_VARS_FILE"

log_inotify_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - INOTIFY_MONITOR - \$1" >> "\$LOG_FILE_INOTIFY"
}

# Debounce: não rodar syncs muito próximos. Tempo em segundos.
readonly SYNC_DEBOUNCE_SECONDS=10
last_sync_time=0

# Carregar variáveis de ambiente necessárias para a função s3sync
if [ -f "\$ENV_VARS_FOR_SETUP_SCRIPT" ]; then
    source "\$ENV_VARS_FOR_SETUP_SCRIPT"
else
    log_inotify_message "ERRO: Arquivo de variáveis de ambiente '\$ENV_VARS_FOR_SETUP_SCRIPT' não encontrado. A função s3sync pode falhar."
fi

if [ ! -d "\$WP_CONTENT_DIR" ]; then
    log_inotify_message "ERRO: Diretório a ser monitorado '\$WP_CONTENT_DIR' não existe. Saindo."
    exit 1
fi

log_inotify_message "INFO: Iniciando monitoramento de '\$WP_CONTENT_DIR' para sincronização com S3."
log_inotify_message "INFO: Script de setup para sync: \$WORDPRESS_SETUP_SCRIPT"

# Loop infinito para monitorar
while true; do
    inotifywait -q -m -r \\
        -e create -e modify -e moved_to -e close_write \\
        --format '%w%f %e' \\
        --exclude '(\\\.swp\$|\\\.swx\$|~$|\\\.part\$|\\\.crdownload\$|cache/)' \\
        "\$WP_CONTENT_DIR" | \\
    while IFS=' ' read -r DETECTED_FILE DETECTED_EVENTS; do
        log_inotify_message "Evento: '\$DETECTED_EVENTS' em '\$DETECTED_FILE'."

        current_time=\$(date +%s)
        if (( current_time - last_sync_time < SYNC_DEBOUNCE_SECONDS )); then
            log_inotify_message "INFO: Debounce ativo. Último sync foi há \$((\$current_time - \$last_sync_time))s. Pulando este trigger."
            continue
        fi

        log_inotify_message "INFO: Disparando sincronização S3..."
        if [ -x "\$WORDPRESS_SETUP_SCRIPT" ]; then
            # O script de monitoramento rodará como root (via systemd),
            # então ele tem permissão para chamar o script principal.
            # A função sync_static_to_s3 dentro do script principal usa o IAM role.
            "\$WORDPRESS_SETUP_SCRIPT" s3sync
            SYNC_EXIT_CODE=\$?

            if [ \$SYNC_EXIT_CODE -eq 0 ]; then
                log_inotify_message "INFO: Sincronização S3 concluída com sucesso."
                last_sync_time=\$(date +%s)
            else
                log_inotify_message "ERRO: Sincronização S3 falhou com código \$SYNC_EXIT_CODE."
            fi
        else
            log_inotify_message "ERRO: Script de setup '\$WORDPRESS_SETUP_SCRIPT' não encontrado ou não é executável."
        fi
    done
    # Se inotifywait sair (raro com -m, mas pode acontecer), logar e reiniciar o loop
    log_inotify_message "AVISO: Loop do inotifywait terminou. Reiniciando em 10s..."
    sleep 10
done
EOF_INOTIFY_SCRIPT
# Fim do Here-Document para o script inotify. O EOF_INOTIFY_SCRIPT DEVE estar sozinho na linha.

    chmod +x "$INOTIFY_MONITOR_SCRIPT_PATH"
    echo "INFO: Script de monitoramento inotify '$INOTIFY_MONITOR_SCRIPT_PATH' criado e tornado executável."
}

# --- Função para Criar e Habilitar o Serviço Systemd para Inotify ---
create_and_enable_inotify_service() {
    echo "INFO: Criando serviço systemd para o monitoramento inotify: $INOTIFY_SERVICE_NAME..."
    local service_file_path="/etc/systemd/system/${INOTIFY_SERVICE_NAME}.service"

    # Conteúdo do arquivo de serviço systemd
    cat > "$service_file_path" <<EOF_SYSTEMD_SERVICE
[Unit]
Description=WordPress EFS to S3 Sync Service using Inotify (v2.2.0)
Documentation=file://$THIS_SCRIPT_TARGET_PATH
After=network.target remote-fs.target mounted-var-www-html.mount # Garantir que EFS esteja montado

[Service]
Type=simple
User=root # O script de monitoramento precisa rodar como root para ler eventos e chamar o sync
ExecStart=$INOTIFY_MONITOR_SCRIPT_PATH
Restart=on-failure
RestartSec=15s
StandardOutput=append:$INOTIFY_MONITOR_LOG_FILE # Redireciona stdout do script para seu log
StandardError=append:$INOTIFY_MONITOR_LOG_FILE  # Redireciona stderr do script para seu log

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD_SERVICE
# Fim do Here-Document para o serviço systemd. O EOF_SYSTEMD_SERVICE DEVE estar sozinho na linha.

    chmod 644 "$service_file_path"
    echo "INFO: Arquivo de serviço '$service_file_path' criado."

    echo "INFO: Recarregando daemon systemd, habilitando e iniciando o serviço $INOTIFY_SERVICE_NAME..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$INOTIFY_SERVICE_NAME.service"
    if sudo systemctl start "$INOTIFY_SERVICE_NAME.service"; then
        echo "INFO: Serviço $INOTIFY_SERVICE_NAME iniciado com sucesso."
        sleep 2 # Dar um tempo para o serviço iniciar e possivelmente logar algo
        sudo systemctl status "$INOTIFY_SERVICE_NAME.service" --no-pager -l
    else
        echo "ERRO: Falha ao iniciar o serviço $INOTIFY_SERVICE_NAME."
        sudo systemctl status "$INOTIFY_SERVICE_NAME.service" --no-pager -l
        echo "ERRO: Verifique os logs do journalctl para $INOTIFY_SERVICE_NAME para mais detalhes: journalctl -u $INOTIFY_SERVICE_NAME -n 50 --no-pager"
        # Não sair com erro fatal aqui, o setup principal pode ter funcionado, mas o sync automático não.
    fi
}


# --- Lógica Principal de Execução ---
# Argumento 's3sync': Chamado pelo script de monitoramento inotify (ou manualmente para teste)
if [ "$1" == "s3sync" ]; then
    # O redirecionamento de log para a função sync_static_to_s3 é feito dentro da própria função agora.
    echo "INFO ($(date)): Chamada 's3sync' recebida por $THIS_SCRIPT_TARGET_PATH (v2.2.0)..." >> "$S3_SYNC_LOG_FILE" # Log inicial da chamada
    if [ -f "$ENV_VARS_FILE" ]; then
        echo "INFO (s3sync): Carregando vars de $ENV_VARS_FILE" >> "$S3_SYNC_LOG_FILE"
        # shellcheck source=/dev/null
        source "$ENV_VARS_FILE"
    else
        echo "WARN (s3sync): $ENV_VARS_FILE não encontrado. Função sync pode falhar." >> "$S3_SYNC_LOG_FILE"
        # Tentar usar MOUNT_POINT padrão se não carregado, como fallback mínimo.
        MOUNT_POINT="${MOUNT_POINT:-/var/www/html}"
        AWS_S3_BUCKET_TARGET_NAME_0="${AWS_S3_BUCKET_TARGET_NAME_0:-}" # Para evitar erro de unbound variable
    fi
    sync_static_to_s3
    exit $?
fi

# --- Continuação do Script Principal de Setup (executado uma vez via UserData) ---
# O UserData já deve ter carregado as variáveis do /home/ec2-user/.env
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.2.0) ($(date)) ---"
echo "INFO: Script target: $THIS_SCRIPT_TARGET_PATH. Log: ${LOG_FILE}"
echo "INFO: =================================================="
if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execução inicial deve ser como root."; exit 1; fi

self_install_script # Instala este script principal no local de destino

echo "INFO: Verificando e imprimindo variáveis de ambiente essenciais (devem ter sido exportadas pelo UserData)..."
if [ -z "${ACCOUNT:-}" ]; then
    ACCOUNT_STS=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -n "$ACCOUNT_STS" ]; then ACCOUNT="$ACCOUNT_STS"; echo "INFO: ACCOUNT ID obtido via AWS STS: $ACCOUNT"; else echo "WARN: Falha ao obter ACCOUNT ID via AWS STS."; ACCOUNT=""; fi
fi
AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ]&&[ -n "${ACCOUNT:-}" ]&&[ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
fi

error_found=0
echo "INFO: --- VALORES DAS VARIÁVEIS ESSENCIAIS ---"
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-UNDEFINED}" # Pega o valor ou "UNDEFINED"
    # Tratar ARN do SecretsManager, que é construído
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        # O valor real a ser verificado é o ARN construído
        current_var_value_to_check="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
        var_name_for_check="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (construído de $var_name)"
    else
        current_var_value_to_check="${!var_name:-}"
        var_name_for_check="$var_name"
    fi

    # Imprimir o valor
    echo "INFO: Var: $var_name_for_check = '$current_var_value_to_check'"

    # Verificar se está vazia (exceto para AWS_EFS_ACCESS_POINT_TARGET_ID_0 que é opcional)
    if [ "$var_name" != "AWS_EFS_ACCESS_POINT_TARGET_ID_0" ] && [ -z "$current_var_value_to_check" ]; then
        echo "ERRO: Variável essencial '$var_name_for_check' não definida ou vazia."
        error_found=1
    fi
done
echo "INFO: --- FIM DOS VALORES DAS VARIÁVEIS ESSENCIAIS ---"
if [ "$error_found" -eq 1 ]; then echo "ERRO CRÍTICO: Uma ou mais variáveis essenciais estão faltando. Abortando setup."; exit 1; fi
echo "INFO: Verificação de variáveis essenciais concluída."


echo "INFO: Instalando pacotes (incluindo inotify-tools)..."
sudo yum update -y -q; sudo amazon-linux-extras install -y epel -q;
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils inotify-tools # Adicionado inotify-tools
sudo amazon-linux-extras enable php7.4 -y -q; sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache
echo "INFO: Pacotes instalados."

mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

echo "INFO: Testando escrita EFS como '$EFS_OWNER_USER'..."
TEMP_EFS_TEST_FILE="$MOUNT_POINT/efs_write_test_$(date +%s).txt"
if sudo -u "$EFS_OWNER_USER" touch "$TEMP_EFS_TEST_FILE"; then echo "INFO: Teste escrita EFS OK."; sudo -u "$EFS_OWNER_USER" rm "$TEMP_EFS_TEST_FILE"; else echo "ERRO: Teste escrita EFS FALHOU."; ls -ld "$MOUNT_POINT"; exit 1; fi

echo "INFO: Obtendo creds RDS..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then echo "ERRO: Falha obter segredo RDS."; exit 1; fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username); DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
if [ -z "$DB_USER" ]||[ "$DB_USER" == "null" ]||[ -z "$DB_PASSWORD" ]||[ "$DB_PASSWORD" == "null" ]; then echo "ERRO: Falha extrair user/pass RDS."; exit 1; fi
DB_NAME_TO_USE="$AWS_DB_INSTANCE_TARGET_NAME_0"
echo "INFO (DB Setup): Nome do DB será: '$DB_NAME_TO_USE' (de AWS_DB_INSTANCE_TARGET_NAME_0)"
echo "DEBUG (DB Setup): Verificando AWS_DB_INSTANCE_TARGET_NAME_0 no ambiente: '$AWS_DB_INSTANCE_TARGET_NAME_0'"
if [ "$DB_NAME_TO_USE" == "null" ] || [ -z "$DB_NAME_TO_USE" ]; then echo "ERRO CRÍTICO: Nome DB não determinado de AWS_DB_INSTANCE_TARGET_NAME_0 ('$AWS_DB_INSTANCE_TARGET_NAME_0')."; exit 1; fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
echo "INFO: Creds RDS OK (User: $DB_USER, DB: $DB_NAME_TO_USE)."

echo "INFO: Verificando WP em '$MOUNT_POINT/wp-includes'..."
if [ -d "$MOUNT_POINT/wp-includes" ]&&[ -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "WARN: WP já existe."; else
    echo "INFO: WP não encontrado. Baixando..."; sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"; sudo mkdir -p "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"; sudo chown "$(id -u):$(id -g)" "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    cd "$WP_DOWNLOAD_DIR"; curl -sLO https://wordpress.org/latest.tar.gz || { echo "ERRO: Falha download WP."; exit 1; }; tar -xzf latest.tar.gz -C "$WP_FINAL_CONTENT_DIR" --strip-components=1 || { echo "ERRO: Falha extração WP."; exit 1; }; rm latest.tar.gz
    echo "INFO: WP baixado e extraído. Copiando para EFS como '$EFS_OWNER_USER'..."
    if sudo -u "$EFS_OWNER_USER" cp -aT "$WP_FINAL_CONTENT_DIR/" "$MOUNT_POINT/"; then echo "INFO: WP copiado para EFS."; else echo "ERRO: Falha copiar WP para EFS."; ls -ld "$MOUNT_POINT"; exit 1; fi
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"; echo "INFO: Limpeza WP temps OK."
fi

echo "INFO: Salvando vars para s3sync em '$ENV_VARS_FILE'..."
ENV_VARS_FILE_CONTENT="#!/bin/bash\n# Vars para $THIS_SCRIPT_TARGET_PATH s3sync (v2.2.0)\n"
for var_name in "${essential_vars[@]}"; do if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then current_var_value_escaped=$(printf '%q' "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"); ENV_VARS_FILE_CONTENT+="export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=$current_var_value_escaped\n"; else current_var_value_escaped=$(printf '%q' "${!var_name}"); ENV_VARS_FILE_CONTENT+="export $var_name=$current_var_value_escaped\n"; fi; done
ENV_VARS_FILE_CONTENT+="export MOUNT_POINT=$(printf '%q' "$MOUNT_POINT")\n"; ENV_VARS_FILE_CONTENT+="export APACHE_USER=$(printf '%q' "$APACHE_USER")\n" # APACHE_USER não é essencial aqui, mas ok
if [ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" ]; then ENV_VARS_FILE_CONTENT+="export AWS_CLOUDFRONT_DISTRIBUTION_ID_0=$(printf '%q' "$AWS_CLOUDFRONT_DISTRIBUTION_ID_0")\n"; fi
echo -e "$ENV_VARS_FILE_CONTENT" | sudo tee "$ENV_VARS_FILE" > /dev/null; sudo chmod 644 "$ENV_VARS_FILE"; echo "INFO: Vars salvas."

if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "ERRO: $CONFIG_SAMPLE_ON_EFS não encontrado."; exit 1; fi
if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then echo "INFO: '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando..."; create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"; else echo "WARN: '$ACTIVE_CONFIG_FILE_EFS' já existe."; fi

# REMOVIDA a chamada para create_s3_sync_mu_plugin

echo "INFO: Criando health check '$HEALTH_CHECK_FILE_PATH_EFS'..."
HEALTH_CHECK_CONTENT="<?php http_response_code(200); header('Content-Type: text/plain; charset=utf-8'); echo 'OK - WP Health Check - v2.2.0 - '.date('Y-m-d\TH:i:s\Z'); exit; ?>"
TEMP_HEALTH_CHECK_FILE=$(mktemp /tmp/healthcheck.XXXXXX.php); sudo chmod 644 "$TEMP_HEALTH_CHECK_FILE"; echo "$HEALTH_CHECK_CONTENT" >"$TEMP_HEALTH_CHECK_FILE"
if sudo -u "$APACHE_USER" cp "$TEMP_HEALTH_CHECK_FILE" "$HEALTH_CHECK_FILE_PATH_EFS"; then echo "INFO: Health check criado."; else echo "ERRO: Falha criar health check."; fi; rm -f "$TEMP_HEALTH_CHECK_FILE"

echo "INFO: Ajustando permissões finais em '$MOUNT_POINT' para '$APACHE_USER'..."
if ! sudo chown -R "$APACHE_USER":"$APACHE_USER" "$MOUNT_POINT"; then echo "AVISO: Falha no chown -R. Verifique config EFS AP. GID atual: $(stat -c "%g" "$MOUNT_POINT") vs Apache GID: $(getent group "$APACHE_USER" | cut -d: -f3)"; ls -ld "$MOUNT_POINT"; fi
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \; ; sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
if [ -f "$ACTIVE_CONFIG_FILE_EFS" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE_EFS"; fi; if [ -f "$HEALTH_CHECK_FILE_PATH_EFS" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH_EFS"; fi; echo "INFO: Permissões ajustadas."

echo "INFO: Configurando Apache..."
HTTPD_WP_CONF="/etc/httpd/conf.d/wordpress_v2.2.0.conf"
if [ ! -f "$HTTPD_WP_CONF" ]; then echo "INFO: Criando $HTTPD_WP_CONF"; sudo tee "$HTTPD_WP_CONF" >/dev/null <<EOF_APACHE_CONF
<Directory "${MOUNT_POINT}">
    AllowOverride All
    Require all granted
</Directory>
<IfModule mod_setenvif.c>
  SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on
</IfModule>
EOF_APACHE_CONF
else
    echo "INFO: $HTTPD_WP_CONF já existe. Verificando conteúdo..."
    if ! grep -q "AllowOverride All" "$HTTPD_WP_CONF"; then sudo sed -i '/<Directory "${MOUNT_POINT//\//\\/}">/a \    AllowOverride All' "$HTTPD_WP_CONF"; echo "INFO: AllowOverride All adicionado a $HTTPD_WP_CONF."; fi
    if ! grep -q "SetEnvIf X-Forwarded-Proto" "$HTTPD_WP_CONF"; then echo -e "\n<IfModule mod_setenvif.c>\n  SetEnvIf X-Forwarded-Proto \"^https\$\" HTTPS=on\n</IfModule>" | sudo tee -a "$HTTPD_WP_CONF" > /dev/null; echo "INFO: SetEnvIf X-Forwarded-Proto adicionado a $HTTPD_WP_CONF."; fi
fi
echo "INFO: Configuração Apache em $HTTPD_WP_CONF verificada/criada."

echo "INFO: Habilitando e reiniciando httpd e php-fpm..."
sudo systemctl enable httpd; sudo systemctl enable php-fpm
if ! sudo systemctl restart php-fpm; then echo "ERRO: Falha reiniciar php-fpm."; sudo systemctl status php-fpm -l --no-pager; fi
if ! sudo systemctl restart httpd; then echo "ERRO: Falha reiniciar httpd."; sudo apachectl configtest; sudo tail -n 50 /var/log/httpd/error_log; exit 1; fi
sleep 3; if systemctl is-active --quiet httpd && systemctl is-active --quiet php-fpm; then echo "INFO: httpd e php-fpm ativos."; else echo "ERRO: httpd ou php-fpm não ativos."; exit 1; fi

# --- Configuração do Monitoramento Inotify ---
create_inotify_monitor_script
create_and_enable_inotify_service

echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v2.2.0) concluído! ($(date)) ---"
echo "INFO: Sincronização com S3 agora é feita via Inotify."
echo "INFO: Script de monitoramento Inotify: $INOTIFY_MONITOR_SCRIPT_PATH"
echo "INFO: Serviço Inotify: $INOTIFY_SERVICE_NAME (Log: $INOTIFY_MONITOR_LOG_FILE)"
echo "INFO: Logs: Principal=${LOG_FILE}, S3Sync (chamado por Inotify)=${S3_SYNC_LOG_FILE}"
echo "INFO: Site: https://${WPDOMAIN}, Health Check: /healthcheck.php"
echo "INFO: LEMBRE-SE de configurar o EFS Access Point com uid=48 e gid=48."
echo "INFO: =================================================="
exit 0
