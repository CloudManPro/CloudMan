#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.3.4-s3-hook-deleter (Adiciona instalação do s3-hook-deleter.php)

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.3.4.sh"
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.3.4_env_vars.sh"

# Script de Monitoramento Python e Serviço
readonly PYTHON_MONITOR_SCRIPT_NAME="efs_s3_monitor_v2.3.3.py"
readonly PYTHON_MONITOR_SCRIPT_PATH="/usr/local/bin/$PYTHON_MONITOR_SCRIPT_NAME"
readonly PYTHON_MONITOR_SERVICE_NAME="wp-efs-s3-pywatchdog-v2.3.4"
readonly PY_MONITOR_LOG_FILE="/var/log/wp_efs_s3_py_monitor_v2.3.4.log"
readonly PY_S3_TRANSFER_LOG_FILE="/var/log/wp_s3_py_transferred_v2.3.4.log"

# Chave S3 para o script Python
readonly AWS_S3_PYTHON_SCRIPT_KEY="efs_s3_monitor.py"

# NOVO: Configuração para o S3 Hook Deleter PHP
readonly S3_HOOK_DELETER_PHP_FILENAME="s3-hook-deleter.php"
# Assume que S3_HOOK_DELETER_PHP_FILENAME está no mesmo diretório que este script de instalação

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.3.4.log"
MOUNT_POINT="/var/www/html"
WP_DOWNLOAD_DIR="/tmp/wp_download_temp"
WP_FINAL_CONTENT_DIR="/tmp/wp_final_efs_content"
ACTIVE_CONFIG_FILE_EFS="$MOUNT_POINT/wp-config.php"
CONFIG_SAMPLE_ON_EFS="$MOUNT_POINT/wp-config-sample.php"
HEALTH_CHECK_FILE_PATH_EFS="$MOUNT_POINT/healthcheck.php"
MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
EFS_OWNER_UID=1000 # Geralmente ec2-user ou o usuário que faz o setup inicial
EFS_OWNER_USER="ec2-user" # Ou o usuário que possui os arquivos no EFS antes do Apache

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
    "AWS_S3_BUCKET_TARGET_NAME_0" # Bucket S3 principal para uploads do WP
    "AWS_S3_BUCKET_TARGET_NAME_SCRIPT" # Bucket S3 para scripts administrativos (como o Python)
    "AWS_S3_BUCKET_TARGET_REGION_SCRIPT" # Região do bucket de scripts
    # AWS_CLOUDFRONT_DISTRIBUTION_ID_0 é opcional, usado pelo script Python
)

# --- Função de Auto-Instalação do Script Principal ---
self_install_script() {
    echo "INFO (self_install): Iniciando auto-instalação do script principal (v2.3.4)..."
    local current_script_path; current_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    echo "INFO (self_install): Copiando script de '$current_script_path' para $THIS_SCRIPT_TARGET_PATH..."
    if ! sudo cp "$current_script_path" "$THIS_SCRIPT_TARGET_PATH"; then echo "ERRO CRÍTICO (self_install): Falha ao copiar script. Abortando."; exit 1; fi
    sudo chmod +x "$THIS_SCRIPT_TARGET_PATH"
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
// Gerado por wordpress_setup_v2.3.4.sh
\$site_scheme = 'https';
\$site_host = '$primary_wpdomain_for_fallback';
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) { \$hosts = explode(',', \$_SERVER['HTTP_X_FORWARDED_HOST']); \$site_host = trim(\$hosts[0]); } elseif (!empty(\$_SERVER['HTTP_HOST'])) { \$site_host = \$_SERVER['HTTP_HOST']; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
define('WP_HOME', \$site_scheme . '://' . \$site_host); define('WP_SITEURL', \$site_scheme . '://' . \$site_host);
define('FS_METHOD', 'direct');
// Adiciona constantes para o S3 Hook Deleter (melhor definir em wp-config.php via script)
define('MEU_S3_BUCKET_NAME', '${AWS_S3_BUCKET_TARGET_NAME_0}'); // Usa a variável do bucket principal
define('MEU_S3_REGION', '$(aws configure get region)'); // Tenta obter a região da config do AWS CLI
define('MEU_S3_BASE_PATH_IN_BUCKET', 'wp-content/uploads/');

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') { \$_SERVER['HTTPS'] = 'on'; }
if (isset(\$_SERVER['HTTP_X_FORWARDED_SSL']) && \$_SERVER['HTTP_X_FORWARDED_SSL'] == 'on') { \$_SERVER['HTTPS'] = 'on'; }
EOPHP
)
    TEMP_DEFINES_FILE_INNER=$(mktemp /tmp/defines.XXXXXX); sudo chmod 644 "$TEMP_DEFINES_FILE_INNER"; echo -e "\n$PHP_DEFINES_BLOCK_CONTENT" >"$TEMP_DEFINES_FILE_INNER"
    if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE_INNER" "$temp_config_file"; else cat "$TEMP_DEFINES_FILE_INNER" >>"$temp_config_file"; fi
    rm -f "$TEMP_DEFINES_FILE_INNER"; echo "INFO: Defines configurados (incluindo para S3 Hook Deleter)."
    echo "INFO: Copiando '$temp_config_file' para '$target_file_on_efs' como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp "$temp_config_file" "$target_file_on_efs"; then echo "INFO: Arquivo '$target_file_on_efs' criado."; else echo "ERRO CRÍTICO: Falha ao copiar para '$target_file_on_efs' como '$APACHE_USER'."; exit 1; fi
}

# --- Função para Baixar e Configurar o Script de Monitoramento Python ---
setup_python_monitor_script() {
    echo "INFO: Baixando e configurando script de monitoramento Python ($PYTHON_MONITOR_SCRIPT_NAME)..."
    if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || \
       [ -z "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}" ] || \
       [ -z "$AWS_S3_PYTHON_SCRIPT_KEY" ]; then
        echo "ERRO CRÍTICO: Variáveis para download do script Python não definidas (BUCKET_SCRIPT, REGION_SCRIPT ou AWS_S3_PYTHON_SCRIPT_KEY hardcoded está vazia)."
        exit 1
    fi
    local s3_python_script_uri="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_PYTHON_SCRIPT_KEY}"
    local temp_python_script_path="/tmp/$(basename "$PYTHON_MONITOR_SCRIPT_PATH")_temp_download"

    echo "INFO: Tentando baixar script Python de '$s3_python_script_uri' para '$temp_python_script_path'..."
    sudo rm -f "$temp_python_script_path" 

    if ! sudo aws s3 cp "$s3_python_script_uri" "$temp_python_script_path" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
        echo "ERRO CRÍTICO: Falha ao baixar o script Python de '$s3_python_script_uri'."
        exit 1
    fi

    if [ ! -s "$temp_python_script_path" ]; then 
        echo "ERRO CRÍTICO: Script Python baixado '$temp_python_script_path' está vazio ou não existe."
        exit 1
    fi

    echo "INFO: Script Python baixado. Movendo para '$PYTHON_MONITOR_SCRIPT_PATH'."
    if ! sudo mv "$temp_python_script_path" "$PYTHON_MONITOR_SCRIPT_PATH"; then
        echo "ERRO CRÍTICO: Falha ao mover script Python para '$PYTHON_MONITOR_SCRIPT_PATH'."
        exit 1
    fi

    if ! sudo chmod +x "$PYTHON_MONITOR_SCRIPT_PATH"; then
         echo "ERRO CRÍTICO: Falha ao tornar o script Python '$PYTHON_MONITOR_SCRIPT_PATH' executável."
        exit 1
    fi
    echo "INFO: Script de monitoramento Python '$PYTHON_MONITOR_SCRIPT_PATH' configurado."
}

# --- Função para Criar e Habilitar o Serviço Systemd para Python Monitor ---
create_and_enable_python_monitor_service() {
    echo "INFO: Criando serviço systemd para o monitoramento Python: $PYTHON_MONITOR_SERVICE_NAME..."
    local service_file_path="/etc/systemd/system/${PYTHON_MONITOR_SERVICE_NAME}.service"
    local patterns_env_str="wp-content/uploads/*;wp-content/themes/*/*.css;wp-content/themes/*/*.js;wp-content/themes/*/*.jpg;wp-content/themes/*/*.jpeg;wp-content/themes/*/*.png;wp-content/themes/*/*.gif;wp-content/themes/*/*.svg;wp-content/themes/*/*.webp;wp-content/themes/*/*.ico;wp-content/themes/*/*.woff;wp-content/themes/*/*.woff2;wp-content/themes/*/*.ttf;wp-content/themes/*/*.eot;wp-content/themes/*/*.otf;wp-content/plugins/*/*.css;wp-content/plugins/*/*.js;wp-content/plugins/*/*.jpg;wp-content/plugins/*/*.jpeg;wp-content/plugins/*/*.png;wp-content/plugins/*/*.gif;wp-content/plugins/*/*.svg;wp-content/plugins/*/*.webp;wp-content/plugins/*/*.ico;wp-content/plugins/*/*.woff;wp-content/plugins/*/*.woff2;wp-includes/js/*;wp-includes/css/*;wp-includes/images/*"

    echo "INFO: Limpando serviço '$PYTHON_MONITOR_SERVICE_NAME' existente, se houver..."
    if sudo systemctl is-active "$PYTHON_MONITOR_SERVICE_NAME.service" &>/dev/null; then sudo systemctl stop "$PYTHON_MONITOR_SERVICE_NAME.service"; fi
    if sudo systemctl is-enabled "$PYTHON_MONITOR_SERVICE_NAME.service" &>/dev/null; then sudo systemctl disable "$PYTHON_MONITOR_SERVICE_NAME.service"; fi
    sudo rm -f "$service_file_path"; sudo rm -f "/etc/systemd/system/multi-user.target.wants/${PYTHON_MONITOR_SERVICE_NAME}.service"; sudo systemctl daemon-reload
    echo "INFO: Limpeza de serviço systemd anterior concluída."

    local mount_unit_name; mount_unit_name=$(systemd-escape -p --suffix=mount "$MOUNT_POINT")
    local aws_cli_full_path; aws_cli_full_path=$(command -v aws || echo "/usr/bin/aws") 
    local escaped_patterns_env_str; printf -v escaped_patterns_env_str "%s" "$patterns_env_str" 

    local py_delete_from_efs_after_sync="true" 
    local py_perform_initial_sync="true"      

    sudo tee "$service_file_path" > /dev/null <<EOF_PY_SYSTEMD_SERVICE
[Unit]
Description=WordPress EFS to S3 Selective Sync Service (Python Watchdog v2.3.4)
Documentation=file://$PYTHON_MONITOR_SCRIPT_PATH
After=network.target remote-fs.target $mount_unit_name
Requires=$mount_unit_name

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $PYTHON_MONITOR_SCRIPT_PATH
Restart=on-failure
RestartSec=15s
Environment="WP_MONITOR_DIR_BASE=$MOUNT_POINT"
Environment="WP_S3_BUCKET=$AWS_S3_BUCKET_TARGET_NAME_0"
Environment="WP_RELEVANT_PATTERNS=$escaped_patterns_env_str"
Environment="WP_PY_MONITOR_LOG_FILE=$PY_MONITOR_LOG_FILE"
Environment="WP_PY_S3_TRANSFER_LOG=$PY_S3_TRANSFER_LOG_FILE"
Environment="WP_SYNC_DEBOUNCE_SECONDS=5"
Environment="WP_AWS_CLI_PATH=$aws_cli_full_path"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="WP_DELETE_FROM_EFS_AFTER_SYNC=${py_delete_from_efs_after_sync}"
Environment="WP_PERFORM_INITIAL_SYNC=${py_perform_initial_sync}"
Environment="AWS_CLOUDFRONT_DISTRIBUTION_TARGET_ID_0=${AWS_CLOUDFRONT_DISTRIBUTION_ID_0:-}" 

[Install]
WantedBy=multi-user.target
EOF_PY_SYSTEMD_SERVICE

    sudo chmod 644 "$service_file_path"
    echo "INFO: Arquivo de serviço '$service_file_path' criado."

    echo "INFO: Recarregando daemon systemd, habilitando e iniciando o serviço $PYTHON_MONITOR_SERVICE_NAME..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$PYTHON_MONITOR_SERVICE_NAME.service"
    if sudo systemctl start "$PYTHON_MONITOR_SERVICE_NAME.service"; then
        echo "INFO: Serviço Python $PYTHON_MONITOR_SERVICE_NAME iniciado com sucesso."
        sleep 3 
        sudo systemctl status "$PYTHON_MONITOR_SERVICE_NAME.service" --no-pager -l
    else
        echo "ERRO: Falha ao iniciar o serviço Python $PYTHON_MONITOR_SERVICE_NAME."
        sudo systemctl status "$PYTHON_MONITOR_SERVICE_NAME.service" --no-pager -l
        journalctl -u "$PYTHON_MONITOR_SERVICE_NAME" -n 50 --no-pager 
    fi
}

# NOVO: Função para instalar o script PHP S3 Hook Deleter
install_s3_hook_deleter_php() {
    echo "INFO: Instalando o script PHP S3 Hook Deleter ($S3_HOOK_DELETER_PHP_FILENAME)..."
    local script_source_path # Caminho onde o s3-hook-deleter.php está localizado
    script_source_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${S3_HOOK_DELETER_PHP_FILENAME}"

    if [ ! -f "$script_source_path" ]; then
        echo "AVISO: Script PHP S3 Hook Deleter '$S3_HOOK_DELETER_PHP_FILENAME' não encontrado em '$script_source_path'. Pulando instalação do hook."
        return 1
    fi

    local mu_plugins_dir="$MOUNT_POINT/wp-content/mu-plugins"
    local target_php_path="$mu_plugins_dir/$S3_HOOK_DELETER_PHP_FILENAME"

    echo "INFO: Criando diretório mu-plugins se não existir: $mu_plugins_dir"
    if sudo -u "$APACHE_USER" mkdir -p "$mu_plugins_dir"; then
        sudo chmod 775 "$mu_plugins_dir" # Permissões para o apache escrever, se necessário, e grupo ler/executar
    else
        echo "ERRO: Falha ao criar diretório mu-plugins '$mu_plugins_dir' como '$APACHE_USER'. Verifique permissões EFS."
        return 1
    fi
    
    echo "INFO: Copiando '$script_source_path' para '$target_php_path' como '$APACHE_USER'..."
    if sudo -u "$APACHE_USER" cp "$script_source_path" "$target_php_path"; then
        sudo chmod 664 "$target_php_path" # Apache dono, grupo apache pode ler
        echo "INFO: Script PHP S3 Hook Deleter instalado em '$target_php_path'."
    else
        echo "ERRO CRÍTICO: Falha ao copiar o S3 Hook Deleter para '$target_php_path' como '$APACHE_USER'. Verifique permissões."
        # Não sair do script principal por causa disso, mas logar como crítico.
        return 1
    fi

    # Adicionar AWS SDK para PHP via Composer se não estiver presente
    # Esta é uma etapa mais complexa e pode variar dependendo do setup.
    # Uma abordagem simples é verificar e instalar se o composer estiver disponível.
    if command -v composer &>/dev/null; then
        echo "INFO: Verificando e instalando AWS SDK para PHP via Composer em '$MOUNT_POINT'..."
        if [ ! -f "$MOUNT_POINT/composer.json" ]; then
            echo "INFO: composer.json não encontrado em '$MOUNT_POINT'. Criando um básico."
            # Criar um composer.json básico se não existir, como root ou EFS_OWNER_USER
            sudo -u "$EFS_OWNER_USER" bash -c "cd '$MOUNT_POINT' && composer init --no-interaction --name=wordpress/site --type=project --require=aws/aws-sdk-php:^3.0" || echo "AVISO: Falha ao inicializar composer.json"
        fi
        if grep -q "aws/aws-sdk-php" "$MOUNT_POINT/composer.json"; then
            echo "INFO: AWS SDK para PHP já está no composer.json. Executando 'composer install'..."
        else
            echo "INFO: Adicionando aws/aws-sdk-php ao composer.json e executando 'composer install'..."
            sudo -u "$EFS_OWNER_USER" bash -c "cd '$MOUNT_POINT' && composer require aws/aws-sdk-php:^3.0" || echo "AVISO: Falha ao executar 'composer require aws/aws-sdk-php'"
        fi
        # Executar composer install como o usuário que tem permissão de escrita no EFS ou como root
        # É importante que o diretório vendor seja legível pelo Apache
        if sudo -u "$EFS_OWNER_USER" bash -c "cd '$MOUNT_POINT' && composer install --no-dev --optimize-autoloader"; then
            echo "INFO: 'composer install' concluído. Verifique o diretório '$MOUNT_POINT/vendor'."
            # Ajustar permissões do diretório vendor se necessário, para que o Apache possa ler
            if [ -d "$MOUNT_POINT/vendor" ]; then
                sudo chown -R "$APACHE_USER":"$APACHE_USER" "$MOUNT_POINT/vendor"
                sudo find "$MOUNT_POINT/vendor" -type d -exec chmod 775 {} \;
                sudo find "$MOUNT_POINT/vendor" -type f -exec chmod 664 {} \;
            fi
        else
            echo "AVISO: Falha ao executar 'composer install'. O S3 Hook Deleter pode não funcionar sem o AWS SDK para PHP."
        fi
    else
        echo "AVISO: Composer não encontrado. AWS SDK para PHP precisa ser instalado manualmente ou por outros meios para o S3 Hook Deleter funcionar."
    fi
}


# --- Lógica Principal de Execução ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.3.4-s3-hook-deleter) ($(date)) ---"
echo "INFO: Script target: $THIS_SCRIPT_TARGET_PATH. Log: ${LOG_FILE}"
echo "INFO: Python Script S3 Key (Hardcoded): $AWS_S3_PYTHON_SCRIPT_KEY"
echo "INFO: S3 Hook Deleter PHP Filename (esperado localmente): $S3_HOOK_DELETER_PHP_FILENAME"
echo "INFO: =================================================="
if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execução inicial deve ser como root."; exit 1; fi

self_install_script

echo "INFO: Verificando e imprimindo variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then ACCOUNT_STS=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); if [ -n "$ACCOUNT_STS" ]; then ACCOUNT="$ACCOUNT_STS"; echo "INFO: ACCOUNT ID obtido via STS: $ACCOUNT"; else echo "WARN: Falha obter ACCOUNT ID via STS."; ACCOUNT=""; fi; fi
AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""; if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ]&&[ -n "${ACCOUNT:-}" ]&&[ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"; fi
error_found=0; echo "INFO: --- VALORES DAS VARIÁVEIS ESSENCIAIS E HARDCODED ---"
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-UNDEFINED}"; var_name_for_check="$var_name"; current_var_value_to_check="${!var_name:-}"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then current_var_value_to_check="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"; var_name_for_check="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (de $var_name)"; fi
    echo "INFO: Var (env): $var_name_for_check = '$current_var_value_to_check'"
    if [ "$var_name" != "AWS_EFS_ACCESS_POINT_TARGET_ID_0" ] && [ -z "$current_var_value_to_check" ]; then echo "ERRO: Var essencial '$var_name_for_check' vazia."; error_found=1; fi
done
echo "INFO: Var (hardcoded): AWS_S3_PYTHON_SCRIPT_KEY = '$AWS_S3_PYTHON_SCRIPT_KEY'"
if [ -z "$AWS_S3_PYTHON_SCRIPT_KEY" ]; then echo "ERRO CRÍTICO: Constante AWS_S3_PYTHON_SCRIPT_KEY está vazia no script!"; error_found=1; fi
echo "INFO: --- FIM DOS VALORES DAS VARIÁVEIS ---"
if [ "$error_found" -eq 1 ]; then echo "ERRO CRÍTICO: Variáveis faltando ou mal configuradas. Abortando."; exit 1; fi
echo "INFO: Verificação de variáveis concluída."

echo "INFO: Instalando pacotes (Apache, PHP, Python3, pip, watchdog, composer, etc.)..."
sudo yum update -y -q
sudo amazon-linux-extras install -y epel -q 
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils # Pacotes base
# NOVO: Instalar Composer
if ! command -v composer &> /dev/null; then
    echo "INFO: Instalando Composer..."
    sudo yum install -y php-cli php-zip wget unzip php-mbstring php-xml # Dependências do Composer
    EXPECTED_CHECKSUM="$(wget -q -O - https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        >&2 echo 'ERRO: Invalid installer checksum'
        rm composer-setup.php
        exit 1
    fi
    php composer-setup.php --quiet
    RESULT=$?
    rm composer-setup.php
    if [ $RESULT -ne 0 ]; then echo "ERRO: Falha ao instalar composer."; exit $RESULT; fi
    sudo mv composer.phar /usr/local/bin/composer
    echo "INFO: Composer instalado."
else
    echo "INFO: Composer já está instalado."
fi


echo "INFO: Habilitando e instalando PHP 7.4 e módulos relacionados..."
sudo amazon-linux-extras enable php7.4 -y -q
sudo yum install -y -q php php-common php-fpm php-mysqlnd php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache
if ! sudo rpm -q php-fpm; then echo "ERRO CRÍTICO: Pacote php-fpm não foi instalado corretamente."; exit 1; fi
echo "INFO: PHP e PHP-FPM instalados."

echo "INFO: Instalando Python3, pip, watchdog e boto3..." # Adicionado boto3 aqui
sudo yum install -y -q python3 python3-pip
sudo pip3 install --upgrade pip 
sudo pip3 install watchdog boto3 # Instala watchdog E BOTO3 para Python3
echo "INFO: Python3, pip, watchdog e boto3 instalados."
echo "INFO: Todos os pacotes de pré-requisitos foram processados."


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

# NOVO: Instalar o S3 Hook Deleter PHP após a instalação do WP
install_s3_hook_deleter_php

echo "INFO: (Opcional) Salvando vars em '$ENV_VARS_FILE'..."
ENV_VARS_FILE_CONTENT="#!/bin/bash\n# Vars para referência (v2.3.4)\n"
ENV_VARS_FILE_CONTENT+="export MOUNT_POINT=$(printf '%q' "$MOUNT_POINT")\n"
ENV_VARS_FILE_CONTENT+="export AWS_S3_BUCKET_TARGET_NAME_0=$(printf '%q' "$AWS_S3_BUCKET_TARGET_NAME_0")\n"
echo -e "$ENV_VARS_FILE_CONTENT" | sudo tee "$ENV_VARS_FILE" > /dev/null; sudo chmod 644 "$ENV_VARS_FILE"; echo "INFO: Vars salvas em $ENV_VARS_FILE."


if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then echo "ERRO: $CONFIG_SAMPLE_ON_EFS não encontrado."; exit 1; fi
if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then echo "INFO: '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando..."; create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"; else echo "WARN: '$ACTIVE_CONFIG_FILE_EFS' já existe."; fi

echo "INFO: Criando health check '$HEALTH_CHECK_FILE_PATH_EFS'..."
HEALTH_CHECK_CONTENT="<?php http_response_code(200); header('Content-Type: text/plain; charset=utf-8'); echo 'OK - WP Health Check - v2.3.4 - '.date('Y-m-d\TH:i:s\Z'); exit; ?>"
TEMP_HEALTH_CHECK_FILE=$(mktemp /tmp/healthcheck.XXXXXX.php); sudo chmod 644 "$TEMP_HEALTH_CHECK_FILE"; echo "$HEALTH_CHECK_CONTENT" >"$TEMP_HEALTH_CHECK_FILE"
if sudo -u "$APACHE_USER" cp "$TEMP_HEALTH_CHECK_FILE" "$HEALTH_CHECK_FILE_PATH_EFS"; then echo "INFO: Health check criado."; else echo "ERRO: Falha criar health check."; fi; rm -f "$TEMP_HEALTH_CHECK_FILE"

echo "INFO: Ajustando permissões finais em '$MOUNT_POINT' para '$APACHE_USER'..."
if ! sudo chown -R "$APACHE_USER":"$APACHE_USER" "$MOUNT_POINT"; then echo "AVISO: Falha no chown -R. Verifique config EFS AP. GID atual: $(stat -c "%g" "$MOUNT_POINT") vs Apache GID: $(getent group "$APACHE_USER" | cut -d: -f3)"; ls -ld "$MOUNT_POINT"; fi
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \; ; sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
if [ -f "$ACTIVE_CONFIG_FILE_EFS" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE_EFS"; fi; if [ -f "$HEALTH_CHECK_FILE_PATH_EFS" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH_EFS"; fi; echo "INFO: Permissões ajustadas."

echo "INFO: Configurando Apache..."
HTTPD_WP_CONF="/etc/httpd/conf.d/wordpress_v2.3.4.conf" 
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
    if ! grep -q "AllowOverride All" "$HTTPD_WP_CONF"; then sudo sed -i '/<Directory "${MOUNT_POINT//\//\\/}">/a \    AllowOverride All' "$HTTPD_WP_CONF"; fi
    if ! grep -q "SetEnvIf X-Forwarded-Proto" "$HTTPD_WP_CONF"; then echo -e "\n<IfModule mod_setenvif.c>\n  SetEnvIf X-Forwarded-Proto \"^https\$\" HTTPS=on\n</IfModule>" | sudo tee -a "$HTTPD_WP_CONF" > /dev/null; fi
fi
echo "INFO: Configuração Apache em $HTTPD_WP_CONF verificada/criada."

# --- Detecção e Inicialização de PHP-FPM e HTTPD ---
PHP_FPM_SERVICE_NAME=""
POSSIBLE_FPM_NAMES=("php-fpm.service" "php7.4-fpm.service" "php74-php-fpm.service")

echo "INFO: Detectando nome do serviço PHP-FPM..."
for fpm_name in "${POSSIBLE_FPM_NAMES[@]}"; do
    if sudo systemctl list-unit-files | grep -q -w "$fpm_name"; then
        PHP_FPM_SERVICE_NAME="$fpm_name"
        echo "INFO: Nome do serviço PHP-FPM detectado: $PHP_FPM_SERVICE_NAME"
        break
    fi
done

if [ -z "$PHP_FPM_SERVICE_NAME" ]; then
    echo "ERRO CRÍTICO: Não foi possível detectar o nome do serviço PHP-FPM instalado."
    exit 1
fi

echo "INFO: Habilitando e reiniciando httpd e $PHP_FPM_SERVICE_NAME..."
sudo systemctl enable httpd "$PHP_FPM_SERVICE_NAME"

php_fpm_restarted_successfully=false
if sudo systemctl restart "$PHP_FPM_SERVICE_NAME"; then
    echo "INFO: $PHP_FPM_SERVICE_NAME reiniciado com sucesso."
    php_fpm_restarted_successfully=true
else
    echo "ERRO: Falha ao reiniciar $PHP_FPM_SERVICE_NAME."
    sudo systemctl status "$PHP_FPM_SERVICE_NAME" -l --no-pager
    sudo journalctl -u "$PHP_FPM_SERVICE_NAME" -n 50 --no-pager
fi

httpd_restarted_successfully=false
if sudo systemctl restart httpd; then
    echo "INFO: httpd reiniciado com sucesso."
    httpd_restarted_successfully=true
else
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."
    sudo apachectl configtest
    sudo tail -n 50 /var/log/httpd/error_log
fi

sleep 3

if $httpd_restarted_successfully && $php_fpm_restarted_successfully && \
   systemctl is-active --quiet httpd && systemctl is-active --quiet "$PHP_FPM_SERVICE_NAME"; then
    echo "INFO: httpd e $PHP_FPM_SERVICE_NAME ativos."
else
    echo "ERRO CRÍTICO: httpd ou $PHP_FPM_SERVICE_NAME não estão ativos."
    exit 1
fi


# --- Configuração do Monitoramento Python com Watchdog ---
setup_python_monitor_script 
create_and_enable_python_monitor_service 

echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v2.3.4-s3-hook-deleter) concluído! ($(date)) ---"
echo "INFO: Sincronização com S3 Python Watchdog: ATIVA (Script: $PYTHON_MONITOR_SCRIPT_PATH, Serviço: $PYTHON_MONITOR_SERVICE_NAME)"
echo "INFO: Deleção de S3 via Hook WordPress PHP: INSTALADO (Script: $MOUNT_POINT/wp-content/mu-plugins/$S3_HOOK_DELETER_PHP_FILENAME)"
echo "INFO: Configurações do Python para EFS/S3 (no service file): DELETE_FROM_EFS_AFTER_SYNC=${py_delete_from_efs_after_sync:-N/A}, PERFORM_INITIAL_SYNC=${py_perform_initial_sync:-N/A}"
echo "INFO: Logs: Principal=${LOG_FILE}, Python Monitor=${PY_MONITOR_LOG_FILE}, Python Transfer=${PY_S3_TRANSFER_LOG_FILE}"
echo "INFO: Site: https://${WPDOMAIN}, Health Check: /healthcheck.php"
echo "INFO: LEMBRE-SE de configurar o EFS Access Point com uid=48 e gid=48 (para o apache)."
echo "INFO: LEMBRE-SE de colocar o script Python ($PYTHON_MONITOR_SCRIPT_NAME ou o nome definido em AWS_S3_PYTHON_SCRIPT_KEY) no bucket S3 '$AWS_S3_BUCKET_TARGET_NAME_SCRIPT' com a chave '$AWS_S3_PYTHON_SCRIPT_KEY'."
echo "INFO: LEMBRE-SE de que o AWS SDK para PHP deve estar funcional para o '$S3_HOOK_DELETER_PHP_FILENAME' deletar do S3."
echo "INFO: =================================================="
exit 0
