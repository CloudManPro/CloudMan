#!/bin/bash

# Atualizar os pacotes do sistema
sudo yum update -y

# Instalar o AWS CLI
sudo yum install -y awscli

# Instalar o Apache para servir a página HTML
sudo yum install -y httpd

# Habilitar e iniciar o serviço Apache
sudo systemctl enable httpd
sudo systemctl start httpd

# Definir o nome do bucket S3 a partir de uma variável de ambiente
BUCKET_NAME=$(grep "aws_s3_bucket_Target_Name_" /etc/environment | cut -d'=' -f2)

# Caminho para o arquivo HTML
HTML_FILE="/var/www/html/index.html"

# Adicionar o cabeçalho da página HTML
echo "<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta http-equiv=\"X-UA-Compatible\" content=\"IE=edge\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>Lista de Arquivos S3</title>
</head>
<body>
    <h1>Arquivos no bucket S3: $BUCKET_NAME</h1>
    <ul>" >$HTML_FILE

# Verificar se o nome do bucket foi encontrado
if [ -z "$BUCKET_NAME" ]; then
    echo "    <p>Erro: Nome do bucket S3 não encontrado.</p>" >>$HTML_FILE
else
    # Verificar se o bucket S3 existe
    if aws s3 ls "s3://$BUCKET_NAME" 2>&1 | grep -q 'NoSuchBucket'; then
        echo "    <p>Erro: O bucket S3 $BUCKET_NAME não existe.</p>" >>$HTML_FILE
    else
        # Listar os arquivos no bucket S3 e adicionar à página HTML
        aws s3 ls s3://$BUCKET_NAME/ --output text | while read -r line; do
            FILE_NAME=$(echo $line | awk '{print $4}')
            if [ ! -z "$FILE_NAME" ]; then
                echo "    <li>$FILE_NAME</li>" >>$HTML_FILE
            fi
        done
    fi
fi

# Adicionar o rodapé da página HTML
echo "    </ul>
</body>
</html>" >>$HTML_FILE

# Mensagem para o usuário
echo "A lista de arquivos foi gerada com sucesso em $HTML_FILE"
