#!/bin/bash
# Obtém credencial de uma tabela DynamoDB e configura o usuário padrão para acesso no terminal

# Carregar variáveis de ambiente do arquivo .env e converter as chaves para MAIÚSCULAS
while IFS='=' read -r key value; do
    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    export "$key=$value"
done </home/ec2-user/.env

# Obter as variáveis para acesso ao DynamoDB (essas variáveis devem estar definidas no arquivo .env)
NAME=$(printenv NAME)
TABLE_NAME=$(printenv AWS_DYNAMODB_TABLE_SOURCE_NAME_0)
REGION=$(printenv AWS_DYNAMODB_TABLE_SOURCE_REGION_0)
ACCOUNT_ID=$(printenv AWS_DYNAMODB_TABLE_SOURCE_ACCOUNT_0)

# Imprimir variáveis de ambiente para depuração
echo "NAME: $NAME"
echo "TABLE_NAME: $TABLE_NAME"
echo "REGION: $REGION"
echo "ACCOUNT_ID: $ACCOUNT_ID"

# Verificar se a tabela do DynamoDB está definida
if [ -n "$TABLE_NAME" ]; then
    # Ler as credenciais da tabela DynamoDB usando o nome (ID) da instância
    RESPONSE=$(aws dynamodb get-item --table-name "$TABLE_NAME" --key "{\"NAME\":{\"S\":\"$NAME\"}}" --region "$REGION")

    # Extrair UserName e Password da resposta do DynamoDB
    USER_NAME=$(echo "$RESPONSE" | grep -A1 '"UserName":' | grep '"S":' | cut -d '"' -f4)
    PASSWORD=$(echo "$RESPONSE" | grep -A1 '"Password":' | grep '"S":' | cut -d '"' -f4)

    # Configurar o usuário com a senha obtida
    if [ -n "$USER_NAME" ] && [ -n "$PASSWORD" ]; then
        # Adiciona o usuário (sem criar diretório home)
        useradd "$USER_NAME" -M
        # Define a senha do usuário
        echo "$USER_NAME:$PASSWORD" | chpasswd
    fi
fi
