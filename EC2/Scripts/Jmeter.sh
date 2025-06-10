#!/bin/bash
# Script Jmeter.sh Version: 3.0.0 (Stable)
# Changelog:
# v3.0.0 - Versão estável e consolidada.
#          - Garante a instalação de TODAS as dependências (Java, pgrep, etc.).
#          - Detecta e exporta JAVA_HOME de forma robusta.
#          - Cria um serviço systemd que aponta corretamente para o script Python.
#          - Estruturado com funções para clareza.

set -e

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - [SETUP] - $1"; }

# --- Definições de Variáveis ---
APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"
USER_FOR_SERVICE="ec2-user"
ENV_FILE_FOR_SERVICE="/home/ec2-user/.env"

# --- Funções de Setup ---

install_dependencies() {
    log "Iniciando a instalação de dependências do sistema..."
    yum update -y -q
    PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget procps-ng java-11-openjdk-devel"
    yum install -y -q $PACKAGES_TO_INSTALL
    pip3 install --upgrade pip -q
    log "Dependências do sistema instaladas com sucesso."
}

configure_java_home() {
    log "Configurando o ambiente Java..."
    if ! command -v java &>/dev/null; then
        log "ERRO CRÍTICO: O comando 'java' não foi encontrado após a instalação."
        return 1
    fi
    # Detecta e exporta JAVA_HOME para a sessão atual
    export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    if [ -z "$JAVA_HOME" ] || [ ! -d "$JAVA_HOME" ]; then
        log "ERRO CRÍTICO: Falha ao detectar o diretório JAVA_HOME."
        return 1
    fi
    log "JAVA_HOME detectado e exportado como: $JAVA_HOME"
    java -version 2>&1 | sed 's/^/  /'
}

install_jmeter() {
    log "Instalando JMeter ${JMETER_VERSION}..."
    if [ ! -d "${JMETER_HOME_PATH}" ]; then
        cd /tmp
        wget -T 30 -t 3 -q "${JMETER_TGZ_URL}" -O "apache-jmeter.tgz"
        tar -xzf "apache-jmeter.tgz" -C "${JMETER_INSTALL_DIR}"
        rm -f "apache-jmeter.tgz"
        log "JMeter instalado em ${JMETER_HOME_PATH}."
    else
        log "JMeter já está instalado."
    fi
    # Verifica se a instalação funciona (requer JAVA_HOME)
    "$JMETER_HOME_PATH/bin/jmeter" --version 2>&1 | sed 's/^/  /'
}

setup_application() {
    log "Configurando a aplicação backend..."
    mkdir -p "${APP_DIR}"

    if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
        log "ERRO CRÍTICO: Variáveis S3 (AWS_S3_BUCKET_TARGET_NAME_SCRIPT, AWS_S3_SCRIPT_KEY) não estão no ambiente."
        return 1
    fi

    PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
    LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
    S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"

    log "Baixando script da aplicação de '${S3_URI_PYTHON_SCRIPT}'..."
    aws s3 cp "${S3_URI_PYTHON_SCRIPT}" "${LOCAL_PYTHON_SCRIPT_PATH}" --region "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-us-east-1}"
    
    log "Instalando pacotes Python para a aplicação..."
    pip3 install -q Flask Flask-CORS boto3 werkzeug
    
    log "Definindo permissões da aplicação..."
    chown -R "${USER_FOR_SERVICE}:${USER_FOR_SERVICE}" "${APP_DIR}"
    chmod -R u+rwX,go+rX,go-w "${APP_DIR}"
}

create_and_start_service() {
    log "Configurando o serviço systemd '${SERVICE_NAME}'..."
    PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
    LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
    SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

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

    log "Serviço systemd criado. Recarregando e reiniciando..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    systemctl restart "${SERVICE_NAME}.service"
}

# --- Execução Principal ---

main() {
    log "Iniciando setup completo do JMeter Remote Backend."
    install_dependencies
    configure_java_home
    install_jmeter
    setup_application
    create_and_start_service

    sleep 5 # Aguarda um momento para o serviço estabilizar
    log "Verificação final do status do serviço:"
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log "SUCESSO! O serviço '${SERVICE_NAME}' está ativo e rodando."
        systemctl status "${SERVICE_NAME}" --no-pager -n 10
    else
        log "ERRO FINAL: O serviço '${SERVICE_NAME}' falhou ao iniciar. Verifique os logs detalhados."
        journalctl -u "${SERVICE_NAME}" --no-pager -n 50
        return 1
    fi
    log "Script Jmeter.sh (v3.0.0) concluído com sucesso!"
}

main "$@"
