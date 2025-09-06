#!/bin/bash
# Script de automação completo para instalar um servidor ioquake3 com cliente WebAssembly
# em uma instância EC2 Amazon Linux 2023 (ARM64).

# Faz o script parar imediatamente se qualquer comando falhar.
set -e

echo ">>> [PASSO 1 de 6] Atualizando sistema e instalando dependências..."
# git: para baixar o código
# gcc/make/cmake: para compilar o motor do jogo a partir do código-fonte em C
# nginx: para servir os arquivos do cliente web
dnf update -y
dnf install -y git gcc make cmake nginx

echo ">>> [PASSO 2 de 6] Baixando o código-fonte do ioquake3..."
# Clonamos o repositório usando o protocolo 'git://' para evitar prompts de autenticação em scripts
git clone --recursive git://github.com/ioquake/ioquake3.git /opt/ioquake3
cd /opt/ioquake3

echo ">>> [PASSO 3 de 6] Compilando o motor do jogo (servidor e cliente WebAssembly)..."
# Este passo pode demorar alguns minutos
# Criamos um diretório de build para manter o código-fonte limpo
mkdir -p build && cd build
# Executamos o cmake para gerar os arquivos de compilação
# -DPLATFORM=js: Especifica que queremos compilar o cliente para JavaScript/WebAssembly
# -DSERVER_BIN_SUFFIX=ded.aarch64: Nomeia o binário do servidor para arquitetura ARM64
cmake .. -DPLATFORM=js -DSERVER_BIN_SUFFIX=ded.aarch64
# Executamos o make para compilar tudo
make

echo ">>> [PASSO 4 de 6] Baixando os arquivos de dados do jogo (Assets)..."
# O motor compilado não contém mapas, texturas ou sons.
# Baixamos os arquivos de dados da versão demo, que são de distribuição livre.
wget https://raw.githubusercontent.com/ioquake/ioquake3-mac-install/master/fs/baseq3/pak0.pk3 -P /opt/ioquake3/build/baseq3

echo ">>> [PASSO 5 de 6] Configurando o servidor Web (Nginx)..."
# Criamos um arquivo de configuração para o Nginx servir nosso jogo
cat <<EOF > /etc/nginx/conf.d/ioquake3.conf
server {
    listen 80;
    server_name _;

    # O root deve apontar para o diretório onde os arquivos web foram compilados
    root /opt/ioquake3/build;
    index ioq3.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Headers essenciais para que o WebAssembly (SharedArrayBuffer) funcione corretamente
    # em navegadores modernos por questões de segurança.
    add_header Cross-Origin-Opener-Policy "same-origin";
    add_header Cross-Origin-Embedder-Policy "require-corp";
}
EOF

# Reinicia o Nginx para aplicar a nova configuração
systemctl restart nginx
# Habilita o Nginx para iniciar no boot
systemctl enable nginx

echo ">>> [PASSO 6 de 6] Criando e iniciando o serviço do servidor de jogo..."
# Criamos um serviço systemd para gerenciar o servidor dedicado do ioquake3
cat <<EOF > /etc/systemd/system/ioquake3.service
[Unit]
Description=ioquake3 Dedicated Server
After=network.target

[Service]
Type=simple
User=ec2-user
# O servidor DEVE ser executado a partir do diretório que contém a pasta 'baseq3'
WorkingDirectory=/opt/ioquake3/build
# Comando para iniciar o servidor dedicado
ExecStart=/opt/ioquake3/build/ioq3ded.aarch64 +set dedicated 2 +set fs_game baseq3
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Recarrega o systemd para ele encontrar nosso novo serviço
systemctl daemon-reload
# Habilita o serviço para iniciar automaticamente no boot da máquina
systemctl enable ioquake3.service
# Inicia o serviço imediatamente
systemctl start ioquake3.service

echo ">>> SUCESSO! O servidor ioquake3 está instalado e em execução."
echo ">>> O servidor web Nginx está servindo o cliente do jogo."
