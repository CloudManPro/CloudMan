#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.4 (Baseado na v1.9.3, Lógica condicional WP_HOME/WP_SITEURL)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Configura WP_HOME, WP_SITEURL condicionalmente: usa WPDOMAIN para acesso público
# e o host/IP atual para acesso direto (admin).
# Inclui endpoint /healthcheck.php.

# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos

# --- Variáveis (podem ser substituídas por variáveis de ambiente) ---
LOG_FILE="/var/log/wordpress_setup.log"
MOUNT_POINT="/var/www/html"                           # Diretório raiz do Apache e ponto de montagem do EFS
WP_DIR_TEMP="/tmp/wordpress-temp"                     # Diretório temporário para download do WP
CONFIG_FILE="$MOUNT_POINT/wp-config.php"              # Caminho para o arquivo wp-config.php
HEALTH_CHECK_FILE_PATH="$MOUNT_POINT/healthcheck.php" # Caminho para o health check

# Marcadores para inserção no wp-config.php
MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"             # Texto para grep/logs
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/' # Padrão escapado para sed

# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.4) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"                   # ID do EFS (fs-xxxxxxxx)
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"    # ARN completo do segredo no Secrets Manager
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0" # Região do segredo (ex: us-east-1)
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"                 # Endpoint do RDS (cluster ou instância)
    "AWS_DB_INSTANCE_TARGET_NAME_0"                     # Nome do banco de dados WordPress
    "WPDOMAIN"                                          # Domínio público do WordPress (ex: wp.meusite.com)
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    fi
done

if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Uma ou mais variáveis essenciais estão faltando. Abortando."
    exit 1
fi
echo "INFO: Verificação de variáveis essenciais concluída com sucesso (WPDOMAIN=${WPDOMAIN})."

# --- Funções Auxiliares ---
mount_efs() {
    local efs_id=$1
    local mount_point=$2
    echo "INFO: Verificando se o ponto de montagem '$mount_point' existe..."
    if [ ! -d "$mount_point" ]; then
        echo "INFO: Criando diretório '$mount_point'..."
        sudo mkdir -p "$mount_point"
    else
        echo "INFO: Diretório '$mount_point' já existe."
    fi

    echo "INFO: Verificando se '$mount_point' já está montado..."
    if mount | grep -q "on ${mount_point} type efs"; then
        echo "INFO: EFS já está montado em '$mount_point'."
    else
        echo "INFO: Montando EFS '$efs_id' em '$mount_point' com TLS..."
        if ! sudo mount -t efs -o tls "$efs_id:/" "$mount_point"; then
            echo "ERRO: Falha ao montar EFS '$efs_id' em '$mount_point'."
            echo "INFO: Verifique ID EFS, Security Group (NFS 2049), e instalação 'amazon-efs-utils'."
            exit 1
        fi
        echo "INFO: EFS montado com sucesso em '$mount_point'."

        echo "INFO: Adicionando montagem do EFS ao /etc/fstab para persistência..."
        if ! grep -q "$efs_id:/ $mount_point efs" /etc/fstab; then
            echo "$efs_id:/ $mount_point efs _netdev,tls 0 0" | sudo tee -a /etc/fstab >/dev/null
            echo "INFO: Entrada adicionada ao /etc/fstab."
        else
            echo "INFO: Entrada para EFS já existe no /etc/fstab."
        fi
    fi
}

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM (modo extra silencioso)..."
sudo yum update -y -q >/dev/null
sudo yum install -y -q httpd jq epel-release aws-cli mysql amazon-efs-utils >/dev/null
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4 (modo extra silencioso)..."
sudo amazon-linux-extras enable php7.4 -y &>/dev/null
echo "INFO: Instalando PHP 7.4 e módulos (modo extra silencioso)..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap >/dev/null
echo "INFO: Instalação de pacotes concluída."

# --- Montagem do EFS ---
mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

# --- Obtenção de Credenciais do RDS via Secrets Manager ---
echo "INFO: Verificando disponibilidade de AWS CLI e JQ..."
if ! command -v aws &>/dev/null || ! command -v jq &>/dev/null; then
    echo "ERRO: AWS CLI ou JQ não encontrados. Instalação falhou?"
    exit 1
fi

echo "INFO: Tentando obter segredo do Secrets Manager..."
if ! SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"); then
    echo "ERRO: Falha ao executar 'aws secretsmanager get-secret-value'. Verifique ARN, região e permissões IAM."
    exit 1
fi
if [ -z "$SECRET_STRING_VALUE" ]; then
    echo "ERRO: AWS CLI retornou valor vazio do segredo."
    exit 1
fi
echo "INFO: Segredo bruto obtido com sucesso."

echo "INFO: Extraindo username e password do JSON do segredo..."
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo."
    echo "DEBUG: Segredo parcial (se extração falhar): $(echo "$SECRET_STRING_VALUE" | cut -c 1-50)..."
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas com sucesso (Usuário: $DB_USER)."

# --- Download e Extração do WordPress ---
echo "INFO: Verificando se o WordPress já existe em '$MOUNT_POINT'..."
if [ -f "$MOUNT_POINT/wp-config.php" ] || [ -f "$MOUNT_POINT/index.php" ]; then
    echo "WARN: Arquivos do WordPress (wp-config.php ou index.php) já encontrados em '$MOUNT_POINT'. Pulando download e extração."
else
    echo "INFO: WordPress não encontrado. Iniciando download e extração..."
    mkdir -p "$WP_DIR_TEMP" && cd "$WP_DIR_TEMP"
    echo "INFO: Baixando WordPress..."
    if ! curl -sLO https://wordpress.org/latest.tar.gz; then echo "ERRO: Falha ao baixar WordPress."; cd /tmp && rm -rf "$WP_DIR_TEMP"; exit 1; fi
    echo "INFO: Extraindo WordPress..."
    if ! tar -xzf latest.tar.gz; then echo "ERRO: Falha ao extrair 'latest.tar.gz'."; cd /tmp && rm -rf "$WP_DIR_TEMP"; exit 1; fi
    rm latest.tar.gz
    if [ ! -d "wordpress" ]; then echo "ERRO: Diretório 'wordpress' não encontrado pós extração."; cd /tmp && rm -rf "$WP_DIR_TEMP"; exit 1; fi
    echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT'..."
    if ! sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/"; then echo "ERRO: Falha ao mover arquivos para $MOUNT_POINT."; cd /tmp && rm -rf "$WP_DIR_TEMP"; exit 1; fi
    cd /tmp && rm -rf "$WP_DIR_TEMP"
    echo "INFO: Arquivos do WordPress movidos."
fi

# --- Configuração do wp-config.php ---
echo "INFO: Verificando se '$CONFIG_FILE' já existe..."
if [ -f "$CONFIG_FILE" ]; then
    echo "WARN: '$CONFIG_FILE' já existe. Pulando criação e configuração inicial de DB/SALTS."
else
    echo "INFO: '$CONFIG_FILE' não encontrado. Criando a partir de 'wp-config-sample.php'..."
    if [ ! -f "$MOUNT_POINT/wp-config-sample.php" ]; then echo "ERRO: '$MOUNT_POINT/wp-config-sample.php' não encontrado."; exit 1; fi
    sudo cp "$MOUNT_POINT/wp-config-sample.php" "$CONFIG_FILE"
    RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
    ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)
    SAFE_DBNAME=$(echo "$AWS_DB_INSTANCE_TARGET_NAME_0" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_USER=$(echo "$DB_USER" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_PASSWORD=$(echo "$DB_PASSWORD" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_ENDPOINT_ADDRESS=$(echo "$ENDPOINT_ADDRESS" | sed -e 's/[&#\/\\\\]/\\&/g')
    echo "INFO: Substituindo placeholders de DB no $CONFIG_FILE..."
    sudo sed -i "s#database_name_here#$SAFE_DBNAME#" "$CONFIG_FILE" && \
    sudo sed -i "s#username_here#$SAFE_DB_USER#" "$CONFIG_FILE" && \
    sudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$CONFIG_FILE" && \
    sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$CONFIG_FILE" || { echo "ERRO: Falha ao substituir um ou mais placeholders de DB."; exit 1; }
    echo "INFO: Placeholders de DB substituídos."
    echo "INFO: Obtendo e configurando SALTS no $CONFIG_FILE..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then echo "ERRO: Falha ao obter SALTS."; else
        sudo sed -i "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" "$CONFIG_FILE"
        TEMP_SALT_FILE=$(mktemp); echo "$SALT" >"$TEMP_SALT_FILE"
        DB_COLLATE_MARKER="/define( *'DB_COLLATE'/"
        if ! sudo sed -i -e "$DB_COLLATE_MARKER r $TEMP_SALT_FILE" "$CONFIG_FILE" 2>/dev/null; then
            if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE" "$CONFIG_FILE"; then
                 echo "ERRO: Falha ao inserir SALTS."; rm -f "$TEMP_SALT_FILE"; exit 1;
            fi
        fi
        rm -f "$TEMP_SALT_FILE"; echo "INFO: SALTS configurados."
    fi
fi

# --- INÍCIO: Inserir Definições Condicionais WP_HOME/WP_SITEURL baseadas em WPDOMAIN ---
echo "INFO: Configurando WP_HOME e WP_SITEURL condicionalmente (WPDOMAIN: $WPDOMAIN)..."
BEGIN_URL_CONFIG_MARKER="// --- BEGIN Conditional URL Config ---"
END_URL_CONFIG_MARKER="// --- END Conditional URL Config ---"

# Remover bloco de configuração de URL antigo/existente para idempotência
if sudo grep -qF "$BEGIN_URL_CONFIG_MARKER" "$CONFIG_FILE"; then
    echo "INFO: Removendo bloco existente de 'Conditional URL Config' para recriá-lo..."
    sudo awk -v b="${BEGIN_URL_CONFIG_MARKER//\//\\/}" -v e="${END_URL_CONFIG_MARKER//\//\\/}" '
        $0 ~ b {p=1; next}
        $0 ~ e {p=0; next}
        !p
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && sudo mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# Preparar o novo bloco de configuração PHP
# A variável de shell $WPDOMAIN será expandida aqui.
# As variáveis PHP como $_SERVER são escapadas com \ para serem literais no here-document.
PHP_URL_CONFIG_BLOCK=$(cat <<EOF

${BEGIN_URL_CONFIG_MARKER}
\$wp_public_domain_from_env = getenv('WPDOMAIN');

if (empty(\$wp_public_domain_from_env)) {
    // Este é um fallback crítico. O script bash já verifica WPDOMAIN,
    // mas se por algum motivo o PHP não a vir, logue ou use um padrão MUITO CUIDADOSO.
    // Para este script, WPDOMAIN é esperado ser '${WPDOMAIN}'.
    \$wp_public_domain_from_env = '${WPDOMAIN}';
}

\$public_site_url_with_protocol = 'https://' . \$wp_public_domain_from_env;

\$current_protocol = 'http://'; // Padrão para acesso direto por IP
// Verifica se o acesso atual é HTTPS (direto ou via proxy que NÃO usa X-Forwarded-Proto)
if (isset(\$_SERVER['HTTPS']) && (\$_SERVER['HTTPS'] == 'on' || \$_SERVER['HTTPS'] == 1)) {
    \$current_protocol = 'https://';
} elseif (!empty(\$_SERVER['SERVER_PORT']) && (\$_SERVER['SERVER_PORT'] == '443')) {
    \$current_protocol = 'https://';
}

// Essencial para CloudFront/ALB terminando SSL e encaminhando como HTTP para a instância
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$current_protocol = 'https://'; // O cliente usou HTTPS para o proxy
    \$_SERVER['HTTPS'] = 'on';      // Informa ao WordPress que a conexão original era segura
}

\$current_host = isset(\$_SERVER['HTTP_HOST']) ? \$_SERVER['HTTP_HOST'] : \$wp_public_domain_from_env;
\$current_site_url_with_protocol = \$current_protocol . \$current_host;

// Se o host atual NÃO for o domínio público, significa que é um acesso direto (ex: IP para admin)
if (\$current_host !== \$wp_public_domain_from_env) {
    if (!defined('WP_HOME')) {
        define('WP_HOME', \$current_site_url_with_protocol);
    }
    if (!defined('WP_SITEURL')) {
        define('WP_SITEURL', \$current_site_url_with_protocol);
    }
} else {
    // Acesso via domínio público (CloudFront)
    if (!defined('WP_HOME')) {
        define('WP_HOME', \$public_site_url_with_protocol);
    }
    if (!defined('WP_SITEURL')) {
        define('WP_SITEURL', \$public_site_url_with_protocol);
    }
}

// Se por algum motivo WP_HOME acabou sendo HTTPS, certifique-se que WordPress sabe disso.
// Isso é uma dupla checagem, já coberto em parte pelo HTTP_X_FORWARDED_PROTO.
if (defined('WP_HOME') && strpos(WP_HOME, 'https://') === 0 && !isset(\$_SERVER['HTTPS'])) {
    \$_SERVER['HTTPS'] = 'on';
}
${END_URL_CONFIG_MARKER}

EOF
)

# Inserir o novo bloco
echo "INFO: Inserindo configuração condicional de URL em $CONFIG_FILE..."
TEMP_URL_CONFIG_INSERT_FILE=$(mktemp)
echo "$PHP_URL_CONFIG_BLOCK" > "$TEMP_URL_CONFIG_INSERT_FILE"
PLACEHOLDER_URL_CONFIG="__WP_CONDITIONAL_URL_INSERT_POINT_$(date +%s)__"
if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/i $PLACEHOLDER_URL_CONFIG" "$CONFIG_FILE"; then
    echo "ERRO: Falha ao inserir placeholder para config de URL em $CONFIG_FILE."
    rm -f "$TEMP_URL_CONFIG_INSERT_FILE"; exit 1;
else
    if ! sudo sed -i -e "\#$PLACEHOLDER_URL_CONFIG#r $TEMP_URL_CONFIG_INSERT_FILE" -e "\#$PLACEHOLDER_URL_CONFIG#d" "$CONFIG_FILE"; then
        echo "ERRO: Falha ao substituir placeholder com config de URL em $CONFIG_FILE."
        sudo sed -i "\#$PLACEHOLDER_URL_CONFIG#d" "$CONFIG_FILE" || echo "WARN: Não foi possível remover placeholder órfão."
    else
        echo "INFO: Configuração condicional de URL inserida com sucesso."
    fi
fi
rm -f "$TEMP_URL_CONFIG_INSERT_FILE"
# --- FIM: Inserir Definições Condicionais WP_HOME/WP_SITEURL ---

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'direct' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHOD', 'direct' );"
if [ -f "$CONFIG_FILE" ]; then
    if sudo grep -q "define( *'FS_METHOD' *, *'direct' *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido."
    else
        if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/i\\$FS_METHOD_LINE" "$CONFIG_FILE"; then
            echo "ERRO: Falha ao inserir FS_METHOD 'direct'."
        else
            echo "INFO: FS_METHOD 'direct' inserido."
        fi
    fi
else
    echo "WARN: $CONFIG_FILE não encontrado para adicionar FS_METHOD."
fi
echo "INFO: Configuração final do wp-config.php concluída."

# <<<--- INÍCIO: Adicionar Arquivo de Health Check --->>>
echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_PATH'..."
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
// Version: 1.9.4
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK";
exit;
?>
EOF
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then echo "INFO: Arquivo de health check criado/atualizado."; else echo "ERRO: Falha ao criar/atualizar health check."; fi
# <<<--- FIM: Adicionar Arquivo de Health Check --->>>

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões e propriedade em '$MOUNT_POINT'..."
sudo chown -R apache:apache "$MOUNT_POINT" || { echo "ERRO: Falha chown em $MOUNT_POINT."; exit 1; }
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \; || echo "WARN: Erros chmod dirs."
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \; || echo "WARN: Erros chmod files."
if [ -f "$CONFIG_FILE" ]; then sudo chown apache:apache "$CONFIG_FILE" && sudo chmod 640 "$CONFIG_FILE" || echo "WARN: Erros chown/chmod $CONFIG_FILE."; fi
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then sudo chown apache:apache "$HEALTH_CHECK_FILE_PATH" && sudo chmod 644 "$HEALTH_CHECK_FILE_PATH" || echo "WARN: Erros chown/chmod $HEALTH_CHECK_FILE_PATH."; fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
if grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
    if ! sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF"; then
        echo "WARN: Falha ao definir AllowOverride All."
    else
        echo "INFO: AllowOverride All definido."
    fi
elif ! grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF"; then echo "WARN: Bloco /var/www/html não encontrado em $HTTPD_CONF."; else echo "INFO: AllowOverride All já parece OK."; fi

echo "INFO: Habilitando e reiniciando httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."; sudo apachectl configtest; sudo tail -n 30 /var/log/httpd/error_log; exit 1;
fi
sleep 5
if systemctl is-active --quiet httpd; then echo "INFO: Serviço httpd está ativo."; else
    echo "ERRO CRÍTICO: httpd não está ativo pós-restart."; sudo tail -n 30 /var/log/httpd/error_log; exit 1;
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.4) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado para: URL pública https://${WPDOMAIN} e acesso admin via IP direto."
echo "INFO: Acesse https://${WPDOMAIN} (ou IP da instância para admin) para usar o site."
echo "INFO: Health Check: /healthcheck.php"
echo "INFO: Log completo: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
