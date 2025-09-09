#!/bin/bash
# Para o script no primeiro erro, facilitando o debug.
set -e

# Carrega as variáveis de ambiente a partir do arquivo .env
set -a
source /home/ec2-user/.env
set +a

# --- Instalação de Pacotes para Amazon Linux 2023 ---
sudo dnf update -y
sudo dnf install -y httpd jq php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring amazon-efs-utils

# Inicia o servidor Apache e configura para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# --- Recuperação de Segredos ---
SECRET_NAME=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0

# Extração do endereço do endpoint (sem a porta)
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

# Recupera os valores dos segredos do AWS Secrets Manager
SECRET_VALUE_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query 'SecretString' --output text --region "$SECRETREGION")
DB_USER=$(echo "$SECRET_VALUE_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_VALUE_JSON" | jq -r .password)

# --- Montagem do EFS com Retry Logic ---
sudo mkdir -p /var/www/html
MAX_RETRIES=12
RETRY_COUNT=0
MOUNT_SUCCESS=false
until [ $RETRY_COUNT -ge $MAX_RETRIES ]
do
    echo "Tentando montar o EFS (tentativa $((RETRY_COUNT+1))/$MAX_RETRIES)..."
    mount -t efs "$EFS_ID":/ /var/www/html
    if [ $? -eq 0 ]; then
        MOUNT_SUCCESS=true
        echo "EFS montado com sucesso."
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT+1))
    sleep 10
done

if [ "$MOUNT_SUCCESS" = false ]; then
    echo "Falha ao montar o EFS após $MAX_RETRIES tentativas."
    exit 1
fi


# Adiciona entrada no fstab para remontar após reinicialização (Boa Prática)
if ! grep -q "$EFS_ID" /etc/fstab; then
  echo "$EFS_ID:/ /var/www/html efs _netdev,tls 0 0" | sudo tee -a /etc/fstab
fi

# --- Instalação do WordPress (Apenas se não estiver instalado) ---
if [ ! -f /var/www/html/wp-config.php ]; then
    cd /tmp
    wget https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    sudo mv wordpress/* /var/www/html/

    # Configuração do arquivo wp-config.php
    cd /var/www/html/
    sudo cp wp-config-sample.php wp-config.php
    sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
    sudo sed -i "s/username_here/$DB_USER/" wp-config.php
    sudo sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
    sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/" wp-config.php

    # Adicionar chaves de segurança (Melhoria de Segurança)
    SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
    STRING_TO_REPLACE="'put your unique phrase here'"
    printf '%s\n' "g/$STRING_TO_REPLACE/d" a "$SALT" . w | ed -s wp-config.php
fi

# Ajusta permissões
sudo chown -R apache:apache /var/www/html/
sudo chmod -R 755 /var/www/html/

# Reinicia o servidor Apache para aplicar as alterações
sudo systemctl restart httpd
