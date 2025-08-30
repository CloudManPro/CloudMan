#!/bin/bash

# --- Error Handling ---
# Sai imediatamente se um comando falhar.
set -e -o pipefail

# --- Centralized Configuration ---
# Defina suas credenciais aqui. Para produção, considere usar o AWS Secrets Manager.
DB_NAME="wordpress_db"
DB_USER="wordpress_user"
DB_PASSWORD="YourStrongPassword123!" 

# --- Logging ---
# Redireciona toda a saída (stdout e stderr) para um arquivo de log e também para o console.
LOG_FILE="/var/log/wordpress-install.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração do WordPress com MariaDB (Versão para AL2023) ---"

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y

echo "Instalando Apache, MariaDB e módulos PHP..."
# CORREÇÃO FINAL: Usando o nome de pacote 'mariadb105-server' encontrado com 'dnf search'.
yum install -y httpd mariadb105-server php php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json

# --- 2. Configuração de Segurança (SELinux) ---
# Permite que o servidor web (httpd) se conecte à rede para acessar o banco de dados.
echo "Configurando a política do SELinux para o banco de dados..."
setsebool -P httpd_can_network_connect_db 1

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando e habilitando os serviços httpd e mariadb..."
systemctl start httpd
systemctl enable httpd
# O nome do serviço para o MariaDB é 'mariadb'.
systemctl start mariadb
systemctl enable mariadb

echo "Aguardando 10 segundos para o MariaDB iniciar completamente..."
sleep 10

# --- 4. Configuração do Banco de Dados ---
# Os comandos 'mysql -e' são compatíveis e não precisam de alteração.
echo "Criando o banco de dados e o usuário para o WordPress..."
mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 5. Instalação do WordPress ---
echo "Baixando e configurando os arquivos do WordPress..."
cd /var/www/html
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
# Move o conteúdo da pasta 'wordpress' para a raiz do diretório web
mv wordpress/* .
# Remove a pasta vazia e o arquivo compactado
rm -rf wordpress latest.tar.gz

echo "Ajustando permissões dos arquivos do WordPress..."
chown -R apache:apache /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) ---
echo "Criando e configurando o arquivo wp-config.php..."
# Cria o arquivo de configuração a partir do exemplo
cp wp-config-sample.php wp-config.php

# Substitui os placeholders pelas nossas variáveis
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s/password_here/${DB_PASSWORD}/g" wp-config.php

# Adiciona chaves de segurança únicas para maior segurança
SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s wp-config.php

# --- 7. Finalização ---
echo "Reiniciando o Apache para aplicar todas as configurações..."
systemctl restart httpd

echo "--- Script de configuração do WordPress concluído com sucesso! ---"
echo "Acesse o IP público da sua instância para finalizar a instalação do WordPress pelo navegador."
