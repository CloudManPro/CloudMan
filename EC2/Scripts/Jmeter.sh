#!/bin/bash
# Script Jmeter.sh Version: 2.4.5
# Changelog:
# v2.4.5 - ## CORREÇÃO ##: Adicionado 'procps-ng' às dependências do yum.
#          Este pacote fornece o comando 'pgrep', que é uma dependência para a funcionalidade de "Reset Forçado"
#          do backend (JmeterServer.py v1.5.0+), resolvendo a falha de inicialização do serviço.
# v2.4.4 - Corrected S3 environment variable injection into systemd service file.
# v2.4.3 - Added boto3 to Python package installations.
# v2.4.2 - Added Flask-CORS to Python package installations.
# v2.4.1 - Corrected conditional logic for Java installation to satisfy linters.
# v2.4   - Simplified for Amazon Linux ONLY.

set -e
exec > >(tee /var/log/jmeter-setup.log | logger -t jmeter-setup -s 2>/dev/console) 2>&1

echo "INFO: Iniciando script Jmeter.sh (Version 2.4.5 - Amazon Linux ONLY) para configurar JMeter Remote Backend."
echo "INFO: Timestamp de início: $(date '+%Y-%m-%d %H:%M:%S')"

APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
ENV_FILE_FOR_S3_DOWNLOAD="/home/ec2-user/.env"
JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"
JDK_TARBALL_URL="https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.tar.gz"
JDK_INSTALL_DIR="/opt/jdk-11"
JDK_TARBALL_NAME=$(basename "${JDK_TARBALL_URL}")
USER_FOR_SERVICE="ec2-user"
MAX_ATTEMPTS=3
RETRY_DELAY=20

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

install_java_manually() {
    log "INFO: Iniciando instalação manual do JDK de ${JDK_TARBALL_URL}"
    cd /tmp || { log "ERRO: cd /tmp falhou"; return 1; }
    log "INFO: Baixando ${JDK_TARBALL_NAME}..."
    if ! wget -T 30 -t 3 -q "${JDK_TARBALL_URL}" -O "${JDK_TARBALL_NAME}"; then
        log "ERRO: Download JDK falhou."; rm -f "${JDK_TARBALL_NAME}"; return 1;
    fi
    mkdir -p "${JDK_INSTALL_DIR}" || { log "ERRO: mkdir ${JDK_INSTALL_DIR} falhou"; rm -f "${JDK_TARBALL_NAME}"; return 1; }
    log "INFO: Extraindo ${JDK_TARBALL_NAME} para ${JDK_INSTALL_DIR}..."
    if ! tar -xzf "${JDK_TARBALL_NAME}" -C "${JDK_INSTALL_DIR}" --strip-components=1; then
        log "ERRO: Extração JDK falhou."; rm -f "${JDK_TARBALL_NAME}"; return 1;
    fi
    rm -f "${JDK_TARBALL_NAME}"
    log "INFO: JDK extraído para ${JDK_INSTALL_DIR}."
    export JAVA_HOME="${JDK_INSTALL_DIR}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    JDK_PROFILE_SCRIPT="/etc/profile.d/jdk_manual.sh"
    { echo "export JAVA_HOME=${JDK_INSTALL_DIR}"; echo "export PATH=\"${JAVA_HOME}/bin:\$PATH\""; } >"${JDK_PROFILE_SCRIPT}"
    chmod +x "${JDK_PROFILE_SCRIPT}"; log "INFO: JAVA_HOME (manual) configurado em ${JDK_PROFILE_SCRIPT}."; return 0;
}

log "INFO: Executando 'yum update -y'..."
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if yum update -y -q; then log "INFO: 'yum update' concluído."; break; fi
    log "AVISO: 'yum update' falhou (tentativa $attempt/$MAX_ATTEMPTS)."; if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then log "ERRO: 'yum update' falhou."; fi; sleep $RETRY_DELAY;
done

log "INFO: Tentando instalar OpenJDK 11..."
JAVA_INSTALLED_SUCCESSFULLY=false
if sudo amazon-linux-extras install -y java-openjdk11 &>/dev/null; then
    log "INFO: OpenJDK 11 instalado."; JAVA_INSTALLED_SUCCESSFULLY=true;
elif sudo amazon-linux-extras install -y java-amazon-corretto11 &>/dev/null; then
    log "INFO: Corretto 11 instalado."; JAVA_INSTALLED_SUCCESSFULLY=true;
fi

if [ "$JAVA_INSTALLED_SUCCESSFULLY" != true ]; then
    log "AVISO: Instalação Java (extras) falhou. Tentando manual..."
    if install_java_manually; then log "INFO: Instalação manual JDK bem-sucedida."; JAVA_INSTALLED_SUCCESSFULLY=true; else log "ERRO CRÍTICO: Falha instalação manual JDK."; exit 1; fi
fi

if [ -z "${JAVA_HOME:-}" ] && command -v java &>/dev/null; then
    JAVA_EXEC_PATH_DETECT=$(readlink -f "$(command -v java)")
    if [[ "$JAVA_EXEC_PATH_DETECT" == */bin/java ]]; then
        export JAVA_HOME=$(dirname "$(dirname "$JAVA_EXEC_PATH_DETECT")"); log "INFO: JAVA_HOME detectado: ${JAVA_HOME}"
        { echo "export JAVA_HOME=${JAVA_HOME}"; echo "export PATH=\"${JAVA_HOME}/bin:\$PATH\""; } >"/etc/profile.d/jdk_auto.sh"; chmod +x /etc/profile.d/jdk_auto.sh;
    fi
fi
if [ -f /etc/profile.d/jdk_manual.sh ]; then source /etc/profile.d/jdk_manual.sh; fi
if [ -f /etc/profile.d/jdk_auto.sh ]; then source /etc/profile.d/jdk_auto.sh; fi

if ! java -version &>/dev/null; then log "ERRO CRÍTICO: 'java -version' falhou."; exit 1;
else log "INFO: Java operacional. Versão:"; java -version 2>&1 | while IFS= read -r line; do log "  $line"; done; fi

log "INFO: Instalando outras dependências..."
# ## CORREÇÃO ##: Adicionado procps-ng para garantir que 'pgrep' esteja disponível para o backend.
PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget procps-ng"
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if yum install -y -q $PACKAGES_TO_INSTALL; then log "INFO: Outras dependências (yum) instaladas."; break; fi
    log "AVISO: Falha dependências (yum) (tentativa $attempt/$MAX_ATTEMPTS)."; if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then log "ERRO CRÍTICO: Falha dependências (yum)."; exit 1; fi; sleep $RETRY_DELAY;
done
PIP_COMMAND="pip3"
"$PIP_COMMAND" install --upgrade pip -q

log "INFO: Iniciando instalação do JMeter ${JMETER_VERSION}..."
cd /tmp || exit 1
if ! [ -d "${JMETER_HOME_PATH}" ]; then
    log "INFO: Baixando JMeter de ${JMETER_TGZ_URL}..."
    wget -T 30 -t 3 -q "${JMETER_TGZ_URL}" -O "apache-jmeter-${JMETER_VERSION}.tgz" || { log "ERRO: Falha ao baixar JMeter."; exit 1; }
    log "INFO: Extraindo JMeter para ${JMETER_INSTALL_DIR}..."
    tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "${JMETER_INSTALL_DIR}" || { log "ERRO: Falha ao extrair JMeter."; exit 1; }
    rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
    log "INFO: JMeter ${JMETER_VERSION} instalado em ${JMETER_HOME_PATH}."
else log "INFO: JMeter já instalado em ${JMETER_HOME_PATH}."; fi

JMETER_PROFILE_SCRIPT="/etc/profile.d/jmeter_env.sh"
{ echo "export JMETER_HOME=${JMETER_HOME_PATH}"; echo "export PATH=\$PATH:\$JMETER_HOME/bin"; } >"${JMETER_PROFILE_SCRIPT}"; chmod +x "${JMETER_PROFILE_SCRIPT}"
source "${JMETER_PROFILE_SCRIPT}"

log "INFO: Verificando o comando 'jmeter' e sua versão..."
"$JMETER_HOME_PATH/bin/jmeter" --version 2>&1 | while IFS= read -r line; do log "  $line"; done

log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

log "INFO: Baixando o script Python do S3."
if [ ! -f "$ENV_FILE_FOR_S3_DOWNLOAD" ]; then log "ERRO CRÍTICO: Arquivo .env '$ENV_FILE_FOR_S3_DOWNLOAD' não encontrado!"; exit 1; fi
set -o allexport; source "$ENV_FILE_FOR_S3_DOWNLOAD"; set +o allexport
if [ -z "${AWS_S3_PYTHON_KEY:-}" ]; then log "ERRO CRÍTICO: AWS_S3_PYTHON_KEY não definida."; exit 1; fi
PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_PYTHON_KEY}")
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_PYTHON_KEY}"
aws s3 cp "$S3_URI_PYTHON_SCRIPT" "$LOCAL_PYTHON_SCRIPT_PATH" --region "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-us-east-1}" || { log "ERRO CRÍTICO: Falha download do script Python."; exit 1; }
log "INFO: Script Python ${PYTHON_SCRIPT_NAME} baixado."

log "INFO: Instalando pacotes Python..."
"$PIP_COMMAND" install -q Flask Flask-CORS boto3 || { log "ERRO: Falha ao instalar pacotes Python."; exit 1; }

log "INFO: Definindo permissões para ${APP_DIR}."
chown -R "${USER_FOR_SERVICE}:${USER_FOR_SERVICE}" "${APP_DIR}"
chmod -R u+rwX,go+rX,go-w "${APP_DIR}"

log "INFO: Configurando o serviço systemd '${SERVICE_NAME}'..."
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_ENV_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${JMETER_HOME_PATH}/bin"
if [ -n "${JAVA_HOME}" ]; then SERVICE_ENV_PATH="${JAVA_HOME}/bin:${SERVICE_ENV_PATH}"; fi

cat >"${SERVICE_FILE_PATH}" <<EOF
[Unit]
Description=JMeter Remote Backend Flask Server
After=network.target

[Service]
User=${USER_FOR_SERVICE}
Group=${USER_FOR_SERVICE}
WorkingDirectory=${APP_DIR}
Environment="PYTHONUNBUFFERED=1"
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="JMETER_HOME=${JMETER_HOME_PATH}"
Environment="PATH=${SERVICE_ENV_PATH}"
EnvironmentFile=${ENV_FILE_FOR_S3_DOWNLOAD}
ExecStart=/usr/bin/python3 ${LOCAL_PYTHON_SCRIPT_PATH}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

log "INFO: Recarregando e iniciando o serviço ${SERVICE_NAME}."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
sleep 5

log "INFO: Verificando status de ${SERVICE_NAME}..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "INFO: ${SERVICE_NAME} iniciado com sucesso."
    systemctl status "${SERVICE_NAME}" --no-pager -n 20
else
    log "ERRO: Falha ao iniciar ${SERVICE_NAME}."
    journalctl -u "${SERVICE_NAME}" --no-pager -n 50
    exit 1
fi

log "INFO: Script Jmeter.sh (Version 2.4.5 - Amazon Linux ONLY) concluído com sucesso!"
exit 0
