#!/bin/bash

# Atualizar o sistema
sudo yum update -y

# Instalar Java (necessário para o JMeter)
sudo yum install java-1.8.0-openjdk -y

# Baixar e descompactar o JMeter (substitua pela versão desejada)
wget https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.4.1.tgz
tar -xzf apache-jmeter-5.4.1.tgz
rm apache-jmeter-5.4.1.tgz

# Navegar para a pasta do JMeter
cd apache-jmeter-5.4.1/bin/

# Modificar as configurações de memória do JMeter para usar 600 MB
sed -i 's/HEAP="-Xms[0-9]*m -Xmx[0-9]*m"/HEAP="-Xms300m -Xmx600m"/' jmeter

# Aumentar o espaço de swap
# Criar um arquivo de swap de 1GB
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Adicionar a entrada de swap ao fstab para torná-la permanente
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab

# Iniciar o JMeter em modo servidor
# Este comando ficará executando e manterá a instância ativa
# para escutar por comandos do controlador JMeter local
nohup ./jmeter-server &

# Opcional: para segurança extra, configure as regras do firewall para restringir o acesso às portas do JMeter apenas ao seu IP local
