#!/bin/bash
# As primeiras linhas .env não afetam a instalação, podem ser mantidas ou removidas
echo "NAME=Instance" > /home/ec2-user/.env
echo "REGION=sa-east-1" >> /home/ec2-user/.env
echo "ACCOUNT=061051249868" >> /home/ec2-user/.env

#!/bin/bash
yum update -y

# Instalar Apache
yum install -y httpd

# Instalar MariaDB
yum install -y mariadb-server

# Instalar PHP 7.4 e extensões necessárias
amazon-linux-extras enable php7.4
yum clean metadata
yum install php php-{pdo,mysqlnd,opcache,xml,gd,curl,mbstring,json,zip} -y

# --- ADIÇÃO 1: Permitir que o Apache se conecte ao banco de dados via SELinux ---
setsebool -P httpd_can_network_connect_db 1

# Iniciar e habilitar serviços
systemctl start httpd
systemctl enable httpd
systemctl start mariadb
systemctl enable mariadb

# --- ADIÇÃO 2: Aguardar 10 segundos para o MariaDB iniciar completamente ---
sleep 10

# Configurar banco de dados para WordPress
mysql -e "CREATE DATABASE wordpress;"
mysql -e "CREATE USER 'wordpress'@'localhost' IDENTIFIED BY 'password';"
mysql -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Baixar e configurar WordPress
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz
chown -R apache:apache /var/www/html

# Configurar WordPress para usar o banco de dados
cp wp-config-sample.php wp-config.php
sed -i 's/database_name_here/wordpress/g' wp-config.php
sed -i 's/username_here/wordpress/g' wp-config.php
sed -i 's/password_here/password/g' wp-config.php

# Reiniciar serviços
systemctl restart httpd
