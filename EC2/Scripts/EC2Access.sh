#!/bin/bash
# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Carregar variáveis de ambiente do arquivo .env
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

LOG_FILE="/var/log/cloud-init-output.log"

#Atribui uma senha padrão para uso em serial console, se as veriáveis de ambiente SerialConsoleUserName e SerialConsolePassword existirem
SerialConsoleUserName=${SerialConsoleUserName:-}
SerialConsolePassword=${SerialConsolePassword:-}
configure_serial_console_access() {
    echo "Configurando acesso ao Serial Console para o usuário $1..."
    if ! id "$1" &>/dev/null; then
        sudo adduser "$1"
    fi
    echo "$1:$2" | sudo chpasswd
    sudo usermod -aG dialout "$1"
    sudo bash -c "echo '$1 ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/$1"
}
if [[ -n "$SerialConsoleUserName" && -n "$SerialConsolePassword" ]]; then
    configure_serial_console_access "$SerialConsoleUserName" "$SerialConsolePassword"
fi

# Atualiza os repositórios de pacotes
yum update -y

# Atualiza o Docker para a versão mais recente
yum update -y docker

# Reinicia o serviço do Docker para aplicar a atualização
service docker restart

# Reinicia o ECS Agent para garantir que ele utilize a versão atualizada do Docker
systemctl restart ecs

# (Opcional) Log de versão para validação
docker --version >/var/log/docker_version.log
