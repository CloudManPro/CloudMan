#!/bin/bash
# Redireciona stdout e stderr para um arquivo de log e também para o console/syslog
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "[UserData] Starting script execution..."

# --- Configuration (Valores a serem substituídos via Terraform) ---
# Substitua estes placeholders pelos atributos corretos dos seus recursos Terraform
# Exemplo: EFS_DNS_NAME="${aws_efs_file_system.EFSName.dns_name}"
EFS_DNS_NAME="fs-xxxxxxxx.efs.us-east-1.amazonaws.com" # <-- **IMPORTANTE: Use o DNS Name REAL aqui**
AP_ID="fsap-xxxxxxxxxxxxxxxxx"                         # <-- Use o ID do Access Point REAL
EFS_MOUNT_POINT="/var/www/html"
DB_SECRET_ARN="arn:aws:secretsmanager:us-east-1:ACCOUNTID:secret:SecretWPress-xxxxxx" # <-- Use o ARN REAL do Secret
DB_NAME="WPRDS"                                        # <-- Use o Nome do DB REAL
DB_ENDPOINT_ADDRESS="wprds.xxxxxxxxxx.us-east-1.rds.amazonaws.com" # <-- Use o Endpoint REAL do RDS
REGION="us-east-1"                                     # <-- Use a Região REAL
# --- End Configuration ---

# --- Logging das Variáveis Recebidas ---
echo "[UserData] --- Configuration Values Check ---"
echo "[UserData] EFS DNS Name        : ${EFS_DNS_NAME}"
echo "[UserData] Access Point ID     : ${AP_ID}"
echo "[UserData] EFS Mount Point     : ${EFS_MOUNT_POINT}"
echo "[UserData] DB Secret ARN       : ${DB_SECRET_ARN}"
echo "[UserData] DB Name             : ${DB_NAME}"
echo "[UserData] DB Endpoint Address : ${DB_ENDPOINT_ADDRESS}"
echo "[UserData] AWS Region          : ${REGION}"
echo "[UserData] --- End Configuration Values Check ---"

# Verifica se as variáveis críticas têm valores (simples verificação de não vazio)
if [ -z "${EFS_DNS_NAME}" ] || [ "${EFS_DNS_NAME}" == "fs-xxxxxxxx.efs.us-east-1.amazonaws.com" ] || \
   [ -z "${AP_ID}" ] || [ "${AP_ID}" == "fsap-xxxxxxxxxxxxxxxxx" ] || \
   [ -z "${DB_SECRET_ARN}" ] || [ "${DB_SECRET_ARN}" == "arn:aws:secretsmanager:us-east-1:ACCOUNTID:secret:SecretWPress-xxxxxx" ] || \
   [ -z "${DB_ENDPOINT_ADDRESS}" ] || [ "${DB_ENDPOINT_ADDRESS}" == "wprds.xxxxxxxxxx.us-east-1.rds.amazonaws.com" ]; then
    echo "[UserData] FATAL: One or more critical configuration variables seem to be using placeholder values or are empty. Aborting."
    echo "[UserData] Please ensure Terraform is passing the correct values (EFS DNS Name, AP ID, Secret ARN, DB Endpoint)."
    exit 1
fi

# Installs
echo "[UserData] Running yum update..."
sudo yum update -y
echo "[UserData] Installing httpd, jq, mysql, amazon-efs-utils, epel-release, aws-cli..."
sudo yum install -y httpd jq mysql amazon-efs-utils epel-release aws-cli
echo "[UserData] Enabling php7.4 extras..."
sudo amazon-linux-extras enable php7.4 -y
echo "[UserData] Installing PHP modules..."
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring
echo "[UserData] Package installations complete."

# EFS Mount
echo "[UserData] Creating EFS mount point directory: ${EFS_MOUNT_POINT}"
sudo mkdir -p ${EFS_MOUNT_POINT}
echo "[UserData] Starting EFS mount attempts using DNS Name: ${EFS_DNS_NAME} and Access Point: ${AP_ID}..."
MAX_RETRIES=3
RETRY_COUNT=0
MOUNT_SUCCESS=false
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    echo "[UserData] Attempting mount (${RETRY_COUNT}/${MAX_RETRIES})..."
    # --- CORREÇÃO AQUI: Usa EFS_DNS_NAME ---
    sudo mount -t efs -o tls,accesspoint=${AP_ID} ${EFS_DNS_NAME}:/ ${EFS_MOUNT_POINT}
    MOUNT_EXIT_CODE=$?
    if [ ${MOUNT_EXIT_CODE} -eq 0 ] && mountpoint -q ${EFS_MOUNT_POINT}; then
        echo "[UserData] EFS mount successful."
        MOUNT_SUCCESS=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    # Tenta obter erro específico do mount.efs
    MOUNT_ERROR=$(tail -n 5 /var/log/messages | grep 'mount.efs')
    echo "[UserData] EFS mount failed (Exit Code: ${MOUNT_EXIT_CODE}). Error hint: ${MOUNT_ERROR}. Retrying in 3 seconds..."
    sleep 3
done

if [ "$MOUNT_SUCCESS" = false ]; then
    echo "[UserData] FATAL: EFS mount failed after ${MAX_RETRIES} attempts. Aborting."
    sudo systemctl status amazon-efs-mount-watchdog || echo "[UserData] amazon-efs-mount-watchdog status check failed."
    exit 1
fi

echo "[UserData] Adding EFS entry to /etc/fstab..."
# --- CORREÇÃO AQUI TAMBÉM (para fstab): Usa DNS Name ---
FSTAB_ENTRY="${EFS_DNS_NAME}:/ ${EFS_MOUNT_POINT} efs _netdev,tls,accesspoint=${AP_ID} 0 0"
# Verifica se já existe para evitar duplicatas
if ! grep -qF -- "$FSTAB_ENTRY" /etc/fstab; then
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    echo "[UserData] fstab entry added."
else
    echo "[UserData] fstab entry already exists."
fi

# Apache
echo "[UserData] Starting and enabling httpd service..."
sudo systemctl start httpd
sudo systemctl enable httpd
echo "[UserData] httpd service started and enabled."

# Secrets
echo "[UserData] Attempting to retrieve secret from ARN: ${DB_SECRET_ARN}"
SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id ${DB_SECRET_ARN} --query 'SecretString' --output text --region ${REGION})
SECRET_RETRIEVAL_CODE=$?
echo "[UserData] AWS CLI exit code for get-secret-value: ${SECRET_RETRIEVAL_CODE}"

if [ ${SECRET_RETRIEVAL_CODE} -ne 0 ] || [ -z "$SOURCE_NAME_VALUE" ]; then
    echo "[UserData] FATAL: Failed to get secret or secret value is empty. AWS CLI Exit Code: ${SECRET_RETRIEVAL_CODE}. Aborting."
    exit 1
fi
echo "[UserData] Secret retrieval successful."

echo "[UserData] Parsing secret JSON..."
DB_USER=$(echo ${SOURCE_NAME_VALUE} | jq -r .username)
DB_PASSWORD=$(echo ${SOURCE_NAME_VALUE} | jq -r .password)
echo "[UserData] Parsing complete."

if [ -z "$DB_USER" ] || [ "$DB_USER" == "null" ] || [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" == "null" ] ; then
     echo "[UserData] FATAL: Failed to parse username or password from secret JSON. Received: [REDACTED]. Aborting." # Não loga o segredo completo
     exit 1
fi
echo "[UserData] Secret parsing successful. User: ${DB_USER}"

# WP-CLI
echo "[UserData] Attempting to install WP-CLI..."
curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
CURL_EXIT_CODE=$?
if [ ${CURL_EXIT_CODE} -ne 0 ]; then
     echo "[UserData] WARNING: curl command failed (Exit Code: ${CURL_EXIT_CODE}) while downloading WP-CLI."
elif [ ! -f wp-cli.phar ]; then
     echo "[UserData] WARNING: wp-cli.phar not found after curl command."
else
    chmod +x wp-cli.phar
    sudo mv wp-cli.phar /usr/local/bin/wp
    MV_EXIT_CODE=$?
    if [ ${MV_EXIT_CODE} -ne 0 ]; then
        echo "[UserData] WARNING: Failed to move wp-cli.phar to /usr/local/bin/wp (Exit Code: ${MV_EXIT_CODE})."
    else
        echo "[UserData] WP-CLI installed to /usr/local/bin/wp."
    fi
fi

# WordPress Install (via WP-CLI if available)
if [ -x /usr/local/bin/wp ]; then
    echo "[UserData] WP-CLI found. Proceeding with WP-CLI installation path..."
    echo "[UserData] Checking if WP core is installed..."
    if ! sudo -u apache /usr/local/bin/wp core is-installed --path=${EFS_MOUNT_POINT} --allow-root; then
        echo "[UserData] WP core not installed. Downloading..."
        sudo -u apache /usr/local/bin/wp core download --path=${EFS_MOUNT_POINT} --allow-root
        CORE_DOWNLOAD_CODE=$?
        echo "[UserData] WP core download exit code: ${CORE_DOWNLOAD_CODE}"
        if [ ${CORE_DOWNLOAD_CODE} -eq 0 ]; then
             echo "[UserData] Creating wp-config.php via WP-CLI..."
             sudo -u apache /usr/local/bin/wp config create --path=${EFS_MOUNT_POINT} --dbname=${DB_NAME} --dbuser=${DB_USER} --dbpass=${DB_PASSWORD} --dbhost=${DB_ENDPOINT_ADDRESS} --allow-root
             CONFIG_CREATE_CODE=$?
             echo "[UserData] WP config create exit code: ${CONFIG_CREATE_CODE}"
             if [ ${CONFIG_CREATE_CODE} -eq 0 ]; then
                echo "[UserData] WP core downloaded and wp-config.php created. Complete install via browser."
             else
                echo "[UserData] WARNING: wp config create failed."
             fi
        else
             echo "[UserData] WARNING: wp core download failed."
        fi
    else
        echo "[UserData] WP core already installed."
    fi
else
    # Fallback Manual WP
    echo "[UserData] WARNING: WP-CLI not found or failed to install. Attempting manual WP installation."
    echo "[UserData] Checking for existing index.php at ${EFS_MOUNT_POINT}/index.php..."
    if [ ! -f "${EFS_MOUNT_POINT}/index.php" ]; then
        echo "[UserData] Downloading WordPress manually..."
        wget https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
        WGET_EXIT_CODE=$?
        echo "[UserData] Manual wget exit code: ${WGET_EXIT_CODE}"
        if [ ${WGET_EXIT_CODE} -eq 0 ] && [ -f /tmp/latest.tar.gz ]; then
            echo "[UserData] Extracting WordPress manually..."
            tar -xzf /tmp/latest.tar.gz -C /tmp/
            echo "[UserData] Moving WordPress files manually..."
            sudo mv /tmp/wordpress/* ${EFS_MOUNT_POINT}/
            rm /tmp/latest.tar.gz; rm -rf /tmp/wordpress
            echo "[UserData] Creating wp-config.php manually..."
            sudo cp ${EFS_MOUNT_POINT}/wp-config-sample.php ${EFS_MOUNT_POINT}/wp-config.php
            echo "[UserData] Running sed commands for wp-config..."
            sudo sed -i "s/database_name_here/${DB_NAME}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/username_here/${DB_USER}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/password_here/${DB_PASSWORD}/" ${EFS_MOUNT_POINT}/wp-config.php
            sudo sed -i "s/localhost/${DB_ENDPOINT_ADDRESS}/" ${EFS_MOUNT_POINT}/wp-config.php
            echo "[UserData] Getting salts..."
            SALT=$(curl -s -L https://api.wordpress.org/secret-key/1.1/salt/)
            echo "[UserData] Applying salts..."
            printf '%s\n' "g/put your unique phrase here/d" a "$SALT" . w | sudo ed -s ${EFS_MOUNT_POINT}/wp-config.php
            echo "[UserData] Manual WP download/config complete."
        else
            echo "[UserData] ERROR: Failed manual WP download (wget exit code: ${WGET_EXIT_CODE})."
        fi
    else
         echo "[UserData] WP files seem to exist (manual check). Skipping manual download/config."
    fi
fi

# Permissions & Restart
echo "[UserData] Setting final permissions for ${EFS_MOUNT_POINT}..."
sudo chown -R apache:apache ${EFS_MOUNT_POINT}
sudo find ${EFS_MOUNT_POINT} -type d -exec chmod 755 {} \;
sudo find ${EFS_MOUNT_POINT} -type f -exec chmod 644 {} \;
sudo chmod 644 ${EFS_MOUNT_POINT}/wp-config.php # Garante leitura
echo "[UserData] Restarting httpd service..."
sudo systemctl restart httpd

echo "[UserData] Script finished successfully." # Mudado para indicar sucesso no final
