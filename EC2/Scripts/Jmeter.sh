#!/bin/bash
# Script Jmeter.sh Version: 2.4.4
# Changelog:
# v2.4.4 - Corrected S3 environment variable injection into systemd service file.
# v2.4.3 - Added boto3 to Python package installations.
# v2.4.2 - Added Flask-CORS to Python package installations.
# v2.4.1 - Corrected conditional logic for Java installation to satisfy linters.
# v2.4   - Simplified for Amazon Linux ONLY.
# v2.3   - Added detailed debugging for 'source .env' command.
# v2.2   - Added automatic JAVA_HOME detection.
# v2.1   - Refined pip command selection.
# v2.0   - Added manual JDK installation as a fallback.

set -e
exec > >(tee /var/log/jmeter-setup.log | logger -t jmeter-setup -s 2>/dev/console) 2>&1

echo "INFO: Iniciando script Jmeter.sh (Version 2.4.4 - Amazon Linux ONLY) para configurar JMeter Remote Backend."
echo "INFO: Timestamp de início: $(date '+%Y-%m-%d %H:%M:%S')"

APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
ENV_FILE_FOR_S3_DOWNLOAD="/home/ec2-user/.env" # Certifique-se que este arquivo contém as variáveis AWS_S3... para o script e para o bucket de relatório
JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"
JDK_TARBALL_URL="https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.tar.gz"
JDK_INSTALL_DIR="/opt/jdk-11"
JDK_TARBALL_NAME=$(basename "${JDK_TARBALL_URL}")

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

install_java_manually() {
    log "INFO: Iniciando instalação manual do JDK de ${JDK_TARBALL_URL}"
    cd /tmp || {
        log "ERRO: cd /tmp falhou"
        return 1
    }
    log "INFO: Baixando ${JDK_TARBALL_NAME}..."
    if ! wget -T 30 -t 3 -q "${JDK_TARBALL_URL}" -O "${JDK_TARBALL_NAME}"; then
        log "ERRO: Download JDK falhou."
        rm -f "${JDK_TARBALL_NAME}"
        return 1
    fi
    mkdir -p "${JDK_INSTALL_DIR}" || {
        log "ERRO: mkdir ${JDK_INSTALL_DIR} falhou"
        rm -f "${JDK_TARBALL_NAME}"
        return 1
    }
    log "INFO: Extraindo ${JDK_TARBALL_NAME} para ${JDK_INSTALL_DIR}..."
    if ! tar -xzf "${JDK_TARBALL_NAME}" -C "${JDK_INSTALL_DIR}" --strip-components=1; then
        log "ERRO: Extração JDK falhou."
        rm -f "${JDK_TARBALL_NAME}"
        return 1
    fi
    rm -f "${JDK_TARBALL_NAME}"
    log "INFO: JDK extraído para ${JDK_INSTALL_DIR}."
    export JAVA_HOME="${JDK_INSTALL_DIR}"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    JDK_PROFILE_SCRIPT="/etc/profile.d/jdk_manual.sh"
    {
        echo "export JAVA_HOME=${JDK_INSTALL_DIR}"
        echo "export PATH=\"${JAVA_HOME}/bin:\$PATH\""
    } >"${JDK_PROFILE_SCRIPT}"
    chmod +x "${JDK_PROFILE_SCRIPT}"
    log "INFO: JAVA_HOME (manual) configurado em ${JDK_PROFILE_SCRIPT}."
    return 0
}

log "INFO: Iniciando instalação de dependências para Amazon Linux."
JAVA_INSTALLED_SUCCESSFULLY=false
MAX_ATTEMPTS=3
RETRY_DELAY=20
USER_FOR_SERVICE="ec2-user"

log "INFO: Executando 'yum update -y'..."
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if yum update -y -q; then
        log "INFO: 'yum update' concluído."
        break
    fi
    log "AVISO: 'yum update' falhou (tentativa $attempt/$MAX_ATTEMPTS)."
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then log "ERRO: 'yum update' falhou."; fi
    sleep $RETRY_DELAY
done

log "INFO: Tentando instalar OpenJDK 11 via amazon-linux-extras..."
if sudo amazon-linux-extras install -y java-openjdk11; then
    log "INFO: OpenJDK 11 instalado via amazon-linux-extras."
    JAVA_INSTALLED_SUCCESSFULLY=true
else
    log "AVISO: Falha OpenJDK 11 (extras). Tentando Corretto 11 (extras)..."
    if sudo amazon-linux-extras install -y java-amazon-corretto11; then
        log "INFO: Corretto 11 instalado via amazon-linux-extras."
        JAVA_INSTALLED_SUCCESSFULLY=true
    else
        log "AVISO: Falha Corretto 11 (extras)."
    fi
fi

if [ "$JAVA_INSTALLED_SUCCESSFULLY" != true ]; then
    log "AVISO: Instalação Java (extras) falhou. Tentando instalação manual..."
    if install_java_manually; then
        log "INFO: Instalação manual JDK bem-sucedida."
        JAVA_INSTALLED_SUCCESSFULLY=true
    else
        log "ERRO CRÍTICO: Falha instalação manual JDK."
        exit 1
    fi
fi

if [ -z "${JAVA_HOME:-}" ] && command -v java &>/dev/null; then
    log "INFO: Detectando JAVA_HOME..."
    JAVA_EXEC_PATH_DETECT=$(readlink -f "$(command -v java)")
    if [[ "$JAVA_EXEC_PATH_DETECT" == */bin/java ]]; then
        DETECTED_JAVA_HOME=$(dirname "$(dirname "$JAVA_EXEC_PATH_DETECT")")
        if [ -d "$DETECTED_JAVA_HOME" ]; then
            export JAVA_HOME="$DETECTED_JAVA_HOME"
            log "INFO: JAVA_HOME detectado: ${JAVA_HOME}"
            JDK_PROFILE_SCRIPT_AUTO="/etc/profile.d/jdk_auto_detected.sh"
            {
                echo "export JAVA_HOME=${JAVA_HOME}"
                echo "export PATH=\"${JAVA_HOME}/bin:\$PATH\""
            } >"${JDK_PROFILE_SCRIPT_AUTO}"
            chmod +x "${JDK_PROFILE_SCRIPT_AUTO}"
            source "${JDK_PROFILE_SCRIPT_AUTO}"
        fi
    fi
elif [ -n "${JAVA_HOME:-}" ]; then
    log "INFO: JAVA_HOME já definido: ${JAVA_HOME}."
    [ -f /etc/profile.d/jdk_manual.sh ] && source /etc/profile.d/jdk_manual.sh
fi

if ! java -version &>/dev/null; then
    log "ERRO CRÍTICO: 'java -version' falhou."
    exit 1
else
    log "INFO: Java operacional. Versão:"
    java -version 2>&1 | while IFS= read -r line; do log "  $line"; done
fi

log "INFO: Instalando outras dependências..."
PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget"
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if yum install -y -q $PACKAGES_TO_INSTALL; then
        log "INFO: Outras dependências (yum) instaladas."
        break
    fi
    log "AVISO: Falha dependências (yum) (tentativa $attempt/$MAX_ATTEMPTS)."
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        log "ERRO CRÍTICO: Falha dependências (yum)."
        exit 1
    fi
    sleep $RETRY_DELAY
done
PIP_COMMAND="pip"
if command -v pip3 &>/dev/null; then PIP_COMMAND="pip3"; fi
log "INFO: Atualizando $PIP_COMMAND..."
"$PIP_COMMAND" install --upgrade pip -q

# --- 2. Instalação do JMeter ---
log "INFO: Iniciando instalação do JMeter ${JMETER_VERSION}..."
cd /tmp || {
    log "ERRO: Não foi possível mudar para /tmp"
    exit 1
}
if ! [ -d "${JMETER_HOME_PATH}" ]; then
    log "INFO: Baixando JMeter de ${JMETER_TGZ_URL}..."
    if ! wget -T 30 -t 3 -q "${JMETER_TGZ_URL}" -O "apache-jmeter-${JMETER_VERSION}.tgz"; then
        log "ERRO: Falha ao baixar JMeter."
        exit 1
    fi
    log "INFO: Extraindo JMeter para ${JMETER_INSTALL_DIR}..."
    mkdir -p "${JMETER_INSTALL_DIR}" || {
        log "ERRO: Não foi possível criar ${JMETER_INSTALL_DIR}"
        exit 1
    }
    if ! tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "${JMETER_INSTALL_DIR}"; then
        log "ERRO: Falha ao extrair JMeter."
        rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
        exit 1
    fi
    rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
    log "INFO: JMeter ${JMETER_VERSION} instalado em ${JMETER_HOME_PATH}."
else log "INFO: JMeter já parece estar instalado em ${JMETER_HOME_PATH}."; fi

JMETER_PROFILE_SCRIPT="/etc/profile.d/jmeter_env.sh"
log "INFO: Configurando JMETER_HOME em ${JMETER_PROFILE_SCRIPT}."
{
    echo "export JMETER_HOME=${JMETER_HOME_PATH}"
    echo "export PATH=\$PATH:\$JMETER_HOME/bin"
} >"${JMETER_PROFILE_SCRIPT}"
chmod +x "${JMETER_PROFILE_SCRIPT}"
log "INFO: Aplicando variáveis de ambiente dos scripts de profile..."
[ -f /etc/profile.d/jdk_manual.sh ] && source /etc/profile.d/jdk_manual.sh
[ -f /etc/profile.d/jdk_auto_detected.sh ] && source /etc/profile.d/jdk_auto_detected.sh
[ -f "${JMETER_PROFILE_SCRIPT}" ] && source "${JMETER_PROFILE_SCRIPT}"

log "INFO: Verificando o comando 'jmeter' e sua versão..."
JMETER_EXEC_PATH="${JMETER_HOME_PATH}/bin/jmeter"
if ! [ -x "$JMETER_EXEC_PATH" ]; then
    log "ERRO CRÍTICO: Executável JMeter não encontrado: '$JMETER_EXEC_PATH'."
    exit 1
fi
EFFECTIVE_PATH_FOR_JMETER_CHECK="${JMETER_HOME_PATH}/bin"
if [ -n "${JAVA_HOME:-}" ] && [ -d "${JAVA_HOME}/bin" ]; then EFFECTIVE_PATH_FOR_JMETER_CHECK="${JAVA_HOME}/bin:${EFFECTIVE_PATH_FOR_JMETER_CHECK}"; fi
EFFECTIVE_PATH_FOR_JMETER_CHECK=$(echo "${EFFECTIVE_PATH_FOR_JMETER_CHECK}:${PATH}" | awk -v RS=: -v ORS=: '!a[$0]++ && $0!="" {print $0}' | sed 's/:$//')
log "INFO: Usando executável JMeter: $JMETER_EXEC_PATH"
log "INFO: JAVA_HOME para verificação JMeter: ${JAVA_HOME:-NÃO DEFINIDO}"
log "INFO: PATH para verificação JMeter: ${EFFECTIVE_PATH_FOR_JMETER_CHECK}"
JMETER_VERSION_OUTPUT=$(timeout 30s env PATH="${EFFECTIVE_PATH_FOR_JMETER_CHECK}" JAVA_HOME="${JAVA_HOME:-}" "$JMETER_EXEC_PATH" --version 2>&1)
EXIT_CODE_JMETER_VERSION=$?
if [ $EXIT_CODE_JMETER_VERSION -ne 0 ]; then
    log "ERRO CRÍTICO com JMeter: Falha ao executar '$JMETER_EXEC_PATH --version' (código: $EXIT_CODE_JMETER_VERSION)."
    log "Saída do JMeter:"
    echo "${JMETER_VERSION_OUTPUT}" | while IFS= read -r line; do log "  JMET_ERR: $line"; done
    exit 1
elif [[ "$JMETER_VERSION_OUTPUT" == *"Error: JAVA_HOME is not defined correctly"* ]] ||
    [[ "$JMETER_VERSION_OUTPUT" == *"JAVA_HOME environment variable is not set"* ]] ||
    [[ "$JMETER_VERSION_OUTPUT" == *"Neither the JAVA_HOME nor the JRE_HOME environment variable is defined"* ]] ||
    [[ "$JMETER_VERSION_OUTPUT" == *"No Java runtime found"* ]]; then
    log "ERRO CRÍTICO com JMeter: Java não encontrado ou JAVA_HOME não configurado corretamente."
    echo "${JMETER_VERSION_OUTPUT}" | while IFS= read -r line; do log "  JMET_ERR: $line"; done
    exit 1
elif [[ "$JMETER_VERSION_OUTPUT" == *"Error: Could not find or load main class org.apache.jmeter.NewDriver"* ]]; then
    log "ERRO CRÍTICO com JMeter: Problema com a instalação (classe principal não encontrada)."
    echo "${JMETER_VERSION_OUTPUT}" | while IFS= read -r line; do log "  JMET_ERR: $line"; done
    exit 1
else
    log "INFO: Versão do JMeter:"
    echo "${JMETER_VERSION_OUTPUT}" | while IFS= read -r line; do log "  $line"; done
fi

# --- 3. Preparar Diretório da Aplicação ---
log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

# --- 4. Carregar Variáveis de Ambiente e Baixar o script Python do S3 ---
log "INFO: Preparando para baixar o script Python do S3."
if [ ! -f "$ENV_FILE_FOR_S3_DOWNLOAD" ]; then
    log "ERRO CRÍTICO: Arquivo .env '$ENV_FILE_FOR_S3_DOWNLOAD' não encontrado!"
    exit 1
fi
log "INFO: Tentando carregar (source) '$ENV_FILE_FOR_S3_DOWNLOAD'"
set +e
log "INFO: 'set -e' temporariamente desativado para source."
# shellcheck source=/dev/null
source "$ENV_FILE_FOR_S3_DOWNLOAD"
SOURCE_EXIT_CODE=$?
set -e
log "INFO: 'set -e' reativado. Código de saída do source: $SOURCE_EXIT_CODE"
if [ $SOURCE_EXIT_CODE -ne 0 ]; then
    log "ERRO CRÍTICO: Falha ao carregar '$ENV_FILE_FOR_S3_DOWNLOAD' (código: $SOURCE_EXIT_CODE)."
    exit 1
fi
log "INFO: .env DEVERIA ter sido carregado."
set -a
log "INFO: 'set -a' habilitado."
log "DEBUG: AWS_S3_BUCKET_TARGET_NAME_SCRIPT = '${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-NÃO CARREGADA}'"
log "DEBUG: AWS_S3_PYTHON_KEY = '${AWS_S3_PYTHON_KEY:-NÃO CARREGADA}'"
log "DEBUG: AWS_S3_BUCKET_TARGET_NAME_REPORT = '${AWS_S3_BUCKET_TARGET_NAME_REPORT:-NÃO CARREGADA}'"
log "DEBUG: AWS_S3_BUCKET_TARGET_REGION_REPORT = '${AWS_S3_BUCKET_TARGET_REGION_REPORT:-NÃO CARREGADA}'"

if [ -z "${AWS_S3_PYTHON_KEY:-}" ]; then
    log "ERRO CRÍTICO: AWS_S3_PYTHON_KEY não definida após source."
    exit 1
fi
PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_PYTHON_KEY}")
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_PYTHON_KEY}"
log "INFO: Baixando ${PYTHON_SCRIPT_NAME} de ${S3_URI_PYTHON_SCRIPT} para ${LOCAL_PYTHON_SCRIPT_PATH}"
S3_CP_OUTPUT_PY=$(aws s3 cp "$S3_URI_PYTHON_SCRIPT" "$LOCAL_PYTHON_SCRIPT_PATH" --region "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-us-east-1}" 2>&1) # Adicionado fallback para região do script
S3_CP_EXIT_CODE_PY=$?
if [ $S3_CP_EXIT_CODE_PY -ne 0 ]; then
    log "ERRO CRÍTICO: Falha download '${PYTHON_SCRIPT_NAME}' (código: $S3_CP_EXIT_CODE_PY). Detalhe: $S3_CP_OUTPUT_PY"
    exit 1
fi
log "INFO: Script Python ${PYTHON_SCRIPT_NAME} baixado."
set +a
log "INFO: 'set +a' desabilitado."

# --- 5. Instalar Dependências Python ---
log "INFO: Instalando pacotes Python (Flask, Flask-CORS, boto3)..."
PYTHON_PACKAGES_TO_INSTALL="Flask Flask-CORS boto3"

if ! "$PIP_COMMAND" install $PYTHON_PACKAGES_TO_INSTALL -q; then
    log "ERRO: Falha ao instalar pacotes Python ($PYTHON_PACKAGES_TO_INSTALL)."
    exit 1
fi
log "INFO: Pacotes Python ($PYTHON_PACKAGES_TO_INSTALL) instalados."

# --- 6. Definir Permissões ---
log "INFO: Definindo permissões para ${APP_DIR} para ${USER_FOR_SERVICE}."
chown -R "${USER_FOR_SERVICE}:${USER_FOR_SERVICE}" "${APP_DIR}"
chmod -R u+rwX,go+rX,go-w "${APP_DIR}"
if [ -f "${LOCAL_PYTHON_SCRIPT_PATH}" ]; then
    log "INFO: chmod +x para ${LOCAL_PYTHON_SCRIPT_PATH}"
    if ! chmod +x "${LOCAL_PYTHON_SCRIPT_PATH}"; then log "ERRO: chmod +x falhou para ${LOCAL_PYTHON_SCRIPT_PATH}"; fi
else
    log "ERRO CRÍTICO: ${LOCAL_PYTHON_SCRIPT_PATH} não encontrado para chmod."
    exit 1
fi

# --- 7. Configurar e Iniciar o Serviço Systemd ---
log "INFO: Configurando o serviço systemd '${SERVICE_NAME}'..."
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_JAVA_HOME_EFFECTIVE="${JAVA_HOME:-}"
if ! [ -d "${SERVICE_JAVA_HOME_EFFECTIVE}/bin" ]; then
    log "AVISO: JAVA_HOME ('${SERVICE_JAVA_HOME_EFFECTIVE}') não é um diretório Java válido ou não está definido para o serviço. Usando fallback /opt/jdk-11."
    SERVICE_JAVA_HOME_EFFECTIVE="/opt/jdk-11"
fi
log "INFO: JAVA_HOME efetivo para o serviço systemd: ${SERVICE_JAVA_HOME_EFFECTIVE}"

SERVICE_ENV_PATH_FINAL="${SERVICE_JAVA_HOME_EFFECTIVE}/bin:${JMETER_HOME_PATH}/bin"
SERVICE_ENV_PATH_FINAL=$(echo "${SERVICE_ENV_PATH_FINAL}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" | awk -v RS=: -v ORS=: '!a[$0]++ && $0!="" {print $0}' | sed 's/:$//')

cat >"${SERVICE_FILE_PATH}" <<EOF
[Unit]
Description=JMeter Remote Backend Flask Server (${PYTHON_SCRIPT_NAME})
After=network.target

[Service]
User=${USER_FOR_SERVICE}
Group=${USER_FOR_SERVICE}
WorkingDirectory=${APP_DIR}
Environment="PYTHONUNBUFFERED=1"
Environment="JAVA_HOME=${SERVICE_JAVA_HOME_EFFECTIVE}"
Environment="JMETER_HOME=${JMETER_HOME_PATH}"
Environment="PATH=${SERVICE_ENV_PATH_FINAL}"
$(if [ -n "${AWS_S3_BUCKET_TARGET_NAME_REPORT:-}" ]; then echo "Environment=\"AWS_S3_BUCKET_TARGET_NAME_REPORT=${AWS_S3_BUCKET_TARGET_NAME_REPORT}\""; fi)
$(if [ -n "${AWS_S3_BUCKET_TARGET_REGION_REPORT:-}" ]; then echo "Environment=\"AWS_S3_BUCKET_TARGET_REGION_REPORT=${AWS_S3_BUCKET_TARGET_REGION_REPORT}\""; fi)
ExecStart=/usr/bin/python3 ${LOCAL_PYTHON_SCRIPT_PATH}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

log "INFO: Serviço systemd: ${SERVICE_FILE_PATH} criado."
log "INFO: --- Conteúdo do arquivo de serviço (${SERVICE_FILE_PATH}) ---"
cat "${SERVICE_FILE_PATH}" | while IFS= read -r line; do log "  SVC_DEF: $line"; done
log "INFO: --- Fim do conteúdo do arquivo de serviço ---"
log "INFO: PATH para o serviço systemd: ${SERVICE_ENV_PATH_FINAL}"
log "INFO: Verificando variáveis de ambiente S3 que serão passadas para o serviço:"
if [ -n "${AWS_S3_BUCKET_TARGET_NAME_REPORT:-}" ]; then log "  SVC_S3_ENV: Environment=\"AWS_S3_BUCKET_TARGET_NAME_REPORT=${AWS_S3_BUCKET_TARGET_NAME_REPORT}\""; fi
if [ -n "${AWS_S3_BUCKET_TARGET_REGION_REPORT:-}" ]; then log "  SVC_S3_ENV: Environment=\"AWS_S3_BUCKET_TARGET_REGION_REPORT=${AWS_S3_BUCKET_TARGET_REGION_REPORT}\""; fi

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
log "INFO: Tentando (re)iniciar ${SERVICE_NAME}..."
systemctl stop "${SERVICE_NAME}.service" || true
sleep 1

if systemctl start "${SERVICE_NAME}.service"; then
    log "INFO: ${SERVICE_NAME} iniciado com sucesso."
    sleep 5
    log "INFO: Verificando status de ${SERVICE_NAME}..."
    systemctl status "${SERVICE_NAME}" --no-pager -n 20 || true
else
    log "ERRO: Falha ao iniciar ${SERVICE_NAME}."
    sleep 2
    log "ERRO: Detalhes do journal para ${SERVICE_NAME}:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 50 || true
    exit 1
fi

log "INFO: Script Jmeter.sh (Version 2.4.4 - Amazon Linux ONLY) concluído com sucesso!"
echo "INFO: Timestamp de conclusão: $(date '+%Y-%m-%d %H:%M:%S')"
exit 0
