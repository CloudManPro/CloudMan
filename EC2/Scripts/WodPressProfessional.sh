#!/bin/bash
# === Script de Configuração do WordPress em EC2 com EFS e RDS ===
# Versão: 1.9.1 (Baseado na v1.9, Adiciona Health Check endpoint /healthcheck.php)
# DESCRIÇÃO: Instala e configura WordPress em Amazon Linux 2,
# utilizando Apache, PHP 7.4, EFS para /var/www/html, e RDS via Secrets Manager.
# Destinado a ser executado por um script de user data que baixa este do S3.

# --- Configuração Inicial e Logging ---
set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para debug detalhado de comandos

# --- Variáveis (podem ser substituídas por variáveis de ambiente) ---
LOG_FILE="/var/log/wordpress_setup.log"
MOUNT_POINT="/var/www/html" # Diretório raiz do Apache e ponto de montagem do EFS
WP_DIR_TEMP="/tmp/wordpress-temp" # Diretório temporário para download do WP

# --- Redirecionamento de Logs ---
# Redireciona stdout e stderr para o arquivo de log E também para o console
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "INFO: =================================================="
echo "INFO: --- Iniciando Script WordPress Setup ($(date)) ---"
echo "INFO: Logging configurado para: ${LOG_FILE}"
echo "INFO: =================================================="

# --- Verificação de Variáveis de Ambiente Essenciais ---
echo "INFO: Verificando variáveis de ambiente essenciais..."
essential_vars=(
    "EFS_ID"                # ID do EFS (fs-xxxxxxxx)
    "SECRET_NAME_ARN"       # ARN completo do segredo no Secrets Manager
    "SECRET_REGION"         # Região do segredo (ex: us-east-1)
    "AWS_DB_INSTANCE_TARGET_ENDPOINT_0" # Endpoint do RDS (cluster ou instância)
    "DB_NAME"               # Nome do banco de dados WordPress
)
error_found=0
for var_name in "${essential_vars[@]}"; do
    # Verifica se a variável está definida E não está vazia
    if [ -z "${!var_name:-}" ]; then
        echo "ERRO: Variável de ambiente essencial '$var_name' não definida ou vazia."
        error_found=1
        # Removido completamente o log DEBUG das variáveis para segurança e limpeza
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
        # Usando o helper de montagem EFS com TLS habilitado
        if ! sudo mount -t efs -o tls "$efs_id:/" "$mount_point"; then
            echo "ERRO: Falha ao montar EFS '$efs_id' em '$mount_point'."
            echo "INFO: Verifique se o ID do EFS está correto, se o Security Group permite NFS (porta 2049) do EC2,"
            echo "INFO: e se o 'amazon-efs-utils' está instalado corretamente."
            exit 1
        fi
        echo "INFO: EFS montado com sucesso em '$mount_point'."

        echo "INFO: Adicionando montagem do EFS ao /etc/fstab para persistência..."
        # Verifica se a entrada já existe para evitar duplicatas
        if ! grep -q "$efs_id:/ $mount_point efs" /etc/fstab; then
            echo "$efs_id:/ $mount_point efs _netdev,tls 0 0" | sudo tee -a /etc/fstab > /dev/null
            echo "INFO: Entrada adicionada ao /etc/fstab."
        else
            echo "INFO: Entrada para EFS já existe no /etc/fstab."
        fi
    fi
}

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
echo "INFO: Instalação de pacotes concluída."

# --- Montagem do EFS ---
mount_efs "$EFS_ID" "$MOUNT_POINT"

# --- Obtenção de Credenciais do RDS via Secrets Manager ---
echo "INFO: Verificando disponibilidade de AWS CLI e JQ..."
if ! command -v aws &>/dev/null || ! command -v jq &>/dev/null; then
    echo "ERRO: AWS CLI ou JQ não encontrados. Instalação falhou?"
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
        exit 1
    fi

    echo "INFO: Extraindo WordPress..."
    if ! tar -xzf latest.tar.gz; then
        echo "ERRO: Falha ao extrair 'latest.tar.gz'."
        exit 1
    fi
    rm latest.tar.gz # Limpa o arquivo baixado

    # Verifica se o diretório 'wordpress' foi criado pela extração
    if [ ! -d "wordpress" ]; then
        echo "ERRO: Diretório 'wordpress' não encontrado após extração."
        exit 1
    fi

    echo "INFO: Movendo arquivos do WordPress para '$MOUNT_POINT' (EFS) (modo menos verboso)..."
    sudo rsync -a --remove-source-files wordpress/ "$MOUNT_POINT/" # -a é menos verboso que -av
    cd /tmp
    rm -rf "$WP_DIR_TEMP"
    echo "INFO: Arquivos do WordPress movidos e diretório temporário limpo."
fi

# --- Configuração do wp-config.php ---
CONFIG_FILE="$MOUNT_POINT/wp-config.php"

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

    # --- INÍCIO DA MODIFICAÇÃO PARA SED SEGURO (DB Creds) ---
    echo "INFO: Preparando variáveis para substituição segura no $CONFIG_FILE..."
    # Escapa caracteres especiais (&, #, /, \) para uso seguro com sed
    # Usando um delimitador diferente (como #) para evitar conflitos com /
    SAFE_DBNAME=$(echo "$DB_NAME" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_USER=$(echo "$DB_USER" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_DB_PASSWORD=$(echo "$DB_PASSWORD" | sed -e 's/[&#\/\\\\]/\\&/g')
    SAFE_ENDPOINT_ADDRESS=$(echo "$ENDPOINT_ADDRESS" | sed -e 's/[&#\/\\\\]/\\&/g')

    echo "INFO: Substituindo placeholders de DB no $CONFIG_FILE (com escape)..."
    sudo sed -i "s#database_name_here#$SAFE_DBNAME#" "$CONFIG_FILE"
    sudo sed -i "s#username_here#$SAFE_DB_USER#" "$CONFIG_FILE"
    sudo sed -i "s#password_here#$SAFE_DB_PASSWORD#" "$CONFIG_FILE"
    sudo sed -i "s#localhost#$SAFE_ENDPOINT_ADDRESS#" "$CONFIG_FILE"
    echo "INFO: Placeholders de DB substituídos."
    # --- FIM DA MODIFICAÇÃO PARA SED SEGURO (DB Creds) ---

    echo "INFO: Obtendo e configurando chaves de segurança (SALTS) no $CONFIG_FILE..."
    SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
    if [ -z "$SALT" ]; then
        echo "ERRO: Falha ao obter SALTS da API do WordPress. Verifique conectividade/firewall para api.wordpress.org."
        # Se SALTS são críticos, considere sair aqui descomentando a linha abaixo
        # exit 1;
    else
        echo "INFO: Removendo/Inserindo SALTS usando arquivo temporário..."
        # Remove linhas existentes de SALT
        sudo sed -i "/define( *'AUTH_KEY'/d;/define( *'SECURE_AUTH_KEY'/d;/define( *'LOGGED_IN_KEY'/d;/define( *'NONCE_KEY'/d;/define( *'AUTH_SALT'/d;/define( *'SECURE_AUTH_SALT'/d;/define( *'LOGGED_IN_SALT'/d;/define( *'NONCE_SALT'/d" "$CONFIG_FILE"

        # --- INÍCIO DA CORREÇÃO SED SALT (v1.8 / v1.9) ---
        # Usa um arquivo temporário para inserir os SALTS de forma robusta
        TEMP_SALT_FILE=$(mktemp)
        # Escreve o conteúdo ORIGINAL do SALT no arquivo temporário
        echo "$SALT" > "$TEMP_SALT_FILE"

        # Marcador para inserir os SALTS DEPOIS dele
        DB_COLLATE_MARKER="/define( *'DB_COLLATE'/"
        # Insere o conteúdo do arquivo temporário DEPOIS da linha DB_COLLATE
        # Usa o comando 'r' (read file) do sed para inserir o conteúdo do arquivo temp DEPOIS da linha DB_COLLATE
        sudo sed -i -e "$DB_COLLATE_MARKER r $TEMP_SALT_FILE" "$CONFIG_FILE"

        # Limpa o arquivo temporário
        rm -f "$TEMP_SALT_FILE"
        # --- FIM DA CORREÇÃO SED SALT (v1.8 / v1.9) ---

        # Verifica se o comando sed falhou (embora a falha seja menos provável com 'r')
        if [ $? -ne 0 ]; then
            echo "ERRO: Falha no sed ao inserir SALTS a partir do arquivo temporário."
            # Tenta limpar o arquivo temporário mesmo em caso de erro
            rm -f "$TEMP_SALT_FILE" # Garante limpeza
            exit 1
        fi
        echo "INFO: SALTS configurados com sucesso."
    fi # Fim do bloco de configuração dos SALTS
fi # Fim do bloco de criação/configuração inicial do wp-config.php

# --- Forçar Método de Escrita Direto ---
echo "INFO: Verificando/Adicionando FS_METHOD 'direct' ao $CONFIG_FILE..."
FS_METHOD_LINE="define( 'FS_METHOD', 'direct' );"
# Marcador final para inserir ANTES dele
MARKER_LINE_SED='\/\* That'\''s all, stop editing! Happy publishing\. \*\/'
if [ -f "$CONFIG_FILE" ]; then
    # Verifica se a linha já existe
    if sudo grep -q "define( *'FS_METHOD' *, *'direct' *);" "$CONFIG_FILE"; then
        echo "INFO: FS_METHOD 'direct' já está definido."
    else
        echo "INFO: Inserindo FS_METHOD 'direct'..."
        # Usa sed para inserir ANTES da linha marcador final
        if ! sudo sed -i "/$MARKER_LINE_SED/i\\$FS_METHOD_LINE" "$CONFIG_FILE"; then
             echo "ERRO: Falha ao inserir FS_METHOD 'direct' no $CONFIG_FILE."
             # Não sair necessariamente, pode não ser crítico, mas registrar o erro.
        else
             echo "INFO: FS_METHOD 'direct' inserido com sucesso."
        fi
    fi
else
    echo "WARN: $CONFIG_FILE não encontrado para adicionar FS_METHOD. Isso pode ser um problema se a configuração inicial foi pulada e o arquivo não existe."
fi
echo "INFO: Configuração final do wp-config.php concluída."

# --- INÍCIO: Adicionar Arquivo de Health Check ---
echo "INFO: Criando arquivo de health check em '$MOUNT_POINT/healthcheck.php'..."
HEALTH_CHECK_FILE_PATH="$MOUNT_POINT/healthcheck.php"
# Usar sudo com bash -c e here-document para criar o arquivo como root
# Isso garante que funcione mesmo antes da mudança final de propriedade/permissão
sudo bash -c "cat > '$HEALTH_CHECK_FILE_PATH'" << EOF
<?php
// Simple health check endpoint for AWS Target Group or other monitors
// Returns HTTP 200 OK status code if PHP processing is working.
header("HTTP/1.1 200 OK");
header("Content-Type: text/plain");
echo "OK";
exit;
?>
EOF

# Verifica se o arquivo foi criado com sucesso
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    echo "INFO: Arquivo de health check '$HEALTH_CHECK_FILE_PATH' criado com sucesso."
else
    echo "ERRO: Falha ao criar o arquivo de health check '$HEALTH_CHECK_FILE_PATH'."
    # Considerar sair se o health check for crítico
    # exit 1;
fi
# As permissões corretas serão definidas na próxima seção
# --- FIM: Adicionar Arquivo de Health Check ---

# --- Ajustes de Permissões e Propriedade ---
echo "INFO: Ajustando permissões de arquivos/diretórios em '$MOUNT_POINT'..."
# Define o apache como dono para que o WordPress/Apache possam escrever (uploads, plugins, etc.)
sudo chown -R apache:apache "$MOUNT_POINT"
echo "INFO: Definindo permissões base (755 dirs, 644 files)..."
# A saída do find é mínima, mantida para confirmação visual se necessário
sudo find "$MOUNT_POINT" -type d -exec chmod 755 {} \;
sudo find "$MOUNT_POINT" -type f -exec chmod 644 {} \;
# Garante que o wp-config.php não seja gravável por todos (um pouco mais seguro)
if [ -f "$CONFIG_FILE" ]; then
    sudo chmod 640 "$CONFIG_FILE" || echo "WARN: Não foi possível ajustar permissões em $CONFIG_FILE (talvez não exista mais?)"
fi
# Garante que o healthcheck.php tenha as permissões corretas também
if [ -f "$HEALTH_CHECK_FILE_PATH" ]; then
    sudo chmod 644 "$HEALTH_CHECK_FILE_PATH" || echo "WARN: Não foi possível ajustar permissões em $HEALTH_CHECK_FILE_PATH"
    sudo chown apache:apache "$HEALTH_CHECK_FILE_PATH" || echo "WARN: Não foi possível ajustar propriedade de $HEALTH_CHECK_FILE_PATH"
fi
echo "INFO: Permissões e propriedade ajustadas."

# --- Configuração e Inicialização do Apache ---
echo "INFO: Configurando Apache para servir de '$MOUNT_POINT'..."
# Simplesmente usar o diretório padrão que já foi configurado como ponto de montagem
# O arquivo de configuração padrão do Apache (httpd.conf) já usa /var/www/html

echo "INFO: Habilitando e iniciando o serviço httpd..."
sudo systemctl enable httpd
sudo systemctl restart httpd # Usa restart para garantir que quaisquer mudanças sejam aplicadas

# Verifica o status do serviço Apache
if systemctl is-active --quiet httpd; then
    echo "INFO: Serviço httpd iniciado com sucesso."
else
    echo "ERRO: Falha ao iniciar o serviço httpd. Verifique os logs do Apache (/var/log/httpd/error_log)."
    # Tenta mostrar as últimas linhas do log de erro do Apache
    echo "DEBUG: Últimas linhas do log de erro do Apache:"
    sudo tail -n 20 /var/log/httpd/error_log || echo "WARN: Não foi possível ler o log de erro do Apache."
    exit 1
fi

# --- Conclusão ---
echo "INFO: =================================================="
echo "INFO: --- Script WordPress Setup concluído com sucesso! ($(date)) ---"
echo "INFO: Acesse o IP/DNS da instância para finalizar a instalação via navegador."
echo "INFO: O Health Check está disponível em /healthcheck.php"
echo "INFO: Log completo (com menos verbosidade) em: ${LOG_FILE}"
echo "INFO: =================================================="

exit 0
