### INÍCIO DA SEÇÃO DE INSTALAÇÃO DE PACOTES - MÉTODO ROBUSTO ###
echo "INFO: Instalando pacotes (Apache, PHP, etc.) e configurando repositório do ProxySQL..."
sudo yum update -y -q

# --- Configuração Robusta do Repositório ProxySQL ---
# Em vez de baixar e executar um script, criamos o arquivo de repositório diretamente.
# Usamos a versão 2.x para manter a compatibilidade com a intenção original.
# O '$releasever' será substituído pelo YUM para '7' no Amazon Linux 2.
echo "INFO: Criando arquivo de repositório para o ProxySQL..."
sudo tee /etc/yum.repos.d/proxysql.repo > /dev/null <<'EOF'
[proxysql]
name=ProxySQL YUM repository for v2.x
baseurl=https://repo.proxysql.com/ProxySQL/proxysql-2.x/centos/$releasever/
gpgcheck=1
gpgkey=https://repo.proxysql.com/ProxySQL/proxysql-2.x/repo_pub_key
EOF

if [ ! -f /etc/yum.repos.d/proxysql.repo ]; then
    echo "ERRO CRÍTICO: Falha ao criar o arquivo de repositório /etc/yum.repos.d/proxysql.repo."
    exit 1
fi
echo "INFO: Arquivo de repositório do ProxySQL criado com sucesso."
# --- Fim da Configuração do Repositório ---


echo "INFO: Instalando httpd, aws-cli, mysql, efs-utils, composer, xray e proxysql..."
# O yum agora usará o novo arquivo de repositório para encontrar o pacote 'proxysql'.
sudo yum install -y httpd jq aws-cli mysql amazon-efs-utils composer xray proxysql
if [ $? -ne 0 ]; then
    echo "ERRO CRÍTICO: Falha durante o 'yum install'. Um ou mais pacotes não puderam ser instalados. Verifique o log do yum."
    exit 1
fi
echo "INFO: Pacotes principais, incluindo ProxySQL, instalados com sucesso."

echo "INFO: Habilitando e instalando PHP 7.4 e módulos..."
sudo amazon-linux-extras enable php7.4 -y -q
sudo yum install -y -q php php-common php-fpm php-mysqlnd php-json php-cli php-xml php-zip php-gd php-mbstring php-soap php-opcache

### FIM DA SEÇÃO DE INSTALAÇÃO ###
