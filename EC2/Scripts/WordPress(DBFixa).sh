#!/bin/bash

# Atualizar os pacotes
sudo yum update -y

# Instalar Apache e extensões PHP
sudo amazon-linux-extras install
sudo yum install -y httpd

# Iniciar e habilitar o Apache para iniciar na inicialização do sistema
sudo systemctl start httpd
sudo systemctl enable httpd

# Baixar e descompactar o WordPress
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

# Mover o WordPress para o diretório do servidor web
sudo mv wordpress/* /var/www/html/

# Ajustar as permissões
sudo chown -R apache:apache /var/www/html
sudo chmod -R 755 /var/www/html

# Configurar o arquivo wp-config.php
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

# Atualizar as configurações do wp-config.php para usar o RDS
# Substitua 'rds_endpoint', 'rds_db_name', 'rds_username', e 'rds_password'
# pelos valores correspondentes do seu RDS
sudo sed -i 's/database_name_here/WordpressDBBasic/' /var/www/html/wp-config.php
sudo sed -i 's/username_here/TypeNewUserName/' /var/www/html/wp-config.php
sudo sed -i 's/password_here/TypeNewPassword/' /var/www/html/wp-config.php
sudo sed -i "s/localhost/wordpressdbbasic.cvbo61erwqo2.ap-south-1.rds.amazonaws.com/" /var/www/html/wp-config.php

# Permitir o tráfego HTTP através do firewall
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
