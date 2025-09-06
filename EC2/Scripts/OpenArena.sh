
# Faz o script parar se qualquer comando falhar
set -e

# 1. ATUALIZAÇÃO DO SISTEMA E INSTALAÇÃO DE DEPENDÊNCIAS
echo ">>> Atualizando o sistema e instalando dependências (wget, unzip)..."
dnf update -y
dnf install -y wget unzip

echo ">>> Testando conectividade geral com a internet..."
curl -v google.com
if [ $? -eq 0 ]; then
    echo ">>> Conectividade com a internet (google.com) FUNCIONOU."
else
    echo ">>> FALHA na conectividade com a internet. O problema está na rede (VPC, Rota, NACL)."
    exit 1 # Para o script aqui se não houver internet
fi

# 2. CRIAÇÃO DE UM USUÁRIO DEDICADO PARA O SERVIDOR
# Boa prática de segurança não rodar o serviço como root.
if ! id "openarena" &>/dev/null; then
    echo ">>> Criando o usuário 'openarena'..."
    useradd -m -s /bin/bash openarena
fi

# 3. DOWNLOAD E EXTRAÇÃO DO SERVIDOR DEDICADO DO OPENARENA
echo ">>> Baixando e extraindo o servidor OpenArena..."
cd /home/openarena
# Link para a versão 0.8.8 do servidor dedicado para Linux
wget https://files.ioquake3.org/openarena/openarena-0.8.8-ded.zip
unzip openarena-0.8.8-ded.zip
# Renomeia a pasta para algo mais simples
mv openarena-0.8.8-ded openarena-server
rm openarena-0.8.8-ded.zip # Limpa o arquivo baixado

# 4. CRIAÇÃO DO ARQUIVO DE CONFIGURAÇÃO DO SERVIDOR (server.cfg)
echo ">>> Criando o arquivo de configuração server.cfg..."
# O OpenArena procura a configuração na pasta 'baseoa'
mkdir -p /home/openarena/.openarena/baseoa
cat <<EOF > /home/openarena/.openarena/baseoa/server.cfg
// Configurações do Servidor de OpenArena da Aula

// Nome do servidor que aparecerá na lista
sets sv_hostname "^5Aula ^6Educacional ^7OpenArena"

// Mensagem do dia
sets g_motd "Bem-vindos à nossa aula sobre servidores de jogos na AWS!"

// Número máximo de jogadores
set sv_maxclients 12

// Tipo de jogo (0 = Free For All, 3 = Team Deathmatch, 4 = CTF)
set g_gametype 0

// Senha para administração remota (RCON) - MUDE SE NECESSÁRIO!
set rconpassword "mude-esta-senha"

// Define o primeiro mapa e inicia o jogo
map oa_dm1
EOF

# 5. MUDAR AS PERMISSÕES DOS ARQUIVOS PARA O USUÁRIO 'openarena'
echo ">>> Ajustando permissões dos arquivos..."
chown -R openarena:openarena /home/openarena

# 6. CRIAÇÃO DO SERVIÇO SYSTEMD PARA GERENCIAR O SERVIDOR
echo ">>> Criando o serviço systemd para o OpenArena..."
cat <<EOF > /etc/systemd/system/openarena.service
[Unit]
Description=Servidor Dedicado OpenArena
After=network.target

[Service]
User=openarena
Group=openarena
WorkingDirectory=/home/openarena/openarena-server
# Comando para iniciar o servidor
# O binário para o servidor dedicado é oa_ded.x86_64
ExecStart=/home/openarena/openarena-server/oa_ded.x86_64 +set dedicated 2 +set fs_game baseoa +exec server.cfg
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 7. HABILITAR E INICIAR O SERVIÇO
echo ">>> Habilitando e iniciando o serviço openarena..."
systemctl daemon-reload
systemctl enable openarena.service
systemctl start openarena.service

echo ">>> Instalação 100% automatizada e finalizada!"
echo ">>> O servidor OpenArena já está rodando."
echo ">>> Para conectar, use o IP público da instância no cliente OpenArena."
echo ">>> Para verificar o status, conecte-se via SSH e use: sudo systemctl status openarena.service"
