#!/bin/bash
# Script para instalar e configurar um servidor QuakeJS a partir do código-fonte
# diretamente em uma instância EC2 Amazon Linux (ARM64 / Graviton).

# Faz o script parar imediatamente se qualquer comando falhar. Essencial para depuração.
set -e

echo ">>> [PASSO 1 de 4] Atualizando o sistema e instalando dependências..."
dnf update -y
# git: para baixar o código-fonte
# gcc-c++ e make: para compilar o servidor de jogo C++
# nodejs: para rodar o servidor web e o processo de build
dnf install -y git gcc-c++ make nodejs

echo ">>> [PASSO 2 de 4] Baixando (clonando) o código-fonte do QuakeJS..."
# Clona o repositório para o diretório /opt, um local padrão para software opcional
git clone https://github.com/inolen/quakejs.git /opt/quakejs

echo ">>> [PASSO 3 de 4] Compilando o projeto QuakeJS..."
# Entra no diretório do projeto
cd /opt/quakejs
# Instala as dependências de JavaScript (Node.js)
npm install
# Executa o processo de build (compilação do servidor C++ e preparação dos arquivos web)
# npx é usado para rodar a ferramenta 'gulp' que está listada no projeto
npx gulp build

echo ">>> [PASSO 4 de 4] Configurando o QuakeJS para rodar como um serviço de sistema..."
# Cria um arquivo de serviço systemd para gerenciar o servidor de forma robusta
cat <<EOF > /etc/systemd/system/quakejs.service
[Unit]
Description=QuakeJS Game Server
After=network.target

[Service]
Type=simple
User=ec2-user
# O servidor DEVE ser executado a partir deste diretório
WorkingDirectory=/opt/quakejs
# Comando completo para iniciar o servidor, usando o caminho absoluto para o node
ExecStart=/usr/bin/node build/ioq3ded.js +set fs_game baseq3 +set dedicated 2 +exec server.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Recarrega o systemd para ele encontrar nosso novo serviço
systemctl daemon-reload
# Habilita o serviço para iniciar automaticamente no boot da máquina
systemctl enable quakejs.service
# Inicia o serviço imediatamente
systemctl start quakejs.service

echo ">>> SUCESSO! O servidor QuakeJS foi instalado, compilado e está em execução."
