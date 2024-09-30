#!/bin/bash

# Atualiza os pacotes do sistema
sudo apt-get update

# Instalar Apache
sudo apt-get install -y apache2 jq

# Iniciar e habilitar Apache para iniciar na inicialização
sudo systemctl start apache2
sudo systemctl enable apache2

# Obter metadados da instância da Azure usando IMDS
metadata=$(curl -H "Metadata: true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01&format=json")

# Instalar o agente do Azure Monitor (Log Analytics)
# Você precisará do seu ID do espaço de trabalho e da chave primária do espaço de trabalho
workspace_id="YOUR_WORKSPACE_ID"
workspace_key="YOUR_WORKSPACE_PRIMARY_KEY"

wget https://aka.ms/InstallAzureMonitorLinuxAgentPackage -O azuremonitoragent.deb
sudo dpkg -i azuremonitoragent.deb

# Configurar o agente com seu espaço de trabalho
sudo /opt/microsoft/azuremonitoragent/bin/configure-helper.sh --wsid $workspace_id --key $workspace_key --enable-performance-counters

# Criar um script de logging personalizado
cat <<'EOF' >/usr/local/bin/custom_logging.sh
#!/bin/bash
while true; do
  echo "$(date) - Logging data from instance" >> /var/log/custom_log.log
  sleep 10
done
EOF

sudo chmod +x /usr/local/bin/custom_logging.sh

# Executar o script de logging em segundo plano
nohup /usr/local/bin/custom_logging.sh &

# Reiniciar o agente do Azure Monitor para aplicar quaisquer alterações
sudo systemctl restart azuremonitoragent

# Extrair variáveis específicas do JSON
location=$(echo $metadata | jq -r '.compute.location')
name=$(echo $metadata | jq -r '.compute.name')
offer=$(echo $metadata | jq -r '.compute.offer')
resourceGroupName=$(echo $metadata | jq -r '.compute.resourceGroupName')
sku=$(echo $metadata | jq -r '.compute.sku')
osDiskCaching=$(echo $metadata | jq -r '.compute.storageProfile.osDisk.caching')
osDiskCreateOption=$(echo $metadata | jq -r '.compute.storageProfile.osDisk.createOption')
diskSizeGB=$(echo $metadata | jq -r '.compute.storageProfile.osDisk.diskSizeGB')
zone=$(echo $metadata | jq -r '.compute.zone')
privateIpAddress=$(echo $metadata | jq -r '.network.interface[0].ipv4.ipAddress[0].privateIpAddress')
subnetAddress=$(echo $metadata | jq -r '.network.interface[0].ipv4.subnet[0].address')
subnetPrefix=$(echo $metadata | jq -r '.network.interface[0].ipv4.subnet[0].prefix')

# Criar a página HTML com informações extraídas
echo "<!DOCTYPE html>" | sudo tee /var/www/html/index.html
echo "<html>" | sudo tee -a /var/www/html/index.html
echo "<head>" | sudo tee -a /var/www/html/index.html
echo "  <title>Instance Information</title>" | sudo tee -a /var/www/html/index.html
echo "</head>" | sudo tee -a /var/www/html/index.html
echo "<body>" | sudo tee -a /var/www/html/index.html
echo "  <h1>Azure VM Instance Information</h1>" | sudo tee -a /var/www/html/index.html
echo "  <p>Location: $location</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Name: $name</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Offer: $offer</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Resource Group Name: $resourceGroupName</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>SKU: $sku</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>OS Disk Caching: $osDiskCaching</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>OS Disk Create Option: $osDiskCreateOption</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Disk Size GB: $diskSizeGB</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Zone: $zone</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Private IP Address: $privateIpAddress</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Subnet Address: $subnetAddress</p>" | sudo tee -a /var/www/html/index.html
echo "  <p>Subnet Prefix: $subnetPrefix</p>" | sudo tee -a /var/www/html/index.html
echo "</body>" | sudo tee -a /var/www/html/index.html
echo "</html>" | sudo tee -a /var/www/html/index.html
# Obter o endereço IP público da instância
public_ip=$(curl -s http://ifconfig.me)
echo "  <p>Public IP Address: $public_ip</p>" | sudo tee -a /var/www/html/index.html
