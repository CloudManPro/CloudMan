#!/bin/bash

LOGFILE="/var/log/user-data.log"
exec >$LOGFILE 2>&1
yum update -y
sudo amazon-linux-extras install epel -y
yum install -y nginx git
systemctl start nginx
systemctl enable nginx

# Obter o token para IMDSv2
METADATA_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Capturar os metadados da instância usando IMDSv2
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $METADATA_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $METADATA_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $METADATA_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $METADATA_TOKEN" http://169.254.169.254/latest/meta-data/instance-type)

# Clonar o repositório do jogo 2048
cd /usr/share/nginx/html
git clone https://github.com/gabrielecirulli/2048.git

# Criar a página de boas-vindas em /logged
echo "<!DOCTYPE html>
<html>
<head>
    <title>Welcome to 2048</title>
</head>
<body>
    <h2>Welcome to 2048 on AWS</h2>
    <p>Instance ID: ${INSTANCE_ID}</p>
    <p>Public IP: ${PUBLIC_IP}</p>
    <p>Availability Zone: ${AZ}</p>
    <p>Instance Type: ${INSTANCE_TYPE}</p>
    <button onclick=\"window.location.href='/2048'\">Start Game</button>
</body>
</html>" >/usr/share/nginx/html/logged.html

# Criar a página inicial com botão de login
echo "<!DOCTYPE html>
<html>
<head>
    <title>Login</title>
</head>
<body>
    <h2>Welcome to AWS</h2>
    <button onclick=\"window.location.href='COGNITO_URL'\">Login</button>
</body>
</html>" >/usr/share/nginx/html/index.html

# Configurar rota Nginx para /logged
echo "location /logged {
    root /usr/share/nginx/html;
    try_files /logged.html =404;
}" >/etc/nginx/conf.d/logged_location.conf

# Reiniciar o Nginx para pegar as mudanças
systemctl restart nginx
