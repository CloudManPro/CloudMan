#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Instalar AWS CLI e netcat
yum install -y aws-cli

# Obter o nome da tabela DynamoDB da ARN
DYNAMODB_TABLE=$(echo $aws_dynamodb_table_Target_ARN_ | awk -F'/' '{print $2}')

# Obter IPs da instância
PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

# Definir a região da AWS
AWS_REGION="us-east-1"

# Função para salvar IPs no DynamoDB
save_ips_to_dynamodb() {
    JSON_DATA="{\"ID\": {\"S\": \"$INSTANCE_ID\"}, \"IP\": {\"S\": \"$PRIVATE_IP\"}, \"PingStatus\": {\"S\": \"Unknown\"}}"
    aws dynamodb put-item --table-name $DYNAMODB_TABLE --item "$JSON_DATA" --region $AWS_REGION
}

# Função para atualizar o status de ping no DynamoDB
update_ping_status() {
    aws dynamodb update-item --table-name $DYNAMODB_TABLE --key "{\"ID\": {\"S\": \"$INSTANCE_ID\"}}" --update-expression "SET PingStatus = :s" --expression-attribute-values "{\":s\": {\"S\": \"$1\"}}" --region $AWS_REGION
}

# Função para ler IPs do DynamoDB e fazer pings
make_pings() {
    IPs=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --query "Items[*].IP.S" --output text)
    for ip in $IPs; do
        if [ "$ip" != "$PRIVATE_IP" ]; then
            if ping -c 1 $ip &>/dev/null; then
                update_ping_status "Online"
            else
                update_ping_status "Offline"
            fi
        fi
    done
}

# Salvar IPs no DynamoDB
save_ips_to_dynamodb

# Loop para ler IPs e fazer pings
while true; do
    make_pings
    sleep 5
done
