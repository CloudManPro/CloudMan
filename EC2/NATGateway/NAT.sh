#!/bin/bash

# Instalação do iptables
sudo yum install iptables-services -y
sudo systemctl enable iptables
sudo systemctl start iptables

# Habilitar IP Forwarding
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/custom-ip-forwarding.conf
sudo sysctl -p /etc/sysctl.d/custom-ip-forwarding.conf

# Configurar iptables para NAT
PRIMARY_INTERFACE=$(netstat -i | awk '{if (NR==3) print $1}')
sudo /sbin/iptables -t nat -A POSTROUTING -o $PRIMARY_INTERFACE -j MASQUERADE
sudo /sbin/iptables -F FORWARD
sudo service iptables save
