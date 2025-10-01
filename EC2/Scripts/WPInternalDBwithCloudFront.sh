#!/bin/bash

# --- Error Handling ---
set -e -o pipefail

# --- Logging ---
LOG_FILE="/var/log/wordpress-install-final-definitive.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração DEFINITIVO v8 (com fix para WP-CLI) ---"

# --- 0. CRIAÇÃO DE SWAP ---
echo "Criando arquivo de SWAP de 1GB para estabilidade..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y
echo "Instalando Nginx, MariaDB, PHP-FPM e utilitários..."
# ADICIONADO: php-cli é essencial para o WP-CLI funcionar na linha de comando
yum install -y nginx mariadb105-server php-fpm php-cli php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json openssl wget policycoreutils-python-utils --allowerasing

# --- 2. Tunning do MariaDB ---
echo "Configurando MariaDB para usar menos memória..."
cat << EOF > /etc/my.cnf.d/low-memory-tune.cnf
[mysqld]
innodb_buffer_pool_size = 128M
key_buffer_size = 8M
query_cache_size = 0
query_cache_type = 0
max_connections = 20
performance_schema = OFF
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
EOF

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando e habilitando os serviços..."
systemctl start nginx; systemctl enable nginx
systemctl start php-fpm; systemctl enable php-fpm
systemctl start mariadb; systemctl enable mariadb
echo "Aguardando 10 segundos para o MariaDB iniciar completamente..."
sleep 10

# --- 4. Configuração do Banco de Dados ---
DB_NAME="wordpress_db"; DB_USER="wordpress_user"; DB_PASSWORD=$(openssl rand -base64 12) 
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

# --- 6. Configuração do wp-config.php ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s#password_here#${DB_PASSWORD}#g" wp-config.php
SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s wp-config.php

echo "Adicionando configurações de proxy reverso e método de escrita no wp-config.php..."
PHP_CONFIG_INSERT="\\
// Força HTTPS para ambientes com Proxy Reverso (CloudFront)\\
if (isset(\\\$_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO']) && \\\$_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO'] === 'https') {\\\$_SERVER['HTTPS'] = 'on'; }\\
define('WP_HOME', 'https://cfwp.cloudman.pro');\\
define('WP_SITEURL', 'https://cfwp.cloudman.pro');\\
define('FS_METHOD', 'direct'); // Força método de escrita direta\\
"
sed -i "/<?php/a ${PHP_CONFIG_INSERT}" wp-config.php

# --- 7. AJUSTE DE PERMISSÕES PROATIVO E SEGURO ---
echo "Ajustando permissões de forma granular e segura para o futuro..."
mkdir -p /var/www/html/wp-content/uploads
mkdir -p /var/www/html/wp-content/languages
chown -R nginx:nginx /var/www/html
find /var/www/html/ -type d -exec chmod 755 {} \;
find /var/www/html/ -type f -exec chmod 644 {} \;
find /var/www/html/wp-content -type d -exec chmod g+w {} \;
chcon -t httpd_sys_rw_content_t -R /var/www/html/wp-content

# --- 8. (PROATIVO) Instalação do WP-CLI para Gerenciamento Avançado ---
echo "Instalando WP-CLI..."
wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
echo "Verificando a instalação do WP-CLI..."
/usr/local/bin/wp --info

# --- 9. Configuração do Nginx ---
echo "Configurando o Nginx para servir o site WordPress..."
cat > /etc/nginx/conf.d/wordpress.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.php index.html index.htm;
    server_name _;
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

# --- 10. Finalização ---
echo "Reiniciando o Nginx e PHP-FPM para aplicar todas as configurações..."
systemctl restart nginx
systemctl restart php-fpm

# --- Mensagens de Sucesso ---
echo "--- Script de configuração do WordPress concluído com sucesso! ---"
echo "Acesso: https://cfwp.cloudman.pro"
echo "WP-CLI instalado e disponível globalmente com o comando 'wp'."
echo "DB Name: ${DB_NAME}, DB User: ${DB_USER}, DB Pass: ${DB_PASSWORD}"
echo "Guarde a senha do DB em um local seguro!"
echo ""
