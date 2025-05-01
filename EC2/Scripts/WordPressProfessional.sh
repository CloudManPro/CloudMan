#!/bin/bash
# CONTEÚDO DESTE SCRIPT: Instala Apache, captura vars, exibe (usando Python para escapar HTML).
# NOME NO S3: WordPressProfessional.sh

set -e # Sair imediatamente se um comando falhar

LOG_FILE="/tmp/setup_show_vars.log"  # Log específico deste script
HTML_FILE="/var/www/html/index.html" # Arquivo web padrão do Apache

# Redireciona stdout/stderr
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Iniciando Script (Nome no S3: WordPressProfessional.sh - Conteúdo: setup_show_vars v5 PYTHON ESCAPE) ---"
echo "Data/Hora: $(date)"
echo "Usuário Atual: $(whoami)"
echo "Diretório Atual: $(pwd)"

# --- 1. Instalar Servidor Web (Apache) e Python (se necessário) ---
echo "INFO: Atualizando pacotes..."
yum update -y -q
echo "INFO: Instalando httpd (Apache)..."
yum install -y -q httpd
if [ $? -ne 0 ]; then
    echo "ERRO: Falha ao instalar httpd."
    exit 1
fi
echo "INFO: Verificando/Instalando Python 3..."
# Garante que python3 esteja instalado (Amazon Linux 2 geralmente tem)
yum install -y -q python3
if ! command -v python3 &>/dev/null; then
    echo "ERRO: Python 3 não encontrado ou falha na instalação."
    exit 1
fi
echo "INFO: httpd e Python 3 instalados/verificados."

# --- 2. Gerar Conteúdo HTML com Variáveis ---
echo "INFO: Gerando conteúdo HTML em $HTML_FILE..."

# Cria o início do arquivo HTML
cat >"$HTML_FILE" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Variáveis de Ambiente da Instância (Teste)</title>
    <style>
        body { font-family: monospace; margin: 20px; background-color: #f4f4f4; }
        pre { background-color: #fff; border: 1px solid #ccc; padding: 15px; white-space: pre-wrap; word-wrap: break-word; }
        h1 { color: #333; }
        .warning { color: #a00; font-weight: bold; border: 1px solid #a00; padding: 10px; background-color: #fee; margin-bottom: 15px;}
    </style>
</head>
<body>
    <h1>Variáveis de Ambiente Detectadas (Teste Apache)</h1>
    <p class="warning">AVISO DE SEGURANÇA: Esta página exibe variáveis de ambiente que podem conter informações sensíveis (chaves, senhas, endpoints). Use apenas para depuração e restrinja o acesso (Security Group)!</p>
    <h2>Informações Gerais</h2>
    <pre>
Hostname: $(hostname)
Data/Hora: $(date)
Usuário Script: $(whoami)
Diretório Script: $(pwd)
    </pre>
    <h2>Variáveis de Ambiente (Comando 'env' via Python escape)</h2>
    <p>Estas são as variáveis disponíveis para este script no momento da execução:</p>
    <pre>
EOF

# Captura a saída do comando 'env' e a anexa ao HTML usando Python para escapar
echo "INFO: Capturando e escapando variáveis de ambiente usando Python 3..."
# Usa python3 para ler stdin e escapar usando html.escape
env | python3 -c "import sys, html; sys.stdout.write(html.escape(sys.stdin.read()))" >>"$HTML_FILE"
PYTHON_EXIT_CODE=$?
echo "DEBUG: Python escape concluído (Exit Code: $PYTHON_EXIT_CODE)"
# Verifica se o comando python falhou
if [ $PYTHON_EXIT_CODE -ne 0 ]; then
    echo "ERRO: Comando Python para escapar variáveis falhou (Exit Code: $PYTHON_EXIT_CODE). Verifique $LOG_FILE para erros Python." >>"$HTML_FILE"
    # Continuamos para ver se o resto funciona, mas a lista de vars estará incompleta/ausente
    # Você pode querer colocar 'exit 1' aqui se a lista de vars for crucial
fi

# Fecha as tags HTML
cat >>"$HTML_FILE" <<EOF
    </pre>
</body>
</html>
EOF

# Verifica se o arquivo foi criado
if [ ! -f "$HTML_FILE" ]; then
    echo "ERRO: Falha ao criar o arquivo HTML $HTML_FILE."
    exit 1
fi

# Ajusta permissões
echo "INFO: Ajustando permissões para $HTML_FILE..."
chmod 644 "$HTML_FILE"
echo "INFO: Conteúdo HTML gerado e permissões ajustadas."

# --- 3. Iniciar e Habilitar Apache ---
echo "INFO: Iniciando o serviço httpd..."
systemctl start httpd
if [ $? -ne 0 ]; then
    echo "ERRO: Falha ao iniciar o serviço httpd."
    systemctl status httpd || true
    exit 1
fi

echo "INFO: Habilitando o serviço httpd para iniciar no boot..."
systemctl enable httpd

echo "INFO: Servidor web Apache iniciado e habilitado."
echo "INFO: Você pode tentar acessar http://<IP_PUBLICO_DA_INSTANCIA>/ para ver as variáveis."
echo "--- Script de Teste Apache v5 PYTHON ESCAPE (Nome no S3: WordPressProfessional.sh) concluído com sucesso ---"

exit 0
