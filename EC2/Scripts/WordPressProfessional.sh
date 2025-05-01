#!/bin/bash
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1 # Envia stdout/stderr para log e console

echo "[UserData] Starting script execution..."

# --- Configuration (Replace placeholders via Terraform interpolation) ---
# Substitua os valores abaixo pelos atributos correspondentes dos seus recursos Terraform
EFS_ID="fs-xxxxxxxxxxxxxxxxx"  # <-- Ex: ${aws_efs_file_system.EFSName.id}
AP_ID="fsap-xxxxxxxxxxxxxxxxx" # <-- Ex: ${aws_efs_access_point.EFS_Access_Point_Instance2_To_EFSName.id}
EFS_MOUNT_POINT="/var/www/html"
DB_SECRET_ARN="arn:aws:secretsmanager:us-east-1:ACCOUNTID:secret:SecretWPress-xxxxxx" # <-- Ex: ${data.aws_secretsmanager_secret_version.SecretWPress.arn}
DB_NAME="WPRDS"                                                                       # <-- Ex: ${aws_db_instance.WPRDS.db_name}
DB_ENDPOINT_ADDRESS="wprds.xxxxxxxxxx.us-east-1.rds.amazonaws.com"                    # <-- Ex: ${aws_db_instance.WPRDS.address}
REGION="us-east-1"                                                                    # <-- Ex: ${data.aws_region.current.name} ou "us-east-1"
S3_BUCKET_NAME="s3-projeto1-wp-offload"                                               # <-- Ex: ${aws_s3_bucket.s3-projeto1-wp-offload.bucket}
INSTANCE_NAME="InstanceFromTerraform"                                                 # <-- Opcional: ${aws_instance.Instance1.tags.Name}
# --- End Configuration ---

# Log das variáveis configuradas (Senha será omitida abaixo)
echo "[UserData] --- Variable Values ---"
echo "[UserData] EFS_ID: ${EFS_ID}"
echo "[UserData] AP_ID: ${AP_ID}"
echo "[UserData] EFS_MOUNT_POINT: ${EFS_MOUNT_POINT}"
echo "[UserData] DB_SECRET_ARN: ${DB_SECRET_ARN}"
echo "[UserData] DB_NAME: ${DB_NAME}"
echo "[UserData] DB_ENDPOINT_ADDRESS: ${DB_ENDPOINT_ADDRESS}"
echo "[UserData] REGION: ${REGION}"
echo "[UserData] S3_BUCKET_NAME: ${S3_BUCKET_NAME}"
echo "[UserData] INSTANCE_NAME: ${INSTANCE_NAME}"
echo "[UserData] --- End Variable Values ---"

# Atualiza pacotes e instala dependências essenciais
echo "[UserData] Updating packages and installing dependencies (httpd, jq, php, aws-cli, efs-utils, mysql client)..."
sudo yum update -y
sudo yum install -y httpd jq mysql amazon-efs-utils epel-release # Instalações base
sudo amazon-linux-extras enable php7.4 -y
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring # PHP e módulos
sudo yum install -y aws-cli                                                                      # Garante que AWS CLI está instalado

# Cria o ponto de montagem para o EFS (seguro se já existir)
echo "[UserData] Creating EFS mount point: ${EFS_MOUNT_POINT}"
sudo mkdir -p ${EFS_MOUNT_POINT}

# Monta o EFS usando Access Point e TLS
echo "[UserData] Attempting to mount EFS Filesystem ID: ${EFS_ID} via Access Point: ${AP_ID} to ${EFS_MOUNT_POINT}"
MAX_RETRIES=5
RETRY_COUNT=0
MOUNT_SUCCESS=false
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    # Tenta montar
    sudo mount -t efs -o tls,accesspoint=${AP_ID} ${EFS_ID}:/ ${EFS_MOUNT_POINT}
    # Verifica se a montagem foi bem-sucedida
    if mountpoint -q ${EFS_MOUNT_POINT}; then
        echo "[UserData] EFS mounted successfully on attempt $((RETRY_COUNT + 1))."
        MOUNT_SUCCESS=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "[UserData] EFS mount failed. Retrying (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep 5
done

# Verifica se a montagem falhou após todas as tentativas
if [ "$MOUNT_SUCCESS" = false ]; then
    echo "[UserData] FATAL: EFS mount failed after ${MAX_RETRIES} attempts. Please check EFS ID, Access Point ID, Security Groups, and Network connectivity. Aborting script."
    exit 1 # Encerra o script se a montagem falhar
fi

# Adiciona a montagem ao /etc/fstab para persistência (verifica se já existe)
echo "[UserData] Adding EFS mount to /etc/fstab for persistence..."
FSTAB_ENTRY="${EFS_ID}:/ ${EFS_MOUNT_POINT} efs _netdev,tls,accesspoint=${AP_ID} 0 0"
if ! grep -qF -- "$FSTAB_ENTRY" /etc/fstab; then
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    echo "[UserData] fstab entry added."
else
    echo "[UserData] fstab entry already exists."
fi

# Inicia e habilita o Apache
echo "[UserData] Starting and enabling httpd service..."
sudo systemctl start httpd
sudo systemctl enable httpd

# Recupera credenciais do DB do Secrets Manager
echo "[UserData] Retrieving DB credentials from Secrets Manager ARN: ${DB_SECRET_ARN}"
SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id ${DB_SECRET_ARN} --query 'SecretString' --output text --region ${REGION})

# Verifica se a recuperação do segredo falhou
if [ $? -ne 0 ]; then
    echo "[UserData] FATAL: Failed to retrieve secret ${DB_SECRET_ARN}. Check IAM permissions for the EC2 instance profile and the secret ARN/region. Aborting script."
    # Considerar desmontar o EFS aqui? sudo umount ${EFS_MOUNT_POINT}
    exit 1
fi
# Verifica se o valor do segredo está vazio
if [ -z "$SOURCE_NAME_VALUE" ]; then
    echo "[UserData] FATAL: Retrieved secret value from ${DB_SECRET_ARN} is empty. Aborting script."
    exit 1
fi

# Parse das credenciais usando jq
DB_USER=$(echo ${SOURCE_NAME_VALUE} | jq -r .username)
DB_PASSWORD=$(echo ${SOURCE_NAME_VALUE} | jq -r .password)

# Verifica se o parse falhou
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ]; then
    echo "[UserData] FATAL: Failed to parse username or password from secret JSON. Value received: '${SOURCE_NAME_VALUE}'. Check secret format. Aborting script."
    exit 1
fi
echo "[UserData] DB User retrieved: ${DB_USER}"
echo "[UserData] DB Password retrieved: [REDACTED]"

# Instala WP-CLI
echo "[UserData] Installing WP-CLI..."
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
if [ -f wp-cli.phar ]; then
    chmod +x wp-cli.phar
    sudo mv wp-cli.phar /usr/local/bin/wp
    echo "[UserData] WP-CLI installed successfully."
else
    echo "[UserData] WARNING: Failed to download wp-cli.phar. Skipping WordPress and plugin installation via WP-CLI."
fi

# Instala WordPress Core e configura wp-config.php usando WP-CLI (se WP-CLI foi instalado)
if [ -x /usr/local/bin/wp ]; then
    echo "[UserData] Checking if WordPress core needs installation at ${EFS_MOUNT_POINT}..."
    # Executa comandos WP-CLI como o usuário apache para permissões corretas
    if sudo -u apache /usr/local/bin/wp core is-installed --path=${EFS_MOUNT_POINT} --allow-root; then
        echo "[UserData] WordPress core already installed."
    else
        echo "[UserData] Downloading WordPress core..."
        # --allow-root pode ser necessário dependendo do ambiente, mas executar como apache é melhor
        sudo -u apache /usr/local/bin/wp core download --path=${EFS_MOUNT_POINT} --locale=en_US --allow-root

        echo "[UserData] Creating wp-config.php..."
        # Cria wp-config.php. Adiciona --skip-check se o DB não estiver acessível imediatamente (menos ideal)
        sudo -u apache /usr/local/bin/wp config create \
            --path=${EFS_MOUNT_POINT} \
            --dbname=${DB_NAME} \
            --dbuser=${DB_USER} \
            --dbpass=${DB_PASSWORD} \
            --dbhost=${DB_ENDPOINT_ADDRESS} \
            --locale=en_US \
            --allow-root

        # A instalação do core (wp core install) criaria tabelas e usuário admin.
        # É mais seguro deixar o usuário fazer isso via interface web na primeira vez.
        echo "[UserData] WordPress core downloaded and wp-config.php created. Please complete the WordPress installation via your web browser."
    fi

    # Instala e ativa o plugin WP Offload Media Lite
    echo "[UserData] Installing/Activating WP Offload Media Lite plugin..."
    PLUGIN_SLUG="amazon-s3-and-cloudfront"
    if sudo -u apache /usr/local/bin/wp plugin is-installed ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root; then
        echo "[UserData] Plugin ${PLUGIN_SLUG} already installed."
        # Ativa se não estiver ativo
        if ! sudo -u apache /usr/local/bin/wp plugin is-active ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root; then
            echo "[UserData] Activating plugin ${PLUGIN_SLUG}..."
            sudo -u apache /usr/local/bin/wp plugin activate ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root
        else
            echo "[UserData] Plugin ${PLUGIN_SLUG} already active."
        fi
    else
        echo "[UserData] Installing and activating plugin ${PLUGIN_SLUG}..."
        sudo -u apache /usr/local/bin/wp plugin install ${PLUGIN_SLUG} --activate --path=${EFS_MOUNT_POINT} --allow-root
    fi
    echo "[UserData] WP Offload Media Lite installed/activated. IMPORTANT: Configure S3 settings via WP Admin. Ensure the EC2 instance IAM role has appropriate S3 permissions for bucket '${S3_BUCKET_NAME}'."

else
    # Fallback se WP-CLI falhou - Instalação Manual (Menos ideal)
    echo "[UserData] WARNING: WP-CLI not found. Attempting manual WordPress download and config."
    if [ ! -f "${EFS_MOUNT_POINT}/index.php" ]; then # Verifica se o WP já existe
        echo "[UserData] Downloading WordPress manually..."
        wget https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
        if [ -f /tmp/latest.tar.gz ]; then
            echo "[UserData] Extracting WordPress..."
            tar -xzf /tmp/latest.tar.gz -C /tmp/
            echo "[UserData] Moving WordPress files..."
            sudo mv /tmp/wordpress/* ${EFS_MOUNT_POINT}/
            rm /tmp/latest.tar.gz
            rm -rf /tmp/wordpress

            echo "[UserData] Creating wp-config.php manually..."
            sudo cp ${EFS_MOUNT_POINT}/wp-config-sample.php ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/database_name_here/${DB_NAME}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/username_here/${DB_USER}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/password_here/${DB_PASSWORD}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/localhost/${DB_ENDPOINT_ADDRESS}/" ${EFS_MOUNT_POINT}/wp-config.php
            # Adiciona chaves únicas (recomendado)
            SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
            STRING='put your unique phrase here'
            printf '%s\n' "g/$STRING/d" a "$SALT" . w | sudo ed -s ${EFS_MOUNT_POINT}/wp-config.php

            echo "[UserData] Manual WordPress download and config complete. Please complete installation via browser."
        else
            echo "[UserData] ERROR: Failed to download WordPress manually."
        fi
    else
        echo "[UserData] WordPress files seem to exist (manual check). Skipping manual download/config."
    fi
    echo "[UserData] NOTE: WP Offload Media plugin NOT installed due to WP-CLI failure. Install manually via WP Admin."
fi

# Define permissões finais para o diretório web (Executado independentemente do método de instalação do WP)
echo "[UserData] Setting final ownership and permissions for ${EFS_MOUNT_POINT}..."
sudo chown -R apache:apache ${EFS_MOUNT_POINT}
sudo find ${EFS_MOUNT_POINT} -type d -exec chmod 755 {} \;
sudo find ${EFS_MOUNT_POINT} -type f -exec chmod 644 {} \;
# Garante que wp-config.php é legível pelo apache, permissões mais restritas podem ser complexas
sudo chmod 644 ${EFS_MOUNT_POINT}/wp-config.php

# Reinicia o Apache para carregar todas as configurações
echo "[UserData] Restarting httpd service..."
sudo systemctl restart httpd

echo "[UserData] Script execution finished."
