#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.3 (Baseado na v1.9.2, Ajusta WP_HOME/WP_SITEURL via WPDOMAIN)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Configura WP_HOME, WP_SITEURL com base na variável de ambiente WPDOMAIN.
# Inclui endpoint /healthcheck.php.
# Destinado a ser executado por um script de user data que baixa este do S3.

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
echo "INFO: --- Iniciando Script WordPress Setup (v1.9.3) ($(date)) ---"
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
    if [ -z "${!var_name:-}" ]; then # O :- é para tratar var não definida vs. var definida como vazia
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
    echo "INFO: Se esta é uma nova instância anexando a um EFS existente, isso é esperado."
else
    echo "INFO: WordPress não encontrado. Iniciando download e extração..."
    echo "INFO: Criando diretório temporário '$WP_DIR_TEMP'..."
    mkdir -p "$WP_DIR_TEMP"
    cd "$WP_DIR_TEMP"

    echo "INFO: Baixando WordPress (versão mais recente)..."
    if ! curl -sLO https://wordpress.org/latest.tar.gz; then
        echo "ERRO: Falha ao baixar WordPress. Verifique conectividade/firewall para wordpress.org."
        cd /tmp
        rm -rf "$WP_DIR_TEMP"
        exit 1
    fi

    echo "INFO: Extraindo WordPress..."
    if ! tar -xzf latest.tar.gz; then
        echo "ERRO: Falha ao extrair 'latest.tar.gz'."
        cd /tmp
        rm -rf "$WP_DIR_TEMP"
        exit 1
    fi
    rm latest.tar.gz

    if [ ! -d "wordpress" ]; then
        echo "ERRO: Diretório 'wordpress' não encontrado após extração."
        cd /tmp
        rm -rf "$WP_DIR_TEMP"
        exit 1
    fi

    echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS) (modo menos verboso)..."
    if ! sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/"; then
        echo "ERRO: Falha ao mover arquivos do WordPress para $MOUNT_POINT via rsync."
        cd /tmp
        rm -rf "$WP_DIR_TEMP"
        exit 1
    fi
    cd /tmp
    rm -rf "$WP_DIR_TEMP"
    echo "INFO: Arquivos do WordPress movidos e diretório temporário limpo."
fi

# --- Configuração do wp-config.php ---
echo "INFO: Verificando se '$CONFIG_FILE' já existe..."
if [ -f "$CONFIG_FILE" ]; then
    echo "WARN: '$CONFIG_FILE' já existe. Pulando criação e configuração inicial de DB/SALTS."
    echo "INFO: Assumindo que a configuração foi feita anteriormente ou manualmente."
else
    echo "INFO: '$CONFIG_FILE' não encontrado. Criando a partir de 'wp-config-sample.php'..."
    if [ ! -f "$MOUNT_POINT/wp-config-sample.php" ]; then
        echo "ERRO: '$MOUNT_POINT/wp-config-sample.php' não encontrado. A instalação do WordPress falhou ou está incompleta?"
        exit 1
    fi
    sudo cp "$MOUNT_POINT/wp-config-sample.php" "$CONFIG_FILE"

    RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
    ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)

    echo "INFO: Preparando variáveis para substituição segura no $CONFIG_FILE..."
    SAFE_DBNAME=$(echo "$AWS_DB_INSTANCE_TARGET_NAME_0" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_USER=$(echo "$DB_USER" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_PASSWORD=$(echo "$DB_PASSWORD" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_ENDPOINT_ADDRESS=$(echo "$ENDPOINT_ADDRESS" | sed -e 's/[&#\/\\\\]/\\&/g')

    echo "INFO: Substituindo placeholders de DB no $CONFIG_FILE (com escape)..."
    if ! sudo sed -i "s#database_name_here#$SAFE_DBNAME#" "$CONFIG_FILE"; then echo "ERRO: Falha ao substituir DB_NAME"; exit 1; fi
    if ! sudo sed -i "s#username_here#$SAFE_DB_USER#" "$CONFIG_FILE"; then echo "ERRO: Falha ao substituir DB_USER"; exit 1; fi
    if ! sudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$CONFIG_FILE"; then echo "ERRO: Falha ao substituir DB_PASSWORD"; exit 1; fi
    if ! sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$CONFIG_FILE"; then echo "ERRO: Falha ao substituir DB_HOST"; exit 1; fi
    echo "INFO: Placeholders de DB substituídos."

    echo "INFO: Obtendo e configurando chaves de segurança (SALTS) no $CONFIG_FILE..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then
        echo "ERRO: Falha ao obter SALTS da API do WordPress."
    else
        echo "INFO: Removendo/Inserindo SALTS usando arquivo temporário..."
        sudo sed -i "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" "$CONFIG_FILE"
        TEMP_SALT_FILE=$(mktemp)
        echo "$SALT" >"$TEMP_SALT_FILE"
        DB_COLLATE_MARKER="/define( *'DB_COLLATE'/"
        # Tenta inserir após DB_COLLATE, se falhar, insere antes do marcador final
        if ! sudo sed -i -e "$DB_COLLATE_MARKER r $TEMP_SALT_FILE" "$CONFIG_FILE" 2>/dev/null; then
            echo "WARN: Não foi possível inserir SALTS após DB_COLLATE. Tentando inserir antes do marcador final..."
            if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/r $TEMP_SALT_FILE" "$CONFIG_FILE"; then #r (read file) coloca ANTES da linha que casa com o padrão
                 echo "ERRO: Falha no sed ao inserir SALTS antes do marcador final."
                 rm -f "$TEMP_SALT_FILE"; exit 1;
            fi
        fi
        rm -f "$TEMP_SALT_FILE"
        echo "INFO: SALTS configurados com sucesso."
    fi
fi # Fim do if [ -f "$CONFIG_FILE" ] (bloco de criação/configuração inicial)

# --- INÍCIO: Inserir Definições WP_HOME/WP_SITEURL baseadas em WPDOMAIN ---
echo "INFO: Configurando WP_HOME e WP_SITEURL com base na variável de ambiente WPDOMAIN ($WPDOMAIN)..."

# Comentários marcadores para este bloco específico
BEGIN_WPDOMAIN_MARKER="// --- BEGIN WPDOMAIN URL Config ---"
END_WPDOMAIN_MARKER="// --- END WPDOMAIN URL Config ---"

# 1. Remover quaisquer definições explícitas anteriores de WP_HOME e WP_SITEURL
# Isso é para limpar definições simples como define('WP_HOME', '...');
# O -E para sed habilita expressões regulares estendidas (varia entre implementações de sed)
# Usaremos padrão básico para maior portabilidade, mas pode ser menos preciso
# sudo sed -i "/^define( *'WP_HOME'/d" "$CONFIG_FILE" # Comentado pois o bloco abaixo é mais robusto
# sudo sed -i "/^define( *'WP_SITEURL'/d" "$CONFIG_FILE" # Comentado

# 2. Remover o bloco antigo de definições dinâmicas de URL se ele existir
OLD_DYNAMIC_BEGIN_MARKER_SED_PATTERN='\/\/ --- Dynamic URL definitions ---'
OLD_DYNAMIC_END_MARKER_SED_PATTERN='\/\/ --- End Dynamic URL definitions ---'
# Usar awk para deletar o bloco entre os marcadores antigos é mais seguro que sed para multilinhas
if sudo grep -q "$OLD_DYNAMIC_BEGIN_MARKER_SED_PATTERN" "$CONFIG_FILE"; then
    echo "INFO: Removendo bloco antigo de 'Dynamic URL definitions'..."
    sudo awk -v b="$OLD_DYNAMIC_BEGIN_MARKER_SED_PATTERN" -v e="$OLD_DYNAMIC_END_MARKER_SED_PATTERN" '
        $0 ~ b {p=1; next}
        $0 ~ e {p=0; next}
        !p
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && sudo mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# 3. Remover o bloco atual (WPDOMAIN) se ele já existir, para tornar o script idempotente
if sudo grep -qF "$BEGIN_WPDOMAIN_MARKER" "$CONFIG_FILE"; then
    echo "INFO: Removendo bloco existente de 'WPDOMAIN URL Config' para recriá-lo..."
    # Usar awk para deletar o bloco entre os marcadores é mais seguro que sed para multilinhas
    sudo awk -v b="${BEGIN_WPDOMAIN_MARKER//\//\\/}" -v e="${END_WPDOMAIN_MARKER//\//\\/}" '
        $0 ~ b {p=1; next}
        $0 ~ e {p=0; next}
        !p
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && sudo mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# 4. Preparar o novo bloco de configuração
# A variável WPDOMAIN já foi verificada no início do script.
# Usar printf para construir o bloco de forma segura, especialmente se WPDOMAIN puder ter chars especiais
# No entanto, para define(), as aspas simples em PHP são importantes.
# Aqui, ${WPDOMAIN} será expandido pelo shell.
PHP_WPDOMAIN_CONFIG_BLOCK=$(cat <<EOF

${BEGIN_WPDOMAIN_MARKER}
define( 'WP_HOME', 'https://${WPDOMAIN}' );
define( 'WP_SITEURL', 'https://${WPDOMAIN}' );

// Inform WordPress that SSL is used, essential for is_ssl() and other functions,
// especially when behind a reverse proxy (like CloudFront/ALB) terminating SSL.
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
// Se o seu ALB/CloudFront sempre encaminha para a instância como HTTP,
// mas a conexão original do cliente era HTTPS, o bloco acima é essencial.
// Você também pode considerar forçar SSL para o admin, mas a CloudFront Function já fará o bloqueio.
// if ( ! defined( 'FORCE_SSL_ADMIN' ) ) {
//    define( 'FORCE_SSL_ADMIN', true );
// }
${END_WPDOMAIN_MARKER}

EOF
)

# 5. Inserir o novo bloco antes da linha marcador final
echo "INFO: Inserindo configuração de WP_HOME/WP_SITEURL baseada em WPDOMAIN em $CONFIG_FILE..."
TEMP_CONFIG_INSERT_FILE=$(mktemp)
echo "$PHP_WPDOMAIN_CONFIG_BLOCK" > "$TEMP_CONFIG_INSERT_FILE"

# Usa sed para inserir o conteúdo do arquivo temporário ANTES da linha marcador final
# Abordagem mais segura: Inserir placeholder, depois ler arquivo e deletar placeholder
PLACEHOLDER_WPDOMAIN="__WPDOMAIN_CONFIG_INSERT_POINT_$(date +%s)__"
if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/i $PLACEHOLDER_WPDOMAIN" "$CONFIG_FILE"; then
    echo "ERRO: Falha ao inserir placeholder para WPDOMAIN config em $CONFIG_FILE."
    rm -f "$TEMP_CONFIG_INSERT_FILE"
    exit 1;
else
    if ! sudo sed -i -e "\#$PLACEHOLDER_WPDOMAIN#r $TEMP_CONFIG_INSERT_FILE" -e "\#$PLACEHOLDER_WPDOMAIN#d" "$CONFIG_FILE"; then
        echo "ERRO: Falha ao substituir placeholder com WPDOMAIN config em $CONFIG_FILE."
        sudo sed -i "\#$PLACEHOLDER_WPDOMAIN#d" "$CONFIG_FILE" || echo "WARN: Não foi possível remover placeholder órfão de WPDOMAIN."
    else
        echo "INFO: Configuração de WP_HOME/WP_SITEURL baseada em WPDOMAIN inserida com sucesso."
    fi
fi
rm -f "$TEMP_CONFIG_INSERT_FILE"
# --- FIM: Inserir Definições WP_HOME/WP_SITEURL baseadas em WPDOMAIN ---

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'direct' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHOD', 'direct' );"
if [ -f "$CONFIG_FILE" ]; then
    if sudo grep -q "define( *'FS_METHOD' *, *'direct' *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido em $CONFIG_FILE."
    else
        echo "INFO: Inserindo FS_METHOD 'direct' em $CONFIG_FILE..."
        if ! sudo sed -i "/$MARKER_LINE_SED_PATTERN/i\\$FS_METHOD_LINE" "$CONFIG_FILE"; then
            echo "ERRO: Falha ao inserir FS_METHOD 'direct' no $CONFIG_FILE."
        else
            echo "INFO: FS_METHOD 'direct' inserido com sucesso."
        fi
    fi
else
    echo "WARN: $CONFIG_FILE não encontrado para adicionar FS_METHOD. Isso pode ser um problema se a configuração inicial foi pulada."
fi
echo "INFO: Configuração final do wp-config.php concluída."

# <<<--- INÍCIO: Adicionar Arquivo de Health Check (v1.9.1 / v1.9.2) --->>>
echo "INFO: Criando/Verificando arquivo de health check em '$HEALTH_CHECK_FILE_PATH'..."
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" <<EOF
<?php
// Simple health check endpoint for AWS Target Group or other monitors
// Returns HTTP 200 OK status code if PHP processing is working.
// Version: 1.9.3
http_response_code(200);
header("Content-Type: text/plain; charset=utf-8");
echo "OK";
exit;
?>
EOF
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    echo "INFO: Arquivo de health check '$HEALTH_CHECK_FILE_PATH' criado/atualizado com sucesso."
else
    echo "ERRO: Falha ao criar/atualizar o arquivo de health check '$HEALTH_CHECK_FILE_PATH'."
fi
# <<<--- FIM: Adicionar Arquivo de Health Check --->>>

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_POINT'..."
if ! sudo chown -R apache:apache "$MOUNT_POINT"; then
    echo "ERRO: Falha ao definir propriedade apache:apache em $MOUNT_POINT."
    exit 1
fi
echo "INFO: Definindo permissões base (755 dirs, 644 files)..."
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \; || echo "WARN: Erros menores ao definir permissões de diretório (755)."
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \; || echo "WARN: Erros menores ao definir permissões de arquivo (644)."
if [ -f "$CONFIG_FILE" ]; then
    sudo chown apache:apache "$CONFIG_FILE" || echo "WARN: Não foi possível ajustar propriedade em $CONFIG_FILE"
    sudo chmod 640 "$CONFIG_FILE" || echo "WARN: Não foi possível ajustar permissões em $CONFIG_FILE (640)"
fi
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    sudo chown apache:apache "$HEALTH_CHECK_FILE_PATH" || echo "WARN: Não foi possível ajustar propriedade de $HEALTH_CHECK_FILE_PATH"
    sudo chmod 644 "$HEALTH_CHECK_FILE_PATH" || echo "WARN: Não foi possível ajustar permissões em $HEALTH_CHECK_FILE_PATH (644)"
fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache para servir de '$MOUNT_POINT'..."
HTTPD_CONF="/etc/httpd/conf/httpd.conf"
if grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF" && ! grep -A5 "<Directory \"/var/www/html\">" "$HTTPD_CONF" | grep -q "AllowOverride All"; then
    echo "INFO: Modificando $HTTPD_CONF para definir AllowOverride All para /var/www/html..."
    if ! sudo sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/s/AllowOverride .*/AllowOverride All/' "$HTTPD_CONF"; then
        echo "WARN: Falha ao tentar definir AllowOverride All automaticamente. Verifique $HTTPD_CONF manualmente se os permalinks não funcionarem."
    else
        echo "INFO: AllowOverride All definido com sucesso."
    fi
elif ! grep -q "<Directory \"/var/www/html\">" "$HTTPD_CONF"; then
    echo "WARN: Bloco de diretório /var/www/html não encontrado como esperado em $HTTPD_CONF. AllowOverride pode não estar correto."
else
    echo "INFO: AllowOverride All já parece estar definido para /var/www/html em $HTTPD_CONF."
fi

echo "INFO: Habilitando e reiniciando o serviço httpd..."
sudo systemctl enable httpd
if ! sudo systemctl restart httpd; then
    echo "ERRO CRÍTICO: Falha ao reiniciar o serviço httpd. Verifique a configuração do Apache e os logs."
    echo "DEBUG: Verificando configuração do Apache: "
    sudo apachectl configtest || echo "WARN: apachectl configtest falhou ou não está disponível."
    echo "DEBUG: Últimas linhas do log de erro do Apache (/var/log/httpd/error_log):"
    sudo tail -n 20 /var/log/httpd/error_log || echo "WARN: Não foi possível ler o log de erro do Apache."
    exit 1
fi
sleep 5
if systemctl is-active --quiet httpd; then
    echo "INFO: Serviço httpd está ativo."
else
    echo "ERRO CRÍTICO: Serviço httpd não está ativo após a tentativa de restart. Verifique os logs."
    echo "DEBUG: Últimas linhas do log de erro do Apache (/var/log/httpd/error_log):"
    sudo tail -n 20 /var/log/httpd/error_log || echo "WARN: Não foi possível ler o log de erro do Apache."
    exit 1
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup (v1.9.3) concluído com sucesso! ($(date)) ---"
echo "INFO: WordPress configurado para usar WP_HOME/WP_SITEURL de WPDOMAIN: https://${WPDOMAIN}"
echo "INFO: Acesse https://${WPDOMAIN} para finalizar a instalação via navegador (se for a primeira vez) ou usar o site."
echo "INFO: O Health Check está disponível em /healthcheck.php"
echo "INFO: Log completo em: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
