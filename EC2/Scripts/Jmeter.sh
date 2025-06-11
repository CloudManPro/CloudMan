#!/bin/bash
#vr 2.5
set -e # Sai imediatamente se um comando falhar
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1 # Log detalhado

echo "INFO: Iniciando script User Data para configurar JMeter Remote Backend."

# --- Configurações ---
APP_DIR="/opt/jmeter-remote-backend"
SERVICE_NAME="jmeter-backend"
ENV_FILE_FOR_S3_DOWNLOAD="/home/ec2-user/.env" # **IMPORTANTE**: Ajuste se necessário

JMETER_VERSION="5.6.3"
JMETER_TGZ_URL="https://dlcdn.apache.org//jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
JMETER_INSTALL_DIR="/opt"
JMETER_HOME_PATH="${JMETER_INSTALL_DIR}/apache-jmeter-${JMETER_VERSION}"

# --- Função de Log ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Função para aguardar liberação do lock do gerenciador de pacotes (yum/dnf) ---
wait_for_package_manager_lock() {
    log "INFO: Verificando lock do gerenciador de pacotes..."
    local lock_file_yum="/var/run/yum.pid"
    local lock_file_dnf="/var/cache/dnf/metadata_lock.pid" # Varia conforme a distro/versão do dnf
    local manager=""
    local lock_file=""

    if command -v dnf &>/dev/null; then
        manager="dnf"
        lock_file="$lock_file_dnf" # DNF pode usar outros mecanismos também, isso é um palpite
        # Uma verificação mais robusta para DNF seria checar se 'dnf' ou 'packagekitd' estão rodando e segurando locks.
    elif command -v yum &>/dev/null; then
        manager="yum"
        lock_file="$lock_file_yum"
    else
        log "AVISO: Gerenciador de pacotes não identificado como yum ou dnf. Pulando verificação de lock."
        return 0
    fi

    log "INFO: Usando gerenciador '$manager'. Arquivo de lock principal esperado: '$lock_file'."
    local timeout_seconds=300 # 5 minutos de timeout
    local interval_seconds=15
    local elapsed_seconds=0

    while true; do
        lock_held=false
        if [[ "$manager" == "yum" ]] && [[ -f "$lock_file" ]] && sudo fuser "$lock_file" &>/dev/null; then
            lock_held=true
        elif [[ "$manager" == "dnf" ]]; then
            # DNF lock é mais complexo. `pgrep dnf` ou `pgrep packagekitd` pode ser necessário.
            # Por simplicidade, vamos assumir que se o arquivo de lock existe e dnf está rodando, está lockado.
            if [[ -f "$lock_file" ]] && pgrep -x "dnf" &>/dev/null; then
                 lock_held=true
            elif pgrep -x "dnf" &>/dev/null || pgrep -x "packagekitd" &>/dev/null ; then
                 log "INFO: Processo '$manager' ou 'packagekitd' está rodando, assumindo lock ativo."
                 lock_held=true # Assumir lock se DNF ou PackageKit estiverem rodando
            fi
        fi

        if [ "$lock_held" = true ]; then
            if [ $elapsed_seconds -ge $timeout_seconds ]; then
                log "ERRO: Timeout ($timeout_seconds s) esperando liberação do lock do '$manager'."
                return 1
            fi
            log "INFO: Lock do '$manager' ativo. Esperando ${interval_seconds}s... (Total esperado: ${elapsed_seconds}s / ${timeout_seconds}s)"
            sleep $interval_seconds
            elapsed_seconds=$((elapsed_seconds + interval_seconds))
        else
            log "INFO: Lock do '$manager' parece estar liberado."
            return 0
        fi
    done
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

# Aguarda liberação do lock do gerenciador de pacotes
if ! wait_for_package_manager_lock; then
    log "ERRO CRÍTICO: Falha ao obter acesso ao gerenciador de pacotes. Abortando."
    exit 1
fi

JAVA_PACKAGE_NAME="" # Será definido abaixo

if [[ "$OS_TYPE" == "amzn" ]]; then # Amazon Linux
    log "INFO: Configurando para Amazon Linux."
    log "INFO: Executando 'yum update -y -q'..."
    yum update -y -q
    # Para Amazon Linux 2, Corretto é o recomendado.
    # Tente instalar Java 11 Corretto. Se precisar de outra versão, ajuste.
    JAVA_PACKAGE_NAME="java-11-amazon-corretto-devel"
    log "INFO: Tentando instalar '${JAVA_PACKAGE_NAME}' e outras dependências (python3, pip, aws-cli, tar, gzip)..."
    if ! yum install -y -q python3 python3-pip aws-cli tar gzip "${JAVA_PACKAGE_NAME}"; then
        log "AVISO: Falha ao instalar '${JAVA_PACKAGE_NAME}'. Tentando 'java-11-openjdk-devel' como fallback..."
        JAVA_PACKAGE_NAME="java-11-openjdk-devel" # Fallback
        if ! yum install -y -q python3 python3-pip aws-cli tar gzip "${JAVA_PACKAGE_NAME}"; then
            log "ERRO CRÍTICO: Falha ao instalar Java (tentou Corretto e OpenJDK) e/ou outras dependências base."
            exit 1
        fi
    fi
    USER_FOR_SERVICE="ec2-user"
elif [[ "$OS_TYPE" == "ubuntu" ]] || [[ "$OS_TYPE" == "debian" ]]; then # Ubuntu/Debian
    log "INFO: Configurando para Ubuntu/Debian."
    export DEBIAN_FRONTEND=noninteractive
    log "INFO: Executando 'apt-get update -y'..."
    apt-get update -y
    JAVA_PACKAGE_NAME="openjdk-11-jdk" # Ou openjdk-17-jdk, etc.
    log "INFO: Instalando '${JAVA_PACKAGE_NAME}' e outras dependências (python3, pip, awscli, tar, gzip)..."
    if ! apt-get install -y python3 python3-pip awscli tar gzip "${JAVA_PACKAGE_NAME}"; then
        log "ERRO CRÍTICO: Falha ao instalar Java e/ou outras dependências base."
        exit 1
    fi
    USER_FOR_SERVICE="ubuntu"
else
    log "ERRO CRÍTICO: Sistema operacional não suportado para instalação automática de dependências: $OS_TYPE"
    exit 1
fi

log "INFO: Verificando instalação do Java..."
if ! java -version &>/dev/null; then
    log "ERRO CRÍTICO: Java não foi instalado ou não está no PATH corretamente após a instalação do pacote '${JAVA_PACKAGE_NAME}'."
    exit 1
else
    log "INFO: Java instalado com sucesso. Versão:"
    java -version # Loga a versão
fi

if ! command -v pip &>/dev/null && command -v pip3 &>/dev/null; then
    ln -s /usr/bin/pip3 /usr/bin/pip || log "AVISO: Não foi possível criar link simbólico para pip."
fi
log "INFO: Atualizando pip..."
pip install --upgrade pip -q
log "INFO: Dependências base (Python, pip, AWS CLI, Java, etc.) instaladas."

# --- 2. Instalação do JMeter ---
# (O resto do script continua como antes, mas agora o Java deve estar instalado corretamente)
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
source "${JMETER_PROFILE_SCRIPT}" # Isso afeta apenas esta sessão de script

log "INFO: Verificando o comando 'jmeter' e sua versão..."
if ! command -v jmeter &> /dev/null; then
    log "AVISO: Comando 'jmeter' não encontrado no PATH após configuração. Verifique ${JMETER_PROFILE_SCRIPT} e a instalação do JMeter e Java."
    # O serviço systemd precisará que o PATH esteja correto para o usuário do serviço ou JMETER_HOME definido.
else
    log "INFO: Comando 'jmeter' encontrado no PATH: $(command -v jmeter)"
    JMETER_VERSION_OUTPUT=$(jmeter --version 2>&1)
    if [[ "$JMETER_VERSION_OUTPUT" == *"Neither the JAVA_HOME nor the JRE_HOME environment variable is defined"* ]]; then
        log "ERRO CRÍTICO com JMeter: ${JMETER_VERSION_OUTPUT}. O Java não foi encontrado pelo JMeter. Verifique a instalação do Java e as variáveis de ambiente."
        exit 1
    elif [[ "$JMETER_VERSION_OUTPUT" == *"Error: Could not find or load main class org.apache.jmeter.NewDriver"* ]]; then
        log "ERRO CRÍTICO com JMeter: ${JMETER_VERSION_OUTPUT}. Problema com a instalação do JMeter ou Java. Verifique a integridade dos arquivos do JMeter e a configuração do Java."
        exit 1
    else
        log "INFO: Versão do JMeter: $JMETER_VERSION_OUTPUT"
    fi
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

PYTHON_SCRIPT_NAME=$(basename "${AWS_S3_SCRIPT_KEY}")
if [ -z "$PYTHON_SCRIPT_NAME" ]; then
    log "ERRO CRÍTICO: Não foi possível extrair o nome do script de AWS_S3_SCRIPT_KEY ('${AWS_S3_SCRIPT_KEY}')."
    exit 1
fi
LOCAL_PYTHON_SCRIPT_PATH="${APP_DIR}/${PYTHON_SCRIPT_NAME}"
log "INFO: Nome do script Python: ${PYTHON_SCRIPT_NAME}. Caminho local: ${LOCAL_PYTHON_SCRIPT_PATH}"

S3_URI_PYTHON_SCRIPT="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"
log "INFO: Baixando ${PYTHON_SCRIPT_NAME} de ${S3_URI_PYTHON_SCRIPT} para ${LOCAL_PYTHON_SCRIPT_PATH}"

if ! aws s3 cp "$S3_URI_PYTHON_SCRIPT" "$LOCAL_PYTHON_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
    log "ERRO CRÍTICO: Falha ao baixar o script Python '${PYTHON_SCRIPT_NAME}' de '$S3_URI_PYTHON_SCRIPT'."
    # Adicionar mais detalhes sobre o erro do aws s3 cp
    ERROR_S3_CP=$(aws s3 cp "$S3_URI_PYTHON_SCRIPT" "$LOCAL_PYTHON_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT" 2>&1)
    log "ERRO S3 CP Detalhe: $ERROR_S3_CP"
    exit 1
fi
log "INFO: Script Python ${PYTHON_SCRIPT_NAME} baixado com sucesso."

# --- 5. Instalar Dependências Python (Flask) ---
log "INFO: Instalando Flask..."
if ! pip install Flask -q; then
    log "ERRO: Falha ao instalar Flask."
    exit 1
fi
log "INFO: Flask instalado."

# --- 6. Definir Permissões ---
log "INFO: Definindo permissões para ${APP_DIR} para o usuário ${USER_FOR_SERVICE}."
chown -R ${USER_FOR_SERVICE}:${USER_FOR_SERVICE} "${APP_DIR}"
chmod 755 "${APP_DIR}"

# --- 7. Configurar e Iniciar o Serviço Systemd ---
log "INFO: Configurando o serviço systemd '${SERVICE_NAME}' para rodar ${LOCAL_PYTHON_SCRIPT_PATH}."

# É importante que o usuário do serviço (ex: ec2-user) tenha o PATH correto para encontrar 'jmeter'
# ou que JMETER_HOME esteja definido no ambiente do serviço.
# /etc/profile.d/jmeter.sh configura isso para sessões de login, mas serviços systemd
# podem não herdar automaticamente. A melhor prática é definir no arquivo de serviço.
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=JMeter Remote Backend Flask Server (${PYTHON_SCRIPT_NAME})
After=network.target

[Service]
User=${USER_FOR_SERVICE}
Group=${USER_FOR_SERVICE}
WorkingDirectory=${APP_DIR}
Environment="JMETER_HOME=${JMETER_HOME_PATH}"
Environment="PATH=/usr/local/bin:/usr/bin:/bin:${JMETER_HOME_PATH}/bin" # Garante que jmeter e java estão no PATH do serviço
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
    log "ERRO: Falha ao iniciar o serviço ${SERVICE_NAME}. Verifique os logs com 'journalctl -u ${SERVICE_NAME}'."
    sleep 2
    journalctl -u ${SERVICE_NAME} --no-pager -n 20 || true
    exit 1
fi

systemctl status "${SERVICE_NAME}" --no-pager || true

log "INFO: Script User Data concluído com sucesso!"
exit 0
