#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.7-mod7-sedfix
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2.
# Cria templates wp-config-production.php e wp-config-management.php no EFS.
# Ativa wp-config-management.php como o wp-config.php padrão.
# Garante que o Apache escute em IPv4 e IPv6 na porta 80.
# Corrige erro no comando sed para comentar Listen 80 genérico.

SCRIPT_VERSION="1.9.7-mod7-sedfix"

# --- Redirecionamento de Logs (Definido cedo para capturar tudo) ---
LOG_FILE="/var/log/wordpress_setup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (Versão: ${SCRIPT_VERSION}) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- BEGIN WAIT LOGIC FOR AMI INITIALIZATION ---
echo "INFO: Script está rodando como parte do cloud-init user-data. Pulando espera explícita por /var/lib/cloud/instance/boot-finished."
# --- END WAIT LOGIC ---

# --- BEGIN YUM WAIT LOGIC ---
echo "INFO: Attempting to disable and stop yum-cron..."
if systemctl list-unit-files | grep -q "yum-cron.service"; then
    sudo systemctl stop yum-cron || echo "WARN: Falha ao parar yum-cron (pode não estar rodando)."
    sudo systemctl disable yum-cron || echo "WARN: Falha ao desabilitar yum-cron."
    echo "INFO: yum-cron stop/disable attempted."
else
    echo "INFO: Serviço yum-cron.service não encontrado. Pulando desativação."
fi

echo "INFO: Performing check and wait for yum to be free... ($(date))"
MAX_YUM_WAIT_ITERATIONS=60
YUM_WAIT_INTERVAL=30
CURRENT_YUM_WAIT_ITERATION=0
STALE_PID_CONFIRMATIONS_NEEDED=2
STALE_PID_CURRENT_CONFIRMATIONS=0

while [ -f /var/run/yum.pid ]; do
    if [ "$CURRENT_YUM_WAIT_ITERATION" -ge "$MAX_YUM_WAIT_ITERATIONS" ]; then
        YUM_PID_CONTENT=$(cat /var/run/yum.pid 2>/dev/null || echo 'unknown')
        echo "ERROR: Yum still locked by /var/run/yum.pid (PID: $YUM_PID_CONTENT) after extended waiting. Aborting. ($(date))"
        if [ "$YUM_PID_CONTENT" != "unknown" ] && [ -n "$YUM_PID_CONTENT" ] && kill -0 "$YUM_PID_CONTENT" 2>/dev/null; then
            echo "INFO: Details for locking yum process $YUM_PID_CONTENT (from yum.pid) before aborting:"
            ps -f -p "$YUM_PID_CONTENT" || echo "WARN: ps -f -p $YUM_PID_CONTENT failed."
            PARENT_PID_OF_LOCKER=$(ps -o ppid= -p "$YUM_PID_CONTENT" 2>/dev/null)
            if [ -n "$PARENT_PID_OF_LOCKER" ]; then
                echo "INFO: Parent of locking process $YUM_PID_CONTENT is PPID: $PARENT_PID_OF_LOCKER. Details:"
                ps -f -p "$PARENT_PID_OF_LOCKER" || echo "WARN: ps -f -p $PARENT_PID_OF_LOCKER failed."
            else
                echo "WARN: Could not determine parent of locking process $YUM_PID_CONTENT."
            fi
        fi
        exit 1
    fi

    YUM_PID_CONTENT=$(cat /var/run/yum.pid 2>/dev/null || echo 'unknown')
    echo "INFO: Yum is busy (PID from /var/run/yum.pid: $YUM_PID_CONTENT). Waiting... (attempt $((CURRENT_YUM_WAIT_ITERATION + 1))/$MAX_YUM_WAIT_ITERATIONS, $(date))"

    if [ "$YUM_PID_CONTENT" != "unknown" ] && [ -n "$YUM_PID_CONTENT" ]; then
        if kill -0 "$YUM_PID_CONTENT" 2>/dev/null; then
            echo "INFO: Details for yum process $YUM_PID_CONTENT (from yum.pid) holding the lock:"
            ps -f -p "$YUM_PID_CONTENT" || echo "WARN: ps -f -p $YUM_PID_CONTENT failed during wait."
            PARENT_PID_OF_LOCKER=$(ps -o ppid= -p "$YUM_PID_CONTENT" 2>/dev/null)
            if [ -n "$PARENT_PID_OF_LOCKER" ]; then
                echo "INFO: Parent of $YUM_PID_CONTENT is PPID: $PARENT_PID_OF_LOCKER. Details:"
                ps -f -p "$PARENT_PID_OF_LOCKER" || echo "WARN: ps -f -p $PARENT_PID_OF_LOCKER failed during wait."
            else
                echo "WARN: Could not determine parent of $YUM_PID_CONTENT during wait."
            fi
            STALE_PID_CURRENT_CONFIRMATIONS=0
        else
            echo "WARN: PID $YUM_PID_CONTENT from /var/run/yum.pid does not seem to be a running process. This might be a stale lock file."
            STALE_PID_CURRENT_CONFIRMATIONS=$((STALE_PID_CURRENT_CONFIRMATIONS + 1))
            echo "INFO: Stale PID confirmation count: $STALE_PID_CURRENT_CONFIRMATIONS/$STALE_PID_CONFIRMATIONS_NEEDED."

            if [ "$STALE_PID_CURRENT_CONFIRMATIONS" -ge "$STALE_PID_CONFIRMATIONS_NEEDED" ]; then
                echo "WARN: Confirmed PID $YUM_PID_CONTENT is stale. Attempting to remove /var/run/yum.pid."
                if sudo rm -f /var/run/yum.pid; then
                    echo "INFO: Successfully removed stale /var/run/yum.pid. Yum should be free now."
                    STALE_PID_CURRENT_CONFIRMATIONS=0
                else
                    echo "ERROR: Failed to remove stale /var/run/yum.pid. Permissions issue? Continuing to wait, but this is problematic."
                fi
            fi
        fi
    else
        echo "WARN: PID from /var/run/yum.pid is '$YUM_PID_CONTENT' (empty or unreadable file). This might also be a stale lock file."
        STALE_PID_CURRENT_CONFIRMATIONS=$((STALE_PID_CURRENT_CONFIRMATIONS + 1))
        echo "INFO: Stale/Empty PID file confirmation count: $STALE_PID_CURRENT_CONFIRMATIONS/$STALE_PID_CONFIRMATIONS_NEEDED."

        if [ "$STALE_PID_CURRENT_CONFIRMATIONS" -ge "$STALE_PID_CONFIRMATIONS_NEEDED" ]; then
             echo "WARN: Confirmed /var/run/yum.pid is problematic (empty/unreadable). Attempting to remove."
             if sudo rm -f /var/run/yum.pid; then
                echo "INFO: Successfully removed problematic /var/run/yum.pid."
                STALE_PID_CURRENT_CONFIRMATIONS=0
             else
                echo "ERROR: Failed to remove problematic /var/run/yum.pid. Continuing to wait, but this is problematic."
             fi
        fi
    fi

    sleep "$YUM_WAIT_INTERVAL"
    CURRENT_YUM_WAIT_ITERATION=$((CURRENT_YUM_WAIT_ITERATION + 1))
done

PGREP_YUM_CHECKS=12
PGREP_YUM_INTERVAL=10
for i in $(seq 1 "$PGREP_YUM_CHECKS"); do
    YUM_PIDS_PGREP=$(pgrep -x yum)
    if [ -z "$YUM_PIDS_PGREP" ]; then
        echo "INFO: No 'yum' process found by pgrep. ($(date))"
        break
    else
        echo "INFO: 'yum' process(es) still detected by pgrep. PIDs: $YUM_PIDS_PGREP. Waiting (pgrep check $i/$PGREP_YUM_CHECKS, $(date))..."
        for YUM_PID_SINGLE in $YUM_PIDS_PGREP; do
            echo "INFO: Details for pgrep-found yum process $YUM_PID_SINGLE:"
            ps -f -p "$YUM_PID_SINGLE" || echo "WARN: ps -f -p $YUM_PID_SINGLE (pgrep) failed."
            PARENT_PID_OF_PGREP_YUM=$(ps -o ppid= -p "$YUM_PID_SINGLE" 2>/dev/null)
            if [ -n "$PARENT_PID_OF_PGREP_YUM" ]; then
                echo "INFO: Parent of pgrep-found $YUM_PID_SINGLE is PPID: $PARENT_PID_OF_PGREP_YUM. Details:"
                ps -f -p "$PARENT_PID_OF_PGREP_YUM" || echo "WARN: ps -f -p $PARENT_PID_OF_PGREP_YUM (pgrep parent) failed."
            else
                echo "WARN: Could not determine parent of pgrep-found $YUM_PID_SINGLE."
            fi
        done
        sleep "$PGREP_YUM_INTERVAL"
    fi

    if [ "$i" -eq "$PGREP_YUM_CHECKS" ]; then
        YUM_PIDS_PGREP_FINAL=$(pgrep -x yum)
        echo "ERROR: 'yum' process(es) (PIDs: $YUM_PIDS_PGREP_FINAL) still running after pgrep checks. Aborting. ($(date))"
        if [ -n "$YUM_PIDS_PGREP_FINAL" ]; then
            for YUM_PID_FINAL_PGREP in $YUM_PIDS_PGREP_FINAL; do
                echo "INFO: Final details for pgrep-found yum process $YUM_PID_FINAL_PGREP before aborting:"
                ps -f -p "$YUM_PID_FINAL_PGREP" || echo "WARN: ps -f -p $YUM_PID_FINAL_PGREP (pgrep final) failed."
                PARENT_PID_OF_FINAL_PGREP=$(ps -o ppid= -p "$YUM_PID_FINAL_PGREP" 2>/dev/null)
                if [ -n "$PARENT_PID_OF_FINAL_PGREP" ]; then
                    echo "INFO: Parent of final pgrep-found $YUM_PID_FINAL_PGREP is PPID: $PARENT_PID_OF_FINAL_PGREP. Details:"
                    ps -f -p "$PARENT_PID_OF_FINAL_PGREP" || echo "WARN: ps -f -p $PARENT_PID_OF_FINAL_PGREP (pgrep final parent) failed."
                else
                    echo "WARN: Could not determine parent of final pgrep-found $YUM_PID_FINAL_PGREP."
                fi
            done
        fi
        exit 1
    fi
done
echo "INFO: Yum lock is free. Proceeding. ($(date))"
# --- END YUM WAIT LOGIC ---

# --- Configuração Inicial ---
set -e
# set -x # Descomente para debugging detalhado do script

# --- Variáveis ---
MOUNT_POINT="/var/www/html"
WP_DIR_TEMP="/tmp/wordpress-temp"
ACTIVE_CONFIG_FILE="$MOUNT_POINT/wp-config.php"
CONFIG_FILE_PROD_TEMPLATE="$MOUNT_POINT/wp-config-production.php"
CONFIG_FILE_MGMT_TEMPLATE="$MOUNT_POINT/wp-config-management.php"
CONFIG_SAMPLE_ORIGINAL="$MOUNT_POINT/wp-config-sample.php"
HEALTH_CHECK_FILE_PATH="$MOUNT_POINT/healthcheck.php"
MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'

# --- Verificação de Variáveis de Ambiente Essenciais ---
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "WPDOMAIN"
    "ACCOUNT"
)
echo "INFO: Verificando formalmente as variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then
    echo "INFO: ACCOUNT ID não fornecido, tentando obter via AWS STS..."
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT" ]; then
        echo "WARN: Falha ao obter ACCOUNT ID. Se o ARN do Secret não for construído corretamente, o script pode falhar."
    else
        echo "INFO: ACCOUNT ID obtido: $ACCOUNT"
    fi
fi

if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] && \
    [ -n "${ACCOUNT:-}" ] && \
    [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
else
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED=""
fi

if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 fornecido diretamente: ${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0}"
elif [ -n "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED" ]; then
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 está vazio, construindo a partir dos componentes..."
    export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED"
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 construído como: $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
else
    export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
fi

error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-}"
    var_to_check_name="$var_name"

    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        if [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
            echo "ERRO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 não pôde ser determinado (nem fornecido, nem construído)."
            error_found=1
        fi
    elif [ -z "$current_var_value" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_to_check_name' não definida ou vazia."
        error_found=1
    fi
done

if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Uma ou mais variáveis essenciais estão faltando. Abortando."
    exit 1
fi

if [ -z "${MANAGEMENT_WPDOMAIN:-}" ]; then
    echo "WARN: MANAGEMENT_WPDOMAIN não definido. O template wp-config-management.php usará um placeholder 'management.example.com'."
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="management.example.com"
else
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="${MANAGEMENT_WPDOMAIN}"
fi
echo "INFO: Domínio de Produção (WPDOMAIN): ${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (MANAGEMENT_WPDOMAIN_EFFECTIVE): ${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
echo "INFO: Verificação de variáveis essenciais concluída."

# --- Funções Auxiliares ---
mount_efs() {
    local efs_id=$1
    local mount_point=$2
    local efs_ap_id="${AWS_EFS_ACCESS_POINT_TARGET_ID_0:-}" # Usando a variável de ambiente correta

    echo "INFO: Verificando se o ponto de montagem '$mount_point' existe..."
    sudo mkdir -p "$mount_point"

    echo "INFO: Verificando se '$mount_point' já está montado..."
    if mount | grep -q "on ${mount_point} type efs"; then
        echo "INFO: EFS já está montado em '$mount_point'."
    else
        echo "INFO: Montando EFS '$efs_id' em '$mount_point'..."
        local mount_options="tls"
        local mount_source="$efs_id:/"

        if [ -n "$efs_ap_id" ]; then
            echo "INFO: Usando Ponto de Acesso EFS: $efs_ap_id"
            mount_source="$efs_id"
            mount_options="tls,accesspoint=$efs_ap_id"
        else
            echo "INFO: Montando raiz do EFS File System (sem Ponto de Acesso específico)."
        fi

        local mount_attempts=3
        local mount_timeout=20
        local attempt_num=1
        while [ "$attempt_num" -le "$mount_attempts" ]; do
            echo "INFO: Tentativa de montagem $attempt_num/$mount_attempts para EFS ($mount_source) em '$mount_point' com opções '$mount_options'..."
            if sudo timeout "${mount_timeout}s" mount -t efs -o "$mount_options" "$mount_source" "$mount_point"; then
                echo "INFO: EFS montado com sucesso em '$mount_point'."
                break
            else
                echo "ERRO: Tentativa $attempt_num/$mount_attempts de montar EFS falhou (timeout ${mount_timeout}s)."
                if [ "$attempt_num" -eq "$mount_attempts" ]; then
                    echo "ERRO CRÍTICO: Falha ao montar EFS após $mount_attempts tentativas."
                    exit 1
                fi
                sleep 5
            fi
            attempt_num=$((attempt_num + 1))
        done

        echo "INFO: Adicionando montagem do EFS ao /etc/fstab para persistência..."
        if grep -q " ${mount_point} efs" /etc/fstab; then
            echo "INFO: Entrada EFS existente para ${mount_point} encontrada no /etc/fstab. Removendo para atualizar..."
            sudo sed -i "\# ${mount_point} efs#d" /etc/fstab
        fi
        local fstab_mount_options="_netdev,${mount_options}"
        local fstab_entry="$mount_source $mount_point efs $fstab_mount_options 0 0"
        echo "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null
        echo "INFO: Entrada adicionada ao /etc/fstab: '$fstab_entry'"
    fi
}

create_wp_config_template() {
    local target_file="$1"
    local wp_home_url="$2"
    local wp_site_url="$3"
    local db_name="$4"
    local db_user="$5"
    local db_password="$6"
    local db_host="$7"

    echo "INFO: Criando template de configuração em '$target_file' para URL: $wp_home_url"
    if [ ! -f "$CONFIG_SAMPLE_ORIGINAL" ]; then
        echo "ERRO: Arquivo original '$CONFIG_SAMPLE_ORIGINAL' não encontrado. O WordPress foi baixado corretamente?"
        exit 1
    fi
    sudo cp "$CONFIG_SAMPLE_ORIGINAL" "$target_file"

    SAFE_DB_NAME=$(printf '%s\n' "$db_name" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_USER=$(printf '%s\n' "$db_user" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(printf '%s\n' "$db_password" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_HOST=$(printf '%s\n' "$db_host" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")

    sudo sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$target_file"
    sudo sed -i "s/username_here/$SAFE_DB_USER/g" "$target_file"
    sudo sed -i "s/password_here/$SAFE_DB_PASSWORD/g" "$target_file"
    sudo sed -i "s/localhost/$SAFE_DB_HOST/g" "$target_file"

    echo "INFO: Obtendo e configurando SALTS em $target_file..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then echo "ERRO: Falha ao obter SALTS para $target_file."; else
        local salt_defines=(AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT)
        for def_key in "${salt_defines[@]}"; do
            sudo sed -i "/^define( *'$def_key'/d" "$target_file"
        done

        TEMP_SALT_FILE=$(mktemp)
        echo "$SALT" >"$TEMP_SALT_FILE"
        if sudo grep -q "$MARKER_LINE_SED_PATTERN" "$target_file"; then
            sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE" "$target_file"
        else
            echo "WARN: Marcador '$MARKER_LINE_SED_RAW' não encontrado em $target_file. Adicionando SALTS no final."
            cat "$TEMP_SALT_FILE" | sudo tee -a "$target_file" >/dev/null
        fi
        rm -f "$TEMP_SALT_FILE"
        echo "INFO: SALTS configurados em $target_file."
    fi

    PHP_DEFINES_BLOCK=$(
        cat <<EOF

define('WP_HOME', '$wp_home_url');
define('WP_SITEURL', '$wp_site_url');
define('FS_METHOD', 'direct');

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}

define('DISALLOW_FILE_EDIT', true);
EOF
    )
    TEMP_DEFINES_FILE=$(mktemp)
    echo "$PHP_DEFINES_BLOCK" >"$TEMP_DEFINES_FILE"
    if sudo grep -q "$MARKER_LINE_SED_PATTERN" "$target_file"; then
        sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE" "$target_file"
    else
        echo "WARN: Marcador '$MARKER_LINE_SED_RAW' não encontrado em $target_file. Adicionando DEFINES no final."
        cat "$TEMP_DEFINES_FILE" | sudo tee -a "$target_file" >/dev/null
    fi
    rm -f "$TEMP_DEFINES_FILE"
    echo "INFO: WP_HOME, WP_SITEURL, FS_METHOD e outras diretivas configuradas em $target_file."
}

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM..."
sudo yum update -y -q
echo "INFO: Habilitando repositório EPEL..."
sudo amazon-linux-extras install -y epel
echo "INFO: Instalando pacotes base..."
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils
echo "INFO: Habilitando PHP 7.4..."
sudo amazon-linux-extras enable php7.4 -y
echo "INFO: Instalando PHP 7.4 e módulos..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap
echo "INFO: Instalação de pacotes concluída."

# --- Montagem do EFS ---
mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

# --- Obtenção de Credenciais do RDS ---
echo "INFO: Obtendo credenciais do RDS via Secrets Manager (ARN: $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0)..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then
    echo "ERRO: Falha ao obter segredo do Secrets Manager."
    exit 1
fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair username ou password do JSON do segredo."
    exit 1
fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
echo "INFO: Credenciais do banco de dados extraídas (Usuário: $DB_USER)."

# --- Download e Extração do WordPress ---
echo "INFO: Verificando se o WordPress já existe em '$MOUNT_POINT'..."
if [ -d "$MOUNT_POINT/wp-includes" ] && [ -f "$MOUNT_POINT/wp-config-sample.php" ]; then
    echo "WARN: Diretório 'wp-includes' e 'wp-config-sample.php' já encontrado em '$MOUNT_POINT'. Pulando download e extração do WordPress."
else
    echo "INFO: WordPress não encontrado ou incompleto. Iniciando download e extração..."
    mkdir -p "$WP_DIR_TEMP" && cd "$WP_DIR_TEMP"
    echo "INFO: Baixando WordPress..."
    curl -sLO https://wordpress.org/latest.tar.gz || {
        echo "ERRO: Falha ao baixar WordPress."
        cd /tmp && rm -rf "$WP_DIR_TEMP"
        exit 1
    }
    echo "INFO: Extraindo WordPress..."
    tar -xzf latest.tar.gz || {
        echo "ERRO: Falha ao extrair 'latest.tar.gz'."
        cd /tmp && rm -rf "$WP_DIR_TEMP"
        exit 1
    }
    rm latest.tar.gz
    if [ ! -d "wordpress" ]; then
        echo "ERRO: Diretório 'wordpress' não encontrado pós extração."
        cd /tmp && rm -rf "$WP_DIR_TEMP"
        exit 1
    fi
    echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT'..."
    sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/" || {
        echo "ERRO: Falha ao mover arquivos para $MOUNT_POINT."
        cd /tmp && rm -rf "$WP_DIR_TEMP"
        exit 1
    }
    cd /tmp && rm -rf "$WP_DIR_TEMP"
    echo "INFO: Arquivos do WordPress movidos."
fi

# --- Configuração dos Templates wp-config ---
if [ -f "$CONFIG_SAMPLE_ORIGINAL" ]; then
    if [ ! -f "$CONFIG_FILE_PROD_TEMPLATE" ] || [ "$(sudo stat -c %s "$CONFIG_FILE_PROD_TEMPLATE")" -lt 100 ]; then
        PRODUCTION_URL="https://${WPDOMAIN}"
        create_wp_config_template "$CONFIG_FILE_PROD_TEMPLATE" "$PRODUCTION_URL" "$PRODUCTION_URL" \
            "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
    else
        echo "WARN: Template $CONFIG_FILE_PROD_TEMPLATE já existe e parece válido. Pulando criação."
    fi

    if [ ! -f "$CONFIG_FILE_MGMT_TEMPLATE" ] || [ "$(sudo stat -c %s "$CONFIG_FILE_MGMT_TEMPLATE")" -lt 100 ]; then
        MANAGEMENT_URL="https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
        create_wp_config_template "$CONFIG_FILE_MGMT_TEMPLATE" "$MANAGEMENT_URL" "$MANAGEMENT_URL" \
            "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
    else
        echo "WARN: Template $CONFIG_FILE_MGMT_TEMPLATE já existe e parece válido. Pulando criação."
    fi

    if [ ! -L "$ACTIVE_CONFIG_FILE" ] && [ ! -f "$ACTIVE_CONFIG_FILE" ] && [ -f "$CONFIG_FILE_MGMT_TEMPLATE" ]; then
        echo "INFO: Ativando $CONFIG_FILE_MGMT_TEMPLATE como o $ACTIVE_CONFIG_FILE padrão."
        sudo cp "$CONFIG_FILE_MGMT_TEMPLATE" "$ACTIVE_CONFIG_FILE"
    elif [ -f "$ACTIVE_CONFIG_FILE" ] || [ -L "$ACTIVE_CONFIG_FILE" ]; then
        echo "WARN: $ACTIVE_CONFIG_FILE já existe. Nenhuma alteração no arquivo ativo será feita por este script para manter o estado atual."
    else
        echo "ERRO: $CONFIG_FILE_MGMT_TEMPLATE não pôde ser criado/encontrado para ativar como padrão."
    fi
else
    echo "WARN: $CONFIG_SAMPLE_ORIGINAL não encontrado. Não é possível criar templates wp-config."
fi

# --- Adicionar Arquivo de Health Check ---
echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_PATH'..."
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
// Version: ${SCRIPT_VERSION}
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK - WordPress Health Check Endpoint - Script v${SCRIPT_VERSION} - Timestamp: " . date("Y-m-d\TH:i:s\Z");
exit;
?>
EOF
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then echo "INFO: Arquivo de health check criado/atualizado."; else echo "ERRO: Falha ao criar/atualizar health check."; fi

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões e propriedade em '$MOUNT_POINT'..."
sudo chown -R apache:apache "$MOUNT_POINT"
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;
if [ -f "$ACTIVE_CONFIG_FILE" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE"; fi
if [ -f "$CONFIG_FILE_PROD_TEMPLATE" ]; then sudo chmod 640 "$CONFIG_FILE_PROD_TEMPLATE"; fi
if [ -f "$CONFIG_FILE_MGMT_TEMPLATE" ]; then sudo chmod 640 "$CONFIG_FILE_MGMT_TEMPLATE"; fi
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH"; fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache..."

APACHE_CONF_FILE="/etc/httpd/conf/httpd.conf"
LISTEN_IPV4_DIRECTIVE="Listen 0.0.0.0:80"
LISTEN_IPV6_DIRECTIVE="Listen [::]:80"
LISTEN_GENERIC_REGEX="^Listen +80$" # Usado para grep
LISTEN_GENERIC_PATTERN_SED="^[[:space:]]*Listen[[:space:]]+80[[:space:]]*$" # Usado para sed (endereço)


needs_ipv4_listen=true
if grep -qF "$LISTEN_IPV4_DIRECTIVE" "$APACHE_CONF_FILE"; then
    needs_ipv4_listen=false
    echo "INFO: Diretiva '$LISTEN_IPV4_DIRECTIVE' já existe no Apache."
fi

needs_ipv6_listen=true
if grep -qF "$LISTEN_IPV6_DIRECTIVE" "$APACHE_CONF_FILE"; then
    needs_ipv6_listen=false
    echo "INFO: Diretiva '$LISTEN_IPV6_DIRECTIVE' já existe no Apache."
fi

config_changed_listen=false
if [ "$needs_ipv4_listen" = true ]; then
    echo "INFO: Adicionando '$LISTEN_IPV4_DIRECTIVE' ao Apache."
    echo "$LISTEN_IPV4_DIRECTIVE" | sudo tee -a "$APACHE_CONF_FILE" > /dev/null
    config_changed_listen=true
fi

if [ "$needs_ipv6_listen" = true ]; then
    echo "INFO: Adicionando '$LISTEN_IPV6_DIRECTIVE' ao Apache."
    echo "$LISTEN_IPV6_DIRECTIVE" | sudo tee -a "$APACHE_CONF_FILE" > /dev/null
    config_changed_listen=true
fi

# Atualiza flags após possíveis adições
if grep -qF "$LISTEN_IPV4_DIRECTIVE" "$APACHE_CONF_FILE"; then needs_ipv4_listen=false; fi
if grep -qF "$LISTEN_IPV6_DIRECTIVE" "$APACHE_CONF_FILE"; then needs_ipv6_listen=false; fi

if ! $needs_ipv4_listen && ! $needs_ipv6_listen ; then
    # Verifica se 'Listen 80' genérico existe E não está já comentado
    if grep -qE "$LISTEN_GENERIC_REGEX" "$APACHE_CONF_FILE" && \
       ! grep -qE "^[[:space:]]*#.*$LISTEN_GENERIC_REGEX" "$APACHE_CONF_FILE"; then
        echo "INFO: Comentando diretiva genérica 'Listen 80' pois '$LISTEN_IPV4_DIRECTIVE' e '$LISTEN_IPV6_DIRECTIVE' estão presentes."
        
        COMMENT_PREFIX="# Script ${SCRIPT_VERSION} (auto-commented): "
        # Aplica o comentário apenas nas linhas que casam com o padrão de Listen 80 genérico
        sudo sed -i -E "/${LISTEN_GENERIC_PATTERN_SED}/s|^|${COMMENT_PREFIX}|" "$APACHE_CONF_FILE"
        
        config_changed_listen=true
    fi
fi

if [ "$config_changed_listen" = true ]; then
    echo "INFO: Configuração de Listen do Apache modificada."
else
    echo "INFO: Nenhuma alteração necessária na configuração de Listen do Apache."
fi

# Configuração AllowOverride
HTTPD_CONF="/etc/httpd/conf/httpd.conf" # Reafirmando, embora já definido
if grep -q "<Directory \"${MOUNT_POINT}\">" "$HTTPD_CONF"; then
    if ! grep -A5 "<Directory \"${MOUNT_POINT}\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
        sudo sed -i "/<Directory \"${MOUNT_POINT//\//\\\/}\">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/" "$HTTPD_CONF" && echo "INFO: AllowOverride All definido para ${MOUNT_POINT}." || echo "WARN: Falha ao definir AllowOverride All para ${MOUNT_POINT}."
    else
        echo "INFO: AllowOverride All já parece OK para ${MOUNT_POINT}."
    fi
elif grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && [ "$MOUNT_POINT" = "/var/www/html" ]; then
     if ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
        sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF" && echo "INFO: AllowOverride All definido para /var/www/html." || echo "WARN: Falha ao definir AllowOverride All para /var/www/html."
    else
        echo "INFO: AllowOverride All já parece OK para /var/www/html."
    fi
else
    echo "WARN: Bloco de diretório para ${MOUNT_POINT} não encontrado explicitamente em $HTTPD_CONF. Verifique a configuração do Apache manualmente se .htaccess não funcionar."
fi

echo "INFO: Habilitando e reiniciando httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd. Verificando config..."
    sudo apachectl configtest
    echo "Últimas linhas do log de erro do Apache:"
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi
sleep 3
if systemctl is-active --quiet httpd; then echo "INFO: Serviço httpd está ativo."; else
    echo "ERRO CRÍTICO: httpd não está ativo pós-restart."
    echo "Últimas linhas do log de erro do Apache:"
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (Versão: ${SCRIPT_VERSION}) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado. Template de gerenciamento ativado por padrão."
echo "INFO: Domínio de Produção (template criado): https://${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (ATIVO): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
echo "INFO: Para alternar para o modo de produção, use um Run Command para copiar/linkar"
echo "INFO: $CONFIG_FILE_PROD_TEMPLATE para $ACTIVE_CONFIG_FILE e reiniciar o Apache (se necessário)."
echo "INFO: Health Check: ${MANAGEMENT_WPDOMAIN_EFFECTIVE}/healthcheck.php (ou ${WPDOMAIN}/healthcheck.php dependendo da config ativa)"
echo "INFO: Log completo: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
