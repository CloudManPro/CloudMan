#!/bin/bash

# Carregar variáveis de ambiente do arquivo .env e converter as chaves para maiúsculas
while IFS='=' read -r key value; do
    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    export "$key=$value"
done </home/ec2-user/.env

# Tenta acesso à internet por 1000 tentativas, esperando 4 segundos entre elas.
MAX_ATTEMPTS=1000
WAIT_TIME=4
TEST_ADDRESS="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
        echo "Tentativa $attempt de $MAX_ATTEMPTS: Testando a conectividade com $TEST_ADDRESS..."
        if curl -I $TEST_ADDRESS >/dev/null 2>&1; then
            echo "Conectividade com a Internet estabelecida."
            return 0
        else
            echo "Conectividade com a Internet falhou. Aguardando $WAIT_TIME segundos para a próxima tentativa..."
            sleep $WAIT_TIME
        fi
    done
    return 1
}
test_connectivity

# Inicia o servidor Apache e configura-o para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# Definição das variáveis (todas em uppercase)
EC2NAME=$NAME
SECRET_NAME_ARN=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0

# Extração do endereço (sem a porta) do endpoint
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

if [ ! -z "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" ] && [ "$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0" != "none" ]; then
    # Recupera os valores dos segredos do AWS Secrets Manager
    SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id $AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 --query 'SecretString' --output text --region $SECRETREGION)
    DB_USER=$(echo $SOURCE_NAME_VALUE | jq -r .username)
    DB_PASSWORD=$(echo $SOURCE_NAME_VALUE | jq -r .password)
else
    # Configura as credenciais da RDS com valores padrão
    DB_USER="TypeNewUserName"
    DB_PASSWORD="TypeNewPassword"
fi

# Verifica se o EFS ARN existe e é diferente de "none"
if [ ! -z "$AWS_EFS_FILE_SYSTEM_TARGET_ARN_0" ] && [ "$AWS_EFS_FILE_SYSTEM_TARGET_ARN_0" != "none" ]; then
    # Montagem do EFS
    EFS_TARGET_ARN=$AWS_EFS_FILE_SYSTEM_TARGET_ARN_0
    sudo mkdir -p /var/www/html
    sudo yum install -y amazon-efs-utils
    sudo mount -t efs $EFS_TARGET_ARN:/ /var/www/html
else
    echo "EFS ARN não definido ou é 'none', pulando a montagem do EFS."
fi

# Configuração do arquivo wp-config.php
cd /var/www/html/
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
sudo sed -i "s/username_here/$DB_USER/" wp-config.php
sudo sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/" wp-config.php

# Ajusta permissões
sudo chown -R apache:apache /var/www/html/
sudo find /var/www/html/ -type d -exec sudo chmod 755 {} \;
sudo find /var/www/html/ -type f -exec sudo chmod 644 {} \;

# Testa a disponibilidade da RDS
MAX_ATTEMPTS_RDS=30
WAIT_TIME_RDS=10
RDS_READY=0

echo "Verificando a disponibilidade da RDS... $ENDPOINT_ADDRESS, $DB_USER, $DBNAME"
for attempt in $(seq 1 $MAX_ATTEMPTS_RDS); do
    if mysql -u "$DB_USER" -p"$DB_PASSWORD" -h "$ENDPOINT_ADDRESS" -e "SHOW DATABASES;" >/dev/null 2>&1; then
        echo "RDS disponível."
        RDS_READY=1
        break
    else
        echo "RDS ainda não disponível $DB_USER $ENDPOINT_ADDRESS. Tentativa $attempt de $MAX_ATTEMPTS_RDS. Aguardando $WAIT_TIME_RDS segundos..."
        sleep $WAIT_TIME_RDS
    fi
done

if [ $RDS_READY -ne 1 ]; then
    echo "RDS não ficou disponível após $MAX_ATTEMPTS_RDS tentativas. Interrompendo a instalação."
    exit 1
fi

# Reinicia o servidor Apache para aplicar as alterações
sudo systemctl restart httpd
