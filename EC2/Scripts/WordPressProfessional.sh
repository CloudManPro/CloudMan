@@ -1,10 +1,10 @@
#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.7-mod5 (Baseado na v1.9.7, com remoção da espera por boot-finished e tentativa de desabilitar yum-cron)
# Versão: 1.9.7-mod6 (Baseado na v1.9.7-mod5, com wp-config-management.php como padrão)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2.
# Cria templates wp-config-production.php e wp-config-management.php no EFS.
# Ativa wp-config-production.php como o wp-config.php padrão.
# A troca para o modo de gerenciamento deve ser feita externamente (ex: Run Command).
# Ativa wp-config-management.php como o wp-config.php padrão.
# A troca para o modo de produção deve ser feita externamente (ex: Run Command).

# --- BEGIN WAIT LOGIC FOR AMI INITIALIZATION ---
# Esta seção foi removida/comentada porque este script é executado como user-data pelo cloud-init.
@@ -170,12 +170,11 @@ MARKER_LINE_SED_PATTERN='\/\* That'\''s all, stop editing! Happy publishing\. \*
# --- Redirecionamento de Logs ---
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: ---   Iniciando Script WordPress Setup (v1.9.7-mod5) ($(date)) ---"
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.7-mod6) ($(date)) ---" # MODIFICADO (versão)
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
# (Mantido como antes, apenas um log foi ajustado)
essential_vars=(
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
@@ -185,7 +184,7 @@ essential_vars=(
    "WPDOMAIN"
    "ACCOUNT"
)
echo "INFO: Verificando formalmente as variáveis de ambiente essenciais..." # Ajuste no log para clareza
echo "INFO: Verificando formalmente as variáveis de ambiente essenciais..."
if [ -z "${ACCOUNT:-}" ]; then
    echo "INFO: ACCOUNT ID não fornecido, tentando obter via AWS STS..."
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
@@ -204,15 +203,13 @@ else
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
    # Nem fornecido, nem pôde ser construído (este caso será pego pelo loop abaixo)
    export AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=""
fi

@@ -223,7 +220,6 @@ for var_name in "${essential_vars[@]}"; do
    var_to_check_name="$var_name"

    if [ "$var_name" == "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0" ]; then
        # Para esta variável, a verificação real é se AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 está preenchido
        if [ -z "${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0:-}" ]; then
            echo "ERRO: AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 não pôde ser determinado (nem fornecido, nem construído)."
            error_found=1
@@ -239,10 +235,9 @@ if [ "$error_found" -eq 1 ]; then
    exit 1
fi

# Tratar MANAGEMENT_WPDOMAIN
if [ -z "${MANAGEMENT_WPDOMAIN:-}" ]; then
    echo "WARN: MANAGEMENT_WPDOMAIN não definido. O template wp-config-management.php usará um placeholder 'management.example.com'."
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="management.example.com" # Placeholder
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="management.example.com"
else
    export MANAGEMENT_WPDOMAIN_EFFECTIVE="${MANAGEMENT_WPDOMAIN}"
fi
@@ -251,7 +246,6 @@ echo "INFO: Domínio de Gerenciamento (MANAGEMENT_WPDOMAIN_EFFECTIVE): ${MANAGEM
echo "INFO: Verificação de variáveis essenciais concluída."

# --- Funções Auxiliares ---
# (Funções mount_efs e create_wp_config_template permanecem as mesmas)
mount_efs() {
    local efs_id=$1
    local mount_point=$2
@@ -464,13 +458,14 @@ if [ -f "$CONFIG_SAMPLE_ORIGINAL" ]; then
        echo "WARN: Template $CONFIG_FILE_MGMT_TEMPLATE já existe e parece válido. Pulando criação."
    fi

    if [ ! -L "$ACTIVE_CONFIG_FILE" ] && [ ! -f "$ACTIVE_CONFIG_FILE" ] && [ -f "$CONFIG_FILE_PROD_TEMPLATE" ]; then
        echo "INFO: Ativando $CONFIG_FILE_PROD_TEMPLATE como o $ACTIVE_CONFIG_FILE padrão."
        sudo cp "$CONFIG_FILE_PROD_TEMPLATE" "$ACTIVE_CONFIG_FILE"
    # MODIFICADO: Agora tenta ativar o wp-config-management.php por padrão
    if [ ! -L "$ACTIVE_CONFIG_FILE" ] && [ ! -f "$ACTIVE_CONFIG_FILE" ] && [ -f "$CONFIG_FILE_MGMT_TEMPLATE" ]; then
        echo "INFO: Ativando $CONFIG_FILE_MGMT_TEMPLATE como o $ACTIVE_CONFIG_FILE padrão." # MODIFICADO
        sudo cp "$CONFIG_FILE_MGMT_TEMPLATE" "$ACTIVE_CONFIG_FILE" # MODIFICADO
    elif [ -f "$ACTIVE_CONFIG_FILE" ] || [ -L "$ACTIVE_CONFIG_FILE" ]; then
        echo "WARN: $ACTIVE_CONFIG_FILE já existe. Nenhuma alteração no arquivo ativo será feita por este script para manter o estado atual."
    else
        echo "ERRO: $CONFIG_FILE_PROD_TEMPLATE não pôde ser criado/encontrado para ativar como padrão."
        echo "ERRO: $CONFIG_FILE_MGMT_TEMPLATE não pôde ser criado/encontrado para ativar como padrão." # MODIFICADO
    fi
else
    echo "WARN: $CONFIG_SAMPLE_ORIGINAL não encontrado. Não é possível criar templates wp-config."
@@ -481,10 +476,10 @@ echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_P
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint
// Version: 1.9.7-mod5
// Version: 1.9.7-mod6
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK - WordPress Health Check Endpoint - Script v1.9.7-mod5 - Timestamp: " . date("Y-m-d\TH:i:s\Z");
echo "OK - WordPress Health Check Endpoint - Script v1.9.7-mod6 - Timestamp: " . date("Y-m-d\TH:i:s\Z"); // MODIFICADO (versão)
exit;
?>
EOF
@@ -539,12 +534,12 @@ fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.7-mod5) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado. Template de produção ativado por padrão."
echo "INFO: Domínio de Produção: https://${WPDOMAIN}"
echo "INFO: Domínio de Gerenciamento (template criado): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"
echo "INFO: Para alternar para o modo de gerenciamento, use um Run Command para copiar/linkar"
echo "INFO: $CONFIG_FILE_MGMT_TEMPLATE para $ACTIVE_CONFIG_FILE e reiniciar o Apache (se necessário)."
echo "INFO: --- Script WordPress Setup (v1.9.7-mod6) concluído com sucesso! ($(date)) ---"             # MODIFICADO (versão)
echo "INFO: WordPress configurado. Template de gerenciamento ativado por padrão."                      # AJUSTADO
echo "INFO: Domínio de Produção (template criado): https://${WPDOMAIN}"                                # AJUSTADO
echo "INFO: Domínio de Gerenciamento (ATIVO): https://${MANAGEMENT_WPDOMAIN_EFFECTIVE}"                # AJUSTADO
echo "INFO: Para alternar para o modo de produção, use um Run Command para copiar/linkar"              # AJUSTADO
echo "INFO: $CONFIG_FILE_PROD_TEMPLATE para $ACTIVE_CONFIG_FILE e reiniciar o Apache (se necessário)." # AJUSTADO
echo "INFO: Health Check: /healthcheck.php"
echo "INFO: Log completo: ${LOG_FILE}"
echo "INFO: =================================================="
