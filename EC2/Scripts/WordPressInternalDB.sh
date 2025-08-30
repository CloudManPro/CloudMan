#!/bin/bash

# --- Error Handling ---
set -e -o pipefail

# --- Centralized Configuration ---
DB_NAME="wordpress_db"
DB_USER="wordpress_user"
DB_PASSWORD="YourStrongPassword123!" 

# --- Logging ---
LOG_FILE="/var/log/wordpress-install.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração do WordPress com MariaDB (Versão para AL2023) ---"

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y

echo "Instalando Apache, MariaDB e módulos PHP..."
# CORREÇÃO FINALÍSSIMA: Usando 'mariadb105-server' (SEM o ponto), conforme a saída do comando 'dnf search'.
yum install -y httpd mariadb105-server php php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json

# --- 2. Configuração de Segurança (SELinux) ---
echo "Configurando a política do SELinux para o banco de dados..."
setsebool -P httpd_can_network_connect_db 1

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando e habilitando os serviços httpd e mariadb..."
systemctl start httpd
systemctl enable httpd
systemctl start mariadb
systemctl enable mariadb

echo "Aguardando 10 segundos para o MariaDB iniciar completamente..."
sleep 10

# --- 4. Configuração do Banco de Dados ---
echo "Criando o banco de dados e o usuário para o WordPress..."
mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 5. Instalação do WordPress ---
echo "Baixando e configurando os arquivos do WordPress..."
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz

echo "Ajustando permissões dos arquivos do WordPress..."
chown -R apache:apache /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s/password_here/${DB_PASSWORD}/g" wp-config.php

SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s wp-config.php

# --- 7. Finalização ---
echo "Reiniciando o Apache para aplicar todas as configurações..."
systemctl restart httpd

echo "--- Script de configuração do WordPress concluído com sucesso! ---"
