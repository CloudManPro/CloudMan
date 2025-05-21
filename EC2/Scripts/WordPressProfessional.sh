#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.7-mod1 (Baseado na v1.9.7, com logging de pai do yum e espera ajustada)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2.
# Cria templates wp-config-production.php e wp-config-management.php no EFS.
# Ativa wp-config-production.php como o wp-config.php padrão.
# A troca para o modo de gerenciamento deve ser feita externamente (ex: Run Command).

# --- BEGIN WAIT LOGIC FOR AMI INITIALIZATION ---
echo "INFO: Waiting for cloud-init to complete initial setup (/var/lib/cloud/instance/boot-finished)..."
MAX_CLOUD_INIT_WAIT_ITERATIONS=40
CURRENT_CLOUD_INIT_WAIT_ITERATION=0
while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
    if [ "$CURRENT_CLOUD_INIT_WAIT_ITERATION" -ge "$MAX_CLOUD_INIT_WAIT_ITERATIONS" ]; then
        echo "WARN: Timeout waiting for /var/lib/cloud/instance/boot-finished. Proceeding cautiously."
        break
    fi
    echo "INFO: Still waiting for /var/lib/cloud/instance/boot-finished... (attempt $((CURRENT_CLOUD_INIT_WAIT_ITERATION + 1))/$MAX_CLOUD_INIT_WAIT_ITERATIONS, $(date))"
    sleep 15
    CURRENT_CLOUD_INIT_WAIT_ITERATION=$((CURRENT_CLOUD_INIT_WAIT_ITERATION + 1))
done
if [ -f /var/lib/cloud/instance/boot-finished ]; then
    echo "INFO: Signal /var/lib/cloud/instance/boot-finished found. ($(date))"
else
    echo "WARN: Proceeding without /var/lib/cloud/instance/boot-finished signal. ($(date))"
fi
# --- END WAIT LOGIC ---

essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" # Modificado para verificar o NOME, já que o ARN é construído
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "WPDOMAIN"
    "ACCOUNT"
    # "MANAGEMENT_WPDOMAIN" # Removido da lista de essenciais, pois tem fallback
)
echo "Nomes das variáveis em essential_vars:"
printf "%s\n" "${essential_vars[@]}"

# --- BEGIN YUM WAIT LOGIC ---
echo "INFO: Performing check and wait for yum to be free... ($(date))"
MAX_YUM_WAIT_ITERATIONS=60 # 60 iterações
YUM_WAIT_INTERVAL=30       # 30 segundos por iteração (Total: 30 minutos)
CURRENT_YUM_WAIT_ITERATION=0

while [ -f /var/run/yum.pid ]; do
    if [ "$CURRENT_YUM_WAIT_ITERATION" -ge "$MAX_YUM_WAIT_ITERATIONS" ]; then
        YUM_PID_CONTENT=$(cat /var/run/yum.pid 2>/dev/null || echo 'unknown')
        echo "ERROR: Yum still locked by /var/run/yum.pid (PID: $YUM_PID_CONTENT) after extended waiting. Aborting. ($(date))"
        # Tenta logar informações sobre o processo bloqueador antes de sair
        if [ "$YUM_PID_CONTENT" != "unknown" ] && kill -0 "$YUM_PID_CONTENT" 2>/dev/null; then
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

    # Loga informações sobre o processo que detém o /var/run/yum.pid
    if [ "$YUM_PID_CONTENT" != "unknown" ] && kill -0 "$YUM_PID_CONTENT" 2>/dev/null; then # Verifica se o PID de yum.pid existe
        echo "INFO: Details for yum process $YUM_PID_CONTENT (from yum.pid) holding the lock:"
        ps -f -p "$YUM_PID_CONTENT" || echo "WARN: ps -f -p $YUM_PID_CONTENT failed during wait."
        PARENT_PID_OF_LOCKER=$(ps -o ppid= -p "$YUM_PID_CONTENT" 2>/dev/null)
        if [ -n "$PARENT_PID_OF_LOCKER" ]; then
            echo "INFO: Parent of $YUM_PID_CONTENT is PPID: $PARENT_PID_OF_LOCKER. Details:"
            ps -f -p "$PARENT_PID_OF_LOCKER" || echo "WARN: ps -f -p $PARENT_PID_OF_LOCKER failed during wait."
        else
            echo "WARN: Could not determine parent of $YUM_PID_CONTENT during wait."
        fi
    else
        echo "WARN: PID $YUM_PID_CONTENT from /var/run/yum.pid does not seem to be a running process, or yum.pid is empty/unreadable."
    fi

    sleep "$YUM_WAIT_INTERVAL"
    CURRENT_YUM_WAIT_ITERATION=$((CURRENT_YUM_WAIT_ITERATION + 1))
done

# Adicionalmente, verificar com pgrep, pois yum.pid pode ter sido removido mas o processo ainda existir
PGREP_YUM_CHECKS=12
PGREP_YUM_INTERVAL=10 # Intervalo para verificações pgrep
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

# --- Configuração Inicial e Logging ---
set -e
# set -x

# --- Variáveis ---
LOG_FILE="/var/log/wordpress_setup.log"
MOUNT_POINT="/var/www/html"
WP_DIR_TEMP="/tmp/wordpress-temp"

# Nomes dos arquivos de configuração
ACTIVE_CONFIG_FILE="$MOUNT_POINT/wp-config.php"
CONFIG_FILE_PROD_TEMPLATE="$MOUNT_POINT/wp-config-production.php"
CONFIG_FILE_MGMT_TEMPLATE="$MOUNT_POINT/wp-config-management.php"
CONFIG_SAMPLE_ORIGINAL="$MOUNT_POINT/wp-config-sample.php" # WordPress original

HEALTH_CHECK_FILE_PATH="$MOUNT_POINT/healthcheck.php"

MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'

# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.7-mod1) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then
    echo "INFO: ACCOUNT ID não fornecido, tentando obter via AWS STS..."
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT" ]; then
        echo "WARN: Falha ao obter ACCOUNT ID. Se o ARN do Secret não for construído corretamente, o script pode falhar."
    else
        echo "INFO: ACCOUNT ID obtido: $ACCOUNT"
    fi
fi

if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] &&
    [ -n "${ACCOUNT:-}" ] &&
    [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
else
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
fi

error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-}"
    var_to_check_name="$var_name"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        # A verificação principal agora é se o ARN_0 foi bem sucedido
        # e se o ARN_0 fornecido externamente (se houver) também é válido.
        if [ -z "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ] && [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
            echo "ERRO: Variável de ambiente essencial AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (ou seus componentes REGION, ACCOUNT, NAME) não definida ou vazia."
            error_found=1
        elif [ -n "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ]; then
            # Prioriza o ARN construído se os componentes foram fornecidos
            export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
            echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 construído e definido como: $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
        elif [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
            # Caso raro: ARN_0 falhou E ARN_0 não foi fornecido
            echo "ERRO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 não pôde ser construído e não foi fornecido diretamente."
            error_found=1
        else
            echo "INFO: Usando AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 fornecido diretamente: ${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0}"
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

# Tratar MANAGEMENT_WPDOMAIN
if [ -z "${MANAGEMENT_WPDOMAIN:-}" ]; then
    echo "WARN: MANAGEMENT_WPDOMAIN não definido. O template wp-config-management.php usará um placeholder 'management.example.com'."
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="management.example.com" # Placeholder
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
    local efs_ap_id="${EFS_ACCESS_POINT_ID:-}" # Assume que EFS_ACCESS_POINT_ID pode ser uma variável de ambiente

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
            if sudo timeout "${mount_timeout}" mount -t efs -o "$mount_options" "$mount_source" "$mount_point"; then
                echo "INFO: EFS montado com sucesso em '$mount_point'."
                break
            else
                echo "ERRO: Tentativa $attempt_num/$mount_attempts de montar EFS falhou."
                if [ "$attempt_num" -eq "$mount_attempts" ]; then
                    echo "ERRO CRÍTICO: Falha ao montar EFS."
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

    SAFE_DB_NAME=$(echo "$db_name" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_USER=$(echo "$db_user" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(echo "$db_password" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_HOST=$(echo "$db_host" | sed -e 's/[&\\/]/\\&/g' -e "s/'/\\'/g")

    sudo sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$target_file"
    sudo sed -i "s/username_here/$SAFE_DB_USER/g" "$target_file"
    sudo sed -i "s/password_here/$SAFE_DB_PASSWORD/g" "$target_file"
    sudo sed -i "s/localhost/$SAFE_DB_HOST/g" "$target_file"

    echo "INFO: Obtendo e configurando SALTS em $target_file..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then echo "ERRO: Falha ao obter SALTS para $target_file."; else
        sudo sed -i "/^define( *'AUTH_KEY'/d" "$target_file"
        sudo sed -i "/^define( *'SECURE_AUTH_KEY'/d" "$target_file"
        sudo sed -i "/^define( *'LOGGED_IN_KEY'/d" "$target_file"
        sudo sed -i "/^define( *'NONCE_KEY'/d" "$target_file"
        sudo sed -i "/^define( *'AUTH_SALT'/d" "$target_file"
        sudo sed -i "/^define( *'SECURE_AUTH_SALT'/d" "$target_file"
        sudo sed -i "/^define( *'LOGGED_IN_SALT'/d" "$target_file"
        sudo sed -i "/^define( *'NONCE_SALT'/d" "$target_file"

        TEMP_SALT_FILE=$(mktemp)
        echo "$SALT" >"$TEMP_SALT_FILE"
        if sudo grep -q "$MARKER_LINE_SED_PATTERN" "$target_file"; then
            sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE" "$target_file"
        else
            echo "WARN: Marcador final não encontrado em $target_file. Adicionando SALTS no final."
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

// Garantir HTTPS se X-Forwarded-Proto estiver presente
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
EOF
    )
    TEMP_DEFINES_FILE=$(mktemp)
    echo "$PHP_DEFINES_BLOCK" >"$TEMP_DEFINES_FILE"
    if sudo grep -q "$MARKER_LINE_SED_PATTERN" "$target_file"; then
        sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_DEFINES_FILE" "$target_file"
    else
        echo "WARN: Marcador final não encontrado em $target_file. Adicionando DEFINES no final."
        cat "$TEMP_DEFINES_FILE" | sudo tee -a "$target_file" >/dev/null
    fi
    rm -f "$TEMP_DEFINES_FILE"
    echo "INFO: WP_HOME, WP_SITEURL, FS_METHOD configurados em $target_file."
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
    echo "ERRO: Falha ao obter segredo."
    exit 1
fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair credenciais do JSON do segredo."
    exit 1
fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
echo "INFO: Credenciais do banco de dados extraídas (Usuário: $DB_USER)."

# --- Download e Extração do WordPress ---
echo "INFO: Verificando se o WordPress já existe em '$MOUNT_POINT'..."
if [ -d "$MOUNT_POINT/wp-includes" ]; then
    echo "WARN: Diretório 'wp-includes' já encontrado em '$MOUNT_POINT'. Pulando download e extração do WordPress."
else
    echo "INFO: WordPress não encontrado. Iniciando download e extração..."
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
    if [ ! -f "$CONFIG_FILE_PROD_TEMPLATE" ]; then
        PRODUCTION_URL="https://${WPDOMAIN}"
        create_wp_config_template "$CONFIG_FILE_PROD_TEMPLATE" "$PRODUCTION_URL" "$PRODUCTION_URL" \
            "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
    else
        echo "WARN: Template $CONFIG_FILE_PROD_TEMPLATE já existe. Pulando criação."
    fi

    if [ ! -f "$CONFIG_FILE_MGMT_TEMPLATE" ]; then
        MANAGEMENT_URL="https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
        create_wp_config_template "$CONFIG_FILE_MGMT_TEMPLATE" "$MANAGEMENT_URL" "$MANAGEMENT_URL" \
            "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
    else
        echo "WARN: Template $CONFIG_FILE_MGMT_TEMPLATE já existe. Pulando criação."
    fi

    if [ ! -f "$ACTIVE_CONFIG_FILE" ] && [ -f "$CONFIG_FILE_PROD_TEMPLATE" ]; then
        echo "INFO: Ativando $CONFIG_FILE_PROD_TEMPLATE como o $ACTIVE_CONFIG_FILE padrão."
        sudo cp "$CONFIG_FILE_PROD_TEMPLATE" "$ACTIVE_CONFIG_FILE"
    elif [ -f "$ACTIVE_CONFIG_FILE" ]; then
        echo "WARN: $ACTIVE_CONFIG_FILE já existe. Nenhuma alteração no arquivo ativo será feita por este script."
    else
        echo "ERRO: $CONFIG_FILE_PROD_TEMPLATE não pôde ser criado/encontrado para ativar como padrão."
    fi
else
    echo "WARN: $CONFIG_SAMPLE_ORIGINAL não encontrado. Não é possível criar templates wp-config."
fi

# --- Adicionar Arquivo de Health Check ---
echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_PATH'..."
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
// Version: 1.9.7-mod1
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK - WordPress Health Check Endpoint - Script v1.9.7-mod1 - Timestamp: " . date("Y-m-d\TH:i:s\Z");
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
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
if grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
    sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF" && echo "INFO: AllowOverride All definido." || echo "WARN: Falha ao definir AllowOverride All."
elif ! grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF"; then echo "WARN: Bloco /var/www/html não encontrado em $HTTPD_CONF."; else echo "INFO: AllowOverride All já parece OK."; fi

echo "INFO: Habilitando e reiniciando httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd. Verificando config..."
    sudo apachectl configtest
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi
sleep 3
if systemctl is-active --quiet httpd; then echo "INFO: Serviço httpd está ativo."; else
    echo "ERRO CRÍTICO: httpd não está ativo pós-restart."
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.7-mod1) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado. Template de produção ativado por padrão."
echo "INFO: Domínio de Produção: https://${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (template criado): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
echo "INFO: Para alternar para o modo de gerenciamento, use um Run Command para copiar/linkar"
echo "INFO: $CONFIG_FILE_MGMT_TEMPLATE para $ACTIVE_CONFIG_FILE."
echo "INFO: Health Check: /healthcheck.php"
echo "INFO: Log completo: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
