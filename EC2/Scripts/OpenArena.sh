
# Script FINAL para configurar um servidor de OpenArena usando Docker
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
usermod -a -G docker ec2-user

# 4. EXECUTAR O CONTAINER DO SERVIDOR OPENARENA (VERSÃO ARM)
echo ">>> Baixando e executando o container OpenArena para ARM..."
docker run \
    -d \
    --restart=always \
    -p 27960:27960/udp \
    --name openarena-server \
    tuxnvape/openarena-arm  # <-- ÚNICA MUDANÇA: o nome da imagem correta

echo ">>> Instalação com Docker finalizada!"
echo ">>> O servidor OpenArena já está rodando dentro de um container."
