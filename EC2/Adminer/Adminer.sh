#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

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

# Baixar e instalar o Adminer
sudo mkdir /var/www/html/adminer
sudo wget -O /var/www/html/adminer/adminer.php https://www.adminer.org/latest-mysql-en.php

# Definir permissões e propriedade para o diretório do Adminer
sudo chown apache:apache -R /var/www/html/adminer
sudo chmod 755 /var/www/html/adminer
sudo chmod 644 /var/www/html/adminer/adminer.php

# Criar um arquivo de configuração para o Apache para o Adminer
echo 'Alias /adminer /var/www/html/adminer
<Directory /var/www/html/adminer>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    DirectoryIndex adminer.php
</Directory>' | sudo tee /etc/httpd/conf.d/adminer.conf

# Reiniciar o serviço Apache
sudo systemctl restart httpd
