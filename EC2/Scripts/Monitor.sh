#!/bin/bash
# === Script de Instalação e Configuração Automatizada de Adminer, FileBrowser e Grafana (RDS Focado) usando Docker ===
# DESCRIÇÃO: Monta EFS, instala Adminer para BD, FileBrowser para arquivos e Grafana para dashboards.
#            FileBrowser usará as mesmas credenciais do RDS.
# Versão: 4.9.3 (Adicionado Grafana, logs aprimorados, preparação de volume para Grafana)

set -e
# set -x # Descomente para depuração extrema (traça cada comando)

LOG_FILE="/var/log/monitor_tools_setup_docker_rds_only.log"
EFS_SETUP_LOG_FILE="/var/log/setup_efs_mount.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

print_line() { printf -- "%s\n" "$1"; }
print_format() {
    local format_string="$1"
    shift
    printf -- "$format_string\n" "$@"
}

print_line "================================================================"
print_line "--- Iniciando Script Monitor Tools Setup Docker (v4.9.3) ---"
print_format "--- Usando Adminer, FileBrowser (creds RDS) e Grafana ---"
print_format "--- Data: %s ---" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
print_line "================================================================"
printf "\n"

# --- Configurações e Variáveis de Ambiente ---
HOST_FB_CONFIG_DIR="/opt/filebrowser_config"
HOST_GRAFANA_DATA_DIR="/opt/grafana_data" # <<< ADICIONADO: Diretório para dados do Grafana

ADMINER_PORT_DEFAULT="8081"
FB_PORT_DEFAULT="8088"
GRAFANA_PORT_DEFAULT="3000" # <<< ADICIONADO: Porta padrão do Grafana
GRAFANA_ADMIN_PASSWORD_DEFAULT="ChangeMePlease123!" # <<< ADICIONADO: Senha inicial segura para o Grafana

ADMINER_IMAGE_TAG="latest"
FILEBROWSER_IMAGE_TAG="latest"
GRAFANA_IMAGE_TAG="latest" # <<< ADICIONADO: Tag da imagem do Grafana
DOCKER_COMPOSE_FILE="/opt/monitoring-tools/docker-compose.yml"
CONTAINER_FB_DATABASE_PATH="/database/filebrowser.db"

SCRIPT_INTERNAL_RDS_ENDPOINT="${AWS_DB_INSTANCE_TARGET_ENDPOINT_0}"
SCRIPT_INTERNAL_RDS_DB_NAME="${AWS_DB_INSTANCE_TARGET_NAME_0}"
SECRETNAME="${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
SCRIPT_INTERNAL_RDS_SECRET_ARN="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${SECRETNAME}"
SCRIPT_INTERNAL_AWS_REGION="${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-${REGION}}"

SCRIPT_INTERNAL_FB_ADMIN_USER=""
SCRIPT_INTERNAL_FB_ADMIN_PASSWORD=""

SCRIPT_INTERNAL_ADMINER_PORT="${ADMINER_PORT:-$ADMINER_PORT_DEFAULT}"
SCRIPT_INTERNAL_FB_PORT="${FB_PORT:-$FB_PORT_DEFAULT}"
SCRIPT_INTERNAL_GRAFANA_PORT="${GRAFANA_PORT:-$GRAFANA_PORT_DEFAULT}" # <<< ADICIONADO
SCRIPT_INTERNAL_GF_ADMIN_PASSWORD="${GF_ADMIN_PASSWORD:-$GRAFANA_ADMIN_PASSWORD_DEFAULT}" # <<< ADICIONADO

EFS_ID="${AWS_EFS_FILE_SYSTEM_TARGET_ID_0}"
EFS_MOUNT_POINT_DEFAULT="/var/www/html"
EFS_MOUNT_POINT="${AWS_EFS_FILE_SYSTEM_TARGET_PATH_0:-$EFS_MOUNT_POINT_DEFAULT}"

RDS_DB_USER_VAL=""
RDS_DB_PASSWORD_VAL=""

# [O restante das seções de verificação de variáveis, instalação de pré-requisitos e montagem do EFS permanecem idênticas]
# ... (código anterior omitido para brevidade, ele não muda) ...
print_line "--- 1. Instalando Pré-requisitos ---"
if command -v yum &>/dev/null; then
    T_YUM_LOCK=300
    I_YUM_LOCK=15
    E_YUM_LOCK=0
    print_line "INFO: Verificando lock yum..."
    while sudo fuser /var/run/yum.pid &>/dev/null; do
        if [ $E_YUM_LOCK -ge $T_YUM_LOCK ]; then
            print_line "ERRO: Timeout lock yum. Saindo."
            exit 1
        fi
        print_format "INFO: Lock yum ativo, esperando %ss..." "$I_YUM_LOCK"
        sleep $I_YUM_LOCK
        E_YUM_LOCK=$((E_YUM_LOCK + I_YUM_LOCK))
    done
    print_line "INFO: Lock yum liberado."
    sudo yum update -y -q
    sudo yum install -y -q jq curl unzip wget policycoreutils-python-utils amazon-efs-utils telnet docker
    print_line "INFO: Pacotes base instalados."
    if ! sudo systemctl is-active --quiet docker; then
        print_line "INFO: Iniciando/habilitando Docker..."
        sudo systemctl start docker
        sudo systemctl enable docker
    else print_line "INFO: Docker ativo."; fi
    if [ -n "$(whoami)" ] && [ "$(whoami)" != "root" ]; then sudo usermod -aG docker "$(whoami)" &>/dev/null || true; fi
    if ! docker compose version &>/dev/null; then
        print_line "INFO: Instalando Docker Compose V2 plugin..."
        _SCRIPT_USER_HOME=""
        if [ -n "$HOME" ] && [ -d "$HOME" ]; then _SCRIPT_USER_HOME="$HOME"; else
            _CURRENT_USER=$(whoami)
            if [ -n "$_CURRENT_USER" ]; then _SCRIPT_USER_HOME=$(getent passwd "$_CURRENT_USER" | cut -d: -f6); fi
        fi
        USER_DOCKER_CLI_PLUGINS_PATH=""
        if [ -n "$_SCRIPT_USER_HOME" ] && [ -d "$_SCRIPT_USER_HOME" ]; then USER_DOCKER_CLI_PLUGINS_PATH="${_SCRIPT_USER_HOME}/.docker/cli-plugins"; else
            print_line "WARN: Não foi possível determinar home dir."
            USER_DOCKER_CLI_PLUGINS_PATH="/tmp/.docker_compose_user_plugins_$(date +%s)"
        fi
        LATEST_COMPOSE_TAG=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        if [ -z "$LATEST_COMPOSE_TAG" ] || [ "$LATEST_COMPOSE_TAG" == "null" ]; then
            print_line "WARN: Tag Docker Compose não encontrada. Usando v2.27.0."
            LATEST_COMPOSE_TAG="v2.27.0"
        else
            if [[ ! "$LATEST_COMPOSE_TAG" =~ ^v ]]; then LATEST_COMPOSE_TAG="v${LATEST_COMPOSE_TAG}"; fi
            print_format "INFO: Tag Docker Compose: %s" "${LATEST_COMPOSE_TAG}"
        fi
        ARCH=$(uname -m)
        ARCH_FOR_COMPOSE=""
        if [ "$ARCH" == "aarch64" ]; then ARCH_FOR_COMPOSE="aarch64"; elif [ "$ARCH" == "x86_64" ]; then ARCH_FOR_COMPOSE="x86_64"; else
            print_format "ERRO CRÍTICO: Arquitetura %s não suportada. Saindo." "$ARCH"
            exit 1
        fi
        COMPOSE_DOWNLOAD_URL="https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_TAG}/docker-compose-linux-${ARCH_FOR_COMPOSE}"
        SYSTEM_PLUGIN_DIR="/usr/local/libexec/docker/cli-plugins"
        sudo mkdir -p "$SYSTEM_PLUGIN_DIR"
        print_format "INFO: Instalando Docker Compose em %s..." "$SYSTEM_PLUGIN_DIR"
        if sudo curl -SL --fail "${COMPOSE_DOWNLOAD_URL}" -o "${SYSTEM_PLUGIN_DIR}/docker-compose"; then
            sudo chmod +x "${SYSTEM_PLUGIN_DIR}/docker-compose"
            if docker compose version &>/dev/null; then print_format "INFO: Docker Compose instalado em %s." "${SYSTEM_PLUGIN_DIR}"; else
                print_format "WARN: Docker Compose não funcional em %s. Fallback para %s..." "$SYSTEM_PLUGIN_DIR" "$USER_DOCKER_CLI_PLUGINS_PATH"
                mkdir -p "${USER_DOCKER_CLI_PLUGINS_PATH}"
                if [ -d "$(dirname "${USER_DOCKER_CLI_PLUGINS_PATH}")" ]; then if curl -SL --fail "${COMPOSE_DOWNLOAD_URL}" -o "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose"; then
                    chmod +x "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose"
                    if docker compose version &>/dev/null; then print_format "INFO: Docker Compose instalado em %s." "${USER_DOCKER_CLI_PLUGINS_PATH}"; else
                        print_line "ERRO CRÍTICO: Falha ao detectar Docker Compose V2 após fallback. Saindo."
                        rm -f "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose"
                        exit 1
                    fi
                else
                    print_format "ERRO CRÍTICO: Download Docker Compose falhou para %s. Saindo." "${USER_DOCKER_CLI_PLUGINS_PATH}"
                    exit 1
                fi; else
                    print_format "ERRO CRÍTICO: Path %s inválido. Saindo." "${USER_DOCKER_CLI_PLUGINS_PATH}"
                    exit 1
                fi
            fi
        else
            print_format "ERRO CRÍTICO: Download Docker Compose falhou para %s. Saindo." "${SYSTEM_PLUGIN_DIR}"
            if [ -f "${SYSTEM_PLUGIN_DIR}/docker-compose" ]; then sudo rm -f "${SYSTEM_PLUGIN_DIR}/docker-compose"; fi
            exit 1
        fi
    else print_line "INFO: Docker Compose V2 já instalado."; fi
else
    print_line "ERRO CRÍTICO: Gerenciador de pacotes não suportado. Saindo."
    exit 1
fi
print_line "INFO: Pré-requisitos instalados."

print_line ""
print_line "--- 2. Configurando e Montando EFS ---"
# ... (código de montagem EFS omitido, sem alterações) ...
(
    exec > >(tee -a "${EFS_SETUP_LOG_FILE}") 2>&1
    set -e # Subshell com set -e
    print_format "INFO: (Log EFS) Preparando Ponto de Montagem '%s'..." "$EFS_MOUNT_POINT"
    sudo mkdir -p "$EFS_MOUNT_POINT"
    print_format "INFO: (Log EFS) Diretório '%s' criado." "$EFS_MOUNT_POINT"
    print_format "INFO: (Log EFS) Tentando desmontar '%s'..." "$EFS_MOUNT_POINT"
    sudo umount -l "$EFS_MOUNT_POINT" || true
    sleep 1
    sudo umount "$EFS_MOUNT_POINT" || true
    if mount | grep -q " ${EFS_MOUNT_POINT} "; then print_format "WARN: (Log EFS) '%s' ainda montado." "$EFS_MOUNT_POINT"; else print_format "INFO: (Log EFS) Ponto de montagem '%s' limpo." "$EFS_MOUNT_POINT"; fi
    print_line "INFO: (Log EFS) Tentando Montar o EFS..."
    MOUNT_OPTIONS_LIST=()
    MOUNT_OPTIONS_LIST+=("tls")
    if [ -n "$EFS_ACCESS_POINT_ID" ]; then
        print_line "INFO: (Log EFS) Usando 'accesspoint'."
        MOUNT_OPTIONS_LIST+=("accesspoint=${EFS_ACCESS_POINT_ID}")
    else print_line "INFO: (Log EFS) Montando raiz EFS (sem accesspoint específico)."; fi
    IFS=',' eval 'MOUNT_OPTIONS_STR="${MOUNT_OPTIONS_LIST[*]}"'
    EFS_TARGET="${EFS_ID}:/"
    print_format "INFO: (Log EFS) Comando: sudo mount -v -t efs -o %s %s %s" "$MOUNT_OPTIONS_STR" "$EFS_TARGET" "$EFS_MOUNT_POINT"
    if sudo mount -v -t efs -o "$MOUNT_OPTIONS_STR" "$EFS_TARGET" "$EFS_MOUNT_POINT"; then
        print_format "SUCESSO: (Log EFS) EFS '%s' montado em '%s'!" "$EFS_ID" "$EFS_MOUNT_POINT"
        FSTAB_ADD_SKIP="false"
    else
        MOUNT_EXIT_CODE=$?
        print_format "ERRO: (Log EFS) Falha ao montar EFS '%s' em '%s' (Código: %s). Verifique %s e logs do sistema." "$EFS_ID" "$EFS_MOUNT_POINT" "$MOUNT_EXIT_CODE" "$EFS_SETUP_LOG_FILE"
        FSTAB_ADD_SKIP="true"
    fi
    print_line "INFO: (Log EFS) Configurando /etc/fstab..."
    if [ "$FSTAB_ADD_SKIP" == "true" ]; then print_line "INFO: (Log EFS) Pulando /etc/fstab."; else
        FSTAB_ENTRY_BASE="${EFS_TARGET} ${EFS_MOUNT_POINT} efs _netdev,${MOUNT_OPTIONS_STR}"
        FSTAB_ENTRY_FULL="${FSTAB_ENTRY_BASE} 0 0"
        FSTAB_GREP_FIXED_STRING="${EFS_TARGET} ${EFS_MOUNT_POINT} efs "
        if sudo grep -qF -- "$FSTAB_GREP_FIXED_STRING" /etc/fstab; then print_format "INFO: (Log EFS) Entrada fstab já existe para '%s'." "$FSTAB_GREP_FIXED_STRING"; else
            print_format "INFO: (Log EFS) Adicionando ao fstab: %s" "$FSTAB_ENTRY_FULL"
            sudo cp /etc/fstab "/etc/fstab.bak.efs_setup_main.$(date +%F-%T)"
            echo "$FSTAB_ENTRY_FULL" | sudo tee -a /etc/fstab >/dev/null
            print_line "INFO: (Log EFS) Entrada adicionada."
        fi
    fi
    print_line "INFO: (Log EFS) Config EFS concluída."
)
print_line "--- Verificação Pós-Montagem EFS ---"
if df -hT | grep -q " ${EFS_MOUNT_POINT} "; then
    print_format "INFO: Montagem EFS em '%s' VERIFICADA." "$EFS_MOUNT_POINT"
    EFS_MOUNTED_SUCCESSFULLY=true
else
    print_format "ERRO: Montagem EFS em '%s' NÃO encontrada." "$EFS_MOUNT_POINT"
    print_format "Verifique '%s' e logs do sistema para detalhes da falha de montagem." "$EFS_SETUP_LOG_FILE"
    EFS_MOUNTED_SUCCESSFULLY=false
fi
print_line "------------------------------------"
printf "\n"

print_line "--- 3. Obtendo Credenciais RDS (para Adminer e FileBrowser) ---"
# ... (código de obtenção de credenciais omitido, sem alterações) ...
print_line "INFO: Buscando credenciais RDS..."
RDS_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SCRIPT_INTERNAL_RDS_SECRET_ARN" --query SecretString --output text --region "$SCRIPT_INTERNAL_AWS_REGION")
if [ -z "$RDS_SECRET_JSON" ]; then
    print_line "ERRO CRÍTICO: Falha ao obter segredo RDS. Saindo."
    exit 1
fi
RDS_DB_USER_VAL=$(echo "$RDS_SECRET_JSON" | jq -r .username)
RDS_DB_PASSWORD_VAL=$(echo "$RDS_SECRET_JSON" | jq -r .password)
if [ -z "$RDS_DB_USER_VAL" ] || [ "$RDS_DB_USER_VAL" == "null" ] || [ -z "$RDS_DB_PASSWORD_VAL" ] || [ "$RDS_DB_PASSWORD_VAL" == "null" ]; then
    print_line "ERRO CRÍTICO: Falha ao extrair user/pass RDS do Secrets Manager. Saindo."
    exit 1
fi
print_format "INFO: Credenciais RDS obtidas (Usuário: %s)." "$RDS_DB_USER_VAL"

print_line "INFO: Configurando FileBrowser para usar as credenciais RDS."
SCRIPT_INTERNAL_FB_ADMIN_USER="${RDS_DB_USER_VAL}"
SCRIPT_INTERNAL_FB_ADMIN_PASSWORD="${RDS_DB_PASSWORD_VAL}"
if [ -z "$SCRIPT_INTERNAL_FB_ADMIN_USER" ] || [ -z "$SCRIPT_INTERNAL_FB_ADMIN_PASSWORD" ]; then
    print_line "ERRO CRÍTICO: Usuário ou senha do RDS (para FileBrowser) estão vazios. Saindo."
    exit 1
fi
print_format "INFO: Credenciais do FileBrowser definidas para: Usuário '%s' (senha não mostrada)." "$SCRIPT_INTERNAL_FB_ADMIN_USER"


print_line ""
print_line "--- 4. Limpando e Preparando Configurações Docker Apps ---"
print_line "INFO: Parando e removendo quaisquer contêineres Docker existentes do compose..."
if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    sudo docker compose -f "${DOCKER_COMPOSE_FILE}" down --remove-orphans || print_line "INFO: 'docker compose down' falhou ou não havia nada para parar (ignorado)."
else
    print_line "INFO: Arquivo Docker Compose não encontrado, pulando 'down'."
fi

print_format "INFO: Criando diretório de configuração FileBrowser: %s" "$HOST_FB_CONFIG_DIR"
sudo mkdir -p "$HOST_FB_CONFIG_DIR"
sudo chmod -R 777 "$HOST_FB_CONFIG_DIR"

# <<< ADICIONADO: Seção para preparar o ambiente do Grafana >>>
print_format "INFO: Criando diretório de dados para o Grafana: %s" "$HOST_GRAFANA_DATA_DIR"
sudo mkdir -p "$HOST_GRAFANA_DATA_DIR"
print_line "INFO: Ajustando permissões do diretório do Grafana para o usuário do contêiner (ID 472)."
sudo chown -R 472:472 "$HOST_GRAFANA_DATA_DIR"
# <<< FIM DA ADIÇÃO >>>

print_line "INFO: Configurações Docker Apps preparadas."

print_line ""
print_line "--- 5. Criando Docker Compose File ---"
sudo mkdir -p "$(dirname "${DOCKER_COMPOSE_FILE}")"
# <<< MODIFICADO: O arquivo docker-compose.yml agora inclui o serviço 'grafana' >>>
sudo bash -c "cat > '${DOCKER_COMPOSE_FILE}'" <<EOF
services:
  adminer:
    image: adminer:${ADMINER_IMAGE_TAG}
    container_name: adminer_mysql_viewer
    restart: unless-stopped
    ports:
      - "${SCRIPT_INTERNAL_ADMINER_PORT}:8080"
    environment:
      TZ: America/Sao_Paulo
    networks: [monitoring_net]

  filebrowser:
    image: filebrowser/filebrowser:${FILEBROWSER_IMAGE_TAG}
    container_name: filebrowser_monitoring
    restart: unless-stopped
    ports: ["${SCRIPT_INTERNAL_FB_PORT}:80"]
    volumes:
      - "${EFS_MOUNT_POINT}:/srv"
      - "${HOST_FB_CONFIG_DIR}:/database"
    environment:
      FB_PORT: "80"
      FB_ADDRESS: "0.0.0.0"
      FB_ROOT: "/srv"
      FB_DATABASE: "${CONTAINER_FB_DATABASE_PATH}"
      FB_USERNAME: "${SCRIPT_INTERNAL_FB_ADMIN_USER}"
      FB_PASSWORD: "${SCRIPT_INTERNAL_FB_ADMIN_PASSWORD}"
      FB_BRANDING_NAME: "EFS Browser (${EFS_MOUNT_POINT})"
      FB_NOAUTH: "false"
      TZ: America/Sao_Paulo
    networks: [monitoring_net]

  grafana:
    image: grafana/grafana-oss:${GRAFANA_IMAGE_TAG}
    container_name: grafana_monitoring
    restart: unless-stopped
    ports:
      - "${SCRIPT_INTERNAL_GRAFANA_PORT}:3000"
    volumes:
      - "${HOST_GRAFANA_DATA_DIR}:/var/lib/grafana"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${SCRIPT_INTERNAL_GF_ADMIN_PASSWORD}"
      TZ: America/Sao_Paulo
    networks: [monitoring_net]

networks:
  monitoring_net:
    driver: bridge
EOF
print_line "INFO: Arquivo Docker Compose criado."

print_line ""
print_line "--- 6. Iniciando Serviços Docker ---"
if ! cd "$(dirname "${DOCKER_COMPOSE_FILE}")"; then
    print_format "ERRO CRÍTICO: Não foi possível mudar para %s. Saindo." "$(dirname "${DOCKER_COMPOSE_FILE}")"
    exit 1
fi
print_line "INFO: Puxando imagens Docker..."
if ! sudo docker compose pull; then
    print_line "ERRO: Falha ao puxar imagens Docker. Verifique a conexão e o Docker Hub."
fi
print_line "INFO: Iniciando contêineres Docker..."
if ! sudo docker compose up -d; then
    print_line "ERRO: Falha ao iniciar contêineres ('docker compose up -d'). Verifique os logs abaixo."
    sudo docker compose logs --tail="50" || echo "Não foi possível obter logs gerais do compose."
fi
print_line "INFO: Aguardando inicialização dos contêineres..."
sleep 15
print_line "INFO: Status dos contêineres (via docker compose ps):"
sudo docker compose ps
# <<< MODIFICADO: Adicionada verificação para o contêiner do Grafana >>>
print_line "--- DEBUG: Verificando IDs dos contêineres ---"
ADM_CONTAINER_ID=$(sudo docker compose ps -q adminer 2>/dev/null || echo "")
FB_CONTAINER_ID=$(sudo docker compose ps -q filebrowser 2>/dev/null || echo "")
GF_CONTAINER_ID=$(sudo docker compose ps -q grafana 2>/dev/null || echo "")
print_format "DEBUG: ADM_CONTAINER_ID = [%s]" "$ADM_CONTAINER_ID"
print_format "DEBUG: FB_CONTAINER_ID = [%s]" "$FB_CONTAINER_ID"
print_format "DEBUG: GF_CONTAINER_ID = [%s]" "$GF_CONTAINER_ID"
print_line "---------------------------------------------"

ADM_STATUS="não encontrado"
FB_STATUS="não encontrado"
GF_STATUS="não encontrado"

if [ -n "$ADM_CONTAINER_ID" ]; then ADM_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$ADM_CONTAINER_ID" 2>/dev/null || echo "erro inspect"); fi
if [ -n "$FB_CONTAINER_ID" ]; then FB_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FB_CONTAINER_ID" 2>/dev/null || echo "erro inspect"); fi
if [ -n "$GF_CONTAINER_ID" ]; then GF_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$GF_CONTAINER_ID" 2>/dev/null || echo "erro inspect"); fi

ALL_SERVICES_RUNNING=true
if [ "$ADM_STATUS" == "running" ]; then print_line "INFO: Adminer ativo (running)."; else
    print_format "WARN: Adminer NÃO está 'running'. Status: %s" "$ADM_STATUS"; sudo docker compose logs --tail="50" adminer; ALL_SERVICES_RUNNING=false; fi
if [ "$FB_STATUS" == "running" ]; then print_line "INFO: FileBrowser ativo (running)."; else
    print_format "WARN: FileBrowser NÃO está 'running'. Status: %s" "$FB_STATUS"; sudo docker compose logs --tail="20" filebrowser; ALL_SERVICES_RUNNING=false; fi
if [ "$GF_STATUS" == "running" ]; then print_line "INFO: Grafana ativo (running)."; else
    print_format "WARN: Grafana NÃO está 'running'. Status: %s" "$GF_STATUS"; sudo docker compose logs --tail="50" grafana; ALL_SERVICES_RUNNING=false; fi

# --- Conclusão ---
print_line ""
print_line "================================================================"
print_line "--- Script Monitor Tools Setup (Docker v4.9.3) concluído! ---"

# <<< MODIFICADO: Seção de conclusão agora inclui informações do Grafana >>>
ADMINER_URL_PARAMS=""
if [ -n "${SCRIPT_INTERNAL_RDS_ENDPOINT}" ] && [ -n "${RDS_DB_USER_VAL}" ]; then
    ADMINER_URL_PARAMS="server=${SCRIPT_INTERNAL_RDS_ENDPOINT}&username=${RDS_DB_USER_VAL}"
    if [ -n "${SCRIPT_INTERNAL_RDS_DB_NAME}" ]; then ADMINER_URL_PARAMS="${ADMINER_URL_PARAMS}&db=${SCRIPT_INTERNAL_RDS_DB_NAME}"; fi
fi

print_format "INFO: Adminer (Interface Web para RDS MySQL):"
if [ -n "$ADMINER_URL_PARAMS" ]; then
    print_line "      Acesse a URL e digite APENAS a senha:"
    print_format "         http://<IP_DA_EC2_OU_DNS>:%s/?%s" "$SCRIPT_INTERNAL_ADMINER_PORT" "$ADMINER_URL_PARAMS"
fi
print_format "      URL Base: http://<IP_DA_EC2_OU_DNS>:%s" "$SCRIPT_INTERNAL_ADMINER_PORT"
print_line ""
print_format "INFO: FileBrowser (Admin: %s - senha igual à do RDS):" "$SCRIPT_INTERNAL_FB_ADMIN_USER"
print_format "      URL: http://<IP_DA_EC2_OU_DNS>:%s" "$SCRIPT_INTERNAL_FB_PORT"
print_line ""
print_format "INFO: Grafana (Monitoramento e Dashboards):"
print_format "      URL: http://<IP_DA_EC2_OU_DNS>:%s" "$SCRIPT_INTERNAL_GRAFANA_PORT"
print_format "      Usuário: admin"
print_format "      Senha: %s (a que foi definida no script)" "$SCRIPT_INTERNAL_GF_ADMIN_PASSWORD"
print_line ""

if [ "$EFS_MOUNTED_SUCCESSFULLY" != true ]; then
    print_format "AVISO: Montagem EFS em '%s' FALHOU. FileBrowser não mostrará dados EFS." "$EFS_MOUNT_POINT"
fi
if [ "$ALL_SERVICES_RUNNING" != true ]; then
    print_line "AVISO: Um ou mais serviços (Adminer, FileBrowser, Grafana) NÃO iniciaram corretamente. Verifique os logs."
fi
print_format "INFO: Para gerenciar: cd %s; sudo docker compose [ps|logs|stop|start|down]" "$(dirname "${DOCKER_COMPOSE_FILE}")"
print_format "INFO: Log principal: %s; Log montagem EFS: %s" "${LOG_FILE}" "${EFS_SETUP_LOG_FILE}"
print_line "================================================================"

if [ "$ALL_SERVICES_RUNNING" != true ] || ([ "$EFS_MOUNTED_SUCCESSFULLY" != true ] && [ "$FB_STATUS" == "running" ]); then
    print_line "AVISO: Script concluído com um ou mais problemas."
    exit 1
else
    print_line "INFO: Script concluído com sucesso! Adminer, FileBrowser e Grafana devem estar operacionais."
    exit 0
fi
