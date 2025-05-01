#!/bin/bash
# Script para ser executado pela EC2 (baixado do S3)
# Instala Apache, captura variáveis de ambiente e as exibe em uma página web.

set -e # Sair imediatamente se um comando falhar

LOG_FILE="/tmp/setup_show_vars.log"
HTML_FILE="/var/www/html/index.html" # Arquivo web padrão do Apache

# Redireciona stdout/stderr deste script para um arquivo de log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Iniciando setup_show_vars.sh ---"
echo "Data/Hora: $(date)"
echo "Usuário Atual: $(whoami)"
echo "Diretório Atual: $(pwd)"

# --- 1. Instalar Servidor Web (Apache) ---
echo "INFO: Atualizando pacotes..."
yum update -y
echo "INFO: Instalando httpd (Apache)..."
yum install -y httpd
if [ $? -ne 0 ]; then
    echo "ERRO: Falha ao instalar httpd."
    exit 1
fi
echo "INFO: httpd instalado com sucesso."

# --- 2. Gerar Conteúdo HTML com Variáveis ---
echo "INFO: Gerando conteúdo HTML em $HTML_FILE..."

# Cria o início do arquivo HTML (sobrescreve se existir)
cat > "$HTML_FILE" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Variáveis de Ambiente da Instância</title>
    <style>
        body { font-family: monospace; margin: 20px; background-color: #f4f4f4; }
        pre { background-color: #fff; border: 1px solid #ccc; padding: 15px; white-space: pre-wrap; word-wrap: break-word; }
        h1 { color: #333; }
        .warning { color: #a00; font-weight: bold; border: 1px solid #a00; padding: 10px; background-color: #fee; margin-bottom: 15px;}
    </style>
</head>
<body>
    <h1>Variáveis de Ambiente Detectadas</h1>
    <p class="warning">AVISO DE SEGURANÇA: Esta página exibe variáveis de ambiente que podem conter informações sensíveis (chaves, senhas, endpoints). Use apenas para depuração e restrinja o acesso (Security Group)!</p>
    <h2>Informações Gerais</h2>
    <pre>
Hostname: $(hostname)
Data/Hora: $(date)
Usuário Script: $(whoami)
Diretório Script: $(pwd)
    </pre>
    <h2>Variáveis de Ambiente (Comando 'env')</h2>
    <p>Estas são as variáveis disponíveis para este script no momento da execução:</p>
    <pre>
EOF

# Captura a saída do comando 'env' e a anexa ao HTML
# Escapa caracteres HTML para exibição segura dentro de <pre>
echo "INFO: Capturando e escapando variáveis de ambiente..."
env | sed 's/&/\&/g; s/</\</g; s/>/\>/g; s/"/\"/g; s/'"'"'/\'/g' >> "$HTML_FILE"
if [ $? -ne 0 ]; then
    echo "AVISO: Falha ao capturar ou processar a saída do comando 'env'." >> "$HTML_FILE"
fi

# Fecha as tags HTML
cat >> "$HTML_FILE" << EOF
    </pre>
</body>
</html>
EOF

# Verifica se o arquivo foi criado
if [ ! -f "$HTML_FILE" ]; then
    echo "ERRO: Falha ao criar o arquivo HTML $HTML_FILE."
    exit 1
fi

# Ajusta permissões para que o Apache possa ler o arquivo
echo "INFO: Ajustando permissões para $HTML_FILE..."
# O usuário apache precisa ler o arquivo. 644 deve ser suficiente.
chmod 644 "$HTML_FILE"
echo "INFO: Conteúdo HTML gerado e permissões ajustadas."


# --- 3. Iniciar e Habilitar Apache ---
echo "INFO: Iniciando o serviço httpd..."
systemctl start httpd
if [ $? -ne 0 ]; then
    echo "ERRO: Falha ao iniciar o serviço httpd."
    # Tenta ver o status para mais detalhes
    systemctl status httpd || true
    exit 1
fi

echo "INFO: Habilitando o serviço httpd para iniciar no boot..."
systemctl enable httpd

echo "INFO: Servidor web Apache iniciado e habilitado."
echo "INFO: Você pode tentar acessar http://<IP_PUBLICO_DA_INSTANCIA>/ para ver as variáveis."
echo "--- setup_show_vars.sh concluído com sucesso ---"

# O script termina aqui, mas o serviço httpd continua rodando em background.
# O exit 0 sinaliza ao script UserData (fetch/run) que este script terminou com sucesso.
exit 0
