#!/bin/bash
# Script Jmeter.sh Version: 2.4.6
# Changelog:
# v2.4.6 - ## ADAPTAÇÃO ##: Script modificado para se alinhar ao user-data padrão fornecido.
#          - Removida a lógica de baixar a si mesmo do S3; isso agora é responsabilidade do user-data.
#          - Ajustada a lógica de download do script Python para usar as variáveis de ambiente que o
#            user-data exporta (ex: AWS_S3_SCRIPT_KEY).
#          - O script agora assume que TODAS as variáveis de ambiente necessárias (para script e relatórios)
#            são pré-carregadas pelo processo que o chama (o user-data).
# v2.4.5 - Adicionado 'procps-ng' para garantir a presença do 'pgrep'.

set -e
# O log já é redirecionado pelo user-data que chama este script.
# exec > >(tee /var/log/jmeter-setup.log | logger -t jmeter-setup -s 2>/dev/console) 2>&1

echo "INFO: Iniciando script Jmeter.sh (Version 2.4.6 - Adaptado para User-Data Padrão)."
echo "INFO: Timestamp de início: $(date '+%Y-%m-%d %H:%M:%S')"

# --- Definições de Variáveis ---
APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"
USER_FOR_SERVICE="ec2-user"
MAX_ATTEMPTS=3
RETRY_DELAY=20

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# --- 1. Instalação de Dependências (Java, Yum, etc.) ---
# (Esta seção permanece a mesma, pois a configuração do ambiente base é necessária)
log "INFO: Executando 'yum update -y'..."
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if yum update -y -q; then log "INFO: 'yum update' concluído."; break; fi
    log "AVISO: 'yum update' falhou (tentativa $attempt/$MAX_ATTEMPTS)."; sleep $RETRY_DELAY;
done

log "INFO: Tentando instalar OpenJDK 11 via amazon-linux-extras..."
if ! sudo amazon-linux-extras install -y java-openjdk11; then
    log "AVISO: Instalação do OpenJDK 11 falhou. O sistema pode precisar de Java configurado manualmente."
fi

if ! java -version &>/dev/null; then
    log "ERRO CRÍTICO: Java não foi instalado ou não está no PATH. Verifique a instalação."
    exit 1
fi
log "INFO: Java operacional. Versão:"; java -version 2>&1 | while IFS= read -r line; do log "  $line"; done

log "INFO: Instalando outras dependências (yum)..."
PACKAGES_TO_INSTALL="python3 python3-pip aws-cli tar gzip wget procps-ng"
yum install -y -q $PACKAGES_TO_INSTALL || { log "ERRO CRÍTICO: Falha ao instalar dependências com yum."; exit 1; }
log "INFO: Outras dependências (yum) instaladas."
pip3 install --upgrade pip -q

# --- 2. Instalação do JMeter ---
# (Esta seção permanece a mesma)
log "INFO: Iniciando instalação do JMeter ${JMETER_VERSION}..."
if [ ! -d "${JMETER_HOME_PATH}" ]; then
    cd /tmp
    log "INFO: Baixando JMeter de ${JMETER_TGZ_URL}..."
    wget -T 30 -t 3 -q "${JMETER_TGZ_URL}" -O "apache-jmeter-${JMETER_VERSION}.tgz" || { log "ERRO: Falha ao baixar JMeter."; exit 1; }
    log "INFO: Extraindo JMeter para ${JMETER_INSTALL_DIR}..."
    tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C "${JMETER_INSTALL_DIR}"
    rm -f "apache-jmeter-${JMETER_VERSION}.tgz"
    log "INFO: JMeter ${JMETER_VERSION} instalado em ${JMETER_HOME_PATH}."
else
    log "INFO: JMeter já parece estar instalado em ${JMETER_HOME_PATH}."
fi

log "INFO: Verificando a versão do JMeter..."
"$JMETER_HOME_PATH/bin/jmeter" --version 2>&1 | while IFS= read -r line; do log "  $line"; done

# --- 3. Preparar Diretório da Aplicação ---
log "INFO: Criando diretório da aplicação em ${APP_DIR}."
mkdir -p "${APP_DIR}"

# --- 4. Baixar o script Python do S3 (Lógica Adaptada) ---
log "INFO: Preparando para baixar o script Python do S3, usando variáveis de ambiente pré-carregadas."

# O user-data exporta AWS_S3_SCRIPT_KEY, mas o bucket/região são os mesmos.
# O script Python é o que realmente precisa ser baixado aqui.
# Assumimos que o nome do script Python é o valor de AWS_S3_SCRIPT_KEY.
if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
    log "ERRO CRÍTICO: As variáveis de ambiente AWS_S3_BUCKET_TARGET_NAME_SCRIPT e/ou AWS_S3_SCRIPT_KEY não foram exportadas pelo user-data."
    exit 1
fi

PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"

log "INFO: Baixando script Python '${PYTHON_SCRIPT_NAME}' de '${S3_URI_PYTHON_SCRIPT}' para '${LOCAL_PYTHON_SCRIPT_PATH}'"
aws s3 cp "${S3_URI_PYTHON_SCRIPT}" "${LOCAL_PYTHON_SCRIPT_PATH}" --region "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-us-east-1}" || {
    log "ERRO CRÍTICO: Falha no download do script Python. Verifique permissões do IAM Role e se o arquivo existe no S3."
    exit 1
}
log "INFO: Script Python ${PYTHON_SCRIPT_NAME} baixado com sucesso."

# --- 5. Instalar Dependências Python ---
log "INFO: Instalando pacotes Python (Flask, Flask-CORS, boto3)..."
pip3 install -q Flask Flask-CORS boto3 || { log "ERRO: Falha ao instalar pacotes Python."; exit 1; }
log "INFO: Pacotes Python instalados."

# --- 6. Definir Permissões ---
log "INFO: Definindo permissões para ${APP_DIR} para o usuário ${USER_FOR_SERVICE}."
chown -R "${USER_FOR_SERVICE}:${USER_FOR_SERVICE}" "${APP_DIR}"
chmod -R u+rwX,go+rX,go-w "${APP_DIR}"
chmod +x "${LOCAL_PYTHON_SCRIPT_PATH}"

# --- 7. Configurar e Iniciar o Serviço Systemd ---
log "INFO: Configurando o serviço systemd '${SERVICE_NAME}'..."
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# O serviço herda o ambiente do processo que o inicia (neste caso, este script,
# que herdou do user-data). No entanto, é mais robusto definir explicitamente no arquivo de serviço.
# O .env precisa ser lido aqui para obter as variáveis de relatório.
ENV_FILE_FOR_SERVICE="/home/ec2-user/.env"

# Definindo o PATH explicitamente para o serviço
SERVICE_ENV_PATH="/usr/local/bin:/usr/bin:/bin:${JMETER_HOME_PATH}/bin"

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
Environment="PATH=${SERVICE_ENV_PATH}"
# Carrega as variáveis (como as do S3 para relatórios) do mesmo arquivo .env
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
cat "${SERVICE_FILE_PATH}"

log "INFO: Recarregando, habilitando e reiniciando o serviço ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
sleep 5 # Dá um tempo para o serviço iniciar

log "INFO: Verificando status final do serviço ${SERVICE_NAME}..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "INFO: ${SERVICE_NAME} iniciado com sucesso."
    systemctl status "${SERVICE_NAME}" --no-pager -n 20
else
    log "ERRO CRÍTICO: Falha ao iniciar o serviço ${SERVICE_NAME}."
    log "ERRO: Verificando logs do journal para depuração:"
    journalctl -u "${SERVICE_NAME}" --no-pager -n 50
    exit 1
fi

log "INFO: Script Jmeter.sh (Version 2.4.6) concluído com sucesso!"
exit 0
