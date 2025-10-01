#!/bin/bash

# --- Error Handling ---
set -e -o pipefail

# --- Logging ---
LOG_FILE="/var/log/wordpress-install-final-v2.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração FINAL (Nginx + SWAP + CloudFront Fix) ---"

# --- 0. CRIAÇÃO DE SWAP ---
echo "Criando arquivo de SWAP de 1GB..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
echo "SWAP ativado."

# --- 1. Instalação de Pacotes ---
echo "Atualizando pacotes e instalando Nginx, MariaDB, PHP-FPM..."
yum update -y
yum install -y nginx mariadb105-server php-fpm php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json openssl wget --allowerasing

# --- 2. Tunning do MariaDB ---
echo "Configurando MariaDB para usar menos memória..."
cat << EOF > /etc/my.cnf.d/low-memory-tune.cnf
[mysqld]
innodb_buffer_pool_size = 128M
key_buffer_size = 8M
max_connections = 20
performance_schema = OFF
EOF

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando serviços..."
systemctl start nginx; systemctl enable nginx
systemctl start php-fpm; systemctl enable php-fpm
systemctl start mariadb; systemctl enable mariadb
echo "Aguardando 10 segundos para o MariaDB iniciar..."
sleep 10

# --- 4. Configuração do Banco de Dados ---
DB_NAME="wordpress_db"
DB_USER="wordpress_user"
DB_PASSWORD=$(openssl rand -base64 12) 
echo "Criando o banco de dados e o usuário para o WordPress..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- 5. Instalação do WordPress ---
echo "Baixando e configurando os arquivos do WordPress..."
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz
chown -R nginx:nginx /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s#password_here#${DB_PASSWORD}#g" wp-config.php
SALT=$(curl -sL https://
