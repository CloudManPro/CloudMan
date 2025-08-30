#!/bin/bash

# --- Error Handling ---
# 'set -e' faz o script sair imediatamente se um comando falhar.
# 'set -o pipefail' garante que falhas em pipelines (ex: cmd1 | cmd2) sejam capturadas.
set -e -o pipefail

# --- Centralized Configuration ---
# Altere os valores aqui em um só lugar.
DB_NAME="wordpress"
DB_USER="wordpress"
# IMPORTANTE: Para produção, use um método seguro para gerar e injetar senhas (ex: AWS Secrets Manager).
# Para este exemplo, uma senha fixa é aceitável.
DB_PASSWORD="a_strong_password_here" 

# --- Logging ---
# Redireciona toda a saída (stdout e stderr) para um arquivo de log, além do log padrão do cloud-init.
# Isso cria um registro limpo e dedicado para depuração.
LOG_FILE="/var/log/wordpress-install.log"
exec > >(tee -a ${LOG_FILE}) 2>&1

echo "--- Início do script de configuração do WordPress ---"

# --- 1. Atualização do Sistema e Instalação de Pacotes ---
echo "Atualizando pacotes do sistema..."
yum update -y

echo "Instalando Apache, MariaDB e PHP..."
# Instala os pacotes pelos seus nomes padrão, que são estáveis.
# O Amazon Linux 2023 gerencia as versões, então sempre teremos uma versão compatível.
yum install -y httpd mariadb-server mariadb php php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip php-json

# --- 2. Configuração de Segurança (SELinux) ---
echo "Configurando a política do SELinux para o banco de dados..."
# Permite que o Apache se conecte à rede local para acessar o banco de dados.
setsebool -P httpd_can_network_connect_db 1

# --- 3. Gerenciamento de Serviços ---
echo "Iniciando e habilitando os serviços httpd e mariadb..."
systemctl start httpd
systemctl enable httpd
systemctl start mariadb
systemctl enable mariadb

echo "Aguardando 10 segundos para o MariaDB iniciar completamente..."
sleep 10

# --- 4. Configuração do Banco de Dados ---
echo "Criando o banco de dados e o usuário para o WordPress..."
# Usamos as variáveis definidas no topo do script.
mysql -e "CREATE DATABASE ${DB_NAME};"
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# --- 5. Instalação do WordPress ---
echo "Baixando e configurando os arquivos do WordPress..."
cd /var/www/html
# 'latest.tar.gz' é um link permanente para a última versão estável. É uma URL muito segura.
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz
mv wordpress/* .
rm -rf wordpress latest.tar.gz

echo "Ajustando permissões dos arquivos do WordPress..."
chown -R apache:apache /var/www/html

# --- 6. Configuração do WordPress (wp-config.php) ---
echo "Criando e configurando o arquivo wp-config.php..."
cp wp-config-sample.php wp-config.php
# Usamos as variáveis novamente para garantir consistência.
sed -i "s/database_name_here/${DB_NAME}/g" wp-config.php
sed -i "s/username_here/${DB_USER}/g" wp-config.php
sed -i "s/password_here/${DB_PASSWORD}/g" wp-config.php

# --- 7. Finalização ---
echo "Reiniciando o Apache para aplicar todas as configurações..."
systemctl restart httpd

echo "--- Script de configuração do WordPress concluído com sucesso! ---"
