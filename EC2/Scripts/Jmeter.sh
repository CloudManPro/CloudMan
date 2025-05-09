#!/bin/bash
set -e # Sai imediatamente se um comando falhar
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1 # Log detalhado

echo "INFO: Iniciando script User Data para configurar JMeter Remote Backend."

# --- Configurações ---
APP_DIR="/opt/jmeter-remote-backend"
# O nome do script Python será determinado dinamicamente a partir de AWS_S3_SCRIPT_KEY
# PYTHON_SCRIPT_NAME="server.py" # Removido, será dinâmico
# LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}" # Removido, será dinâmico
SERVICE_NAME="jmeter-backend"

# Caminho para o arquivo .env que contém as configurações do S3
ENV_FILE_FOR_S3_DOWNLOAD="/home/ec2-user/.env" # **IMPORTANTE**: Ajuste se necessário

# Versão do JMeter para instalar (verifique a URL e versão mais recentes)
JMETER_VERSION="5.6.3" # Substitua pela versão desejada
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"

# --- Função de Log ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- 1. Detecção do SO e Instalação de Dependências Base ---
log "INFO: Detectando sistema operacional e instalando dependências base."
OS_TYPE=""
USER_FOR_SERVICE=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
elif type lsb_release >/dev/null 2>&1; then
    OS_TYPE=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
else
    OS_TYPE=$(uname -s)
fi
log "INFO: Sistema operacional detectado: $OS_TYPE"

if [[ "$OS_TYPE" == "amzn" ]]; then
    log "INFO: Configurando para Amazon Linux."
    yum update -y
    yum install -y python3 python3-pip aws-cli tar gzip java-11-openjdk-devel # ou java-17, etc.
    USER_FOR_SERVICE="ec2-user"
elif [[ "$OS_TYPE" == "ubuntu" ]] || [[ "$OS_TYPE" == "debian" ]]; then
    log "INFO: Configurando para Ubuntu/Debian."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 python3-pip awscli tar gzip openjdk-11-jdk # ou openjdk-17-jdk, etc.
    USER_FOR_SERVICE="ubuntu"
else
    log "ERRO: Sistema operacional não suportado para instalação automática de dependências: $OS_TYPE"
    exit 1
fi

if ! command -v pip &>/dev/null && command -v pip3 &>/dev/null; then
    ln -s /usr/bin/pip3 /usr/bin/pip || log "AVISO: Não foi possível criar link simbólico para pip."
fi
pip install --upgrade pip
log "INFO: Dependências base (Python, pip, AWS CLI, Java) instaladas."

# --- 2. Instalação do JMeter ---
log "INFO: Iniciando instalação do JMeter ${JMETER_VERSION}..."
if [ -d "${JMETER_HOME_PATH}" ]; then
    log "INFO: JMeter já parece estar instalado em ${JMETER_HOME_PATH}. Pulando download."
else
    cd /tmp
    log "INFO: Baixando JMeter de ${JMETER_TGZ_URL}..."
    if ! wget -q "${JMETER_TGZ_URL}" -O "apache-jmeter-${JMETER_VERSION}.tgz"; then
        log "ERRO: Falha ao baixar JMeter. Verifique a URL e a conexão."
        exit 1
    fi
    log "INFO: Extraindo JMeter para ${JMETER_INSTALL_DIR}..."
    if ! tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "${JMETER_INSTALL_DIR}"; then
        log "ERRO: Falha ao extrair JMeter."
        rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
        exit 1
    fi
    rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
    log "INFO: JMeter ${JMETER_VERSION} instalado em ${JMETER_HOME_PATH}."
fi

JMETER_PROFILE_SCRIPT="/etc/profile.d/jmeter.sh"
log "INFO: Configurando JMETER_HOME e PATH em ${JMETER_PROFILE_SCRIPT}."
echo "export JMETER_HOME=${JMETER_HOME_PATH}" > "${JMETER_PROFILE_SCRIPT}"
echo "export PATH=\$PATH:\$JMETER_HOME/bin" >> "${JMETER_PROFILE_SCRIPT}"
chmod +x "${JMETER_PROFILE_SCRIPT}"
log "INFO: Aplicando configurações do JMeter para a sessão atual."
source "${JMETER_PROFILE_SCRIPT}"
if ! command -v jmeter &> /dev/null; then
    log "AVISO: Comando 'jmeter' não encontrado no PATH após configuração. Verifique ${JMETER_PROFILE_SCRIPT} e a instalação."
else
    log "INFO: Comando 'jmeter' encontrado no PATH: $(command -v jmeter)"
    log "INFO: Versão do JMeter: $(jmeter --version)"
fi

# --- 3. Preparar Diretório da Aplicação ---
log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

# --- 4. Carregar Variáveis de Ambiente e Baixar o script Python do S3 ---
log "INFO: Preparando para baixar o script Python do S3."

if [ ! -f "$ENV_FILE_FOR_S3_DOWNLOAD" ]; then
    log "ERRO CRÍTICO: Arquivo de ambiente '$ENV_FILE_FOR_S3_DOWNLOAD' não encontrado!"
    exit 1
fi
log "INFO: Usando arquivo de ambiente '$ENV_FILE_FOR_S3_DOWNLOAD' para obter detalhes do S3."

set -a
if ! . "$ENV_FILE_FOR_S3_DOWNLOAD"; then
    log "ERRO: Falha ao carregar (source) o arquivo de ambiente '$ENV_FILE_FOR_S3_DOWNLOAD'."
    set +a
    exit 1
fi
set +a
log "INFO: Variáveis de ambiente carregadas de '$ENV_FILE_FOR_S3_DOWNLOAD'."

if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || \
   [ -z "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}" ] || \
   [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
    log "ERRO CRÍTICO: Variáveis S3 (AWS_S3_BUCKET_TARGET_NAME_SCRIPT, AWS_S3_BUCKET_TARGET_REGION_SCRIPT, AWS_S3_SCRIPT_KEY) não definidas ou vazias em '$ENV_FILE_FOR_S3_DOWNLOAD'."
    exit 1
fi
log "INFO: Variáveis S3 para download: BUCKET=${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}, REGION=${AWS_S3_BUCKET_TARGET_REGION_SCRIPT}, KEY=${AWS_S3_SCRIPT_KEY}"

# Extrai o nome base do arquivo da chave S3
PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
if [ -z "$PYTHON_SCRIPT_NAME" ]; then
    log "ERRO CRÍTICO: Não foi possível extrair o nome do script de AWS_S3_SCRIPT_KEY ('${AWS_S3_SCRIPT_KEY}'). A chave não pode terminar com '/' ou ser vazia."
    exit 1
fi
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
log "INFO: Nome do script Python determinado como: ${PYTHON_SCRIPT_NAME}"
log "INFO: Caminho local para o script Python: ${LOCAL_PYTHON_SCRIPT_PATH}"


S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"
log "INFO: Baixando ${PYTHON_SCRIPT_NAME} de ${S3_URI_PYTHON_SCRIPT} para ${LOCAL_PYTHON_SCRIPT_PATH}"

if ! aws s3 cp "$S3_URI_PYTHON_SCRIPT" "$LOCAL_PYTHON_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
    log "ERRO CRÍTICO: Falha ao baixar o script Python '${PYTHON_SCRIPT_NAME}' de '$S3_URI_PYTHON_SCRIPT'."
    exit 1
fi
log "INFO: Script Python ${PYTHON_SCRIPT_NAME} baixado com sucesso para ${LOCAL_PYTHON_SCRIPT_PATH}."

# --- 5. Instalar Dependências Python (Flask) ---
log "INFO: Instalando dependências Python (Flask) para ${PYTHON_SCRIPT_NAME}."
if ! pip install Flask; then
    log "ERRO: Falha ao instalar Flask. Verifique a instalação do pip."
    exit 1
fi
log "INFO: Flask instalado com sucesso."

# --- 6. Definir Permissões ---
log "INFO: Definindo permissões para ${APP_DIR} para o usuário ${USER_FOR_SERVICE}."
chown -R ${USER_FOR_SERVICE}:${USER_FOR_SERVICE} "${APP_DIR}"
chmod 755 "${APP_DIR}"

# --- 7. Configurar e Iniciar o Serviço Systemd ---
log "INFO: Configurando o serviço systemd '${SERVICE_NAME}' para rodar ${LOCAL_PYTHON_SCRIPT_PATH}."

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=JMeter Remote Backend Flask Server (${PYTHON_SCRIPT_NAME})
After=network.target

[Service]
User=${USER_FOR_SERVICE}
Group=${USER_FOR_SERVICE}
WorkingDirectory=${APP_DIR}
# Se o JMeter não for encontrado no PATH do usuário do serviço, descomente e ajuste:
# Environment="JMETER_HOME=${JMETER_HOME_PATH}"
# Environment="PATH=/usr/local/bin:/usr/bin:/bin:${JMETER_HOME_PATH}/bin"
ExecStart=/usr/bin/python3 ${LOCAL_PYTHON_SCRIPT_PATH}
Restart=always
StandardOutput=append:/var/log/${SERVICE_NAME}.log
StandardError=append:/var/log/${SERVICE_NAME}.error.log
# LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

log "INFO: Recarregando daemon systemd, habilitando e iniciando o serviço ${SERVICE_NAME}."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
if systemctl start "${SERVICE_NAME}.service"; then
    log "INFO: Serviço ${SERVICE_NAME} iniciado com sucesso."
else
    log "ERRO: Falha ao iniciar o serviço ${SERVICE_NAME}. Verifique os logs do serviço com 'journalctl -u ${SERVICE_NAME}'."
    sleep 2
    journalctl -u ${SERVICE_NAME} --no-pager -n 20 || true
    exit 1
fi

systemctl status "${SERVICE_NAME}" --no-pager || true

log "INFO: Script User Data concluído com sucesso!"
exit 0
