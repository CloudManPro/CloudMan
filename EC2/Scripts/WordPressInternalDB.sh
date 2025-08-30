#!/bin/bash

#Script for Amazon Linux 2023
yum update -y

# Instalar Apache (httpd)
yum install -y httpd

# Instalar MariaDB
# O pacote mariadb-server no AL2023 instala uma versão recente
yum install -y mariadb-server

# Instalar PHP 8.2 e extensões necessárias (o padrão no AL2023)
# Esta é a principal correção: usamos 'yum' diretamente, sem 'amazon-linux-extras'
yum install -y php php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json

# Permitir que o Apache faça conexões de rede para o banco de dados (SELinux)
# Esta linha continua sendo uma boa prática de segurança
setsebool -P httpd_can_network_connect_db 1

# Iniciar e habilitar serviços
systemctl start httpd
systemctl enable httpd
systemctl start mariadb
systemctl enable mariadb

# Aguardar um momento para o serviço do MariaDB estabilizar antes de tentar conectar
sleep 10

# Configurar o banco de dados para o WordPress
# Nenhuma alteração aqui, a lógica está correta
mysql -e "CREATE DATABASE wordpress;"
mysql -e "CREATE USER 'wordpress'@'localhost' IDENTIFIED BY 'password';"
mysql -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Baixar e configurar o WordPress
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz
chown -R apache:apache /var/www/html

# Configurar o wp-config.php
cp wp-config-sample.php wp-config.php
sed -i "s/database_name_here/wordpress/g" wp-config.php
sed -i "s/username_here/wordpress/g" wp-config.php
sed -i "s/password_here/password/g" wp-config.php

# Reiniciar o Apache para garantir que ele carregue todas as configurações e módulos do PHP
systemctl restart httpd
