#!/bin/bash
# Script FINAL para configurar um servidor de QuakeJS usando Docker
# em uma instância EC2 ARM (Graviton), como a t4g.micro.
# Este script usa uma imagem Docker multi-arquitetura que é compatível com ARM64.

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

# 4. EXECUTAR O CONTAINER DO SERVIDOR QUAKEJS (IMAGEM CORRETA)
echo ">>> Baixando e executando o container QuakeJS multi-arquitetura..."
# A imagem 'treyyoder/quakejs-server' tem suporte nativo para ARM64.
# O Docker irá automaticamente baixar a versão correta para esta instância.
docker run \
    -d \
    --restart=always \
    -p 80:80/tcp \
    -p 27960:27960/udp \
    --name quakejs-server \
    treyyoder/quakejs-server

echo ">>> Instalação com Docker finalizada!"
echo ">>> O servidor QuakeJS já está rodando e acessível via navegador."
