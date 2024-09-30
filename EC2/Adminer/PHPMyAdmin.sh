#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Carregar variáveis de ambiente do arquivo .env
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

# Atualizar pacotes
sudo yum update -y

# Remover a versão atual do PHP
sudo yum remove php* -y

logger "desinstalou php"

# Instalar o repositório EPEL
sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

# Instalar o repositório Remi
sudo yum install -y https://rpms.remirepo.net/enterprise/remi-release-7.rpm

# Instalar o YUM Utils
sudo yum install yum-utils -y

# Instalar o plugin de prioridades do YUM
sudo yum install yum-plugin-priorities -y

# Configurar a prioridade do repositório Remi
sudo sed -i 's/\[remi-php72\]/\[remi-php72\]\npriority=1/g' /etc/yum.repos.d/remi-php72.repo

# Habilitar o repositório Remi para PHP 7.2
sudo yum-config-manager --enable remi-php72

logger "instalou novo php 7.2"

# Limpar o cache do YUM
sudo yum clean all

# Instalar o PHP 7.2 e extensões necessárias
sudo yum install php php-mysqlnd php-mbstring php-xml -y

# Instalar o unzip, caso ainda não esteja instalado
sudo yum install unzip -y

# Iniciar e habilitar o serviço Apache
sudo systemctl start httpd
sudo systemctl enable httpd

# Baixar e instalar o PHPMyAdmin
cd /var/www/html
sudo wget https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip
sudo unzip phpMyAdmin-5.2.1-all-languages.zip
sudo mv phpMyAdmin-5.2.1-all-languages phpmyadmin
sudo rm phpMyAdmin-5.2.1-all-languages.zip

# Definir permissões e propriedade para o diretório do PHPMyAdmin
sudo chown apache:apache -R /var/www/html/phpmyadmin
sudo find /var/www/html/phpmyadmin -type d -exec chmod 755 {} \;
sudo find /var/www/html/phpmyadmin -type f -exec chmod 644 {} \;

# Criar um arquivo de configuração para o PHPMyAdmin
echo 'Alias /phpmyadmin /var/www/html/phpmyadmin
<Directory /var/www/html/phpmyadmin>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>' | sudo tee /etc/httpd/conf.d/phpmyadmin.conf

#RDS End Point
RDS_ENDPOINT_VAR="aws_db_instance_Target_Endpoint_0"
# Extrai o hostname sem a porta
RDS_HOST=$(eval echo \$$RDS_ENDPOINT_VAR | sed -e 's/:.*//')
# Extrai apenas a porta
RDS_PORT=$(eval echo \$$RDS_ENDPOINT_VAR | sed -e 's/.*://')
# Adiciona o hostname e a porta ao arquivo config.inc.php do PHPMyAdmin
echo "\$cfg['Servers'][\$i]['host'] = '${RDS_HOST}';" | sudo tee -a /var/www/html/phpmyadmin/config.inc.php
echo "\$cfg['Servers'][\$i]['port'] = '${RDS_PORT}';" | sudo tee -a /var/www/html/phpmyadmin/config.inc.php
echo "\$cfg['Servers'][\$i]['connect_type'] = 'tcp';" | sudo tee -a /var/www/html/phpmyadmin/config.inc.php

logger "END POINT: $RDS_ENDPOINT"

# Reiniciar o serviço Apache
sudo systemctl restart httpd
