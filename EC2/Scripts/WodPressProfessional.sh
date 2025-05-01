#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "[UserData] Init."

# --- Configuration (Replace placeholders via Terraform interpolation) ---
EFS_ID="fs-xxxxxxxxxxxxxxxxx"
AP_ID="fsap-xxxxxxxxxxxxxxxxx"
EFS_MOUNT_POINT="/var/www/html"
DB_SECRET_ARN="arn:aws:secretsmanager:us-east-1:ACCOUNTID:secret:SecretWPress-xxxxxx"
DB_NAME="WPRDS"
DB_ENDPOINT_ADDRESS="wprds.xxxxxxxxxx.us-east-1.rds.amazonaws.com"
REGION="us-east-1"
S3_BUCKET_NAME="s3-projeto1-wp-offload"
# --- End Configuration ---

echo "[UserData] Vars: EFS=${EFS_ID} AP=${AP_ID} DB=${DB_NAME} S3=${S3_BUCKET_NAME}"

# Installs
sudo yum update -y
sudo yum install -y httpd jq mysql amazon-efs-utils epel-release aws-cli
sudo amazon-linux-extras enable php7.4 -y
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring

# EFS Mount
sudo mkdir -p ${EFS_MOUNT_POINT}
MAX_RETRIES=3 # Reduzido para 3 tentativas
RETRY_COUNT=0
MOUNT_SUCCESS=false
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    sudo mount -t efs -o tls,accesspoint=${AP_ID} ${EFS_ID}:/ ${EFS_MOUNT_POINT}
    if mountpoint -q ${EFS_MOUNT_POINT}; then
        echo "[UserData] EFS mount OK."
        MOUNT_SUCCESS=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "[UserData] EFS mount retry (${RETRY_COUNT}/${MAX_RETRIES})"
    sleep 3
done
if [ "$MOUNT_SUCCESS" = false ]; then
    echo "[UserData] FATAL: EFS mount failed. Aborting."
    exit 1
fi
FSTAB_ENTRY="${EFS_ID}:/ ${EFS_MOUNT_POINT} efs _netdev,tls,accesspoint=${AP_ID} 0 0"
echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab # Adição simplificada ao fstab

# Apache
sudo systemctl start httpd
sudo systemctl enable httpd

# Secrets
SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id ${DB_SECRET_ARN} --query 'SecretString' --output text --region ${REGION})
if [ $? -ne 0 ] || [ -z "$SOURCE_NAME_VALUE" ]; then
    echo "[UserData] FATAL: Failed to get/empty secret. Aborting."
    exit 1
fi
DB_USER=$(echo ${SOURCE_NAME_VALUE} | jq -r .username)
DB_PASSWORD=$(echo ${SOURCE_NAME_VALUE} | jq -r .password)
if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ] ; then
     echo "[UserData] FATAL: Failed to parse secret. Aborting."
     exit 1
fi
echo "[UserData] Secret OK. User: ${DB_USER}"

# WP-CLI
echo "[UserData] Installing WP-CLI..."
curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp

# WordPress & Plugin Install (via WP-CLI if available)
if [ -x /usr/local/bin/wp ]; then
    echo "[UserData] Using WP-CLI..."
    if ! sudo -u apache /usr/local/bin/wp core is-installed --path=${EFS_MOUNT_POINT} --allow-root; then
        sudo -u apache /usr/local/bin/wp core download --path=${EFS_MOUNT_POINT} --allow-root
        sudo -u apache /usr/local/bin/wp config create --path=${EFS_MOUNT_POINT} --dbname=${DB_NAME} --dbuser=${DB_USER} --dbpass=${DB_PASSWORD} --dbhost=${DB_ENDPOINT_ADDRESS} --allow-root
        echo "[UserData] WP core/config created. Complete install via browser."
    else
        echo "[UserData] WP core already installed."
    fi
    PLUGIN_SLUG="amazon-s3-and-cloudfront"
    if ! sudo -u apache /usr/local/bin/wp plugin is-installed ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root; then
        sudo -u apache /usr/local/bin/wp plugin install ${PLUGIN_SLUG} --activate --path=${EFS_MOUNT_POINT} --allow-root
        echo "[UserData] S3 Plugin installed & activated."
    elif ! sudo -u apache /usr/local/bin/wp plugin is-active ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root; then
         sudo -u apache /usr/local/bin/wp plugin activate ${PLUGIN_SLUG} --path=${EFS_MOUNT_POINT} --allow-root
         echo "[UserData] S3 Plugin activated."
    else
        echo "[UserData] S3 Plugin already active."
    fi
else
    # Fallback Manual WP (Mantido por robustez, mas consome espaço)
    echo "[UserData] WARNING: WP-CLI failed. Attempting manual WP install."
    if [ ! -f "${EFS_MOUNT_POINT}/index.php" ]; then
        wget https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
        if [ -f /tmp/latest.tar.gz ]; then
            tar -xzf /tmp/latest.tar.gz -C /tmp/
            sudo mv /tmp/wordpress/* ${EFS_MOUNT_POINT}/
            rm /tmp/latest.tar.gz; rm -rf /tmp/wordpress
            sudo cp ${EFS_MOUNT_POINT}/wp-config-sample.php ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/database_name_here/${DB_NAME}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/username_here/${DB_USER}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/password_here/${DB_PASSWORD}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/localhost/${DB_ENDPOINT_ADDRESS}/" ${EFS_MOUNT_POINT}/wp-config.php
            SALT=$(curl -s -L https://api.wordpress.org/secret-key/1.1/salt/)
            printf '%s\n' "g/put your unique phrase here/d" a "$SALT" . w | sudo ed -s ${EFS_MOUNT_POINT}/wp-config.php
            echo "[UserData] Manual WP download/config complete."
        else
            echo "[UserData] ERROR: Failed manual WP download."
        fi
    else
         echo "[UserData] WP files exist (manual check)."
    fi
     echo "[UserData] Manual S3 Plugin install needed via WP Admin."
fi

# Permissions & Restart
sudo chown -R apache:apache ${EFS_MOUNT_POINT}
sudo find ${EFS_MOUNT_POINT} -type d -exec chmod 755 {} \;
sudo find ${EFS_MOUNT_POINT} -type f -exec chmod 644 {} \;
sudo chmod 644 ${EFS_MOUNT_POINT}/wp-config.php # Garante leitura
sudo systemctl restart httpd

echo "[UserData] Finished."
