#!/bin/bash
# Script para configurar um servidor de OpenArena em uma instância EC2 com Amazon Linux 2023.

# Faz o script parar se qualquer comando falhar
set -e

# 1. ATUALIZAÇÃO DO SISTEMA E INSTALAÇÃO DE DEPENDÊNCIAS
echo ">>> Atualizando o sistema e instalando dependências (wget, unzip)..."
dnf update -y
dnf install -y wget unzip

# 2. TESTE DE CONECTIVIDADE
echo ">>> Testando conectividade geral com a internet..."
curl -v https://www.google.com
if [ $? -eq 0 ]; then
    echo ">>> Conectividade com a internet (google.com) FUNCIONOU."
else
    echo ">>> FALHA na conectividade com a internet. O problema está na rede (VPC, Rota, NACL)."
    exit 1 # Para o script aqui se não houver internet
fi

# 3. CRIAÇÃO DE UM USUÁRIO DEDICADO PARA O SERVIDOR
if ! id "openarena" &>/dev/null; then
    echo ">>> Criando o usuário 'openarena'..."
    useradd -m -s /bin/bash openarena
fi

# 4. DOWNLOAD E EXTRAÇÃO DO SERVIDOR DEDICADO DO OPENARENA
echo ">>> Baixando e extraindo o servidor OpenArena..."
cd /home/openarena
wget "https://downloads.sourceforge.net/project/openarena/openarena/0.8.8/openarena-0.8.8-ded.zip" -O openarena-0.8.8-ded.zip
unzip openarena-0.8.8-ded.zip
mv openarena-0.8.8-ded openarena-server
rm openarena-0.8.8-ded.zip

# 5. CRIAÇÃO DO ARQUIVO DE CONFIGURAÇÃO DO SERVIDOR (server.cfg)
echo ">>> Criando o arquivo de configuração server.cfg..."
mkdir -p /home/openarena/.openarena/baseoa
cat <<EOF > /home/openarena/.openarena/baseoa/server.cfg
// Configurações do Servidor de OpenArena da Aula
sets sv_hostname "^5Aula ^6Educacional ^7OpenArena"
sets g_motd "Bem-vindos à nossa aula sobre servidores de jogos na AWS!"
set sv_maxclients 12
set g_gametype 0
set rconpassword "mude-esta-senha"
map oa_dm1
EOF

# 6. MUDAR AS PERMISSÕES DOS ARQUIVOS PARA O USUÁRIO 'openarena'
echo ">>> Ajustando permissões dos arquivos..."
chown -R openarena:openarena /home/openarena

# 7. CRIAÇÃO DO SERVIÇO SYSTEMD PARA GERENCIAR O SERVIDOR
echo ">>> Criando o serviço systemd para o OpenArena..."
cat <<EOF > /etc/systemd/system/openarena.service
[Unit]
Description=Servidor Dedicado OpenArena
After=network.target

[Service]
User=openarena
Group=openarena
WorkingDirectory=/home/openarena/openarena-server
ExecStart=/home/openarena/openarena-server/oa_ded.x86_64 +set dedicated 2 +set fs_game baseoa +exec server.cfg
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 8. HABILITAR E INICIAR O SERVIÇO
echo ">>> Habilitando e iniciando o serviço openarena..."
systemctl daemon-reload
systemctl enable openarena.service
systemctl start openarena.service

echo ">>> Instalação 100% automatizada e finalizada!"
echo ">>> O servidor OpenArena já está rodando."
