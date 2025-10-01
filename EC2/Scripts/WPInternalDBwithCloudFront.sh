#!/bin/bash

# --- Error Handling ---
set -e -o pipefail

# --- Logging ---
LOG_FILE="/var/log/wordpress-install-final-v3.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração FINAL v3 (Nginx + SWAP + CloudFront Fix) ---"

# --- 0. CRIAÇÃO DE SWAP (ESSENCIAL PARA INSTÂNCIAS PEQUENAS) ---
echo "Criando arquivo de SWAP de 1GB para estabilidade..."
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
# Tornar o SWAP permanente
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
echo "SWAP ativado com sucesso."

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y

echo "Instalando Nginx, MariaDB, PHP-FPM e utilitários..."
yum install -y nginx mariadb105-server php-fpm php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json openssl wget --allowerasing

# --- 2. Tunning do MariaDB para Baixo Consumo de RAM ---
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
echo "Configuração de memória do MariaDB aplicada."

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando e habilitando os serviços nginx, php-fpm e mariadb..."
systemctl start nginx
systemctl enable nginx
systemctl start php-fpm
systemctl enable php-fpm
systemctl start mariadb
systemctl enable mariadb

echo "Aguardando 10 segundos para o MariaDB iniciar completamente..."
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

echo "Ajustando permissões dos arquivos do WordPress para o usuário do Nginx..."
chown -R nginx:nginx /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) com Fix para CloudFront ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s#password_here#${DB_PASSWORD}#g" wp-config.php

# ***** LINHA CORRIGIDA AQUI *****
SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s wp-config.php

echo "Adicionando configurações de proxy reverso/CloudFront no wp-config.php..."
echo "define('WP_HOME', 'https://cfwp.cloudman.pro');" >> wp-config.php
echo "define('WP_SITEURL', 'https://cfwp.cloudman.pro');" >> wp-config.php
echo "if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {" >> wp-config.php
echo "    \$_SERVER['HTTPS'] = 'on';" >> wp-config.php
echo "}" >> wp-config.php

# --- 7. Configuração do Nginx para o WordPress (Sem modificações arriscadas) ---
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
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires max;
        log_not_found off;
    }
}
EOF

# --- 8. Finalização ---
echo "Reiniciando o Nginx e PHP-FPM para aplicar todas as configurações..."
systemctl restart nginx
systemctl restart php-fpm

# --- Mensagens de Sucesso ---
echo "--- Script de configuração do WordPress concluído com sucesso! ---"
echo "O acesso a esta instância deve ser feito através da sua distribuição CloudFront: https://cfwp.cloudman.pro"
echo ""
echo "--- Informações do Banco de Dados ---"
echo "Banco de dados: ${DB_NAME}"
echo "Usuário do DB: ${DB_USER}"
echo "Senha do DB (gerada aleatoriamente): ${DB_PASSWORD}"
echo "Guarde esta senha em um local seguro!"
echo ""
