#!/bin/bash

# Carregar variáveis de ambiente do arquivo .env
# (Esta parte continua igual e funcional)
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

# Tenta acesso a internet. Objetivo é aguardar a inicialização.
# (Esta parte continua igual e funcional)
max_attempts=100
wait_time=4
test_address="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $max_attempts); do
        echo "Tentativa $attempt de $max_attempts: Testando a conectividade com $test_address..."
        if curl -Is $test_address >/dev/null 2>&1; then
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

# --- INÍCIO DAS CORREÇÕES PARA AMAZON LINUX 2023 ---

# Atualiza os pacotes e instala o servidor web Apache e outras ferramentas
# AL2023 usa dnf. `yum` é um link simbólico, mas é boa prática usar `dnf`.
# `epel-release` foi removido, pois não é usado no AL2023. `jq` está no repositório principal.
sudo dnf update -y
sudo dnf install -y httpd jq

# Instala PHP e módulos necessários.
# `amazon-linux-extras` foi REMOVIDO no AL2023.
# Instalamos o PHP diretamente. O AL2023 geralmente oferece uma versão recente como padrão (ex: PHP 8.1 ou 8.2).
sudo dnf install -y php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring

# Instalação do AWS CLI - NÃO É NECESSÁRIO
# O AWS CLI v2 já vem pré-instalado nas AMIs do AL2023.
# A linha `sudo dnf install -y aws-cli` foi removida.

# Instala o client MariaDB (compatível com MySQL)
# É a prática recomendada no AL2023 em vez do pacote 'mysql'.
sudo dnf install -y mariadb10.5-server # O server já inclui o client

# --- FIM DAS CORREÇÕES PARA AMAZON LINUX 2023 ---

# Inicia o servidor Apache e configura para iniciar na inicialização
# (Esta parte continua igual e funcional)
sudo systemctl start httpd
sudo systemctl enable httpd

# Definição das variáveis e busca no Secrets Manager
# (Esta parte continua igual e funcional, pois depende do AWS CLI que já está instalado)
EC2NAME=$NAME
SECRET_NAME=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

if [ ! -z "$SECRET_NAME" ] && [ "$SECRET_NAME" != "none" ]; then
    SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query 'SecretString' --output text --region "$SECRETREGION")
    DB_USER=$(echo $SOURCE_NAME_VALUE | jq -r .username)
    DB_PASSWORD=$(echo $SOURCE_NAME_VALUE | jq -r .password)
else
    DB_USER="TypeNewUserName"
    DB_PASSWORD="TypeNewPassword"
fi

# Montagem do EFS
# (Esta parte continua igual e funcional, mas depende da instalação correta do amazon-efs-utils)
if [ ! -z "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" ] && [ "$AWS_EFS_FILE_SYSTEM_TARGET_ID_0" != "none" ]; then
    EFS_ID=$AWS_EFS_FILE_SYSTEM_TARGET_ID_0
    sudo mkdir -p /var/www/html
    # O pacote amazon-efs-utils precisa ser instalado
    sudo dnf install -y amazon-efs-utils
    sudo mount -t efs $EFS_ID:/ /var/www/html
else
    echo "EFS ID não definido ou é 'none', pulando a montagem do EFS."
fi

# Download e configuração do WordPress
# (Esta parte continua igual e funcional)
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
sudo mv wordpress/* /var/www/html/
cd /var/www/html/
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
sudo sed -i "s/username_here/$DB_USER/" wp-config.php
sudo sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/" wp-config.php

# Ajusta permissões
# (Esta parte continua igual e funcional)
sudo chown -R apache:apache /var/www/html/
sudo chmod -R 755 /var/www/html/

# Testa a disponibilidade da RDS
# (Esta parte continua igual e funcional, pois o client mariadb usa o comando `mysql`)
max_attempts_rds=30
wait_time_rds=10
rds_ready=0

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

echo "Instalação do WordPress concluída com sucesso!"
