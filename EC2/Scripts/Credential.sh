#!/bin/bash
# Obtem credencial de uma DynamoDB e configura o usuário padrão para acesso no terminal

# Carregar variáveis de ambiente do arquivo .env
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

# Obter o nome da instância da variável de ambiente

# Variáveis para acesso ao DynamoDB (essas variáveis devem ser configuradas previamente)
NAME=$(printenv Name)
TABLE_NAME=$(printenv aws_dynamodb_table_Source_Name_Credential)
REGION=$(printenv aws_dynamodb_table_Source_Region_Credential)
ACCOUNT_ID=$(printenv aws_dynamodb_table_Source_Account_Credential)

# Imprimir variáveis de ambiente para depuração
echo "NAME: $NAME"
echo "TABLE_NAME: $TABLE_NAME"
echo "REGION: $REGION"
echo "ACCOUNT_ID: $ACCOUNT_ID"

# Verificar se a tabela do DynamoDB está definida
if [ -n "$TABLE_NAME" ]; then
    # Ler as credenciais da tabela DynamoDB usando o ID da instância
    RESPONSE=$(aws dynamodb get-item --table-name $TABLE_NAME --key "{\"Name\":{\"S\":\"$NAME\"}}" --region $REGION)

    # Extrair UserName e Password
    # Extrair UserName e Password da resposta do DynamoDB
    USER_NAME=$(echo "$RESPONSE" | grep -A1 '"UserName":' | grep '"S":' | cut -d '"' -f4)
    PASSWORD=$(echo "$RESPONSE" | grep -A1 '"Password":' | grep '"S":' | cut -d '"' -f4)

    # Configurar o usuário com a senha obtida
    if [ -n "$USER_NAME" ] && [ -n "$PASSWORD" ]; then
        # Adiciona o usuário (sem criar diretório home)
        useradd $USER_NAME -M

        # Define a senha do usuário
        echo "$USER_NAME:$PASSWORD" | chpasswd
    fi
fi
