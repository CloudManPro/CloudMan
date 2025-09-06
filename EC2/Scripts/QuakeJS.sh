#!/bin/bash
# Script FINAL E CORRIGIDO para configurar um servidor de QuakeJS
# em uma instância EC2 ARM (Graviton).
#
# Esta versão usa uma imagem do Amazon ECR Public Gallery para evitar
# os problemas de limite de taxa (rate limit) do Docker Hub.

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
usermod -a -G docker ec2-user

# 4. EXECUTAR O CONTAINER DO SERVIDOR QUAKEJS (IMAGEM DO ECR PÚBLICO)
echo ">>> Baixando e executando o container QuakeJS a partir do Amazon ECR Public..."
# Esta é a mudança crucial. A imagem vem de um repositório da Amazon.
docker run \
    -d \
    --restart=always \
    -p 80:80/tcp \
    -p 27960:27960/udp \
    --name quakejs-server \
    public.ecr.aws/l6m2p1w3/quakejs:latest

echo ">>> Instalação com Docker finalizada!"
echo ">>> O servidor QuakeJS já está rodando e acessível via navegador."
