#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 2.0 (Baseado na v1.9, Adiciona healthcheck.php dedicado)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Inclui um endpoint /healthcheck.php leve para health checks do ALB.
# Destinado a ser executado por um script de user data que baixa este do S3.
# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos
LOG_FILE="/var/log/wordpress-setup.log"
# Redireciona toda a saída (: 2.0 (Baseado na v1.9, Adiciona Health Check Endpoint)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Adiciona um endpoint /healthcheck.php para uso pelo ALB Target Group.
# Destinado a ser executado por um script de user data que baixa este do S3.
# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos
LOG_FILE="/var/log/wordpress-setup.log"
# Redireciona toda a saída (stdout e stderr) para o arquivo de log E para o console/cloud-init-output.log
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup v2.0 ($(date)) ---"
echo "INFO: Log principal em: ${LOG_FILE}"
echo "INFO: Usuário atual: $(whoami)"
echo "INFO: Diretório atual: $(pwd)"
echo "INFO: =================================================="

# --- Carregamento de Variáveis de Ambiente ---
if [ -f "/home/ec2-user/.env" ]; then
    echo "INFO: Arquivo /home/ec2-user/.env encontrado. Carregando variáveis..."
    set -a
    # shellcheck source=/dev/null
    source /home/ec2-user/.env
    set +a
    echo "INFO: Variáveis do .env carregadas e exportadas para este shell."
else
    echo "WARN: Arquivo /home/ec2-user/.env não encontrado. Confiando nas variáveis de ambiente herdadas/exportadas pelo script pai."
fi

# --- Verificação de Variáveis Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
essential_vars=(
    "NAME"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "AWS_SECRETSMANAGER_SECRETstdout e stderr) para o arquivo de log E para o console/cloud-init-output.log
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup v2.0 ($(date)) ---"
echo "INFO: Log principal em: ${LOG_FILE}"
echo "INFO: Usuário atual: $(whoami)"
echo "INFO: Diretório atual: $(pwd)"
echo "INFO: =================================================="

# --- Carregamento de Variáveis de Ambiente ---
if [ -f "/home/ec2-user/.env" ]; then
    echo "INFO: Arquivo /home/ec2-user/.env encontrado. Carregando variáveis..."
    set -a
    # shellcheck source=/dev/null
    source /home/ec2-user/.env
    set +a
    echo "INFO: Variáveis do .env carregadas e exportadas para este shell."
else
    echo "WARN: Arquivo /home/ec2-user/.env não encontrado. Confiando nas variáveis de ambiente herdadas/exportadas pelo script pai."
fi

# --- Verificação de Variáveis Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
essential_vars=(
    "NAME"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0"
    "AWS_DB_INSTANCE_TARGET_NAME_0"
    "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    # Removido completamente o log DEBUG das variáveis para segurança e limpeza
    fi
done

if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Falha na verificação de variáveis essenciais. Verifique o .env ou a exportação do script pai. Saindo."
    exit 1
fi
echo "INFO: Verificação de variáveis essenciais concluída com sucesso."

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM (modo extra silencioso)..."
# A saída padrão (stdout) é redirecionada para /dev/null para reduzir logs
# A saída de erro (stderr) ainda será capturada pelo 'exec > >(tee ...)' inicial
sudo yum update -y -q > /dev/null # Boa prática adicionar um update
sudo yum install -y -q httpd jq epel-release aws-cli mysql amazon-efs-utils > /dev/null
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4 (modo extra silencioso)..."
# Redireciona stdout e stderr para /dev/null para silenciar completamente este comando
sudo amazon-linux-extras enable php7.4 -y &> /dev/null
echo "INFO: Instalando PHP 7.4 e módulos (modo extra silencioso)..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap > /dev/null
echo "INFO: Instalação de pacotes de pré-requisitos concluída."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando e iniciando o Apache (httpd)..."
sudo systemctl start httpd
sudo systemctl enable httpd
echo "INFO: Serviço httpd iniciado e habilitado."

# --- Recuperação de Segredos (DB Credentials) ---
echo "INFO: Recuperando credenciais do banco de dados do Secrets Manager..."
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
SECRET_REGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0

if ! command -v aws &>/dev/null || ! command -v jq &>/dev/null; then
    echo "ERRO: Comandos 'aws' ou 'jq' não encontrados no PATH. Instalação falhou?"
    exit 1
fi

# Log genérico sem expor ARN completo ou região, se não necessário
echo "INFO: Tentando obter segredo do Secrets Manager..."
if ! SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME_ARN" --query 'SecretString' --output text --region "$SECRET_REGION"); then
    echo "ERRO: Falha ao executar 'aws secretsmanager get-secret-value'. Verifique ARN, região e permissões IAM."
    exit 1
fi
if [ -z "$SECRET_STRING_VALUE" ]; then
    # Não loga o ARN aqui por segurança
    echo "ERRO: AWS CLI retornou valor vazio_VERSION_SOURCE_REGION_0"
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0"
    "AWS_EFS_FILE_SYSTEM_TARGET_ID_0"
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
    # Removido completamente o log DEBUG das variáveis para segurança e limpeza
    fi
done

if [ "$error_found" -eq 1 ]; then
    echo "ERRO: Falha na verificação de variáveis essenciais. Verifique o .env ou a exportação do script pai. Saindo."
    exit 1
fi
echo "INFO: Verificação de variáveis essenciais concluída com sucesso."

# --- Instalação de Pré-requisitos ---
echo "INFO: Iniciando instalação de pacotes via YUM (modo extra silencioso)..."
# A saída padrão (stdout) é redirecionada para /dev/null para reduzir logs
# A saída de erro (stderr) ainda será capturada pelo 'exec > >(tee ...)' inicial
sudo yum install -y -q httpd jq epel-release aws-cli mysql amazon-efs-utils > /dev/null
echo "INFO: Habilitando amazon-linux-extras para PHP 7.4 (modo extra silencioso)..."
# Redireciona stdout e stderr para /dev/null para silenciar completamente este comando
sudo amazon-linux-extras enable php7.4 -y &> /dev/null
echo "INFO: Instalando PHP 7.4 e módulos (modo extra silencioso)..."
sudo yum install -y -q php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring php-soap > /dev/null
echo "INFO: Instalação de pacotes de pré-requisitos concluída."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando e iniciando o Apache (httpd)..."
sudo systemctl start httpd
sudo systemctl enable httpd
echo "INFO: Serviço httpd iniciado e habilitado."

# --- Recuperação de Segredos (DB Credentials) ---
echo "INFO: Recuperando credenciais do banco de dados do Secrets Manager..."
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
SECRET_REGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0

if ! command -v aws &>/dev/null || ! command -v jq &>/dev/null; then
    echo "ERRO: Comandos 'aws' ou 'jq' não encontrados no PATH. Instalação falhou?"
    exit 1
fi

# Log genérico sem expor ARN completo ou região, se não necessário
echo "INFO: Tentando obter segredo do Secrets Manager..."
if ! SECRET_STRING_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME_ARN" --query 'SecretString' --output text --region "$SECRET_REGION"); then
    echo "ERRO: Falha ao executar 'aws secretsmanager get-secret-value'. Verifique ARN, região e permissões IAM."
    exit 1
fi
if [ -z "$SECRET_STRING_VALUE" ]; then
    # Não loga o ARN aqui por segurança
    echo "ERRO: AWS CLI retornou valor vazio do segredo."
    exit 1
fi
echo "INFO: Segredo bruto obtido com sucesso."

echo "INFO: Extraindo username e password do JSON do segredo..."
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo."
    # Mantém log parcial do segredo para debug essencial SE a extração falhar
    echo "DEBUG: Segredo parcial (se extração falhar): $(echo "$SECRET_STRING_VALUE" | cut -c 1-50)..."
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas com sucesso (Usuário: $DB_USER)." # Não loga a senha

# --- Montagem do EFS ---
echo "INFO: Iniciando montagem do EFS..."
EFS_ID=$AWS_EFS_FILE_SYSTEM_TARGET_ID_0
MOUNT_POINT="/var/www/html"

echo "INFO: Garantindo que o ponto de montagem '$MOUNT_POINT' exista..."
sudo mkdir -p "$MOUNT_POINT"

echo "INFO: Tentando montar EFS '$EFS_ID' em '$MOUNT_POINT'..."
if ! sudo mount -t efs -o tls "$EFS_ID:/" "$MOUNT_POINT"; then
    echo "ERRO: Falha ao do segredo."
    exit 1
fi
echo "INFO: Segredo bruto obtido com sucesso."

echo "INFO: Extraindo username e password do JSON do segredo..."
DB_USER=$(echo "$SECRET_STRING_VALUE" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_STRING_VALUE" | jq -r .password)

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "ERRO: Falha ao extrair 'username' ou 'password' do JSON do segredo."
    # Mantém log parcial do segredo para debug essencial SE a extração falhar
    echo "DEBUG: Segredo parcial (se extração falhar): $(echo "$SECRET_STRING_VALUE" | cut -c 1-50)..."
    exit 1
fi
echo "INFO: Credenciais do banco de dados extraídas com sucesso (Usuário: $DB_USER)." # Não loga a senha

# --- Montagem do EFS ---
echo "INFO: Iniciando montagem do EFS..."
EFS_ID=$AWS_EFS_FILE_SYSTEM_TARGET_ID_0
MOUNT_POINT="/var/www/html"

echo "INFO: Garantindo que o ponto de montagem '$MOUNT_POINT' exista..."
sudo mkdir -p "$MOUNT_POINT"

echo "INFO: Tentando montar EFS '$EFS_ID' em '$MOUNT_POINT'..."
# Adiciona retry simples para a montagem do EFS, que pode falhar ocasionalmente na inicialização
RETRY_COUNT=0
MAX_RETRIES=3
RETRY_DELAY=10
while ! sudo mount -t efs -o tls "$EFS_ID:/" "$MOUNT_POINT"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "ERRO: Falha ao montar EFS '$EFS_ID' em '$MOUNT_POINT' após $MAX_RETRIES tentativas. Verifique ID, Mount Targets, Security Groups (NFS 2049) e Permissões IAM."
 montar EFS '$EFS_ID' em '$MOUNT_POINT'. Verifique ID, Mount Targets, Security Groups (NFS 2049) e Permissões IAM."
    exit 1
fi
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERRO: 'mount' retornou sucesso, mas '$MOUNT_POINT' não é um ponto de montagem válido!"
    exit 1
fi
echo "INFO: EFS '$EFS_ID' montado com sucesso em '$MOUNT_POINT'."

# --- Download e Configuração do WordPress ---
WP_DIR_TEMP="/tmp/wordpress-latest"
mkdir -p "$WP_DIR_TEMP"
cd "$WP_DIR_TEMP"

echo "INFO: Baixando a versão mais recente do WordPress (modo silencioso)..."
wget -q https://wordpress.org/latest.tar.gz
if [ ! -f "latest.tar.gz" ]; then
    echo "ERRO: Falha ao baixar WordPress (latest.tar.gz não encontrado)."
    exit 1
fi

echo "INFO: Extraindo WordPress..."
tar -xzf latest.tar.gz
if [ ! -d "wordpress" ]; then
    echo "ERRO: Diretório 'wordpress' não encontrado após extração."
    exit 1
fi

echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS) (modo menos verboso)..."
sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/" # -a é menos verboso que -av
cd /tmp
rm -rf "$WP_DIR_TEMP"
echo "INFO: Arquivos do WordPress movidos e diretório temporário limpo."

# --- INÍCIO: Criação do Endpoint de Health Check Dedicado ---
HEALTH_CHECK_FILE="$MOUNT_POINT/healthcheck.php"
echo "INFO: Criando arquivo de health check dedicado em '$HEALTH_CHECK_FILE'..."
# Usa sudo bash -c para permitir redirecionamento '>' para um arquivo que precisa de root/apache
sudo bash -c "cat > '$HEALTH_CHECK_FILE'" << EOF
<?php
// Simples health check para o ALB Target Group
// Testa se o PHP está sendo processado corretamente pelo Apache.
// Retorna HTTP 200 OK por padrão se o script for executado sem erros fatais.
// Mantido extremamente leve para não adicionar carga significativa.

http_response_code(200);
header('Content-Type: text/plain'); // Define o tipo de conteúdo
echo "OK";        exit 1
    fi
    echo "WARN: Falha ao montar EFS (tentativa $RETRY_COUNT/$MAX_RETRIES). Tentando novamente em $RETRY_DELAY segundos..."
    sleep $RETRY_DELAY
done

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERRO: 'mount' retornou sucesso, mas '$MOUNT_POINT' não é um ponto de montagem válido após a montagem!"
    exit 1
fi
echo "INFO: EFS '$EFS_ID' montado com sucesso em '$MOUNT_POINT'."

# --- Download e Configuração do WordPress ---
WP_DIR_TEMP="/tmp/wordpress-latest"
mkdir -p "$WP_DIR_TEMP"
cd "$WP_DIR_TEMP"

echo "INFO: Baixando a versão mais recente do WordPress (modo silencioso)..."
wget -q https://wordpress.org/latest.tar.gz
if [ ! -f "latest.tar.gz" ]; then
    echo "ERRO: Falha ao baixar WordPress (latest.tar.gz não encontrado)."
     // Corpo da resposta simples, ALB se importa mais com o status 200

// Não adicione verificações complexas aqui (como conexão com BD)
// a menos que seja absolutamente necessário e você entenda o impacto
// na frequência e no tempo limite do health check do ALB.
// O objetivo principal é verificar se o servidor web e o PHP estão respondendo.
exit; // Termina a execução explicitamente
?>
EOF

# Verifica se o arquivo foi criado com sucesso
if [ ! -f "$HEALTH_CHECK_FILE" ]; then
    echo "ERRO: Falha ao criar o arquivo de health check '$HEALTH_CHECK_FILE'. Verifique permissões no EFS ou espaço."
    # Consideramos isso um erro fatal, pois o ALB não funcionará corretamente
    exit 1
else
    echo "INFO: Arquivo de health check '$HEALTH_CHECK_FILE' criado com sucesso."
    # Asexit 1
fi

echo "INFO: Extraindo WordPress..."
tar -xzf latest.tar.gz
if [ ! -d "wordpress" ]; then
    echo "ERRO: Diretório 'wordpress' não encontrado após extração."
    exit 1
fi

echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS) (modo menos verboso)..."
sudo rsync -a --remove-source- permissões serão ajustadas globalmente na seção seguinte.
fi
# --- FIM: Criação do Endpoint de Health Checkfiles wordpress/ "$MOUNT_POINT/" # -a é menos verboso que -av
cd /tmp
rm -rf "$WP_DIR_TEMP"
echo "INFO: Arquivos do WordPress movidos e diretório temporário Dedicado ---

# --- Configuração do wp-config.php ---
CONFIG_FILE="$MOUNT_POINT/wp-config.php"
echo "INFO: Configurando $CONFIG_FILE..."
if [ ! -f "$MOUNT_POINT/wp-config-sample.php" ]; then
    # Verifica se o WP foi movido corretamente
     limpo."

# --- INÍCIO: Criação do Endpoint de Health Check Dedicado ---
HEALTH_CHECK_FILE="$MOUNT_POINT/healthcheck.php"
echo "INFO: Criando arquivo de health check dedicado em '$HEALTH_CHECK_FILE'..."
# Usa sudo bash -c com Here Document para criar o arquivo como root
sudo bashif ls -l "$MOUNT_POINT/"; then
       echo "DEBUG: Conteúdo de $MOUNT_POINT -c "cat > '$HEALTH_CHECK_FILE'" << EOF
<?php
/*
 * Simples health:"
       ls -l "$MOUNT_POINT/"
    fi
    echo "ERRO: wp-config-sample check para o ALB (ou outro Load Balancer/Monitor).
 * Testa se o PHP está sendo processado corretamente.php não encontrado em '$MOUNT_POINT'. Falha ao mover arquivos do WP?"
    exit 1
fi
sudo cp "$MOUNT_POINT/wp-config-sample.php" "$CONFIG_FILE"

RDS pelo servidor web (Apache).
 * Retorna HTTP 200 OK e um corpo simples por padrão se o script_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT" | cut -d: -f1)

# --- INÍCIO DA MODIFICAÇÃO PARA SED SEGURO for executado sem erros.
 *
 * Mantenha este script o mais leve possível.
 * Evite incluir wp-load.php ou fazer consultas ao banco de dados aqui,
 * pois isso adicionaria latência e depend (DB Creds) ---
echo "INFO: Preparando variáveis para substituição segura no $CONFIG_FILE..."
# Escapa caracteres especiais para o sed (delimitador #, e outros comuns como &, /, \ )
SAFEências desnecessárias para um
 * health check básico de infraestrutura (Servidor Web + PHP).
 */
header_DBNAME=$(echo "$DBNAME" | sed -e 's/[&#\/\\\\]/\\&/g')
("Cache-Control: no-cache, must-revalidate"); // Evitar cache pelo ALB ou intermediários
header("SAFE_DB_USER=$(echo "$DB_USER" | sed -e 's/[&#\/\\\\]/\\&/g')
SAFE_DB_PASSWORD=$(echo "$DB_PASSWORD" | sed -e 'sExpires: Sat, 26 Jul 1997 05:00:00 GMT");/[&#\/\\\\]/\\&/g')
SAFE_ENDPOINT_ADDRESS=$(echo "$ENDPOINT_ADDRESS" // Data no passado
http_response_code(200);
echo "OK";
exit; // | sed -e 's/[&#\/\\\\]/\\&/g')

echo "INFO: Substituindo placeholders de DB no $CONFIG_FILE (com escape)..."
sudo sed -i "s#database_name_here# Termina explicitamente
?>
EOF

# Verifica se o arquivo foi criado
if [ ! -f "$HEALTH_CHECK_FILE" ]; then
    echo "ERRO: Falha ao criar o arquivo de health check '$HEALTH_CHECK$SAFE_DBNAME#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir database_name_here."; exit 1; fi
sudo sed -i "_FILE'."
    # Considerar este erro como fatal para a configuração
    exit 1
else
    echo "INFO: Arquivo de health check '$HEALTH_CHECK_FILE' criado com sucesso."
    # Ass#username_here#$SAFE_DB_USER#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir username_here."; exit 1; fi
 permissões corretas serão aplicadas globalmente na seção 'Ajuste de Permissões' abaixo
fi
# --- FIM: Criação do Endpoint de Health Check Dedicado ---

# --- Configuração do wp-configsudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$CONFIG_FILE"
.php ---
CONFIG_FILE="$MOUNT_POINT/wp-config.php"
echo "INFO:if [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir password_here Configurando $CONFIG_FILE..."
if [ ! -f "$MOUNT_POINT/wp-config-sample.php" ]; then
    echo "ERRO: wp-config-sample.php não encontrado em '$MOUNT_POINT'. Os."; exit 1; fi
sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir localhost (DB_HOST)."; exit 1; fi
echo "INFO: Placeholders de DB substituídos com sucesso." arquivos do WordPress foram copiados corretamente?"
    exit 1
fi
# Copia o sample ANTES de tentar modificá-lo
sudo cp "$MOUNT_POINT/wp-config-sample.php" "$CONFIG_FILE"


# --- FIM DA MODIFICAÇÃO PARA SED SEGURO (DB Creds) ---

# --- Configuração dos SALTS ---
echo "INFO: Obtendo e configurando chaves de segurança (SALTS)RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
ENDPOINT_ADDRESS=$(echo "$RDS_ENDPOINT no $CONFIG_FILE (modo silencioso)..."
SALT=$(curl -sL https://api.wordpress." | cut -d: -f1) # Extrai apenas o endereço/host

# --- INÍCIO DA MODorg/secret-key/1.1/salt/)
if [ -z "$SALT" ]; then
    IFICAÇÃO PARA SED SEGURO (DB Creds) ---
echo "INFO: Preparando variáveis para substituição seguraecho "WARN: Falha ao obter SALTS da API do WordPress. Verifique conectividade/firewall para api.wordpress. no $CONFIG_FILE..."
# Escapa caracteres especiais para o sed (usando # como delimitador)
# Escapaorg. As SALTS não serão configuradas automaticamente."
    # Não sai do script, mas avisa. A: # (delimitador), & (substituição especial), / (comum em senhas/arns), \ (escape)
escape_sed() {
    echo "$1" | sed -e 's/[&#\/\\\\]/\\ instalação do WP pedirá para gerar manualmente.
else
    echo "INFO: Removendo/Inserindo SALTS usando&/g'
}
SAFE_DBNAME=$(escape_sed "$DBNAME")
SAFE_DB_USER=$(escape arquivo temporário..."
    # Remove linhas existentes de SALT para evitar duplicatas
    sudo sed -i "/define( *'_sed "$DB_USER")
SAFE_DB_PASSWORD=$(escape_sed "$DB_PASSWORD")
SAFEAUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_ENDPOINT_ADDRESS=$(escape_sed "$ENDPOINT_ADDRESS")

echo "INFO: Substituindo placeholders de DB no $_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_CONFIG_FILE (com escape)..."
# Usar sudo para cada sed, pois o arquivo agora pode pertencer a root ouIN_SALT'/d;/define( *'NONCE_SALT'/d" "$CONFIG_FILE"

    # --- INÍCIO DA CORREÇÃO SED SALT (v1.8 / v1.9 / v2 apache
# Verifica o status de saída de cada comando sed crucial
sudo sed -i "s#database_name_.0) ---
    # Usa um arquivo temporário para inserir os SALTS de forma robusta
    TEMP_SALT_here#$SAFE_DBNAME#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir database_name_here."; exit 1; fi
sudo sed -i "s#username_here#$SAFE_DB_USER#" "$CONFIG_FILE"
ifFILE=$(mktemp)
    # Escreve o conteúdo ORIGINAL do SALT no arquivo temporário
    echo "$SALT" > "$TEMP_SALT_FILE"

    # Marcador para inserir os SALTS DEPOIS dele (linha [ $? -ne 0 ]; then echo "ERRO: Falha no sed ao substituir username_here."; exit 1; fi
sudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: Falha no define DB_COLLATE)
    DB_COLLATE_MARKER_SED="/define( *'DB_COLLATE'/"
    # Usa o comando 'r' (read file) do sed para inserir o conteúdo do arquivo temp DEPOIS da linha que casa com o marcador
    sudo sed -i -e "$DB_COLLATE_MARK sed ao substituir password_here."; exit 1; fi
sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$CONFIG_FILE"
if [ $? -ne 0 ]; then echo "ERRO: FalER_SED r $TEMP_SALT_FILE" "$CONFIG_FILE"

    # Verifica se o comando sedha no sed ao substituir localhost."; exit 1; fi
echo "INFO: Placeholders de DB substituídos com sucesso." falhou
    if [ $? -ne 0 ]; then
        echo "ERRO: Falha no sed ao inserir SALTS a partir do arquivo temporário."
        rm -f "$TEMP_SALT_FILE" # Garante limpeza
        exit 1
    fi
    # Limpa o arquivo temporário
    rm
# --- FIM DA MODIFICAÇÃO PARA SED SEGURO (DB Creds) ---

# --- Configuração dos SALTS ---
echo "INFO: Obtendo e configurando chaves de segurança (SALTS) no $CONFIG_FILE (modo silencioso)..."
SALT=$(curl -sL https://api.wordpress.org/secret- -f "$TEMP_SALT_FILE"
    echo "INFO: SALTS configurados com sucesso."
    # --- FIM DA CORREÇÃO SED SALT ---
fi # Fim do bloco de configuração dos SALTS

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'key/1.1/salt/)
if [ -z "$SALT" ]; then
    echo "WARN: Falha ao obter SALTS da API do WordPress. Verifique conectividade/firewall para api.wordpress.org. A instalação continudirect' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHOD', 'direct' );"
# Marcador final para inserir ANTES dele: /* That's all, stop editing! Happy publishing. */
ará, mas isso é INSEGURO."
    # Não sai, mas avisa. A instalação web do WP pode gerar salts se faltarem, mas é melhor tê-los aqui.
else
    echo "INFO:MARKER_LINE_SED='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
if [ -f "$CONFIG_FILE" ]; then
    # Verifica se a linha já existe (com espaços Removendo/Inserindo SALTS usando arquivo temporário..."
    # Marcadores para garantir que estamos substituindo a flexíveis)
    if sudo grep -q "define( *'FS_METHOD' *, *'direct' seção correta
    START_MARKER="/\*#@\+/"
    END_MARKER="/\* *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido."
    else
        echo "INFO: Inserindo FS_METHOD 'direct'..."
        # Usa sed para inserir ANTES#@-\*/"
    SALT_BLOCK_MARKER="/Authentication Unique Keys and Salts./"

    # Remove linhas existentes de SALT entre os marcadores padrão, se existirem
    # (Não estritamente necessário com da linha marcador final (comando 'i' - insert before)
        # Escapa a barra no marcador e usa a abordagem de substituição abaixo, mas limpa)
    sudo sed -i "/define( *'AUTH_KEY'/, quebra de linha protegida por \
        sudo sed -i "/$MARKER_LINE_SED/i\\
$FS_METHOD_LINE
" "$CONFIG_FILE"
         # Verifica se o comando sed falhou/define( *'NONCE_SALT'/d" "$CONFIG_FILE"

    # Usa um arquivo temporário para
        if [ $? -ne 0 ]; then
             echo "ERRO: Falha no sed ao inserir os SALTS de forma robusta
    TEMP_SALT_FILE=$(mktemp)
    # Escreve o inserir FS_METHOD."
             exit 1
        fi
        echo "INFO: FS_METHOD 'direct conteúdo ORIGINAL do SALT no arquivo temporário
    echo "$SALT" > "$TEMP_SALT_FILE"

    # Usa o comando 'r' (read file) do sed para inserir o conteúdo do arquivo temp
    # DEPOIS da linha que' adicionado."
    fi
else
    # Isso não deveria acontecer se o cp do sample funcionou
    echo "ERRO: $CONFIG_FILE não encontrado para adicionar FS_METHOD. Algo está errado."
    exit 1 contém o comentário "Authentication Unique Keys and Salts."
    sudo sed -i -e "/$SALT_BLOCK_MARKER/r $TEMP_SALT_FILE" "$CONFIG_FILE"

    # Limpa o arquivo temporário
    rm
fi
echo "INFO: Configuração final do wp-config.php concluída."

# --- Ajuste de Permiss -f "$TEMP_SALT_FILE"
    # Verifica se o comando sed falhou
    if [ $ões ---
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_POINT'? -ne 0 ]; then
        echo "ERRO: Falha no sed ao inserir SALTS a partir..."
# Garante que o usuário e grupo apache existam (geralmente já existem após instalar httpd)
 do arquivo temporário."
        rm -f "$TEMP_SALT_FILE" # Garante limpeza
        exit 1
    fi
    echo "INFO: SALTS configurados com sucesso."
fi # Fim do bloco de configuração dos# Não custa verificar/criar grupo e usuário se necessário (adaptar se usar nginx/outro)
# get SALTS

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'direct' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHODent group apache > /dev/null || sudo groupadd apache
# getent passwd apache > /dev/null || sudo useradd -g apache -s /sbin/nologin -d /var/www apache

# Define propriedade recurs', 'direct' );"
# Marcador final para inserir ANTES dele
MARKER_LINE_SED='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
if [ -f "$CONFIG_FILEivamente para apache:apache (inclui healthcheck.php e tudo do WP)
sudo chown -R apache:apache "$" ]; then
    # Verifica se a linha já existe (com espaços flexíveis)
    if sudo grep -q "MOUNT_POINT"
if [ $? -ne 0 ]; then echo "ERRO: Falha nodefine( *'FS_METHOD' *, *'direct' *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido."
    else
        echo "INFO: Inserindo FS chown para '$MOUNT_POINT'."; exit 1; fi

echo "INFO: Definindo permissões base (755 dirs, 644 files)..."
# Diretórios: rwxr-xr-x (7_METHOD 'direct' antes da linha final de comentário..."
        # Usa sed para inserir ANTES da linha marcador55) - dono pode tudo, grupo/outros podem ler/executar (necessário para navegar)
sudo find final
        # A sintaxe com \ requer nova linha literal ou múltiplas expressões -e
        sudo sed -i "$MOUNT_POINT" -type d -exec chmod 755 {} \;
# Arquivos: rw-r--r-- (644) - dono pode ler/escrever, grupo/outros podem apenas "/$MARKER_LINE_SED/i $FS_METHOD_LINE" "$CONFIG_FILE"

         # Verifica se ler
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;

WP o comando sed falhou
        if [ $? -ne 0 ]; then
             echo "ERRO:_CONTENT_DIR="$MOUNT_POINT/wp-content"
if [ -d "$WP_CONTENT_ Falha no sed ao inserir FS_METHOD."
             exit 1
        fi
        echo "INFO:DIR" ]; then
    echo "INFO: Ajustando permissões mais permissivas para wp-content (permitir FS_METHOD 'direct' adicionado."
    fi
else
    # Isso não deveria acontecer se a cópia do wp-config-sample funcionou
    echo "ERRO: $CONFIG_FILE não encontrado para adicionar FS_METHOD uploads/atualizações via web)..."
    # Diretórios em wp-content: rwxrwxr-x (. Algo deu muito errado."
    exit 1
fi
echo "INFO: Configuração final do wp-config.775) - grupo (apache) também pode escrever
    sudo find "$WP_CONTENT_DIR" -type dphp concluída."

# --- Ajuste de Permissões ---
# Esta seção agora aplicará permissões ao -exec chmod 775 {} \;
    # Arquivos em wp-content: rw-rw-r-- ( healthcheck.php também
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_664) - grupo (apache) também pode escrever
    sudo find "$WP_CONTENT_DIR" -type f -exec chmod 664 {} \;

    UPLOAD_DIR="$WP_CONTENT_DIR/uploadsPOINT'..."
# Garante que o Apache seja o dono de tudo no webroot
sudo chown -R"
    if [ ! -d "$UPLOAD_DIR" ]; then
        echo "INFO: Criando diret apache:apache "$MOUNT_POINT"
echo "INFO: Definindo permissões base (755 dirsório de uploads ($UPLOAD_DIR) pois não existe..."
        sudo mkdir -p "$UPLOAD_DIR"
        , 644 files)..."
# Diretórios: rwxr-xr-x | Arquivos: rw# Certifica que o diretório criado também tenha as permissões corretas
        sudo chown apache:apache "$UPLOAD-r--r-- (inclui healthcheck.php)
sudo find "$MOUNT_POINT" -type_DIR"
        sudo chmod 775 "$UPLOAD_DIR"
    else
         echo "INFO: d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;

WP_CONTENT_DIR="$MOUNT_POINT/wp-content"
if Diretório de uploads ($UPLOAD_DIR) já existe, garantindo permissões (775)..."
         sudo [ -d "$WP_CONTENT_DIR" ]; then
    echo "INFO: Ajustando permissões específicas para wp-content chown apache:apache "$UPLOAD_DIR" # Garante dono caso tenha sido criado manualmente antes
         sudo chmod 77..."
    # Permite que o servidor web escreva em diretórios dentro de wp-content (plugins, temas5 "$UPLOAD_DIR" # Garante permissões
    fi
else
    echo "WARN: Diretório '$WP_CONTENT_DIR' não encontrado. As permissões específicas para ele não serão aplicadas."
fi

if [ -, uploads)
    sudo find "$WP_CONTENT_DIR" -type d -exec chmod 775 {}f "$CONFIG_FILE" ]; then
    echo "INFO: Protegendo $CONFIG_FILE (chmod 66 \; # rwxrwxr-x
    # Permite que o servidor web escreva em arquivos dentro de wp-content0)..."
    # rw-rw---- (660) - Apenas dono (apache) e grupo (ex: atualizações)
    sudo find "$WP_CONTENT_DIR" -type f -exec chmod  (apache) podem ler/escrever. Outros não têm acesso.
    # Isso protege as credenciais do banco664 {} \; # rw-rw-r--

    UPLOAD_DIR="$WP_CONTENT_DIR/uploads"
    echo "INFO: Garantindo diretório de uploads ($UPLOAD_DIR) e permissões (775)... de dados.
    sudo chmod 660 "$CONFIG_FILE"
else
     # Isso seria um erro grave"
    # O diretório de uploads precisa ser gravável pelo Apache
    sudo mkdir -p "$UPLOAD_DIR" # neste ponto
     echo "ERRO: $CONFIG_FILE não encontrado ao tentar definir permissões 660." Cria se não existir
    sudo chown -R apache:apache "$UPLOAD_DIR" # Garante dono
    sudo chmod
     exit 1
fi

# O healthcheck.php terá permissão 644 devido ao find 775 "$UPLOAD_DIR" # Garante permissão rwxrwxr-x
else
    echo " geral, o que é adequado.
# O chown -R já o definiu como apache:apache.

echoWARN: Diretório '$WP_CONTENT_DIR' não encontrado para ajuste fino de permissões."
fi

# "INFO: Ajuste de permissões concluído."

# --- Reiniciar Apache ---
echo "INFO: Rein Protege o wp-config.php um pouco mais
if [ -f "$CONFIG_FILE" ]; then
    iciando o Apache para aplicar todas as configurações..."
sudo systemctl restart httpd
if ! sudo systemctl is-echo "INFO: Protegendo $CONFIG_FILE (chmod 660)..."
    # rw-rw---- (Apache pode ler/escrever, grupo apache pode ler/escrever, outros não podem fazer nada)
    active --quiet httpd; then
    echo "ERRO: Serviço httpd falhou ao reiniciar. Verifique os logs do Apache (/var/log/httpd/error_log)."
    # Tenta mostrar as últimas linhas do log# Isso é um pouco mais restritivo que 644 ou 664
    sudo chmod  de erro do apache
    sudo tail -n 20 /var/log/httpd/error_log
    exit660 "$CONFIG_FILE"
    # Garante que o dono/grupo esteja correto (já deve estar 1
fi
echo "INFO: Apache reiniciado com sucesso."

# --- Conclusão ---
echo pelo chown -R anterior)
    sudo chown apache:apache "$CONFIG_FILE"
else
      "INFO: =================================================="
echo "INFO: --- Script WordPress Setup v2.0 concluído com sucesso! ($(date)) ---"
echo "INFO: Acesse o IP/DNS da instância para finalizar a instalação doecho "ERRO: $CONFIG_FILE não encontrado no final para aplicar permissões 660."
      WordPress via navegador."
echo "INFO: O endpoint de health check para o ALB está em /healthcheck.php# Provavelmente já teria saído antes, mas é uma verificação final
     exit 1
fi
echo "INFO:"
echo "INFO: Log completo em: ${LOG_FILE}"
echo "INFO: ==================================================" Ajuste de permissões concluído."

# --- Reiniciar Apache ---
echo "INFO: Reiniciando o Apache

exit 0
