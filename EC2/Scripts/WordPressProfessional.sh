#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS, RDS, ProxySQL e X-Ray ===
# Versão: 2.4.0-xray-integration (Adiciona instrumentação completa do AWS X-Ray)
# Modificado para validar otimização, adicionar ProxySQL e integrar X-Ray.

# --- Configurações Chave ---
readonly THIS_SCRIPT_TARGET_PATH="/usr/local/bin/wordpress_setup_v2.4.0.sh"
readonly APACHE_USER="apache"
readonly ENV_VARS_FILE="/etc/wordpress_setup_v2.4.0_env_vars.sh"

# --- Variáveis Globais ---
LOG_FILE="/var/log/wordpress_setup_v2.4.0.log"
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

# --- Funções Auxiliares ---
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
// Gerado por wordpress_setup_v2.4.0.sh
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

### INÍCIO DA FUNÇÃO PARA PROXYSQL ###
setup_and_configure_proxysql() {
    local rds_host="$1"; local rds_port="$2"; local db_user="$3"; local db_pass="$4"
    echo "INFO (ProxySQL): Iniciando configuração do ProxySQL..."
    run_proxysql_admin() { mysql -u admin -padmin -h 127.0.0.1 -P 6032 -e "$1"; }
    if ! sudo systemctl start proxysql; then echo "ERRO CRÍTICO (ProxySQL): Falha ao iniciar o serviço ProxySQL para configuração."; exit 1; fi
    sleep 5
    echo "INFO (ProxySQL): Configurando servidor backend (RDS)..."
    run_proxysql_admin "INSERT INTO mysql_servers (hostgroup_id, hostname, port) VALUES (10, '${rds_host}', ${rds_port});"
    echo "INFO (ProxySQL): Configurando usuário de conexão com o backend..."
    run_proxysql_admin "INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('${db_user}', '${db_pass}', 10);"
    echo "INFO (ProxySQL): Configurando regra de roteamento transparente..."
    run_proxysql_admin "INSERT INTO mysql_query_rules (rule_id, active, username, destination_hostgroup, apply) VALUES (1, 1, '${db_user}', 10, 1);"
    echo "INFO (ProxySQL): Carregando e salvando configurações..."
    run_proxysql_admin "LOAD MYSQL SERVERS TO RUNTIME;"; run_proxysql_admin "LOAD MYSQL USERS TO RUNTIME;"; run_proxysql_admin "LOAD MYSQL QUERY RULES TO RUNTIME;"
    run_proxysql_admin "SAVE MYSQL SERVERS TO DISK;"; run_proxysql_admin "SAVE MYSQL USERS TO DISK;"; run_proxysql_admin "SAVE MYSQL QUERY RULES TO DISK;"
    echo "INFO (ProxySQL): Configuração do ProxySQL concluída."
}
### FIM DA FUNÇÃO PARA PROXYSQL ###

### INÍCIO DA FUNÇÃO DE INSTRUMENTAÇÃO DO X-RAY ###
setup_xray_instrumentation() {
    local wp_path="$1"
    echo "INFO (X-Ray): Iniciando instrumentação do WordPress em '$wp_path'..."

    # 1. Instalar o AWS SDK via Composer
    local composer_json_path="$wp_path/composer.json"
    if [ ! -f "$composer_json_path" ]; then
        echo "INFO (X-Ray): Criando '$composer_json_path'..."
        sudo -u "$APACHE_USER" tee "$composer_json_path" >/dev/null <<'EOF'
{
    "require": {
        "aws/aws-sdk-php": "^3.200"
    },
    "config": {
        "platform": {
            "php": "7.4"
        }
    }
}
EOF
    else
        echo "INFO (X-Ray): '$composer_json_path' já existe. Verificando dependência."
        # Garante que a dependência está lá, de forma simples
        if ! sudo -u "$APACHE_USER" grep -q '"aws/aws-sdk-php"' "$composer_json_path"; then
            echo "ERRO CRÍTICO (X-Ray): composer.json existe, mas não contém aws-sdk-php."
            exit 1
        fi
    fi

    echo "INFO (X-Ray): Executando 'composer install' para instalar o AWS SDK..."
    (cd "$wp_path" && sudo -u "$APACHE_USER" /usr/local/bin/composer install --no-dev -o)
    if [ $? -ne 0 ]; then
        echo "ERRO CRÍTICO (X-Ray): Falha no 'composer install'."
        exit 1
    fi

    # 2. Criar o Must-Use Plugin para iniciar o rastreamento
    local mu_plugin_dir="$wp_path/wp-content/mu-plugins"
    local xray_init_plugin_path="$mu_plugin_dir/xray-init.php"
    sudo -u "$APACHE_USER" mkdir -p "$mu_plugin_dir"
    
    if [ ! -f "$xray_init_plugin_path" ]; then
        echo "INFO (X-Ray): Criando Must-Use Plugin em '$xray_init_plugin_path'..."
        sudo -u "$APACHE_USER" tee "$xray_init_plugin_path" > /dev/null <<'EOPHP'
<?php
/**
 * Plugin Name: AWS X-Ray Tracer Initializer
 * Description: Inicia o rastreamento do AWS X-Ray para cada requisição.
 * Version: 1.0
 */

if (isset($_SERVER['REQUEST_URI']) && strpos($_SERVER['REQUEST_URI'], 'healthcheck.php') !== false) {
    return; // Não rastrear health checks para evitar ruído.
}

if (file_exists(__DIR__ . '/../../vendor/autoload.php')) {
    require_once __DIR__ . '/../../vendor/autoload.php';
    
    // Configuração do cliente X-Ray
    // O Daemon Name é o endereço UDP onde o X-Ray Daemon está escutando.
    $xray_client = new Aws\XRay\XRayClient([
        'version' => 'latest',
        'region'  => getenv('AWS_REGION') ?: 'us-east-1', // Use a região do ambiente ou um padrão
        'daemon_name' => '127.0.0.1:2000',
    ]);

    // O nome do segmento deve representar sua aplicação.
    $segment_name = $_SERVER['HTTP_HOST'] ?? 'wordpress-site';
    
    // Inicia o segmento principal para a requisição
    $xray_client->beginSegment($segment_name, null);

    // Garante que o segmento será fechado e enviado no final da execução do script
    register_shutdown_function(function() use ($xray_client) {
        $xray_client->endSegment();
        $xray_client->send();
    });

    // Torna o cliente acessível globalmente se necessário (opcional, mas útil para o db.php)
    $GLOBALS['xray_client'] = $xray_client;
}
EOPHP
    else
        echo "INFO (X-Ray): Must-Use Plugin já existe em '$xray_init_plugin_path'."
    fi

    # 3. Criar o DB Drop-in para rastrear queries SQL
    local db_dropin_path="$wp_path/wp-content/db.php"
    if [ ! -f "$db_dropin_path" ]; then
        echo "INFO (X-Ray): Criando DB Drop-in em '$db_dropin_path'..."
        sudo -u "$APACHE_USER" tee "$db_dropin_path" > /dev/null <<'EOPHP'
<?php
/**
 * WordPress DB Drop-in for AWS X-Ray Tracing.
 *
 * Coloque este arquivo em /wp-content/db.php
 */

// Inclui a classe original do WordPress
if (file_exists(ABSPATH . WPINC . '/wp-db.php')) {
    require_once(ABSPATH . WPINC . '/wp-db.php');
}

if (class_exists('wpdb')) {
    class XRay_wpdb extends wpdb {
        
        public function query($query) {
            // Obtém o cliente X-Ray global, iniciado pelo mu-plugin
            $xray_client = $GLOBALS['xray_client'] ?? null;
            
            if (!$xray_client) {
                // Se o cliente não estiver disponível, executa a query normalmente
                return parent::query($query);
            }

            // Inicia um subsegmento para a chamada ao banco de dados
            $xray_client->beginSubsegment('RDS-Query');
            
            try {
                // Adiciona metadados úteis para análise no console do X-Ray
                $xray_client->addMetadata('sql', substr($query, 0, 500)); // Limita o tamanho da query por segurança

                // Executa a query original
                $result = parent::query($query);
                
                if ($this->last_error) {
                    $xray_client->addAnnotation('db_error', true);
                    $xray_client->addMetadata('db_error_message', $this->last_error);
                }

                return $result;

            } finally {
                // Garante que o subsegmento seja fechado, mesmo que ocorra um erro
                $xray_client->endSubsegment();
            }
        }
    }
    
    // Substitui a instância global do wpdb pela nossa classe instrumentada
    $wpdb = new XRay_wpdb(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST);
}
EOPHP
    else
        echo "INFO (X-Ray): DB Drop-in já existe em '$db_dropin_path'."
    fi

    echo "INFO (X-Ray): Instrumentação do WordPress concluída."
}
### FIM DA FUNÇÃO DE INSTRUMENTAÇÃO DO X-RAY ###

tune_apache_and_phpfpm() {
    echo "INFO (Performance Tuning): Otimizando Apache (MPM Event) e PHP-FPM..."
    local APACHE_MPM_TUNING_CONF="/etc/httpd/conf.d/mpm_tuning.conf"
    sudo tee "$APACHE_MPM_TUNING_CONF" >/dev/null <<EOF_APACHE_MPM
<IfModule mpm_event_module>
    StartServers             3; MinSpareThreads          25; MaxSpareThreads          75
    ThreadsPerChild          25; ServerLimit              16; MaxRequestWorkers        400
    MaxConnectionsPerChild   1000
</IfModule>
EOF_APACHE_MPM
    local PHP_FPM_POOL_CONF="/etc/php-fpm.d/www.conf"
    if [ -f "$PHP_FPM_POOL_CONF" ]; then
        sudo sed -i 's/^pm.max_children = .*/pm.max_children = 50/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 10/' "$PHP_FPM_POOL_CONF"
        sudo sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 30/' "$PHP_FPM_POOL_CONF"
    fi
}

# --- Lógica Principal de Execução ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v2.4.0-XRAY) ($(date)) ---"
echo "INFO: Script target: $THIS_SCRIPT_TARGET_PATH. Log: ${LOG_FILE}"
echo "INFO: =================================================="
if [ "$(id -u)" -ne 0 ]; then echo "ERRO: Execução inicial deve ser como root."; exit 1; fi

# Verificação de variáveis (bloco omitido para brevidade, igual ao anterior)
echo "INFO: Verificando e imprimindo variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then ACCOUNT_STS=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); if [ -n "$ACCOUNT_STS" ]; then ACCOUNT="$ACCOUNT_STS"; else ACCOUNT=""; fi; fi
AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] && [ -n "${ACCOUNT:-}" ] && [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
fi
error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value_to_check="${!var_name:-}"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then current_var_value_to_check="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"; fi
    if [ "$var_name" != "AWS_EFS_ACCESS_POINT_TARGET_ID_0" ] && [ -z "$current_var_value_to_check" ]; then echo "ERRO: Var essencial '$var_name' está vazia."; error_found=1; fi
done
if [ "$error_found" -eq 1 ]; then echo "ERRO CRÍTICO: Variáveis faltando. Abortando."; exit 1; fi
echo "INFO: Verificação de variáveis concluída."

### INÍCIO DA SEÇÃO DE INSTALAÇÃO - ESTRATÉGIA DE DOWNLOAD DIRETO (MAIS GARANTIDA) ###
echo "INFO: Instalando pacotes base (Apache, PHP, etc.)..."
# Instala tudo, exceto o proxysql, que será instalado manualmente via download.
sudo yum update -y -q
sudo yum install -y httpd jq aws-cli mysql amazon-efs-utils composer xray php php-common php-fpm php-mysqlnd php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache
if [ $? -ne 0 ]; then
    echo "ERRO CRÍTICO: Falha ao instalar pacotes base via YUM."
    exit 1
fi
echo "INFO: Pacotes base instalados com sucesso."

# --- Bloco de Instalação Local do ProxySQL via Download Direto ---
echo "INFO: Tentando instalar ProxySQL via download direto de RPM, já que o repositório YUM está instável."

# Usamos a URL que foi confirmada como funcional anteriormente.
PROXYSQL_RPM_URL="https://repo.proxysql.com/ProxySQL/proxysql-2.x/centos/7/proxysql-2.5.5-1-centos7.x86_64.rpm"
LOCAL_RPM_PATH="/tmp/proxysql.rpm"

echo "INFO: Baixando ProxySQL RPM de $PROXYSQL_RPM_URL..."
# Usamos -L para seguir redirecionamentos e --fail para que o curl retorne um erro em caso de HTTP 4xx/5xx
# A conectividade foi provada com o teste manual, então este passo deve funcionar.
if curl -L --fail -o "$LOCAL_RPM_PATH" "$PROXYSQL_RPM_URL"; then
    echo "INFO: Download do RPM bem-sucedido. Instalando localmente..."
    
    # O yum localinstall resolve dependências que o RPM possa ter a partir dos repositórios da Amazon.
    sudo yum localinstall -y "$LOCAL_RPM_PATH"
    if [ $? -ne 0 ]; then
        echo "ERRO CRÍTICO: Falha ao instalar o RPM local do ProxySQL com 'yum localinstall'."
        exit 1
    fi
    # Limpa o arquivo baixado
    rm -f "$LOCAL_RPM_PATH"
    echo "INFO: ProxySQL instalado com sucesso."
else
    # Este erro agora seria extremamente inesperado, já que provamos que o curl funciona.
    echo "ERRO CRÍTICO: Falha ao baixar o RPM do ProxySQL. A conectividade da EC2 para este URL específico está intermitente ou bloqueada."
    exit 1
fi
# --- Fim do Bloco de Instalação Local ---

### FIM DA SEÇÃO DE INSTALAÇÃO ###


echo "INFO: Limpando cache do YUM para garantir que o novo repositório seja lido."
sudo yum clean all

echo "INFO: Instalando httpd, aws-cli, mysql, efs-utils, composer, xray e proxysql..."
# O yum agora usará a URL correta para encontrar o pacote 'proxysql'.
sudo yum install -y httpd jq aws-cli mysql amazon-efs-utils composer xray proxysql
if [ $? -ne 0 ]; then
    echo "ERRO CRÍTICO: Falha durante o 'yum install'. Um ou mais pacotes não puderam ser instalados. Verifique o log do yum."
    exit 1
fi
echo "INFO: Pacotes principais, incluindo ProxySQL, instalados com sucesso."

echo "INFO: Habilitando e instalando PHP 7.4 e módulos..."
sudo amazon-linux-extras enable php7.4 -y -q
sudo yum install -y -q php php-common php-fpm php-mysqlnd php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache

### FIM DA SEÇÃO DE INSTALAÇÃO ###

mount_efs "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" "$MOUNT_POINT"

EFS_TEST_FILE="$MOUNT_POINT/efs_write_test_$(date +%s).tmp"
if sudo -u "$APACHE_USER" touch "$EFS_TEST_FILE"; then sudo -u "$APACHE_USER" rm -f "$EFS_TEST_FILE"; else echo "ERRO CRÍTICO: Falha no teste de escrita no EFS."; ls -ld "$MOUNT_POINT"; exit 1; fi

echo "INFO: Obtendo credenciais do RDS do Secrets Manager..."
SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" --query 'SecretString' --output text --region "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0")
if [ -z "$SECRET_STRING_VALUE" ]; then echo "ERRO: Falha obter segredo RDS."; exit 1; fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username); DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
DB_NAME_TO_USE="$AWS_DB_INSTANCE_TARGET_NAME_0"
RDS_ACTUAL_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1)
RDS_ACTUAL_PORT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f2); [ -z "$RDS_ACTUAL_PORT" ] && RDS_ACTUAL_PORT=3306
DB_HOST_FOR_WP_CONFIG="127.0.0.1" # WordPress irá se conectar ao ProxySQL localmente
if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$RDS_ACTUAL_HOST_ENDPOINT" ]; then echo "ERRO CRÍTICO: Falha ao extrair credenciais do RDS."; exit 1; fi
echo "INFO: Credenciais do RDS obtidas."

setup_and_configure_proxysql "$RDS_ACTUAL_HOST_ENDPOINT" "$RDS_ACTUAL_PORT" "$DB_USER" "$DB_PASSWORD"

echo "INFO: Verificando WP em '$MOUNT_POINT/wp-includes'..."
if [ ! -d "$MOUNT_POINT/wp-includes" ]; then
    echo "INFO: WordPress não encontrado no EFS. Baixando e instalando..."
    sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    sudo mkdir -p "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR" && sudo chown "$(id -u):$(id -g)" "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
    (cd "$WP_DOWNLOAD_DIR" && curl -sLO https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz -C "$WP_FINAL_CONTENT_DIR" --strip-components=1 && rm latest.tar.gz)
    if [ $? -ne 0 ]; then echo "ERRO CRÍTICO: Falha no download/extração do WordPress."; exit 1; fi
    echo "INFO: Copiando para EFS como '$APACHE_USER'..."
    sudo -u "$APACHE_USER" cp -aT "$WP_FINAL_CONTENT_DIR/" "$MOUNT_POINT/"; sudo rm -rf "$WP_DOWNLOAD_DIR" "$WP_FINAL_CONTENT_DIR"
else
    echo "WARN: Instalação do WordPress já existe. Pulando download."
fi

### INÍCIO DA SEÇÃO DE CONFIGURAÇÃO DO X-RAY ###
# Chama a função para instalar o SDK e criar os arquivos de instrumentação.
# Isso é feito depois que o WordPress está no lugar, mas antes de iniciar os serviços.
setup_xray_instrumentation "$MOUNT_POINT"
### FIM DA SEÇÃO DE CONFIGURAÇÃO DO X-RAY ###

if [ ! -f "$ACTIVE_CONFIG_FILE_EFS" ]; then
    echo "INFO: '$ACTIVE_CONFIG_FILE_EFS' não encontrado. Criando...";
    create_wp_config_template "$ACTIVE_CONFIG_FILE_EFS" "$WPDOMAIN" "$DB_NAME_TO_USE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_FOR_WP_CONFIG"
else
    echo "WARN: '$ACTIVE_CONFIG_FILE_EFS' já existe.";
fi

echo "INFO: Criando arquivo de health check..."
sudo -u "$APACHE_USER" tee "$HEALTH_CHECK_FILE_PATH_EFS" >/dev/null <<< '<?php http_response_code(200); echo "OK"; ?>'
echo "INFO: Ajustando permissões finais no EFS..."
sudo chown -R "$APACHE_USER:$APACHE_USER" "$MOUNT_POINT"
sudo find "$MOUNT_POINT" -type d -exec chmod 775 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
echo "INFO: Configurando Apache..."
sudo sed -i "s#^DocumentRoot \"/var/www/html\"#DocumentRoot \"$MOUNT_POINT\"#" /etc/httpd/conf/httpd.conf
sudo sed -i "s#^<Directory \"/var/www/html\">#<Directory \"$MOUNT_POINT\">#" /etc/httpd/conf/httpd.conf
sudo tee "/etc/httpd/conf.d/wordpress.conf" >/dev/null <<< "<Directory \"$MOUNT_POINT\">; AllowOverride All; Require all granted; </Directory>"
tune_apache_and_phpfpm

### INÍCIO DA SEÇÃO DE INICIALIZAÇÃO DE SERVIÇOS MODIFICADA PARA X-RAY ###
PHP_FPM_SERVICE_NAME=""
for fpm_name in "php-fpm.service" "php7.4-fpm.service" "php74-php-fpm.service"; do
    if sudo systemctl list-unit-files | grep -q -w "$fpm_name"; then PHP_FPM_SERVICE_NAME="$fpm_name"; break; fi
done
if [ -z "$PHP_FPM_SERVICE_NAME" ]; then echo "ERRO CRÍTICO: Não foi possível detectar o serviço PHP-FPM."; exit 1; fi

echo "INFO: Habilitando e reiniciando serviços (httpd, $PHP_FPM_SERVICE_NAME, proxysql, xray)..."
sudo systemctl enable httpd
sudo systemctl enable "$PHP_FPM_SERVICE_NAME"
sudo systemctl enable proxysql
sudo systemctl enable xray

# Reinicia os serviços na ordem correta
sudo systemctl restart xray
sudo systemctl restart proxysql
sudo systemctl restart "$PHP_FPM_SERVICE_NAME"
sudo systemctl restart httpd

sleep 3
if systemctl is-active --quiet httpd && systemctl is-active --quiet "$PHP_FPM_SERVICE_NAME" && systemctl is-active --quiet proxysql && systemctl is-active --quiet xray; then
    echo "INFO: Todos os serviços (httpd, php-fpm, proxysql, xray) estão ativos."
else
    echo "ERRO CRÍTICO: Um ou mais serviços essenciais não estão ativos."
    sudo systemctl status httpd --no-pager; sudo systemctl status "$PHP_FPM_SERVICE_NAME" --no-pager
    sudo systemctl status proxysql --no-pager; sudo systemctl status xray --no-pager
    exit 1
fi
### FIM DA SEÇÃO DE INICIALIZAÇÃO DE SERVIÇOS ###

echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v2.4.0-XRAY) concluído! ($(date)) ---"
echo "INFO: Adicionado ProxySQL e instrumentação completa do AWS X-Ray."
echo "INFO: WordPress agora envia traces para o X-Ray para cada requisição e chamada SQL."
echo "INFO: =================================================="
exit 0
