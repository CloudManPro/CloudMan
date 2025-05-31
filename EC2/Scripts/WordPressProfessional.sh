#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.2.2-zero-touch-s3-inotify-selective-root-log (Monitors root, Selective S3 Sync, Transfer Log)

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.2.2.sh"
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.2.2_env_vars.sh"

# Script de Monitoramento Inotify e Serviço
readonly INOTIFY_MONITOR_SCRIPT_PATH="/usr/local/bin/wp_efs_s3_inotify_monitor_v2.2.2.sh"
readonly INOTIFY_SERVICE_NAME="wp-efs-s3-sync-inotify-v2.2.2"
readonly INOTIFY_MONITOR_LOG_FILE="/var/log/wp_efs_s3_inotify_monitor_v2.2.2.log"
readonly S3_TRANSFER_LOG_FILE="/var/log/wp_s3_transferred_files_v2.2.2.log" # Novo log para arquivos transferidos

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.2.2.log" # Log deste script principal

MOUNT_POINT="/var/www/html" # Raiz do WordPress, será monitorada pelo inotify
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
    # "AWS_CLOUDFRONT_DISTRIBUTION_ID_0"
)

# --- Função de Auto-Instalação do Script Principal ---
self_install_script() {
    echo "INFO (self_install): Iniciando auto-instalação do script principal (v2.2.2)..."
    local current_script_path; current_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    echo "INFO (self_install): Copiando script de '$current_script_path' para $THIS_SCRIPT_TARGET_PATH..."
    if ! cp "$current_script_path" "$THIS_SCRIPT_TARGET_PATH"; then echo "ERRO CRÍTICO (self_install): Falha ao copiar script. Abortando."; exit 1; fi
    chmod +x "$THIS_SCRIPT_TARGET_PATH"
    echo "INFO (self_install): Script principal instalado e executável em $THIS_SCRIPT_TARGET_PATH."
}

# --- Funções Auxiliares (mount_efs, create_wp_config_template - idênticas à v2.2.0) ---
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
// Gerado por wordpress_setup_v2.2.2.sh
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

# --- Função para Criar o Script de Monitoramento Inotify (CORRIGIDA) ---
create_inotify_monitor_script() {
    echo "INFO: Criando script de monitoramento inotify seletivo em $INOTIFY_MONITOR_SCRIPT_PATH (v2.2.2 - correção sintaxe while)..."

    # ... (printf para safe_... variáveis como antes) ...
    local safe_monitor_dir_base; printf -v safe_monitor_dir_base "%q" "$MOUNT_POINT"
    local safe_inotify_log_file; printf -v safe_inotify_log_file "%q" "$INOTIFY_MONITOR_LOG_FILE"
    local safe_s3_transfer_log_file; printf -v safe_s3_transfer_log_file "%q" "$S3_TRANSFER_LOG_FILE"
    local safe_env_vars_file; printf -v safe_env_vars_file "%q" "$ENV_VARS_FILE"
    local safe_s3_bucket; printf -v safe_s3_bucket "%q" "$AWS_S3_BUCKET_TARGET_NAME_0"

    # Construir a string de RELEVANT_PATTERNS (como antes)
    local relevant_patterns_string="RELEVANT_PATTERNS=(\n"
    relevant_patterns_string+="    \"wp-content/uploads/*\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.css\"\n" # etc... (adicione todos os seus patterns)
    relevant_patterns_string+="    \"wp-content/themes/*/*.js\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.jpg\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.jpeg\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.png\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.gif\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.svg\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.webp\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.ico\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.woff\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.woff2\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.ttf\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.eot\"\n"
    relevant_patterns_string+="    \"wp-content/themes/*/*.otf\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.css\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.js\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.jpg\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.jpeg\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.png\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.gif\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.svg\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.webp\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.ico\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.woff\"\n"
    relevant_patterns_string+="    \"wp-content/plugins/*/*.woff2\"\n"
    relevant_patterns_string+="    \"wp-includes/js/*\"\n"
    relevant_patterns_string+="    \"wp-includes/css/*\"\n"
    relevant_patterns_string+="    \"wp-includes/images/*\"\n"
    relevant_patterns_string+=")"


    # Template do script de monitoramento
    local inotify_script_content
    inotify_script_content=$(cat <<EOF_INOTIFY_TEMPLATE_CONTENT
#!/bin/bash
# Script de monitoramento de EFS para S3 Sync usando inotifywait (Seletivo v2.2.2 - correção sintaxe)
# Gerado por: $THIS_SCRIPT_TARGET_PATH

# Valores injetados pelo script de setup:
readonly MONITOR_DIR_BASE=$safe_monitor_dir_base
readonly LOG_FILE_INOTIFY=$safe_inotify_log_file
readonly S3_TRANSFER_LOG_FILE=$safe_s3_transfer_log_file
readonly ENV_VARS_FOR_SETUP_SCRIPT=$safe_env_vars_file
readonly S3_BUCKET_TARGET_NAME_0=$safe_s3_bucket

log_inotify_message() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - INOTIFY_MONITOR - \$1" >> "\$LOG_FILE_INOTIFY"
}

log_s3_transfer() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - S3_TRANSFER - \$1" >> "\$S3_TRANSFER_LOG_FILE"
}

readonly SYNC_DEBOUNCE_SECONDS=3
declare -A last_sync_file_map

if [ -f "\$ENV_VARS_FOR_SETUP_SCRIPT" ]; then source "\$ENV_VARS_FOR_SETUP_SCRIPT"; fi
if [ ! -d "\$MONITOR_DIR_BASE" ]; then log_inotify_message "ERRO: Diretório base '\$MONITOR_DIR_BASE' não existe."; exit 1; fi
if [ -z "\$S3_BUCKET_TARGET_NAME_0" ]; then log_inotify_message "ERRO: S3_BUCKET_TARGET_NAME_0 não definido."; exit 1; fi

log_inotify_message "INFO: Iniciando monitoramento de '\$MONITOR_DIR_BASE' para S3 sync seletivo."
touch "\$LOG_FILE_INOTIFY" "\$S3_TRANSFER_LOG_FILE"; chmod 644 "\$LOG_FILE_INOTIFY" "\$S3_TRANSFER_LOG_FILE"

$relevant_patterns_string

aws_cli_path=\$(command -v aws)
if [ -z "\$aws_cli_path" ]; then log_inotify_message "ERRO: AWS CLI não encontrado."; exit 1; fi

while true; do
    inotifywait -q -m -r \\
        -e create -e modify -e moved_to -e close_write \\
        --format '%w%f %e' \\
        --exclude '(\\.swp\$|\\.swx\$|~$|\\.part\$|\\.crdownload\$|cache/|\\.git/|node_modules/|uploads/sites/)' \\
        "\$MONITOR_DIR_BASE" | # <-- REMOVIDA A BARRA INVERTIDA DAQUI
    while IFS=' ' read -r DETECTED_ABSOLUTE_FILE DETECTED_EVENTS; do # Esta linha é a continuação lógica do pipe
        if [ -d "\$DETECTED_ABSOLUTE_FILE" ]; then continue; fi

        log_inotify_message "Evento: '\$DETECTED_EVENTS' em '\$DETECTED_ABSOLUTE_FILE'."
        RELATIVE_FILE_PATH="\${DETECTED_ABSOLUTE_FILE#\$MONITOR_DIR_BASE/}"

        file_is_relevant=false
        for pattern in "\${RELEVANT_PATTERNS[@]}"; do
            if [[ "\$RELATIVE_FILE_PATH" == \$pattern ]]; then
                file_is_relevant=true
                log_inotify_message "INFO: Arquivo '\$RELATIVE_FILE_PATH' corresponde ao pattern '\$pattern'."
                break
            fi
        done
        
        if ! \$file_is_relevant && [[ "\$RELATIVE_FILE_PATH" == wp-content/uploads/* ]]; then
            file_is_relevant=true
            log_inotify_message "INFO: Arquivo '\$RELATIVE_FILE_PATH' (upload) considerado relevante por fallback."
        fi

        if ! \$file_is_relevant; then
            log_inotify_message "INFO: Arquivo '\$RELATIVE_FILE_PATH' não relevante. Ignorando."
            continue
        fi

        log_inotify_message "INFO: Arquivo relevante '\$RELATIVE_FILE_PATH' modificado. Preparando para S3."

        current_time=\$(date +%s)
        if [ -n "\${last_sync_file_map[\$DETECTED_ABSOLUTE_FILE]:-}" ] && \\
           (( current_time - last_sync_file_map[\$DETECTED_ABSOLUTE_FILE] < SYNC_DEBOUNCE_SECONDS )); then
            log_inotify_message "INFO: Debounce ativo para '\$DETECTED_ABSOLUTE_FILE'. Pulando."
            continue
        fi

        S3_DEST_PATH="s3://\$S3_BUCKET_TARGET_NAME_0/\$RELATIVE_FILE_PATH"
        log_inotify_message "INFO: Copiando '\$DETECTED_ABSOLUTE_FILE' para '\$S3_DEST_PATH'..."

        if "\$aws_cli_path" s3 cp "\$DETECTED_ABSOLUTE_FILE" "\$S3_DEST_PATH" --acl private --only-show-errors; then
            log_inotify_message "INFO: Cópia S3 OK para '\$RELATIVE_FILE_PATH'."
            log_s3_transfer "TRANSFERRED: \$RELATIVE_FILE_PATH"
            last_sync_file_map["\$DETECTED_ABSOLUTE_FILE"]=\$(date +%s)
        else
            log_inotify_message "ERRO: Falha ao copiar '\$RELATIVE_FILE_PATH' para S3."
        fi
    done
    log_inotify_message "AVISO: Loop inotifywait terminou. Reiniciando em 10s..."
    sleep 10
done
EOF_INOTIFY_TEMPLATE_CONTENT
)

    echo "$inotify_script_content" > "$INOTIFY_MONITOR_SCRIPT_PATH"
    chmod +x "$INOTIFY_MONITOR_SCRIPT_PATH"
    echo "INFO: Script de monitoramento inotify '$INOTIFY_MONITOR_SCRIPT_PATH' criado e tornado executável (com correção de sintaxe)."
}


# --- Função para Criar e Habilitar o Serviço Systemd para Inotify (MODIFICADA) ---
create_and_enable_inotify_service() {
    echo "INFO: Criando serviço systemd para o monitoramento inotify: $INOTIFY_SERVICE_NAME (v2.2.2)..."
    local service_file_path="/etc/systemd/system/${INOTIFY_SERVICE_NAME}.service"

    # Garantir que o MOUNT_POINT seja uma dependência explícita para a montagem do EFS
    # O nome do unit da montagem systemd geralmente é baseado no caminho,
    # substituindo '/' por '-' e prefixando com o tipo de montagem, e.g., var-www-html.mount
    # Para EFS, pode ser mais complexo se não estiver no fstab ou se o systemd não o gerenciar automaticamente.
    # Usar remote-fs.target é um bom começo. Adicionar um `RequiresMountsFor=` se souber o caminho exato do systemd.
    # Para um ponto de montagem como /var/www/html, a unidade systemd gerada pelo fstab seria var-www-html.mount
    local mount_unit_name
    mount_unit_name=$(systemd-escape -p --suffix=mount "$MOUNT_POINT") # Gera o nome da unidade de montagem

    # Conteúdo do arquivo de serviço systemd
    # Usar printf para escapar valores que vão para o template
    local safe_inotify_script_path; printf -v safe_inotify_script_path "%q" "$INOTIFY_MONITOR_SCRIPT_PATH"
    local safe_inotify_log_file; printf -v safe_inotify_log_file "%q" "$INOTIFY_MONITOR_LOG_FILE"

    # Usamos um template para o arquivo de serviço para evitar problemas com expansão de variáveis no here-doc
    local systemd_service_content
    systemd_service_content=$(cat <<EOF_SYSTEMD_SERVICE_TEMPLATE
[Unit]
Description=WordPress EFS to S3 Selective Sync Service (v2.2.2)
Documentation=file://$THIS_SCRIPT_TARGET_PATH
After=network.target remote-fs.target $mount_unit_name
Requires=$mount_unit_name # Garante que o EFS esteja montado

[Service]
Type=simple
User=root
ExecStart=$safe_inotify_script_path
Restart=on-failure
RestartSec=15s
StandardOutput=append:$safe_inotify_log_file
StandardError=append:$safe_inotify_log_file

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD_SERVICE_TEMPLATE
) # Fim do here-doc do template

    echo "$systemd_service_content" | sudo tee "$service_file_path" > /dev/null
    chmod 644 "$service_file_path"
    echo "INFO: Arquivo de serviço '$service_file_path' criado."

    echo "INFO: Recarregando daemon systemd, habilitando e iniciando o serviço $INOTIFY_SERVICE_NAME..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$INOTIFY_SERVICE_NAME.service"
    if sudo systemctl start "$INOTIFY_SERVICE_NAME.service"; then
        echo "INFO: Serviço $INOTIFY_SERVICE_NAME iniciado com sucesso."
        sleep 2
        sudo systemctl status "$INOTIFY_SERVICE_NAME.service" --no-pager -l
    else
        echo "ERRO: Falha ao iniciar o serviço $INOTIFY_SERVICE_NAME."
        sudo systemctl status "$INOTIFY_SERVICE_NAME.service" --no-pager -l
        journalctl -u "$INOTIFY_SERVICE_NAME" -n 50 --no-pager
    fi
}

# --- Lógica Principal de Execução ---
# REMOVIDO o bloco if [ "$1" == "s3sync" ], pois não há mais uma função s3sync a ser chamada externamente por este script.
# O script de monitoramento inotify agora lida com o `aws s3 cp`.

# --- Continuação do Script Principal de Setup ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.2.2) ($(date)) ---"
echo "INFO: Script target: $THIS_SCRIPT_TARGET_PATH. Log: ${LOG_FILE}"
echo "INFO: =================================================="
if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execução inicial deve ser como root."; exit 1; fi

self_install_script # Apenas instala este script principal

echo "INFO: Verificando e imprimindo variáveis de ambiente essenciais..."
# (Bloco de verificação de variáveis, incluindo impressão dos valores - como na v2.2.0)
if [ -z "${ACCOUNT:-}" ]; then ACCOUNT_STS=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); if [ -n "$ACCOUNT_STS" ]; then ACCOUNT="$ACCOUNT_STS"; echo "INFO: ACCOUNT ID obtido via STS: $ACCOUNT"; else echo "WARN: Falha obter ACCOUNT ID via STS."; ACCOUNT=""; fi; fi
AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""; if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ]&&[ -n "${ACCOUNT:-}" ]&&[ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"; fi
error_found=0; echo "INFO: --- VALORES DAS VARIÁVEIS ESSENCIAIS ---"
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-UNDEFINED}"; var_name_for_check="$var_name"; current_var_value_to_check="${!var_name:-}"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then current_var_value_to_check="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"; var_name_for_check="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (de $var_name)"; fi
    echo "INFO: Var: $var_name_for_check = '$current_var_value_to_check'"
    if [ "$var_name" != "AWS_EFS_ACCESS_POINT_TARGET_ID_0" ] && [ -z "$current_var_value_to_check" ]; then echo "ERRO: Var essencial '$var_name_for_check' vazia."; error_found=1; fi
done; echo "INFO: --- FIM DOS VALORES DAS VARIÁVEIS ---"
if [ "$error_found" -eq 1 ]; then echo "ERRO CRÍTICO: Variáveis essenciais faltando. Abortando."; exit 1; fi
echo "INFO: Verificação de variáveis concluída."


echo "INFO: Instalando pacotes (incluindo inotify-tools)..."
sudo yum update -y -q; sudo amazon-linux-extras install -y epel -q;
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils inotify-tools
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

# Salvar variáveis de ambiente para o script Inotify usar, se necessário (embora ele receba muitas via template)
echo "INFO: Salvando vars para script inotify em '$ENV_VARS_FILE' (pode ser redundante)..."
ENV_VARS_FILE_CONTENT="#!/bin/bash\n# Vars para $INOTIFY_MONITOR_SCRIPT_PATH (v2.2.2)\n"
# Apenas algumas chaves que o inotify script poderia precisar diretamente se não fossem injetadas
ENV_VARS_FILE_CONTENT+="export MOUNT_POINT=$(printf '%q' "$MOUNT_POINT")\n"
ENV_VARS_FILE_CONTENT+="export AWS_S3_BUCKET_TARGET_NAME_0=$(printf '%q' "$AWS_S3_BUCKET_TARGET_NAME_0")\n"
# if [ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" ]; then ENV_VARS_FILE_CONTENT+="export AWS_CLOUDFRONT_DISTRIBUTION_ID_0=$(printf '%q' "$AWS_CLOUDFRONT_DISTRIBUTION_ID_0")\n"; fi
echo -e "$ENV_VARS_FILE_CONTENT" | sudo tee "$ENV_VARS_FILE" > /dev/null; sudo chmod 644 "$ENV_VARS_FILE"; echo "INFO: Vars salvas em $ENV_VARS_FILE."

if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "ERRO: $CONFIG_SAMPLE_ON_EFS não encontrado."; exit 1; fi
if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then echo "INFO: '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando..."; create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"; else echo "WARN: '$ACTIVE_CONFIG_FILE_EFS' já existe."; fi

echo "INFO: Criando health check '$HEALTH_CHECK_FILE_PATH_EFS'..."
HEALTH_CHECK_CONTENT="<?php http_response_code(200); header('Content-Type: text/plain; charset=utf-8'); echo 'OK - WP Health Check - v2.2.2 - '.date('Y-m-d\TH:i:s\Z'); exit; ?>"
TEMP_HEALTH_CHECK_FILE=$(mktemp /tmp/healthcheck.XXXXXX.php); sudo chmod 644 "$TEMP_HEALTH_CHECK_FILE"; echo "$HEALTH_CHECK_CONTENT" >"$TEMP_HEALTH_CHECK_FILE"
if sudo -u "$APACHE_USER" cp "$TEMP_HEALTH_CHECK_FILE" "$HEALTH_CHECK_FILE_PATH_EFS"; then echo "INFO: Health check criado."; else echo "ERRO: Falha criar health check."; fi; rm -f "$TEMP_HEALTH_CHECK_FILE"

echo "INFO: Ajustando permissões finais em '$MOUNT_POINT' para '$APACHE_USER'..."
if ! sudo chown -R "$APACHE_USER":"$APACHE_USER" "$MOUNT_POINT"; then echo "AVISO: Falha no chown -R. Verifique config EFS AP. GID atual: $(stat -c "%g" "$MOUNT_POINT") vs Apache GID: $(getent group "$APACHE_USER" | cut -d: -f3)"; ls -ld "$MOUNT_POINT"; fi
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \; ; sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
if [ -f "$ACTIVE_CONFIG_FILE_EFS" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE_EFS"; fi; if [ -f "$HEALTH_CHECK_FILE_PATH_EFS" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH_EFS"; fi; echo "INFO: Permissões ajustadas."

echo "INFO: Configurando Apache..."
HTTPD_WP_CONF="/etc/httpd/conf.d/wordpress_v2.2.2.conf"
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
echo "INFO: --- Script WordPress Setup (v2.2.2) concluído! ($(date)) ---"
echo "INFO: Sincronização com S3 agora é via Inotify (monitorando $MOUNT_POINT)."
echo "INFO: Script de monitoramento: $INOTIFY_MONITOR_SCRIPT_PATH"
echo "INFO: Serviço Inotify: $INOTIFY_SERVICE_NAME (Log do monitor: $INOTIFY_MONITOR_LOG_FILE, Log de transferências: $S3_TRANSFER_LOG_FILE)"
echo "INFO: Logs: Principal=${LOG_FILE}"
echo "INFO: Site: https://${WPDOMAIN}, Health Check: /healthcheck.php"
echo "INFO: LEMBRE-SE de configurar o EFS Access Point com uid=48 e gid=48."
echo "INFO: =================================================="
exit 0
