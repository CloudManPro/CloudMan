#!/bin/bash

# --- Error Handling ---
set -e -o pipefail

# --- Logging ---
LOG_FILE="/var/log/wordpress-install-universal.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração do WordPress com MariaDB (Versão Universal para AL2023) ---"

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y

echo "Instalando Apache, MariaDB, PHP e utilitários..."
yum install -y httpd mariadb105-server php php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json openssl wget --allowerasing

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

echo "Ajustando permissões dos arquivos do WordPress..."
chown -R apache:apache /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s#password_here#${DB_PASSWORD}#g" wp-config.php

SALT=$(curl -sL https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s wp-config.php

# --- 7. Finalização ---
echo "Reiniciando o Apache para aplicar todas as configurações..."
systemctl restart httpd

# --- LÓGICA UNIVERSAL DE DETECÇÃO DE ENDEREÇO ---
echo "--- Script de configuração do WordPress concluído com sucesso! ---"
echo ""

# Tenta obter o endereço IPv4 público. O comando curl falhará silenciosamente se não houver um.
# O || true garante que o script não pare aqui caso o comando falhe (por causa do set -e).
PUBLIC_IPV4=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)

# Se um endereço IPv4 foi encontrado, mostre-o. Este é o cenário standalone.
if [ -n "$PUBLIC_IPV4" ]; then
    echo "Cenário STANDALONE detectado (com IP público IPv4)."
    echo "Acesse o seu site em: http://${PUBLIC_IPV4}"
    echo "Para usar HTTPS, configure um domínio e um certificado SSL."
else
    # Se não houver IPv4, obtenha o DNS público (que resolverá para IPv6). Este é o cenário CloudFront.
    PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname || true)
    echo "Cenário CLOUDFRONT / IPv6-only detectado."
    echo "O acesso a esta instância deve ser feito através da sua distribuição CloudFront."
    echo "DNS da Instância (para referência na configuração da origem do CloudFront): ${PUBLIC_DNS}"
fi

echo ""
echo "--- Informações do Banco de Dados ---"
echo "Banco de dados: ${DB_NAME}"
echo "Usuário do DB: ${DB_USER}"
echo "Senha do DB (gerada aleatoriamente): ${DB_PASSWORD}"
echo "Guarde esta senha em um local seguro!"
echo ""
