#Este Script realiza um tetse de conectividade em uma dynamodb, s3 e EFS. Escreve um dado aleatório em cada recurso e em seguida lê a apresenta na tela.

#!/bin/bash

# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Create a session token for IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Get the availability zone, instance ID, and IP address using the session token
availability_zone=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
ip_address=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

# Definir variáveis de ambiente para os nomes dos recursos AWS
DYNAMODB_TABLE=$aws_dynamodb_table_Target_Name_
DYNAMODB_REGION=$aws_dynamodb_table_Target_Region_
EFS_NAME=$aws_efs_file_system_Target_Name_
EFS_REGION=$aws_efs_file_system_Target_Region_
S3_BUCKET=$aws_s3_bucket_Target_Name_
S3_REGION=$aws_s3_bucket_Target_Region_
EC2NAME=$Name
EFS_ARN=$aws_efs_file_system_Target_ARN_
EFS_ACCESS_POINT_ID=$aws_efs_access_point_Target_ID_
# Atualizar pacotes e instalar AWS CLI
sudo yum update -y
sudo yum install -y aws-cli

#Monatgem do EFS
# Extrair o ID do EFS do ARN
EFS_ID=$(echo $EFS_ARN | cut -d '/' -f 2)
# Instalar os utilitários necessários para trabalhar com o Amazon EFS
sudo yum install -y amazon-efs-utils
# Criar um diretório local para montar o EFS
sudo mkdir -p /mnt/efs
# Montar o EFS no diretório criado
sudo mount -t efs -o tls,accesspoint=$EFS_ACCESS_POINT_ID $EFS_ID:/ /mnt/efs
# Adicionar a montagem ao fstab para que ela seja remontada automaticamente após reinicializações
echo "$EFS_ID:/ /mnt/efs efs defaults,_netdev,tls,accesspoint=$EFS_ACCESS_POINT_ID 0 0" >>/etc/fstab

# Gerar um dado aleatório
data=$(date +%s)

# Inserir dados no DynamoDB
aws dynamodb put-item --table-name "$DYNAMODB_TABLE" --item '{"ID": {"S": "testKey"}, "data": {"N": "'$data'"}}' --region "$DYNAMODB_REGION"

# Criar um arquivo no EFS com dados aleatórios
echo $data >/mnt/efs/data.txt

# Inserir dados no S3
echo $data | aws s3 cp - s3://$S3_BUCKET/data.txt --region "$S3_REGION"

# Ler os dados de cada serviço e gerar a página HTML
dynamodb_data=$(aws dynamodb get-item --table-name "$DYNAMODB_TABLE" --key '{"ID": {"S": "testKey"}}' --region "$DYNAMODB_REGION" --query 'Item.data.N' --output text)
efs_data=$(cat /mnt/efs/data.txt)
s3_data=$(aws s3 cp s3://$S3_BUCKET/data.txt - --region "$S3_REGION")

# Instalar e iniciar o Apache
sudo yum install -y httpd
sudo systemctl start httpd
sudo systemctl enable httpd

# Gerar conteúdo HTML
cat <<EOF >/var/www/html/index.html
<html>
<head><title>Teste de Conectividade AWS</title></head>
<body>
<h1>Resultados:</h1>
<p><strong>EC2 Name:</strong> $EC2NAME</p>
<p><strong>EC2 ID:</strong> $instance_id</p>
<p><strong>EC2 IP:</strong> $ip_address</p>
<p><strong>EC2 AZ:</strong> $availability_zone</p>
<p><strong>DynamoDB Table Name:</strong> $DYNAMODB_TABLE</p>
<p>DynamoDB Data: $dynamodb_data</p>
<p>EFS Name: $EFS_NAME</p>
<p>EFS ID: $EFS_ID</p>
<p>EFS Access Point ID: $EFS_ACCESS_POINT_ID</p>
<p>EFS Data: $efs_data</p>
<p>S3 Name: $S3_BUCKET</p>
<p>S3 Data: $s3_data</p>
</body>
</html>
EOF
