#!/bin/bash
# Script Jmeter.sh Version: 2.4.7
# Changelog:
# v2.4.7 - ## CORREÇÃO CRÍTICA ##: Corrigida a linha 'ExecStart' no arquivo de serviço systemd.
#          Ela estava apontando incorretamente para 'Jmeter.sh' em vez do script da aplicação Python
#          ('JmeterServer.py'), o que causava a falha imediata do serviço.
# v2.4.6 - Adaptado para o user-data padrão.

set -e

echo "INFO: Iniciando script Jmeter.sh (Version 2.4.7 - CORRIGIDO)."
echo "INFO: Timestamp de início: $(date '+%Y-%m-%d %H:%M:%S')"

# --- Definições de Variáveis ---
APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"
USER_FOR_SERVICE="ec2-user"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# --- 1. Instalação de Dependências ---
log "INFO: Instalando dependências do sistema..."
yum update -y -q
PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget procps-ng java-11-openjdk-devel"
yum install -y -q $PACKAGES_TO_INSTALL || { log "ERRO CRÍTICO: Falha ao instalar dependências com yum."; exit 1; }
log "INFO: Dependências do sistema instaladas."
pip3 install --upgrade pip -q

# --- 2. Instalação do JMeter ---
log "INFO: Instalando JMeter ${JMETER_VERSION}..."
if [ ! -d "${JMETER_HOME_PATH}" ]; then
    cd /tmp
    wget -T 30 -t 3 -q "${JMETER_TGZ_URL}" -O "apache-jmeter-${JMETER_VERSION}.tgz"
    tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "${JMETER_INSTALL_DIR}"
    rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
    log "INFO: JMeter instalado em ${JMETER_HOME_PATH}."
else
    log "INFO: JMeter já está instalado."
fi
"$JMETER_HOME_PATH/bin/jmeter" --version

# --- 3. Preparar Diretório da Aplicação ---
log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

# --- 4. Baixar o script da Aplicação Python ---
log "INFO: Baixando script da aplicação Python do S3..."

# O user-data já exportou as variáveis para o ambiente
if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
    log "ERRO CRÍTICO: Variáveis S3 para o script da aplicação não encontradas no ambiente."
    exit 1
fi

PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"

log "INFO: Baixando de '${S3_URI_PYTHON_SCRIPT}' para '${LOCAL_PYTHON_SCRIPT_PATH}'"
aws s3 cp "${S3_URI_PYTHON_SCRIPT}" "${LOCAL_PYTHON_SCRIPT_PATH}" --region "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-us-east-1}"
log "INFO: Script da aplicação ${PYTHON_SCRIPT_NAME} baixado."

# --- 5. Instalar Dependências Python ---
log "INFO: Instalando pacotes Python..."
pip3 install -q Flask Flask-CORS boto3 werkzeug || { log "ERRO: Falha ao instalar pacotes Python."; exit 1; }
log "INFO: Pacotes Python instalados."

# --- 6. Definir Permissões ---
log "INFO: Definindo permissões para ${APP_DIR}."
chown -R "${USER_FOR_SERVICE}:${USER_FOR_SERVICE}" "${APP_DIR}"
chmod -R u+rwX,go+rX,go-w "${APP_DIR}"

# --- 7. Configurar e Iniciar o Serviço Systemd (CORRIGIDO) ---
log "INFO: Configurando o serviço systemd '${SERVICE_NAME}'..."
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE_FOR_SERVICE="/home/ec2-user/.env"

cat >"${SERVICE_FILE_PATH}" <<EOF
[Unit]
Description=JMeter Remote Backend Flask Server
After=network.target

[Service]
User=${USER_FOR_SERVICE}
Group=${USER_FOR_SERVICE}
WorkingDirectory=${APP_DIR}
Environment="PYTHONUNBUFFERED=1"
Environment="JMETER_HOME=${JMETER_HOME_PATH}"
# Carrega as variáveis (como as do S3 para relatórios) do mesmo arquivo .env
EnvironmentFile=${ENV_FILE_FOR_SERVICE}

# ## CORREÇÃO CRÍTICA ##
# A linha ExecStart DEVE chamar o interpretador python3 para executar o SCRIPT PYTHON.
ExecStart=/usr/bin/python3 ${LOCAL_PYTHON_SCRIPT_PATH}

Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

log "INFO: Serviço systemd criado em ${SERVICE_FILE_PATH}."
log "INFO: Conteúdo do arquivo de serviço:"
cat "${SERVICE_FILE_PATH}" | sed 's/^/  /'

log "INFO: Recarregando, habilitando e reiniciando o serviço ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
sleep 5

log "INFO: Verificando status final do serviço ${SERVICE_NAME}..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "INFO: SUCESSO! O serviço ${SERVICE_NAME} foi iniciado corretamente."
    systemctl status "${SERVICE_NAME}" --no-pager -n 20
else
    log "ERRO CRÍTICO: O serviço ${SERVICE_NAME} falhou ao iniciar, mesmo após a correção."
    log "ERRO: Verificando logs do journal para depuração final:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 50
    exit 1
fi

log "INFO: Script Jmeter.sh (Version 2.4.7) concluído com sucesso!"
exit 0
