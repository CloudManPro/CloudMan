#!/bin/bash

# Carregar variáveis de ambiente do arquivo .env
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

#Tenta acesso a internet por 10x a cada 30s. Objetivo é aguardar a inicialização, se houver alguma dependencia de alguma
#instância, como um NAT por exemplo,  para ter acesso a internet.
max_attempts=1000
wait_time=4
test_address="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $max_attempts); do
        echo "Tentativa $attempt de $max_attempts: Testando a conectividade com $test_address..."
        if curl -I $test_address >/dev/null 2>&1; then
            echo "Conectividade com a Internet estabelecida."
            return 0
        else
            echo "Conectividade com a Internet falhou. Aguardando $wait_time segundos para a próxima tentativa..."
            sleep $wait_time
        fi
    done
    return 1
}
test_connectivity

# Atualiza os pacotes e instala o servidor web Apache
sudo yum update -y
sudo yum install -y httpd jq epel-release

# Habilita o repositório do Amazon Linux Extra para PHP 7.4
sudo amazon-linux-extras enable php7.4

# Instala PHP 7.4 e módulos necessários
sudo yum install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring

# Instalação do AWS CLI para Red Hat-based (Amazon Linux, RHEL, CentOS)
sudo yum install -y aws-cli

# Inicia o servidor Apache e configura para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# Definição das variáveis
EC2NAME=$Name
SECRET_NAME_ARN=$aws_secretsmanager_secret_version_Source_ARN_0
DBNAME=$aws_db_instance_Target_Name_0
SECRETREGION=$aws_secretsmanager_secret_version_Source_Region_0
RDS_ENDPOINT=$aws_db_instance_Target_Endpoint_0
# Extração do endereço e da porta do endpoint
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

if [ ! -z "$aws_secretsmanager_secret_version_Source_ARN_0" ] && [ "$aws_secretsmanager_secret_version_Source_ARN_0" != "none" ]; then
    # Recupera os valores dos segredos do AWS Secrets Manager
    SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id $aws_secretsmanager_secret_version_Source_ARN_0 --query 'SecretString' --output text --region $SECRETREGION)
    DB_USER=$(echo $SOURCE_NAME_VALUE | jq -r .username)
    DB_PASSWORD=$(echo $SOURCE_NAME_VALUE | jq -r .password)
else
    # Configura as credenciais da RDS com valores padrão
    DB_USER="TypeNewUserName"
    DB_PASSWORD="TypeNewPassword"
fi

#instala o client MySQL
sudo yum install -y mysql

# Verifica se o EFS ID existe e é diferente de none
if [ ! -z "$aws_efs_file_system_Target_ID_0" ] && [ "$aws_efs_file_system_Target_ID_0" != "none" ]; then
    # Montagem do EFS
    EFS_ID=$aws_efs_file_system_Target_ID_0
    sudo mkdir -p /var/www/html
    sudo yum install -y amazon-efs-utils
    sudo mount -t efs $EFS_ID:/ /var/www/html
else
    echo "EFS ID não definido ou é 'none', pulando a montagem do EFS."
fi

# Testa a disponibilidade da RDS
max_attempts_rds=30
wait_time_rds=10
rds_ready=0

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

echo "Verificando a disponibilidade da RDS..."
for attempt in $(seq 1 $max_attempts_rds); do
    if mysql -u "$DB_USER" -p"$DB_PASSWORD" -h "$ENDPOINT_ADDRESS" -e "SHOW DATABASES;" >/dev/null 2>&1; then
        echo "RDS disponível."
        rds_ready=1
        break
    else
        echo "RDS ainda não disponível $DB_USER $ENDPOINT_ADDRESS. Tentativa $attempt de $max_attempts_rds. Aguardando $wait_time_rds segundos..."
        sleep $wait_time_rds
    fi
done

if [ $rds_ready -ne 1 ]; then
    echo "RDS não ficou disponível após $max_attempts_rds tentativas. Interrompendo a instalação."
    exit 1
fi

# Reinicia o servidor Apache para aplicar as alterações
sudo systemctl restart httpd
