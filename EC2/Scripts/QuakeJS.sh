#!/bin/bash
# Script para configurar um servidor de QuakeJS usando Docker
# em uma instância EC2 ARM (Graviton), como a t4g.micro.

# Faz o script parar se qualquer comando falhar
set -e

# 1. ATUALIZAÇÃO DO SISTEMA E INSTALAÇÃO DO DOCKER
echo ">>> Atualizando o sistema e instalando o Docker..."
dnf update -y
dnf install -y docker

# 2. INICIAR E HABILITAR O SERVIÇO DO DOCKER
echo ">>> Iniciando e habilitando o serviço Docker..."
systemctl start docker
systemctl enable docker

# 3. ADICIONAR O USUÁRIO PADRÃO AO GRUPO DOCKER
# Permite que o usuário ec2-user execute comandos docker sem 'sudo' (boa prática)
usermod -a -G docker ec2-user

# 4. EXECUTAR O CONTAINER DO SERVIDOR QUAKEJS
echo ">>> Baixando e executando o container QuakeJS..."
# Este container é especial:
# - Ele serve o site do jogo na porta 80 (TCP)
# - Ele roda o servidor do jogo na porta 27960 (UDP)
docker run \
    -d \
    --restart=always \
    -p 80:80/tcp \
    -p 27960:27960/udp \
    --name quakejs-server \
    inolen/quakejs-server

echo ">>> Instalação com Docker finalizada!"
echo ">>> O servidor QuakeJS já está rodando e acessível via navegador."
