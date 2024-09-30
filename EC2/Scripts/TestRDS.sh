#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Instala o servidor web Apache
sudo yum update -y
sudo yum install -y httpd

# Instalação do AWS CLI para Red Hat-based (Amazon Linux, RHEL, CentOS)
sudo yum install -y aws-cli

#Instalação do NetCat
sudo yum install nc -y

# Inicia o servidor Apache e configura para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# Lê as variáveis de ambiente
ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
# Definição das variáveis
EC2NAME=$Name
SECRET_NAME_ARN=$aws_secretsmanager_secret_version_Source_ARN_
RDS_NAME=$aws_db_instance_Target_Name_
RDS_REGION=$aws_db_instance_Target_Region_
RDS_ACCOUNT=$aws_db_instance_Target_Account_
SECRETREGION=$aws_secretsmanager_secret_version_Source_Region_

# Recupera os valores dos segredos do AWS Secrets Manager
SOURCE_NAME_VALUE=$(aws secretsmanager get-secret-value --secret-id $SECRET_NAME_ARN --query 'SecretString' --output text --region $SECRETREGION)
aws secretsmanager get-secret-value --secret-id arn:aws:secretsmanager:ap-south-1:959864610333:secret:TestRDS-JXwdd3 --query 'SecretString' --output text --region ap-south-1

# Verifica se a leitura da secret foi bem-sucedida
SOURCE_NAME_STATUS=$?
if [ $SOURCE_NAME_STATUS -eq 0 ]; then
    SOURCE_NAME_DISPLAY="Leitura bem sucedida: $SOURCE_NAME_VALUE"
else
    SOURCE_NAME_DISPLAY="Falha na leitura da secret"
fi

RDS_ENDPOINT=$aws_db_instance_Target_Endpoint_

# Extração do endereço e da porta do endpoint
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)
ENDPOINT_PORT=$(echo $RDS_ENDPOINT | cut -d: -f2)

# Tempo limite para a tentativa de conexão, em segundos
TIMEOUT=5

# Utilizando 'nc' (netcat) para verificar a conexão e salvando o resultado na variável "ping"
if nc -z -w $TIMEOUT $ENDPOINT_ADDRESS $ENDPOINT_PORT; then
    ping="True"
else
    ping="False"
fi

# Cria uma página HTML com as informações
cat <<EOF >/var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <title>EC2 Instance Information</title>
</head>
<body>
    <h1>EC2 Instance Information</h1>
    <p><strong>Name:</strong> $EC2NAME</p>
    <p><strong>ID:</strong> $ID</p>
    <p><strong>Secres ARN:</strong> $SECRET_NAME_ARN</p>
    <p><strong>Source Name:</strong> $SOURCE_NAME_DISPLAY</p>
    <p><strong>Target Name:</strong> $RDS_NAME</p>
    <p><strong>Target Region:</strong> $RDS_REGION</p>
    <p><strong>Target Account:</strong> $RDS_ACCOUNT</p>
    <p><strong>Target Endpoint:</strong> $RDS_ENDPOINT</p>
    <p><strong>Resultado Ping:</strong> $ping</p>
</body>
</html>
EOF

# Reinicia o servidor Apache para aplicar as alterações
sudo systemctl restart httpd
