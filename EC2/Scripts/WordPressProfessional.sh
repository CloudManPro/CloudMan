2/Scripts/WordPressProfessional.sh
+62
-76
Lines changed: 62 additions & 76 deletions
Original file line number	Diff line number	Diff line change
@@ -1,46 +1,29 @@
#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.7-mod1 (Baseado na v1.9.7, com logging de pai do yum e espera ajustada, e remoção de yum.pid obsoleto)
# Versão: 1.9.7-mod5 (Baseado na v1.9.7, com remoção da espera por boot-finished e tentativa de desabilitar yum-cron)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2.
# Cria templates wp-config-production.php e wp-config-management.php no EFS.
# Ativa wp-config-production.php como o wp-config.php padrão.
# A troca para o modo de gerenciamento deve ser feita externamente (ex: Run Command).

# --- BEGIN WAIT LOGIC FOR AMI INITIALIZATION ---
# Esta seção foi removida/comentada porque este script é executado como user-data pelo cloud-init.
# Esperar pelo boot-finished aqui causaria um timeout, pois o cloud-init só
# criaria o boot-finished DEPOIS que este script (user-data) terminasse.
echo "INFO: Script está rodando 1.9.7-mod1 como parte do cloud-init user-data. Pulando espera explícita por /var/lib/cloud/instance/boot-finished."
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
# --- BEGIN YUM WAIT LOGIC ---
# Tentar desabilitar e parar o yum-cron antes de prosseguir, para evitar locks.
echo "INFO: Attempting to disable and stop yum-cron..."
if systemctl list-unit-files | grep -q "yum-cron.service"; then
    sudo systemctl stop yum-cron || echo "WARN: Falha ao parar yum-cron (pode não estar rodando)."
    sudo systemctl disable yum-cron || echo "WARN: Falha ao desabilitar yum-cron."
    echo "INFO: yum-cron stop/disable attempted."
else
    echo "WARN: Proceeding without /var/lib/cloud/instance/boot-finished signal. ($(date))"
    echo "INFO: Serviço yum-cron.service não encontrado. Pulando desativação."
fi
# --- END WAIT LOGIC ---

# --- BEGIN YUM WAIT LOGIC ---
echo "INFO: Performing check and wait for yum to be free... ($(date))"
MAX_YUM_WAIT_ITERATIONS=60 # 60 iterações (Total: 30 minutos com intervalo de 30s)
YUM_WAIT_INTERVAL=30       # 30 segundos por iteração
@@ -92,10 +75,8 @@ while [ -f /var/run/yum.pid ]; do
                if sudo rm -f /var/run/yum.pid; then
                    echo "INFO: Successfully removed stale /var/run/yum.pid. Yum should be free now."
                    STALE_PID_CURRENT_CONFIRMATIONS=0 # Resetar
                    # O loop while continuará e sairá na próxima verificação de -f /var/run/yum.pid
                else
                    echo "ERROR: Failed to remove stale /var/run/yum.pid. Permissions issue? Continuing to wait, but this is problematic."
                    # Não resetar confirmações, para que não tente remover repetidamente sem sucesso
                fi
            fi
        fi
@@ -189,12 +170,22 @@ MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*
# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.7-mod1) ($(date)) ---"
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.7-mod5) ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
# (Mantido como antes, apenas um log foi ajustado)
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "WPDOMAIN"
    "ACCOUNT"
)
echo "INFO: Verificando formalmente as variáveis de ambiente essenciais..." # Ajuste no log para clareza
if [ -z "${ACCOUNT:-}" ]; then
    echo "INFO: ACCOUNT ID não fornecido, tentando obter via AWS STS..."
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
@@ -205,28 +196,37 @@ if [ -z "${ACCOUNT:-}" ]; then
    fi
fi

if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] &&
    [ -n "${ACCOUNT:-}" ] &&
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-}" ] && \
    [ -n "${ACCOUNT:-}" ] && \
    [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0:-}" ]; then
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
else
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED=""
fi
# Prioriza o ARN fornecido, senão usa o construído
if [ -n "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 fornecido diretamente: ${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0}"
elif [ -n "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED" ]; then
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 está vazio, construindo a partir dos componentes..."
    export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0_CONSTRUCTED"
    echo "INFO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 construído como: $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
else
    # Tenta usar o ARN se fornecido diretamente
    AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}"
    # Nem fornecido, nem pôde ser construído (este caso será pego pelo loop abaixo)
    export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
fi

error_found=0
for var_name in "${essential_vars[@]}"; do
    current_var_value="${!var_name:-}"
    var_to_check_name="$var_name"
    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        # A verificação principal agora é se o ARN_0 foi bem sucedido
        if [ -z "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ]; then
            echo "ERRO: Variável de ambiente essencial AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (ou seus componentes REGION, ACCOUNT, NAME) não definida ou vazia, e não pôde ser construída."
        # Para esta variável, a verificação real é se AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 está preenchido
        if [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
            echo "ERRO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 não pôde ser determinado (nem fornecido, nem construído)."
            error_found=1
        else
            # Prioriza o ARN construído ou o fornecido diretamente
            export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0="$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
            echo "INFO: Usando AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0: $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
        fi
    elif [ -z "$current_var_value" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_to_check_name' não definida ou vazia."
@@ -251,10 +251,11 @@ echo "INFO: Domínio de Gerenciamento (MANAGEMENT_WPDOMAIN_EFFECTIVE): ${MANAGEM
echo "INFO: Verificação de variáveis essenciais concluída."

# --- Funções Auxiliares ---
# (Funções mount_efs e create_wp_config_template permanecem as mesmas)
mount_efs() {
    local efs_id=$1
    local mount_point=$2
    local efs_ap_id="${EFS_ACCESS_POINT_ID:-}" # Assume que EFS_ACCESS_POINT_ID pode ser uma variável de ambiente
    local efs_ap_id="${EFS_ACCESS_POINT_ID:-}"

    echo "INFO: Verificando se o ponto de montagem '$mount_point' existe..."
    sudo mkdir -p "$mount_point"
@@ -269,14 +270,14 @@ mount_efs() {

        if [ -n "$efs_ap_id" ]; then
            echo "INFO: Usando Ponto de Acesso EFS: $efs_ap_id"
            mount_source="$efs_id" # Para AP, a origem é apenas o ID do FS
            mount_source="$efs_id" 
            mount_options="tls,accesspoint=$efs_ap_id"
        else
            echo "INFO: Montando raiz do EFS File System (sem Ponto de Acesso específico)."
        fi

        local mount_attempts=3
        local mount_timeout=20 # segundos
        local mount_timeout=20 
        local attempt_num=1
        while [ "$attempt_num" -le "$mount_attempts" ]; do
            echo "INFO: Tentativa de montagem $attempt_num/$mount_attempts para EFS ($mount_source) em '$mount_point' com opções '$mount_options'..."
@@ -287,9 +288,6 @@ mount_efs() {
                echo "ERRO: Tentativa $attempt_num/$mount_attempts de montar EFS falhou (timeout ${mount_timeout}s)."
                if [ "$attempt_num" -eq "$mount_attempts" ]; then
                    echo "ERRO CRÍTICO: Falha ao montar EFS após $mount_attempts tentativas."
                    # Adicionar mais informações de debug, se necessário
                    # dmesg | tail
                    # cat /var/log/amazon/efs/mount.log (se existir e for relevante)
                    exit 1
                fi
                sleep 5
@@ -302,7 +300,7 @@ mount_efs() {
            echo "INFO: Entrada EFS existente para ${mount_point} encontrada no /etc/fstab. Removendo para atualizar..."
            sudo sed -i "\# ${mount_point} efs#d" /etc/fstab
        fi
        local fstab_mount_options="_netdev,${mount_options}" # _netdev é importante para montagens de rede
        local fstab_mount_options="_netdev,${mount_options}" 
        local fstab_entry="$mount_source $mount_point efs $fstab_mount_options 0 0"
        echo "$fstab_entry" | sudo tee -a /etc/fstab >/dev/null
        echo "INFO: Entrada adicionada ao /etc/fstab: '$fstab_entry'"
@@ -327,7 +325,7 @@ create_wp_config_template() {

    SAFE_DB_NAME=$(printf '%s\n' "$db_name" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_USER=$(printf '%s\n' "$db_user" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")
    SAFE_DB_PASSWORD=$(printf '%s\n' "$db_password" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g") # Cuidado com aspas simples na senha
    SAFE_DB_PASSWORD=$(printf '%s\n' "$db_password" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g") 
    SAFE_DB_HOST=$(printf '%s\n' "$db_host" | sed -e 's/[\/&]/\\&/g' -e "s/'/\\'/g")

    sudo sed -i "s/database_name_here/$SAFE_DB_NAME/g" "$target_file"
@@ -338,7 +336,6 @@ create_wp_config_template() {
    echo "INFO: Obtendo e configurando SALTS em $target_file..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then echo "ERRO: Falha ao obter SALTS para $target_file."; else
        # Remove existing salt definitions more robustly
        local salt_defines=(AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT)
        for def_key in "${salt_defines[@]}"; do
            sudo sed -i "/^define( *'$def_key'/d" "$target_file"
@@ -363,15 +360,11 @@ define('WP_HOME', '$wp_home_url');
define('WP_SITEURL', '$wp_site_url');
define('FS_METHOD', 'direct');
// Garantir HTTPS se X-Forwarded-Proto estiver presente (e.g., atrás de um Load Balancer)
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
// Desabilitar editor de arquivos do painel WP para segurança
define('DISALLOW_FILE_EDIT', true);
// Limitar revisões de post (opcional)
// define('WP_POST_REVISIONS', 3);
EOF
    )
    TEMP_DEFINES_FILE=$(mktemp)
@@ -411,18 +404,16 @@ if [ -z "$SECRET_STRING_VALUE" ]; then
fi
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)
# DB_NAME é AWS_DB_INSTANCE_TARGET_NAME_0
# DB_HOST é AWS_DB_INSTANCE_TARGET_ENDPOINT_0
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair username ou password do JSON do segredo."
    exit 1
fi
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1) # Remove a porta se existir
DB_HOST_ENDPOINT=$(echo "$AWS_DB_INSTANCE_TARGET_ENDPOINT_0" | cut -d: -f1) 
echo "INFO: Credenciais do banco de dados extraídas (Usuário: $DB_USER)."

# --- Download e Extração do WordPress ---
echo "INFO: Verificando se o WordPress já existe em '$MOUNT_POINT'..."
if [ -d "$MOUNT_POINT/wp-includes" ] && [ -f "$MOUNT_POINT/wp-config-sample.php" ]; then # Verifica um pouco mais
if [ -d "$MOUNT_POINT/wp-includes" ] && [ -f "$MOUNT_POINT/wp-config-sample.php" ]; then 
    echo "WARN: Diretório 'wp-includes' e 'wp-config-sample.php' já encontrado em '$MOUNT_POINT'. Pulando download e extração do WordPress."
else
    echo "INFO: WordPress não encontrado ou incompleto. Iniciando download e extração..."
@@ -446,9 +437,6 @@ else
        exit 1
    fi
    echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT'..."
    # Usar rsync para mover, garantindo que não sobrescreva arquivos de configuração existentes, a menos que o diretório esteja vazio
    # Se $MOUNT_POINT não está vazio, mas não tem WP, rsync pode ser perigoso.
    # A verificação acima de wp-includes deve ser suficiente.
    sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/" || {
        echo "ERRO: Falha ao mover arquivos para $MOUNT_POINT."
        cd /tmp && rm -rf "$WP_DIR_TEMP"
@@ -460,7 +448,7 @@ fi

# --- Configuração dos Templates wp-config ---
if [ -f "$CONFIG_SAMPLE_ORIGINAL" ]; then
    if [ ! -f "$CONFIG_FILE_PROD_TEMPLATE" ] || [ "$(sudo stat -c %s "$CONFIG_FILE_PROD_TEMPLATE")" -lt 100 ]; then # Recria se for pequeno/vazio
    if [ ! -f "$CONFIG_FILE_PROD_TEMPLATE" ] || [ "$(sudo stat -c %s "$CONFIG_FILE_PROD_TEMPLATE")" -lt 100 ]; then 
        PRODUCTION_URL="https://${WPDOMAIN}"
        create_wp_config_template "$CONFIG_FILE_PROD_TEMPLATE" "$PRODUCTION_URL" "$PRODUCTION_URL" \
            "$AWS_DB_INSTANCE_TARGET_NAME_0" "$DB_USER" "$DB_PASSWORD" "$DB_HOST_ENDPOINT"
@@ -493,10 +481,10 @@ echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_P
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
// Version: 1.9.7-mod1
// Version: 1.9.7-mod5
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK - WordPress Health Check Endpoint - Script v1.9.7-mod1 - Timestamp: " . date("Y-m-d\TH:i:s\Z");
echo "OK - WordPress Health Check Endpoint - Script v1.9.7-mod5 - Timestamp: " . date("Y-m-d\TH:i:s\Z");
exit;
?>
EOF
@@ -507,24 +495,22 @@ echo "INFO: Ajustando permissões e propriedade em '$MOUNT_POINT'..."
sudo chown -R apache:apache "$MOUNT_POINT"
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;
# Permissões mais restritas para arquivos de configuração
if [ -f "$ACTIVE_CONFIG_FILE" ]; then sudo chmod 640 "$ACTIVE_CONFIG_FILE"; fi
if [ -f "$CONFIG_FILE_PROD_TEMPLATE" ]; then sudo chmod 640 "$CONFIG_FILE_PROD_TEMPLATE"; fi
if [ -f "$CONFIG_FILE_MGMT_TEMPLATE" ]; then sudo chmod 640 "$CONFIG_FILE_MGMT_TEMPLATE"; fi
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH"; fi # Healthcheck precisa ser legível pelo webserver
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then sudo chmod 644 "$HEALTH_CHECK_FILE_PATH"; fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
# Garante que AllowOverride All está configurado para o DocumentRoot
if grep -q "<Directory \"${MOUNT_POINT}\">" "$HTTPD_CONF"; then
    if ! grep -A5 "<Directory \"${MOUNT_POINT}\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
        sudo sed -i "/<Directory \"${MOUNT_POINT//\//\\\/}\">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/" "$HTTPD_CONF" && echo "INFO: AllowOverride All definido para ${MOUNT_POINT}." || echo "WARN: Falha ao definir AllowOverride All para ${MOUNT_POINT}."
    else
        echo "INFO: AllowOverride All já parece OK para ${MOUNT_POINT}."
    fi
elif grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && [ "$MOUNT_POINT" = "/var/www/html" ]; then # Caso padrão
elif grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && [ "$MOUNT_POINT" = "/var/www/html" ]; then 
     if ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
        sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF" && echo "INFO: AllowOverride All definido para /var/www/html." || echo "WARN: Falha ao definir AllowOverride All para /var/www/html."
    else
@@ -543,7 +529,7 @@ if ! sudo systemctl restart httpd; then
    sudo tail -n 30 /var/log/httpd/error_log
    exit 1
fi
sleep 3 # Dar um tempo para o serviço estabilizar
sleep 3 
if systemctl is-active --quiet httpd; then echo "INFO: Serviço httpd está ativo."; else
    echo "ERRO CRÍTICO: httpd não está ativo pós-restart."
    echo "Últimas linhas do log de erro do Apache:"
@@ -553,7 +539,7 @@ fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.7-mod1) concluído com sucesso! ($(date)) ---"
echo "INFO: --- Script WordPress Setup (v1.9.7-mod5) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado. Template de produção ativado por padrão."
echo "INFO: Domínio de Produção: https://${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (template criado): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
