#!/bin/bash
# Script robusto para configurar NAT em uma instância Amazon Linux 2

# Instala o iptables-services para persistir as regras
sudo yum install -y iptables-services

# Habilita o encaminhamento de pacotes IP no kernel
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/custom-ip-forwarding.conf
sudo sysctl -p /etc/sysctl.d/custom-ip-forwarding.conf

# Forma robusta de obter a interface de rede principal
PRIMARY_INTERFACE=$(ip route | grep default | sed -e "s/^.*dev.//" -e "s/.proto.*//")
if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "ERRO: Não foi possível detectar a interface de rede primária. Abortando." >&2
    exit 1
fi
echo "INFO: Interface de rede primária detectada: $PRIMARY_INTERFACE"

# Adiciona a regra de MASQUERADE para fazer o NAT
sudo /sbin/iptables -t nat -A POSTROUTING -o "$PRIMARY_INTERFACE" -j MASQUERADE

# Limpa regras antigas de FORWARD (opcional, mas bom para garantir)
sudo /sbin/iptables -F FORWARD

# Salva a configuração do iptables para que ela persista após o reboot
sudo service iptables save

# Habilita e reinicia o serviço iptables para aplicar todas as configurações
sudo systemctl enable iptables
sudo systemctl restart iptables
