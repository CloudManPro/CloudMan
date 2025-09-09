

# Carrega as variáveis de ambiente a partir do arquivo .env
set -a
source /home/ec2-user/.env
set +a

# --- Instalação de Pacotes para Amazon Linux 2023 ---
# Correção: O Amazon Linux 2023 usa 'dnf' e os nomes dos pacotes são consistentes,
# mas garantimos que todos os módulos PHP necessários estejam listados.
sudo dnf update -y
sudo dnf install -y httpd jq php php-mysqlnd php-fpm php-json php-cli php-xml php-zip php-gd php-mbstring mariadb10.5-common amazon-efs-utils

# Inicia o servidor Apache e configura para iniciar na inicialização
sudo systemctl start httpd
sudo systemctl enable httpd

# --- Recuperação de Segredos ---
SECRET_NAME=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0
SECRETREGION=$AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0
DBNAME=$AWS_DB_INSTANCE_TARGET_NAME_0
RDS_ENDPOINT=$AWS_DB_INSTANCE_TARGET_ENDPOINT_0

# Extração do endereço do endpoint (sem a porta)
ENDPOINT_ADDRESS=$(echo $RDS_ENDPOINT | cut -d: -f1)

# Recupera os valores dos segredos do AWS Secrets Manager
SECRET_VALUE_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query 'SecretString' --output text --region "$SECRETREGION")
DB_USER=$(echo "$SECRET_VALUE_JSON" | jq -r .username)
DB_PASSWORD=$(echo "$SECRET_VALUE_JSON" | jq -r .password)

# --- Montagem do EFS ---
sudo mkdir -p /var/www/html
# A variável EFS_ID é injetada pelo Terraform no arquivo .env
sudo mount -t efs "$EFS_ID":/ /var/www/html

# Adiciona entrada no fstab para remontar após reinicialização (Boa Prática)
# Verifica se a entrada já não existe antes de adicionar
if ! grep -q "$EFS_ID" /etc/fstab; then
  echo "$EFS_ID:/ /var/www/html efs _netdev,tls 0 0" | sudo tee -a /etc/fstab
fi

# --- Instalação do WordPress (Apenas se não estiver instalado) ---
if [ ! -f /var/www/html/wp-config.php ]; then
    cd /tmp
    wget https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    sudo mv wordpress/* /var/www/html/

    # Configuração do arquivo wp-config.php
    cd /var/www/html/
    sudo cp wp-config-sample.php wp-config.php
    sudo sed -i "s/database_name_here/$DBNAME/" wp-config.php
    sudo sed -i "s/username_here/$DB_USER/" wp-config.php
    sudo sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
    sudo sed -i "s/localhost/$ENDPOINT_ADDRESS/" wp-config.php

    # Adicionar chaves de segurança (Melhoria de Segurança)
    SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
    STRING_TO_REPLACE="'put your unique phrase here'"
    printf '%s\n' "g/$STRING_TO_REPLACE/d" a "$SALT" . w | ed -s wp-config.php
fi

# Ajusta permissões
# Correção: No Amazon Linux 2023, o usuário e o grupo do Apache são ambos 'apache'.
# O comando estava correto, mas falhava porque a instalação do httpd não ocorria.
# Agora que a instalação está corrigida, este comando funcionará.
sudo chown -R apache:apache /var/www/html/
sudo chmod -R 755 /var/www/html/

# Reinicia o servidor Apache para aplicar as alterações
# Correção: O nome do serviço 'httpd' está correto. O problema era que ele não existia.
sudo systemctl restart httpd
