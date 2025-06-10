#!/bin/bash
# Script Jmeter.sh Version: 2.4.8
# Changelog:
# v2.4.8 - ## CORREÇÃO CRÍTICA FINAL ##: Adicionada lógica robusta para detectar e exportar a variável
#          de ambiente JAVA_HOME antes de executar o JMeter. A falha em definir JAVA_HOME estava
#          causando a interrupção do script ao tentar verificar a versão do JMeter.
# v2.4.7 - Corrigida a linha 'ExecStart' no arquivo de serviço systemd.

set -e

echo "INFO: Iniciando script Jmeter.sh (Version 2.4.8 - Correção Final JAVA_HOME)."
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

# --- 1. Instalação de Dependências e Configuração do JAVA_HOME ---
log "INFO: Instalando dependências do sistema..."
yum update -y -q
# Usamos java-11-openjdk-devel para garantir que teremos o JDK completo
PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget procps-ng java-11-openjdk-devel"
yum install -y -q $PACKAGES_TO_INSTALL || { log "ERRO CRÍTICO: Falha ao instalar dependências com yum."; exit 1; }
log "INFO: Dependências do sistema instaladas."

# ## CORREÇÃO ##: Detectar e exportar JAVA_HOME
# Encontra o caminho do executável java
JAVA_EXEC_PATH=$(readlink -f $(which java))
# Deriva o diretório JAVA_HOME a partir do caminho do executável (ex: /usr/lib/jvm/java-11-openjdk-.../bin/java -> /usr/lib/jvm/java-11-openjdk-...)
export JAVA_HOME=$(dirname $(dirname $JAVA_EXEC_PATH))

if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME" ]; then
    log "ERRO CRÍTICO: Falha ao detectar o diretório JAVA_HOME automaticamente."
    exit 1
fi

log "INFO: JAVA_HOME detectado e exportado como: $JAVA_HOME"
log "INFO: Verificando a versão do Java para confirmar..."
java -version 2>&1 | while IFS= read -r line; do log "  $line"; done

# Instalação do pip
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

# Agora, com JAVA_HOME exportado, este comando deve funcionar
log "INFO: Verificando a versão do JMeter..."
"$JMETER_HOME_PATH/bin/jmeter" --version 2>&1 | while IFS= read -r line; do log "  $line"; done

# --- 3. Preparar Diretório da Aplicação ---
log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

# --- 4. Baixar o script da Aplicação Python ---
log "INFO: Baixando script da aplicação Python do S3..."
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

# --- 7. Configurar e Iniciar o Serviço Systemd ---
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
# Exporta o JAVA_HOME detectado para o ambiente do serviço também
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="JMETER_HOME=${JMETER_HOME_PATH}"
EnvironmentFile=${ENV_FILE_FOR_SERVICE}
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
    log "ERRO CRÍTICO: O serviço ${SERVICE_NAME} falhou ao iniciar."
    log "ERRO: Verificando logs do journal para depuração final:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 50
    exit 1
fi

log "INFO: Script Jmeter.sh (Version 2.4.8) concluído com sucesso!"
exit 0
