#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.3 (Baseado na v1.9.2, Gera múltiplos modelos de wp-config.php)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Gera wp-config-production.php (dinâmico para ASG/LB) e wp-config-management.php (estático para interface de gerenciamento).
# Por padrão, ativa wp-config-production.php como wp-config.php.
# Inclui endpoint /healthcheck.php.

# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos

# --- Variáveis (podem ser substituídas por variáveis de ambiente) ---
LOG_FILE="/var/log/wordpress_setup.log"
MOUNT_POINT="/var/www/html"                           # Diretório raiz do Apache e ponto de montagem do EFS
WP_DIR_TEMP="/tmp/wordpress-temp"                     # Diretório temporário para download do WP

# Caminhos para os arquivos de configuração
ACTIVE_CONFIG_FILE="$MOUNT_POINT/wp-config.php"
PRODUCTION_CONFIG_MODEL_FILE="$MOUNT_POINT/wp-config-production.php"
MANAGEMENT_CONFIG_MODEL_FILE="$MOUNT_POINT/wp-config-management.php"
SAMPLE_CONFIG_FILE_PATH="$MOUNT_POINT/wp-config-sample.php"

HEALTH_CHECK_FILE_PATH="$MOUNT_POINT/healthcheck.php" # Caminho para o health check

# Marcadores para inserção no wp-config.php
MARKER_LINE_SED_RAW="/* That's all, stop editing! Happy publishing. */"             # Texto para grep/logs
MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*\/' # Padrão escapado para sed

# URL estática para a interface de gerenciamento (ajuste conforme seu domínio)
MANAGEMENT_URL_BASE_HTTPS="https://management.projeto.cloudman.pro/wp"

# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.3) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
# AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
# ^^ Descomente e ajuste se for buscar ACCOUNT e outras de variáveis de ambiente no script. Por ora, assumindo que o ARN completo é passado.
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"                   # ID do EFS (fs-xxxxxxxx)
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"    # ARN completo do segredo no Secrets Manager
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0" # Região do segredo (ex: us-east-1)
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"                 # Endpoint do RDS (cluster ou instância)
    "AWS_DB_INSTANCE_TARGET_NAME_0"                     # Nome do banco de dados WordPress
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
echo "INFO: Verificação de variáveis essenciais concluída com sucesso."

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

create_wp_config_base() {
    local target_config_file=$1 # Caminho completo para o arquivo de config a ser criado
    echo "INFO: Criando base para '$target_config_file' a partir de '$SAMPLE_CONFIG_FILE_PATH'..."

    if [ ! -f "$SAMPLE_CONFIG_FILE_PATH" ]; then
        echo "ERRO: '$SAMPLE_CONFIG_FILE_PATH' não encontrado. A instalação do WordPress falhou ou está incompleta?"
        return 1 # Usar return para que a função possa ser verificada
    fi
    sudo cp "$SAMPLE_CONFIG_FILE_PATH" "$target_config_file"

    RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
    ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)

    SAFE_DBNAME=$(echo "$AWS_DB_INSTANCE_TARGET_NAME_0" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_USER=$(echo "$DB_USER" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_PASSWORD=$(echo "$DB_PASSWORD" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_ENDPOINT_ADDRESS=$(echo "$ENDPOINT_ADDRESS" | sed -e 's/[&#\/\\\\]/\\&/g')

    echo "INFO: Substituindo placeholders de DB em '$target_config_file'..."
    sudo sed -i "s#database_name_here#$SAFE_DBNAME#" "$target_config_file"
    sudo sed -i "s#username_here#$SAFE_DB_USER#" "$target_config_file"
    sudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$target_config_file"
    sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$target_config_file"
    echo "INFO: Placeholders de DB substituídos."

    echo "INFO: Obtendo e configurando chaves de segurança (SALTS) em '$target_config_file'..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then
        echo "ERRO: Falha ao obter SALTS da API do WordPress."
    else
        TEMP_SALT_FILE=$(mktemp)
        echo "$SALT" >"$TEMP_SALT_FILE"
        DB_COLLATE_MARKER="/define( *'DB_COLLATE'/"
        sudo sed -i -e "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" "$target_config_file"
        sudo sed -i -e "$DB_COLLATE_MARKER r $TEMP_SALT_FILE" "$target_config_file"
        rm -f "$TEMP_SALT_FILE"
        echo "INFO: SALTS configurados com sucesso em '$target_config_file'."
    fi
    return 0
}

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM..."
sudo yum update -y -q
sudo yum install -y -q httpd jq epel-release aws-cli mysql amazon-efs-utils
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4..."
sudo amazon-linux-extras enable php7.4 -y
echo "INFO: Instalando PHP 7.4 e módulos..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap
echo "INFO: Instalação de pacotes concluída."

# --- Montagem do EFS ---
mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

# --- Obtenção de Credenciais do RDS via Secrets Manager ---
echo "INFO: Obtendo segredo do Secrets Manager..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then
    echo "ERRO: Falha ao obter segredo ou valor vazio."
    exit 1
fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo."
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas (Usuário: $DB_USER)."

# --- Download e Extração do WordPress ---
echo "INFO: Verificando se o WordPress já existe em '$MOUNT_POINT'..."
if [ -f "$ACTIVE_CONFIG_FILE" ] || [ -f "$MOUNT_POINT/index.php" ]; then
    echo "WARN: Arquivos do WordPress já encontrados. Pulando download e extração."
else
    echo "INFO: WordPress não encontrado. Iniciando download e extração..."
    mkdir -p "$WP_DIR_TEMP" && cd "$WP_DIR_TEMP"
    curl -sLO https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/"
    cd /tmp && rm -rf "$WP_DIR_TEMP"
    echo "INFO: WordPress baixado e extraído."
fi

# --- CRIAÇÃO DOS MODELOS DE CONFIGURAÇÃO DO WORDPRESS ---
echo "INFO: === Iniciando Criação dos Modelos de wp-config.php ==="

# --- Modelo 1: wp-config-production.php (para ASG/LB, URLs dinâmicas) ---
echo "INFO: Criando modelo '$PRODUCTION_CONFIG_MODEL_FILE'..."
if ! create_wp_config_base "$PRODUCTION_CONFIG_MODEL_FILE"; then
    echo "ERRO: Falha ao criar base para $PRODUCTION_CONFIG_MODEL_FILE."
    exit 1
fi

# Bloco PHP para URLs dinâmicas (Produção)
PHP_BLOCK_PRODUCTION=$(cat <<'EOF'

// --- Dynamic URL definitions (Production/ASG Mode) ---
if ( isset( $_SERVER['HTTP_HOST'] ) ) {
    $protocol = 'http://';
    if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && strtolower( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) === 'https' ) {
        $protocol = 'https://';
        $_SERVER['HTTPS'] = 'on';
    } elseif ( isset( $_SERVER['HTTPS'] ) && ( strtolower( $_SERVER['HTTPS'] ) == 'on' || $_SERVER['HTTPS'] == '1' ) ) {
        $protocol = 'https://';
    } elseif ( ! empty( $_SERVER['SERVER_PORT'] ) && ( $_SERVER['SERVER_PORT'] == '443' ) ) {
        $protocol = 'https://';
    }

    $_wp_home_url = $protocol . $_SERVER['HTTP_HOST']; // Sem /wp
    $_wp_site_url = $protocol . $_SERVER['HTTP_HOST']; // Sem /wp

    if ( ! defined( 'WP_HOME' ) ) { define( 'WP_HOME', $_wp_home_url ); }
    if ( ! defined( 'WP_SITEURL' ) ) { define( 'WP_SITEURL', $_wp_site_url ); }
}
// --- End Dynamic URL definitions (Production/ASG Mode) ---

define( 'FS_METHOD', 'direct' ); // FS_METHOD para ambos os modos
EOF
)

# Insere o bloco PHP no modelo de produção
TEMP_PHP_FILE_PROD=$(mktemp)
echo "$PHP_BLOCK_PRODUCTION" > "$TEMP_PHP_FILE_PROD"
# Insere antes da linha marcador final
sudo sed -i -e "/$MARKER_LINE_SED_PATTERN/r $TEMP_PHP_FILE_PROD" -e "/$MARKER_LINE_SED_PATTERN/i\\" "$PRODUCTION_CONFIG_MODEL_FILE"
# A linha acima foi ajustada para inserir o conteúdo e uma nova linha antes do marcador.
# Uma forma mais precisa de inserir antes é usar 'i' e depois o conteúdo.
# Vamos refazer a inserção para ser mais clara:
sudo sed -i "/$MARKER_LINE_SED_PATTERN/i $PHP_BLOCK_PRODUCTION" "$PRODUCTION_CONFIG_MODEL_FILE" # Requer que PHP_BLOCK_PRODUCTION seja escapado para sed ou use arquivos
# Mais seguro é com arquivo temporário e 'r'
# sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_PHP_FILE_PROD" "$PRODUCTION_CONFIG_MODEL_FILE" # Isto insere DEPOIS da linha do marcador
# Corrigindo a inserção para ser ANTES:
# Primeiro, limpa qualquer inserção anterior malfeita (se o script rodar várias vezes para debug)
sudo sed -i "/\/\/ --- Dynamic URL definitions (Production\/ASG Mode) ---/,/\/\/ --- End Dynamic URL definitions (Production\/ASG Mode) ---/d" "$PRODUCTION_CONFIG_MODEL_FILE"
sudo sed -i "/define( *'FS_METHOD', *'direct' *);/d" "$PRODUCTION_CONFIG_MODEL_FILE" # Limpa FS_METHOD também para reinserir

# Reinsere o bloco PHP de produção
PLACEHOLDER_PROD="__WP_PROD_URL_INSERT_$(date +%s)__"
sudo sed -i "/$MARKER_LINE_SED_PATTERN/i $PLACEHOLDER_PROD" "$PRODUCTION_CONFIG_MODEL_FILE"
sudo sed -i -e "\#$PLACEHOLDER_PROD#r $TEMP_PHP_FILE_PROD" -e "\#$PLACEHOLDER_PROD#d" "$PRODUCTION_CONFIG_MODEL_FILE"
rm -f "$TEMP_PHP_FILE_PROD"
echo "INFO: Bloco de URL dinâmica e FS_METHOD inserido em '$PRODUCTION_CONFIG_MODEL_FILE'."


# --- Modelo 2: wp-config-management.php (para interface de gerenciamento, URL estática com /wp/) ---
echo "INFO: Criando modelo '$MANAGEMENT_CONFIG_MODEL_FILE'..."
if ! create_wp_config_base "$MANAGEMENT_CONFIG_MODEL_FILE"; then
    echo "ERRO: Falha ao criar base para $MANAGEMENT_CONFIG_MODEL_FILE."
    exit 1
fi

# Bloco PHP para URLs estáticas (Gerenciamento)
PHP_BLOCK_MANAGEMENT=$(cat <<EOF

// --- Static URL definitions (Management Interface Mode) ---
// Define WP_HOME and WP_SITEURL for the management interface.
// Handles HTTPS termination at the CloudFront proxy.
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
    // Define URLs com HTTPS
    if ( ! defined( 'WP_HOME' ) ) { define('WP_HOME', '${MANAGEMENT_URL_BASE_HTTPS}'); }
    if ( ! defined( 'WP_SITEURL' ) ) { define('WP_SITEURL', '${MANAGEMENT_URL_BASE_HTTPS}'); }
} else {
    // Fallback se não estiver atrás de um proxy HTTPS (improvável com CloudFront)
    // Ou se acessado diretamente via HTTP na EC2 para algum teste.
    // Ajuste o protocolo http/https e a URL base conforme necessário para este caso.
    $_management_url_http = 'http://' . (isset(\$_SERVER['HTTP_HOST']) ? \$_SERVER['HTTP_HOST'] : 'localhost') . '/wp';
    if ( ! defined( 'WP_HOME' ) ) { define('WP_HOME', \$_management_url_http); }
    if ( ! defined( 'WP_SITEURL' ) ) { define('WP_SITEURL', \$_management_url_http); }
}
// --- End Static URL definitions (Management Interface Mode) ---

define( 'FS_METHOD', 'direct' ); // FS_METHOD para ambos os modos
EOF
)

# Insere o bloco PHP no modelo de gerenciamento
TEMP_PHP_FILE_MGMT=$(mktemp)
echo "$PHP_BLOCK_MANAGEMENT" > "$TEMP_PHP_FILE_MGMT"

# Limpa inserções anteriores
sudo sed -i "/\/\/ --- Static URL definitions (Management Interface Mode) ---/,/\/\/ --- End Static URL definitions (Management Interface Mode) ---/d" "$MANAGEMENT_CONFIG_MODEL_FILE"
sudo sed -i "/define( *'FS_METHOD', *'direct' *);/d" "$MANAGEMENT_CONFIG_MODEL_FILE"

# Reinsere o bloco PHP de gerenciamento
PLACEHOLDER_MGMT="__WP_MGMT_URL_INSERT_$(date +%s)__"
sudo sed -i "/$MARKER_LINE_SED_PATTERN/i $PLACEHOLDER_MGMT" "$MANAGEMENT_CONFIG_MODEL_FILE"
sudo sed -i -e "\#$PLACEHOLDER_MGMT#r $TEMP_PHP_FILE_MGMT" -e "\#$PLACEHOLDER_MGMT#d" "$MANAGEMENT_CONFIG_MODEL_FILE"
rm -f "$TEMP_PHP_FILE_MGMT"
echo "INFO: Bloco de URL estática e FS_METHOD inserido em '$MANAGEMENT_CONFIG_MODEL_FILE'."

echo "INFO: === Criação dos Modelos de wp-config.php Concluída ==="

# --- ATIVAÇÃO DA CONFIGURAÇÃO PADRÃO (PRODUÇÃO) ---
echo "INFO: Ativando '$PRODUCTION_CONFIG_MODEL_FILE' como '$ACTIVE_CONFIG_FILE' padrão..."
if [ -f "$PRODUCTION_CONFIG_MODEL_FILE" ]; then
    sudo cp "$PRODUCTION_CONFIG_MODEL_FILE" "$ACTIVE_CONFIG_FILE"
    echo "INFO: Configuração padrão (Produção/ASG) ativada."
else
    echo "ERRO: Modelo '$PRODUCTION_CONFIG_MODEL_FILE' não encontrado para ativar como padrão."
    exit 1
fi
# <<<--- FIM: Configuração do wp-config.php e Ativação do Padrão --->>>

# <<<--- INÍCIO: Adicionar Arquivo de Health Check --->>>
echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_PATH'..."
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK";
exit;
?>
EOF
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    echo "INFO: Arquivo de health check criado/atualizado."
else
    echo "ERRO: Falha ao criar/atualizar o arquivo de health check."
fi
# <<<--- FIM: Adicionar Arquivo de Health Check --->>>

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões e propriedade em '$MOUNT_POINT'..."
sudo chown -R apache:apache "$MOUNT_POINT"
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;

# Permissões mais restritas para os arquivos de config
if [ -f "$ACTIVE_CONFIG_FILE" ]; then
    sudo chmod 640 "$ACTIVE_CONFIG_FILE"
fi
if [ -f "$PRODUCTION_CONFIG_MODEL_FILE" ]; then
    sudo chmod 640 "$PRODUCTION_CONFIG_MODEL_FILE"
fi
if [ -f "$MANAGEMENT_CONFIG_MODEL_FILE" ]; then
    sudo chmod 640 "$MANAGEMENT_CONFIG_MODEL_FILE"
fi
# Permissões para healthcheck (apache precisa ler)
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    sudo chmod 644 "$HEALTH_CHECK_FILE_PATH" # Já coberto pelo find -type f, mas reforça.
fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
if ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
    echo "INFO: Modificando $HTTPD_CONF para AllowOverride All..."
    sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF"
else
    echo "INFO: AllowOverride All já parece estar definido."
fi

echo "INFO: Habilitando e reiniciando httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar httpd."
    sudo apachectl configtest || echo "WARN: apachectl configtest falhou."
    sudo tail -n 20 /var/log/httpd/error_log || echo "WARN: Não foi possível ler /var/log/httpd/error_log."
    exit 1
fi
sleep 5
if ! systemctl is-active --quiet httpd; then
    echo "ERRO CRÍTICO: Serviço httpd não está ativo após restart."
    exit 1
fi
echo "INFO: Serviço httpd está ativo."

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.3) concluído com sucesso! ($(date)) ---"
echo "INFO: Modelos wp-config-production.php e wp-config-management.php criados."
echo "INFO: wp-config.php ativado para modo Produção/ASG (URLs dinâmicas)."
echo "INFO: Use Run Command para copiar wp-config-management.php para wp-config.php para ativar o modo de gerenciamento."
echo "INFO: Health Check em /healthcheck.php"
echo "INFO: Log completo em: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
