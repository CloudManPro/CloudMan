#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Atualiza os pacotes e instala o servidor web Apache
sudo yum update -y
sudo yum install -y httpd

# Instala JSON
sudo yum install -y jq

# Habilita o repositório EPEL
sudo yum install -y epel-release

# Habilita o repositório do Amazon Linux Extra para PHP 7.4
sudo amazon-linux-extras enable php7.4

# Instala PHP 7.4 e módulos necessários
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring

# Instalação do AWS CLI para Red Hat-based (Amazon Linux, RHEL, CentOS)
sudo yum install -y aws-cli

# Inicia o servidor Apache e configura para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# Lê as variáveis de ambiente
ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

# Definição das variáveis
EC2NAME=$NAME
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
S3_BUCKET_ARN=$AWS_S3_BUCKET_TARGET_ARN_0

# Extração do endereço e da porta do endpoint
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

# Recupera os valores dos segredos do AWS Secrets Manager
SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME_ARN --query 'SecretString' --output text --region $SECRETREGION)
DB_USER=$(echo $SOURCE_NAME_VALUE | jq -r .username)
DB_PASSWORD=$(echo $SOURCE_NAME_VALUE | jq -r .password)

# Instala o client MySQL
sudo yum install -y mysql

# Montagem do EFS
EFS_TARGET_ARN=$AWS_EFS_FILE_SYSTEM_TARGET_ARN_0
sudo mkdir /var/www/html
sudo yum install -y amazon-efs-utils
sudo mount -t efs $EFS_TARGET_ARN:/ /var/www/html

# Download do WordPress
wget https://wordpress.org/latest.tar.gz
# Mover o WordPress para o diretório do servidor web
tar -xzf latest.tar.gz
sudo mv wordpress/* /var/www/html/

# Configuração do arquivo wp-config.php
cd /var/www/html/
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
sudo sed -i "s/username_here/$DB_USER/" wp-config.php
sudo sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/" wp-config.php

# Ajusta permissões
sudo chown -R apache:apache /var/www/html/
sudo chmod -R 755 /var/www/html/

# Reinicia o servidor Apache para aplicar as alterações
sudo systemctl restart httpd
