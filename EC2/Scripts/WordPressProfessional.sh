#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.7-mod7 (URLs dinâmicas com fallback para WPDOMAIN)

# --- Variáveis Essenciais ---
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "WPDOMAIN"
    "ACCOUNT"
    "AWS_EFS_ACCESS_POINT_TARGET_ID_0"
)
echo "Nomes das variáveis em essential_vars:"
printf "%s\n" "${essential_vars[@]}"

echo "INFO: As esperas por cloud-init e yum foram REMOVIDAS."

# --- Configuração Inicial e Logging ---
set -e
# set -x

# --- Variáveis ---
LOG_FILE="/var/log/wordpress_setup.log"
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

# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.7-mod7) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
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
fi
error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-}"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        if [ -z "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ] && [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then error_found=1; fi
    elif [ -z "$current_var_value" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    fi
done
if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Uma ou mais variáveis essenciais estão faltando. Abortando."
    exit 1
fi
# MANAGEMENT_WPDOMAIN não é mais usado para wp-config, mas pode ser útil para outras coisas.
if [ -z "${MANAGEMENT_WPDOMAIN:-}" ]; then export MANAGEMENT_WPDOMAIN_EFFECTIVE="management.example.com"; else export MANAGEMENT_WPDOMAIN_EFFECTIVE="${MANAGEMENT_WPDOMAIN}"; fi
echo "INFO: Domínio de Produção (WPDOMAIN): ${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (informativo): ${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
echo "INFO: Verificação de variáveis essenciais concluída."

# --- Funções Auxiliares ---
mount_efs() {
    local efs_id=$1
    local mount_point_arg=$2
    local efs_ap_id="${AWS_EFS_ACCESS_POINT_TARGET_ID_0:-}"

    echo "INFO: Verificando se '$mount_point_arg' já está montado..."
    if mount | grep -q "on ${mount_point_arg} type efs"; then
        echo "INFO: EFS já está montado em '$mount_point_arg'."
    else
        sudo mkdir -p "$mount_point_arg"
        echo "INFO: Montando EFS '$efs_id' em '$mount_point_arg' via AP '$efs_ap_id'..."
        local mount_options="tls,accesspoint=$efs_ap_id"
        local mount_source="$efs_id"

        if sudo timeout 30 mount -t efs -o "$mount_options" "$mount_source" "$mount_point_arg"; then
            echo "INFO: EFS montado com sucesso em '$mount_point_arg'."
        else
            echo "ERRO CRÍTICO: Falha ao montar EFS. Verifique logs do sistema, conectividade e config do AP."
            # Adicionar mais debug se necessário aqui
            exit 1
        fi
        if ! grep -q "${mount_point_arg} efs" /etc/fstab; then
            local fstab_mount_options="_netdev,${mount_options}"
            local fstab_entry="$mount_source $mount_point_arg efs $fstab_mount_options 0 0"
            echo "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null
            echo "INFO: Entrada adicionada ao /etc/fstab: '$fstab_entry'"
        fi
    fi
}

create_wp_config_template() {
    local target_file_on_efs="$1"
    local primary_wpdomain_for_fallback="$2" # Recebe o valor de WPDOMAIN
    local db_name="$3"
    local db_user="$4"
    local db_password="$5"
    local db_host="$6"
    local temp_config_file
    temp_config_file=$(mktemp /tmp/wp-config.XXXXXX.php)
    sudo chmod 644 "$temp_config_file"
    trap 'rm -f "$temp_config_file"' RETURN

    echo "INFO: Criando configuração em '$temp_config_file' para EFS '$target_file_on_efs', com URLs dinâmicas (fallback para: $primary_wpdomain_for_fallback)"
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
        sed -i -e "/^define( *'AUTH_KEY'/d" -e "/^define( *'SECURE_AUTH_KEY'/d" \
            -e "/^define( *'LOGGED_IN_KEY'/d" -e "/^define( *'NONCE_KEY'/d" \
            -e "/^define( *'AUTH_SALT'/d" -e "/^define( *'SECURE_AUTH_SALT'/d" \
            -e "/^define( *'LOGGED_IN_SALT'/d" -e "/^define( *'NONCE_SALT'/d" "$temp_config_file"
        if grep -q "$MARKER_LINE_SED_PATTERN" "$temp_config_file"; then
            sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE_INNER" "$temp_config_file"
        else
            cat "$TEMP_SALT_FILE_INNER" >>"$temp_config_file"
        fi
        rm -f "$TEMP_SALT_FILE_INNER"
        echo "INFO: SALTS configurados."
    else echo "ERRO: Falha ao obter SALTS."; fi

    PHP_DEFINES_BLOCK_CONTENT=$(cat <<EOPHP
// --- Dynamic WordPress URL configuration ---
// Determine Scheme
if (!empty(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    \$_SERVER['HTTPS'] = 'on';
    \$site_scheme = 'https';
} elseif (!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off') {
    \$site_scheme = 'https';
} elseif (isset(\$_SERVER['SERVER_PORT']) && \$_SERVER['SERVER_PORT'] == 443) {
    \$site_scheme = 'https';
} else {
    \$site_scheme = 'http';
}

// Determine Host
// O valor da variável de shell WPDOMAIN (passado via primary_wpdomain_for_fallback) é injetado aqui pelo Bash.
\$fallback_host = '$primary_wpdomain_for_fallback';

if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) {
    \$site_host = \$_SERVER['HTTP_X_FORWARDED_HOST'];
    \$site_scheme = 'https'; // Assume https se X-Forwarded-Host está presente (CloudFront)
    \$_SERVER['HTTPS'] = 'on';
} elseif (!empty(\$_SERVER['HTTP_HOST'])) {
    \$site_host = \$_SERVER['HTTP_HOST'];
} else {
    \$site_host = \$fallback_host;
    \$site_scheme = 'https'; // Assume https para o fallback principal
    \$_SERVER['HTTPS'] = 'on';
}

define('WP_HOME', \$site_scheme . '://' . \$site_host);
define('WP_SITEURL', \$site_scheme . '://' . \$site_host);
// --- End Dynamic WordPress URL configuration ---

define('FS_METHOD', 'direct');

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
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
    echo "INFO: Defines (incluindo URLs dinâmicas) configurados."

    echo "INFO: Copiando '$temp_config_file' para '$target_file_on_efs' como 'apache'..."
    if sudo -u apache cp "$temp_config_file" "$target_file_on_efs"; then
        echo "INFO: Arquivo '$target_file_on_efs' criado."
    else
        echo "ERRO CRÍTICO: Falha ao copiar para '$target_file_on_efs' como 'apache'."
        exit 1
    fi
}

# --- Instalação de Pré-requisitos ---
echo "INFO: Instalando pacotes..."
sudo yum update -y -q
sudo amazon-linux-extras install -y epel -q
sudo yum install -y -q httpd jq aws-cli mysql amazon-efs-utils
sudo amazon-linux-extras enable php7.4 -y -q
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap
echo "INFO: Pacotes instalados."

# --- Montagem do EFS ---
mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

# --- Teste de Escrita no EFS ---
echo "INFO: Testando escrita no EFS como usuário '$EFS_OWNER_USER' (UID $EFS_OWNER_UID)..."
TEMP_EFS_TEST_FILE="$MOUNT_POINT/efs_write_test_owner.txt"
if sudo -u "$EFS_OWNER_USER" touch "$TEMP_EFS_TEST_FILE"; then
    echo "INFO: Teste de escrita no EFS como '$EFS_OWNER_USER' SUCESSO."
    sudo -u "$EFS_OWNER_USER" rm "$TEMP_EFS_TEST_FILE"
else
    echo "ERRO CRÍTICO: Teste de escrita no EFS como '$EFS_OWNER_USER' FALHOU."
    ls -ld "$MOUNT_POINT"
    exit 1
fi

# --- Obtenção de Credenciais do RDS ---
echo "INFO: Obtendo credenciais do RDS..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then
    echo "ERRO: Falha ao obter segredo RDS."
    exit 1
fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair creds RDS."
    exit 1
fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
echo "INFO: Credenciais RDS extraídas (Usuário: $DB_USER)."

# --- Download e Preparação do WordPress ---
echo "INFO: Verificando se WordPress já existe em '$MOUNT_POINT'..."
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

# --- Configuração do wp-config.php ---
if [ ! -f "$CONFIG_SAMPLE_ON_EFS" ]; then
    echo "ERRO CRÍTICO: $CONFIG_SAMPLE_ON_EFS não encontrado. O WordPress foi copiado corretamente para o EFS?"
    exit 1
fi

if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then
    echo "INFO: Arquivo '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando com configurações dinâmicas..."
    create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" \
        "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
else
    echo "WARN: Arquivo de configuração ativo '$ACTIVE_CONFIG_FILE_EFS' já existe. Nenhuma alteração será feita no wp-config.php."
fi

# --- Adicionar Arquivo de Health Check ---
echo "INFO: Criando health check em '$HEALTH_CHECK_FILE_PATH_EFS' como 'apache'..."
HEALTH_CHECK_CONTENT="<?php http_response_code(200); header(\"Content-Type: text/plain; charset=utf-8\"); echo \"OK - WP Health Check - v1.9.7-mod7 - \" . date(\"Y-m-d\TH:i:s\Z\"); exit; ?>"
TEMP_HEALTH_CHECK_FILE=$(mktemp /tmp/healthcheck.XXXXXX.php)
sudo chmod 644 "$TEMP_HEALTH_CHECK_FILE"
echo "$HEALTH_CHECK_CONTENT" >"$TEMP_HEALTH_CHECK_FILE"
if sudo -u apache cp "$TEMP_HEALTH_CHECK_FILE" "$HEALTH_CHECK_FILE_PATH_EFS"; then
    echo "INFO: Health check criado."
else echo "ERRO: Falha ao criar health check como 'apache'."; fi
rm -f "$TEMP_HEALTH_CHECK_FILE"

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões finais em '$MOUNT_POINT'..."
if sudo chown -R apache:apache "$MOUNT_POINT"; then
    echo "INFO: Propriedade de '$MOUNT_POINT' definida para apache:apache."
else
    echo "WARN: Falha no chown -R apache:apache '$MOUNT_POINT'. Verificando GID."
    if ! stat -c "%g" "$MOUNT_POINT" | grep -q "48"; then
        echo "ERRO CRÍTICO: GID do '$MOUNT_POINT' não é 48 (apache) E chown falhou."
        ls -ld "$MOUNT_POINT"
    else
        echo "INFO: GID do '$MOUNT_POINT' é 48 (apache). Permissões de grupo devem ser suficientes."
    fi
fi
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;

if [ -f "$ACTIVE_CONFIG_FILE_EFS" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE_EFS"; fi
if [ -f "$HEALTH_CHECK_FILE_PATH_EFS" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH_EFS"; fi
echo "INFO: Permissões ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
if grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
    sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF" && echo "INFO: AllowOverride All definido."
else echo "INFO: AllowOverride All já parece OK ou bloco não encontrado."; fi

echo "INFO: Habilitando e reiniciando httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."
    sudo apachectl configtest
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi
sleep 3
if systemctl is-active --quiet httpd; then echo "INFO: httpd ativo."; else
    echo "ERRO CRÍTICO: httpd não ativo."
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.7-mod7) concluído! ($(date)) ---"
echo "INFO: WordPress configurado com URLs dinâmicas. Fallback principal para: https://${WPDOMAIN}"
if [ -n "${MANAGEMENT_WPDOMAIN:-}" ] && [ "${MANAGEMENT_WPDOMAIN_EFFECTIVE}" != "${WPDOMAIN}" ] && [ "${MANAGEMENT_WPDOMAIN_EFFECTIVE}" != "management.example.com" ]; then
    echo "INFO: Domínio de Gerenciamento (informativo, se DNS aponta para esta instalação): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
fi
echo "INFO: Health Check: /healthcheck.php"
echo "INFO: Log: ${LOG_FILE}"
echo "INFO: =================================================="
exit 0
