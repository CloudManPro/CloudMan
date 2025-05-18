#!/bin/bash
# === Script de Instalação e Configuração Automatizada de Adminer e FileBrowser (RDS Focado) usando Docker ===
# DESCRIÇÃO: Monta EFS, instala Adminer para visualização de BD e FileBrowser.
#            FileBrowser é configurado para ter permissões de escrita no EFS
#            usando o UID/GID do usuário 'apache' do host.
# Versão: 4.9.3 (Baseado na v4.9.2, corrigido printf na função print_line)

set -e # Sair imediatamente se um comando falhar
# set -x # Descomente para depuração extrema (traça cada comando)

# --- Configuração de Logging ---
LOG_FILE="/var/log/monitor_tools_setup_docker_rds_only.log"
EFS_SETUP_LOG_FILE="/var/log/setup_efs_mount.log"

# Redireciona stdout e stderr para o arquivo de log E também para o console
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- Funções Auxiliares de Impressão ---
# CORRIGIDO: print_line para maior portabilidade do printf
print_line() { local i; for i in $(seq 1 70); do printf "%s" "-"; done; printf "\n"; } # Imprime uma linha de hífens
print_header() {
    print_line
    printf "--- %s ---\n" "$1"
    print_line
}
print_info() { printf "INFO: %s\n" "$1"; }
print_warn() { printf "WARN: %s\n" "$1"; }
print_error() { printf "ERRO: %s\n" "$1"; }
print_debug() { printf "DEBUG: %s\n" "$1"; }
print_format() {
    local format_string="$1"
    shift
    printf -- "$format_string\n" "$@" # O duplo hífen aqui é geralmente seguro para printf quando seguido de um formato
}


# --- Cabeçalho do Script ---
echo ""
print_header "Iniciando Script Monitor Tools Setup Docker (v4.9.3)"
print_info "Usando Adminer e FileBrowser com permissões de escrita EFS ajustadas."
print_format "Data: %s" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

# --- Configurações e Variáveis de Ambiente ---
print_header "Definindo Variáveis de Configuração"

FB_ADMIN_USER_DEFAULT="fbadmin"
HOST_FB_CONFIG_DIR="/opt/filebrowser_config" # Diretório no host para o DB do FileBrowser
ADMINER_PORT_DEFAULT="8081"
FB_PORT_DEFAULT="8088"
ADMINER_IMAGE_TAG="latest"
FILEBROWSER_IMAGE_TAG="latest" # Usar 'latest' ou uma tag específica como 'v2.23.0'
DOCKER_COMPOSE_FILE="/opt/monitoring-tools/docker-compose.yml"
CONTAINER_FB_DATABASE_PATH="/database/filebrowser.db" # Caminho do DB do FileBrowser DENTRO do contêiner

# Variáveis populadas pelo ambiente de execução (ex: User Data, CodeDeploy)
SCRIPT_INTERNAL_RDS_ENDPOINT="${AWS_DB_INSTANCE_TARGET_ENDPOINT_0}"
SCRIPT_INTERNAL_RDS_DB_NAME="${AWS_DB_INSTANCE_TARGET_NAME_0}"
SECRETNAME="${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0}"
SCRIPT_INTERNAL_RDS_SECRET_ARN="arn:aws:secretsmanager:${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0}:${ACCOUNT}:secret:${SECRETNAME}"
SCRIPT_INTERNAL_AWS_REGION="${AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0:-${REGION}}" # Fallback para $REGION

# Variáveis de configuração do FileBrowser (podem ser sobrescritas por variáveis de ambiente)
SCRIPT_INTERNAL_FB_ADMIN_PASSWORD="${FB_ADMIN_PASSWORD:-DefaultInsecureFbPassword123!}"
SCRIPT_INTERNAL_FB_ADMIN_USER="${FB_ADMIN_USER:-$FB_ADMIN_USER_DEFAULT}"

# Variáveis de porta (podem ser sobrescritas por variáveis de ambiente)
SCRIPT_INTERNAL_ADMINER_PORT="${ADMINER_PORT:-$ADMINER_PORT_DEFAULT}"
SCRIPT_INTERNAL_FB_PORT="${FB_PORT:-$FB_PORT_DEFAULT}"

# Variáveis EFS
EFS_ID="${AWS_EFS_FILE_SYSTEM_TARGET_ID_0}"
EFS_MOUNT_POINT_DEFAULT="/var/www/html" # Ponto de montagem do WordPress, FileBrowser o acessará aqui
EFS_MOUNT_POINT="${AWS_EFS_FILE_SYSTEM_TARGET_PATH_0:-$EFS_MOUNT_POINT_DEFAULT}"
# EFS_ACCESS_POINT_ID="${AWS_EFS_ACCESS_POINT_TARGET_ID_0}" # Comentado, montar raiz se não especificado

RDS_DB_USER_VAL=""    # Será preenchido pelo Secrets Manager
RDS_DB_PASSWORD_VAL="" # Será preenchido pelo Secrets Manager

print_info "Variáveis de ambiente e padrões definidos."
# ... (seções de debug de variáveis RDS e EFS como no original, se desejar adicioná-las novamente) ...

# --- Verificação de Variáveis Essenciais ---
print_header "Verificando Variáveis Essenciais"
essential_vars_check=("SCRIPT_INTERNAL_RDS_ENDPOINT" "SCRIPT_INTERNAL_RDS_DB_NAME" "SCRIPT_INTERNAL_RDS_SECRET_ARN" "SCRIPT_INTERNAL_AWS_REGION" "EFS_ID")
error_found_vars=0
for v_name in "${essential_vars_check[@]}"; do
    v_val="${!v_name}"
    if [ -z "${v_val}" ]; then
        original_var_name="$v_name" # Para clareza na mensagem de erro
        # Mapeia nomes internos de volta para os nomes originais esperados do ambiente
        case "$v_name" in
            SCRIPT_INTERNAL_RDS_ENDPOINT) original_var_name="AWS_DB_INSTANCE_TARGET_ENDPOINT_0" ;;
            SCRIPT_INTERNAL_RDS_DB_NAME)  original_var_name="AWS_DB_INSTANCE_TARGET_NAME_0" ;;
            SCRIPT_INTERNAL_RDS_SECRET_ARN) original_var_name="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0 (ou seus componentes)" ;;
            SCRIPT_INTERNAL_AWS_REGION)   original_var_name="AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0 ou REGION" ;;
            EFS_ID)                       original_var_name="AWS_EFS_FILE_SYSTEM_TARGET_ID_0" ;;
        esac
        print_error "Variável essencial '$v_name' (esperada de '$original_var_name') não populada."
        error_found_vars=1
    fi
done
if [ "$error_found_vars" -eq 1 ]; then
    print_error "CRÍTICO: Uma ou mais variáveis essenciais estão faltando. Saindo."
    exit 1
fi
print_info "Verificação de variáveis essenciais concluída. Todas presentes."
echo ""

# --- 1. Instalando Pré-requisitos ---
print_header "1. Instalando Pré-requisitos (YUM, Docker, Docker Compose)"
if command -v yum &>/dev/null; then
    T_YUM_LOCK=300; I_YUM_LOCK=15; E_YUM_LOCK=0
    print_info "Verificando lock do yum..."
    while sudo fuser /var/run/yum.pid &>/dev/null; do
        if [ $E_YUM_LOCK -ge $T_YUM_LOCK ]; then print_error "Timeout esperando liberação do lock do yum. Saindo."; exit 1; fi
        print_info "Lock do yum ativo, aguardando ${I_YUM_LOCK}s..."
        sleep $I_YUM_LOCK; E_YUM_LOCK=$((E_YUM_LOCK + I_YUM_LOCK))
    done
    print_info "Lock do yum liberado."
    sudo yum update -y -q
    print_info "Instalando pacotes: jq, curl, unzip, wget, policycoreutils-python-utils, amazon-efs-utils, telnet, docker..."
    sudo yum install -y -q jq curl unzip wget policycoreutils-python-utils amazon-efs-utils telnet docker
    print_info "Pacotes base instalados."
    if ! sudo systemctl is-active --quiet docker; then
        print_info "Iniciando e habilitando serviço Docker..."
        sudo systemctl start docker
        sudo systemctl enable docker
    else print_info "Serviço Docker já está ativo."; fi
    if [ -n "$(whoami)" ] && [ "$(whoami)" != "root" ]; then
        print_info "Adicionando usuário atual ($(whoami)) ao grupo docker..."
        sudo usermod -aG docker "$(whoami)" &>/dev/null || print_warn "Falha ao adicionar usuário ao grupo docker (ignorado se já membro)."
    fi
    if ! docker compose version &>/dev/null; then
        print_info "Instalando Docker Compose V2 plugin..."
        _SCRIPT_USER_HOME=""
        if [ -n "$HOME" ] && [ -d "$HOME" ]; then _SCRIPT_USER_HOME="$HOME"; else
            _CURRENT_USER=$(whoami); if [ -n "$_CURRENT_USER" ]; then _SCRIPT_USER_HOME=$(getent passwd "$_CURRENT_USER" | cut -d: -f6); fi
        fi
        USER_DOCKER_CLI_PLUGINS_PATH=""
        if [ -n "$_SCRIPT_USER_HOME" ] && [ -d "$_SCRIPT_USER_HOME" ]; then USER_DOCKER_CLI_PLUGINS_PATH="${_SCRIPT_USER_HOME}/.docker/cli-plugins"; else
            print_warn "Não foi possível determinar o diretório home do usuário. Usando path temporário para Docker Compose."
            USER_DOCKER_CLI_PLUGINS_PATH="/tmp/.docker_compose_user_plugins_$(date +%s)"
        fi
        LATEST_COMPOSE_TAG=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
        if [ -z "$LATEST_COMPOSE_TAG" ] || [ "$LATEST_COMPOSE_TAG" == "null" ]; then
            print_warn "Tag mais recente do Docker Compose não encontrada via API. Usando v2.27.0 como fallback."
            LATEST_COMPOSE_TAG="v2.27.0"
        else
            if [[ ! "$LATEST_COMPOSE_TAG" =~ ^v ]]; then LATEST_COMPOSE_TAG="v${LATEST_COMPOSE_TAG}"; fi # Garante prefixo 'v'
            print_info "Tag mais recente do Docker Compose encontrada: ${LATEST_COMPOSE_TAG}"
        fi
        ARCH=$(uname -m)
        ARCH_FOR_COMPOSE=""
        if [ "$ARCH" == "aarch64" ]; then ARCH_FOR_COMPOSE="aarch64"; elif [ "$ARCH" == "x86_64" ]; then ARCH_FOR_COMPOSE="x86_64"; else
            print_error "CRÍTICO: Arquitetura do sistema '${ARCH}' não suportada para Docker Compose. Saindo."
            exit 1
        fi
        COMPOSE_DOWNLOAD_URL="https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_TAG}/docker-compose-linux-${ARCH_FOR_COMPOSE}"
        SYSTEM_PLUGIN_DIR="/usr/local/libexec/docker/cli-plugins" # Local preferencial para system-wide
        sudo mkdir -p "$SYSTEM_PLUGIN_DIR"
        print_info "Tentando instalar Docker Compose em '${SYSTEM_PLUGIN_DIR}'..."
        if sudo curl -SL --fail "${COMPOSE_DOWNLOAD_URL}" -o "${SYSTEM_PLUGIN_DIR}/docker-compose"; then
            sudo chmod +x "${SYSTEM_PLUGIN_DIR}/docker-compose"
            if docker compose version &>/dev/null; then print_info "Docker Compose V2 instalado com sucesso em '${SYSTEM_PLUGIN_DIR}'."; else
                print_warn "Docker Compose não funcional em '${SYSTEM_PLUGIN_DIR}'. Tentando fallback para '${USER_DOCKER_CLI_PLUGINS_PATH}'..."
                mkdir -p "${USER_DOCKER_CLI_PLUGINS_PATH}"
                if [ -d "$(dirname "${USER_DOCKER_CLI_PLUGINS_PATH}")" ]; then # Verifica se o diretório pai do plugin existe
                    if curl -SL --fail "${COMPOSE_DOWNLOAD_URL}" -o "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose"; then
                        chmod +x "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose"
                        if docker compose version &>/dev/null; then print_info "Docker Compose V2 instalado com sucesso em '${USER_DOCKER_CLI_PLUGINS_PATH}'."; else
                            print_error "CRÍTICO: Falha ao detectar Docker Compose V2 funcional após fallback. Saindo."
                            rm -f "${USER_DOCKER_CLI_PLUGINS_PATH}/docker-compose" # Limpeza
                            exit 1
                        fi
                    else
                        print_error "CRÍTICO: Download do Docker Compose falhou para '${USER_DOCKER_CLI_PLUGINS_PATH}'. Saindo."
                        exit 1
                    fi
                else
                     print_error "CRÍTICO: Path do diretório de plugins do usuário '${USER_DOCKER_CLI_PLUGINS_PATH}' inválido. Saindo."
                     exit 1
                fi
            fi
        else
            print_error "CRÍTICO: Download do Docker Compose falhou para '${SYSTEM_PLUGIN_DIR}'. Saindo."
            if [ -f "${SYSTEM_PLUGIN_DIR}/docker-compose" ]; then sudo rm -f "${SYSTEM_PLUGIN_DIR}/docker-compose"; fi # Limpeza
            exit 1
        fi
    else print_info "Docker Compose V2 já está instalado."; fi
else
    print_error "CRÍTICO: Gerenciador de pacotes 'yum' não encontrado. Este script é para Amazon Linux 2. Saindo."
    exit 1
fi
print_info "Instalação de pré-requisitos concluída."
echo ""

# --- 2. Configurando e Montando EFS ---
# ...(O restante do script permanece IDENTICO à versão 4.9.2 que você já tem e que eu forneci anteriormente) ...
# Cole o restante do script a partir daqui, da seção:
# print_header "2. Configurando e Montando EFS no Host"
# até o final do script.
# --- 2. Configurando e Montando EFS ---
print_header "2. Configurando e Montando EFS no Host"
# Esta subshell garante que logs específicos da montagem EFS vão para seu próprio arquivo
(
    exec > >(tee -a "${EFS_SETUP_LOG_FILE}") 2>&1 # Redireciona output desta subshell
    set -e # Habilita saída em erro dentro da subshell
    print_info "(Log EFS) Preparando Ponto de Montagem '${EFS_MOUNT_POINT}' no host..."
    sudo mkdir -p "$EFS_MOUNT_POINT"
    print_info "(Log EFS) Diretório '${EFS_MOUNT_POINT}' criado/verificado."

    print_info "(Log EFS) Tentando desmontar '${EFS_MOUNT_POINT}' (caso já montado incorretamente)..."
    # Tenta desmontar para garantir uma montagem limpa. Ignora erros se não estiver montado.
    sudo umount -l "$EFS_MOUNT_POINT" || true # Lazy unmount
    sleep 1 # Pequena pausa
    sudo umount "$EFS_MOUNT_POINT" || true    # Normal unmount

    if mount | grep -q " ${EFS_MOUNT_POINT} "; then
        print_warn "(Log EFS) '${EFS_MOUNT_POINT}' ainda parece estar montado após tentativas de desmontagem."
    else
        print_info "(Log EFS) Ponto de montagem '${EFS_MOUNT_POINT}' parece estar limpo."
    fi

    print_info "(Log EFS) Tentando Montar o EFS '${EFS_ID}' em '${EFS_MOUNT_POINT}'..."
    MOUNT_OPTIONS_LIST=("tls") # Sempre usar TLS
    if [ -n "$EFS_ACCESS_POINT_ID" ]; then
        print_info "(Log EFS) Usando Access Point ID: ${EFS_ACCESS_POINT_ID}"
        MOUNT_OPTIONS_LIST+=("accesspoint=${EFS_ACCESS_POINT_ID}")
    else
        print_info "(Log EFS) Montando a raiz do EFS (sem Access Point específico)."
    fi
    IFS=',' eval 'MOUNT_OPTIONS_STR="${MOUNT_OPTIONS_LIST[*]}"' # Converte array para string separada por vírgula
    EFS_TARGET="${EFS_ID}:/" # Sufixo ':/' para montar a raiz do EFS (ou Access Point)

    print_info "(Log EFS) Comando de montagem: sudo mount -v -t efs -o '${MOUNT_OPTIONS_STR}' '${EFS_TARGET}' '${EFS_MOUNT_POINT}'"
    if sudo mount -v -t efs -o "$MOUNT_OPTIONS_STR" "$EFS_TARGET" "$EFS_MOUNT_POINT"; then
        print_info "(Log EFS) SUCESSO: EFS '${EFS_ID}' montado em '${EFS_MOUNT_POINT}'!"
        FSTAB_ADD_SKIP="false"
    else
        MOUNT_EXIT_CODE=$?
        print_error "(Log EFS) FALHA ao montar EFS '${EFS_ID}' em '${EFS_MOUNT_POINT}' (Código de saída: ${MOUNT_EXIT_CODE})."
        print_error "(Log EFS) Verifique o ID do EFS, Security Group (porta NFS 2049), políticas IAM, e se 'amazon-efs-utils' está instalado e funcional."
        print_error "(Log EFS) Consulte este log (${EFS_SETUP_LOG_FILE}) e os logs do sistema (ex: /var/log/messages ou journalctl) para mais detalhes."
        FSTAB_ADD_SKIP="true" # Não adiciona ao fstab se a montagem falhou
    fi

    print_info "(Log EFS) Configurando /etc/fstab para persistência da montagem EFS..."
    if [ "$FSTAB_ADD_SKIP" == "true" ]; then
        print_warn "(Log EFS) Pulando adição ao /etc/fstab devido à falha na montagem inicial."
    else
        FSTAB_ENTRY_BASE="${EFS_TARGET} ${EFS_MOUNT_POINT} efs _netdev,${MOUNT_OPTIONS_STR}"
        FSTAB_ENTRY_FULL="${FSTAB_ENTRY_BASE} 0 0"
        FSTAB_GREP_FIXED_STRING="${EFS_TARGET} ${EFS_MOUNT_POINT} efs " # String para grep, menos propensa a falsos positivos

        if sudo grep -qF -- "$FSTAB_GREP_FIXED_STRING" /etc/fstab; then
            print_info "(Log EFS) Entrada para '${FSTAB_GREP_FIXED_STRING}' já existe no /etc/fstab."
        else
            print_info "(Log EFS) Adicionando ao /etc/fstab: ${FSTAB_ENTRY_FULL}"
            sudo cp /etc/fstab "/etc/fstab.bak.efs_setup_main.$(date +%F-%T)" # Backup do fstab
            echo "$FSTAB_ENTRY_FULL" | sudo tee -a /etc/fstab >/dev/null
            print_info "(Log EFS) Entrada adicionada ao /etc/fstab."
        fi
    fi
    print_info "(Log EFS) Configuração da montagem EFS no host concluída."
) # Fim da subshell para logs de EFS

# --- Verificação Pós-Montagem EFS no Host ---
print_header "Verificação Pós-Montagem EFS no Host"
EFS_MOUNTED_SUCCESSFULLY_ON_HOST=false
if df -hT | grep -q " ${EFS_MOUNT_POINT} "; then # Verifica se o ponto de montagem está listado
    print_info "SUCESSO: Montagem EFS em '${EFS_MOUNT_POINT}' VERIFICADA no host."
    EFS_MOUNTED_SUCCESSFULLY_ON_HOST=true
else
    print_error "FALHA CRÍTICA: Montagem EFS em '${EFS_MOUNT_POINT}' NÃO encontrada no host após tentativa."
    print_error "O FileBrowser não poderá acessar os dados do EFS. Verifique '${EFS_SETUP_LOG_FILE}' e logs do sistema."
    # Considerar 'exit 1' aqui se o EFS for absolutamente essencial e o script não deve continuar.
    # Por enquanto, o script continuará e avisará no final.
fi
echo ""

# --- 3. Obtendo Credenciais RDS (para Adminer) ---
print_header "3. Obtendo Credenciais RDS do Secrets Manager"
print_info "Buscando credenciais RDS do segredo: ${SCRIPT_INTERNAL_RDS_SECRET_ARN} na região ${SCRIPT_INTERNAL_AWS_REGION}"
RDS_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SCRIPT_INTERNAL_RDS_SECRET_ARN" --query SecretString --output text --region "$SCRIPT_INTERNAL_AWS_REGION")
if [ -z "$RDS_SECRET_JSON" ]; then
    print_error "CRÍTICO: Falha ao obter o valor do segredo RDS do Secrets Manager. String vazia retornada. Saindo."
    exit 1
fi
RDS_DB_USER_VAL=$(echo "$RDS_SECRET_JSON" | jq -r .username)
RDS_DB_PASSWORD_VAL=$(echo "$RDS_SECRET_JSON" | jq -r .password) # Não será impresso
if [ -z "$RDS_DB_USER_VAL" ] || [ "$RDS_DB_USER_VAL" == "null" ] || [ -z "$RDS_DB_PASSWORD_VAL" ] || [ "$RDS_DB_PASSWORD_VAL" == "null" ]; then
    print_error "CRÍTICO: Falha ao extrair 'username' ou 'password' do JSON do segredo RDS. Saindo."
    print_debug "JSON Parcial Recebido (primeiros 50 chars): $(echo "$RDS_SECRET_JSON" | cut -c 1-50)..."
    exit 1
fi
print_info "Credenciais RDS obtidas com sucesso (Usuário: ${RDS_DB_USER_VAL})."
# ... (seção de debug de variáveis RDS pós-SecretsManager como no original, se desejar) ...
echo ""

# --- 4. Limpando e Preparando Configurações Docker Apps ---
print_header "4. Preparando Configurações para Aplicações Docker"
print_info "Parando e removendo quaisquer contêineres Docker existentes gerenciados por este compose file (se houver)..."
if [ -f "${DOCKER_COMPOSE_FILE}" ]; then
    sudo docker compose -f "${DOCKER_COMPOSE_FILE}" down --remove-orphans || print_warn "'docker compose down' falhou ou não havia nada para parar (ignorado)."
else
    print_info "Arquivo Docker Compose '${DOCKER_COMPOSE_FILE}' não encontrado, pulando 'down'."
fi

print_info "Criando/Verificando diretório de configuração do FileBrowser no host: ${HOST_FB_CONFIG_DIR}"
sudo mkdir -p "$HOST_FB_CONFIG_DIR"
# Permissões para o diretório que conterá o filebrowser.db.
# O contêiner FileBrowser (rodando como PUID/PGID especificados) precisará escrever aqui.
# Se PUID/PGID for apache:apache, então apache:apache deve ter permissão de escrita.
# Por simplicidade, 777 é usado, mas poderia ser mais restrito se PUID/PGID for conhecido e fixo.
sudo chmod -R 777 "$HOST_FB_CONFIG_DIR" # Facilitar, mas pode ser mais restrito.
print_info "Configurações para aplicações Docker preparadas."
echo ""

# --- 5. Criando Docker Compose File ---
print_header "5. Gerando Arquivo Docker Compose"
sudo mkdir -p "$(dirname "${DOCKER_COMPOSE_FILE}")" # Garante que o diretório /opt/monitoring-tools exista

# --- Início da Modificação: Obter UID/GID do Apache ---
# Tenta obter o UID e GID do usuário 'apache' do sistema host.
# O usuário 'apache' é tipicamente criado pela instalação do pacote httpd (Apache).
# 48 é o UID/GID padrão para 'apache' no Amazon Linux 2 e é usado como fallback.
APACHE_UID=$(id -u apache 2>/dev/null || echo "48")
APACHE_GID=$(id -g apache 2>/dev/null || echo "48")
print_info "UID do usuário 'apache' no host (para FileBrowser PUID): ${APACHE_UID}"
print_info "GID do grupo 'apache' no host (para FileBrowser PGID): ${APACHE_GID}"
# --- Fim da Modificação ---

# Gerar o arquivo docker-compose.yml
sudo bash -c "cat > '${DOCKER_COMPOSE_FILE}'" <<EOF
version: '3.8' # Especificar versão do compose format

services:
  adminer:
    image: adminer:${ADMINER_IMAGE_TAG}
    container_name: adminer_mysql_viewer
    restart: unless-stopped
    ports:
      - "${SCRIPT_INTERNAL_ADMINER_PORT}:8080" # Mapeia porta do host para porta 8080 do Adminer
    environment:
      TZ: America/Sao_Paulo # Define o fuso horário
    networks:
      - monitoring_net

  filebrowser:
    image: filebrowser/filebrowser:${FILEBROWSER_IMAGE_TAG}
    container_name: filebrowser_monitoring
    restart: unless-stopped
    ports:
      - "${SCRIPT_INTERNAL_FB_PORT}:80" # Mapeia porta do host para porta 80 do FileBrowser
    volumes:
      # MODIFICADO: Montar o EFS como read-write (rw)
      # ${EFS_MOUNT_POINT} é o caminho no HOST (ex: /var/www/html)
      # /srv é o caminho DENTRO do contêiner FileBrowser
      - "${EFS_MOUNT_POINT}:/srv:rw"
      # Monta o diretório de configuração do host para persistir o banco de dados do FileBrowser
      - "${HOST_FB_CONFIG_DIR}:/database:rw"
    environment:
      FB_PORT: "80" # FileBrowser escuta na porta 80 DENTRO do contêiner
      FB_ADDRESS: "0.0.0.0" # Escuta em todas as interfaces DENTRO do contêiner
      FB_ROOT: "/srv" # Define o diretório raiz para o FileBrowser DENTRO do contêiner
      FB_DATABASE: "${CONTAINER_FB_DATABASE_PATH}" # Caminho para o filebrowser.db DENTRO do contêiner
      FB_USERNAME: "${SCRIPT_INTERNAL_FB_ADMIN_USER}"
      FB_PASSWORD: "${SCRIPT_INTERNAL_FB_ADMIN_PASSWORD}"
      FB_BRANDING_NAME: "EFS Browser (${EFS_MOUNT_POINT})" # Nome exibido na interface
      FB_NOAUTH: "false" # Requer autenticação (true para desabilitar login)
      TZ: America/Sao_Paulo # Define o fuso horário
      # ADICIONADO: Executar FileBrowser com o UID e GID do usuário 'apache' do host
      # Isso é crucial para que o FileBrowser tenha permissão para ler/escrever
      # nos arquivos do EFS que são de propriedade do 'apache:apache' (WordPress).
      PUID: "${APACHE_UID}"
      PGID: "${APACHE_GID}"
    networks:
      - monitoring_net

networks:
  monitoring_net:
    driver: bridge # Usa a rede bridge padrão do Docker
EOF
print_info "Arquivo Docker Compose '${DOCKER_COMPOSE_FILE}' criado/atualizado com sucesso."
echo ""

# --- 6. Iniciando Serviços Docker ---
print_header "6. Iniciando Serviços Docker via Docker Compose"
if ! cd "$(dirname "${DOCKER_COMPOSE_FILE}")"; then
    print_error "CRÍTICO: Não foi possível mudar para o diretório do Docker Compose: $(dirname "${DOCKER_COMPOSE_FILE}"). Saindo."
    exit 1
fi
print_info "Diretório atual: $(pwd)"

print_info "Puxando as imagens Docker mais recentes (adminer, filebrowser)..."
if ! sudo docker compose pull; then
    print_warn "Falha ao executar 'docker compose pull'. Tentando continuar. Pode usar imagens locais cacheadas."
    # Não sair, 'up' pode funcionar com imagens locais. O erro será pego se as imagens não existirem.
fi

print_info "Iniciando contêineres Docker em modo detached (-d)..."
if ! sudo docker compose up -d; then
    print_error "FALHA ao iniciar contêineres com 'docker compose up -d'."
    print_info "Exibindo últimos 50 logs do Docker Compose para depuração:"
    sudo docker compose logs --tail="50" || print_warn "Não foi possível obter logs gerais do compose."
    # Não sair ainda, verificar status individual
fi

print_info "Aguardando 15 segundos para inicialização dos contêineres..."
sleep 15

print_info "Status dos contêineres (via 'docker compose ps'):"
sudo docker compose ps
print_line # Linha separadora

# --- Verificação de Status dos Contêineres ---
print_info "Verificando status individual dos contêineres..."
ADM_CONTAINER_ID=$(sudo docker compose ps -q adminer 2>/dev/null || echo "")
FB_CONTAINER_ID=$(sudo docker compose ps -q filebrowser 2>/dev/null || echo "")

print_debug "ID do Contêiner Adminer: [${ADM_CONTAINER_ID}]"
print_debug "ID do Contêiner FileBrowser: [${FB_CONTAINER_ID}]"

ADM_STATUS="não encontrado"
FB_STATUS="não encontrado"

if [ -n "$ADM_CONTAINER_ID" ]; then
    ADM_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$ADM_CONTAINER_ID" 2>/dev/null || echo "erro_inspect_adm")
else
    print_warn "ID do contêiner Adminer não encontrado via 'docker compose ps -q adminer'."
fi
if [ -n "$FB_CONTAINER_ID" ]; then
    FB_STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$FB_CONTAINER_ID" 2>/dev/null || echo "erro_inspect_fb")
else
    print_warn "ID do contêiner FileBrowser não encontrado via 'docker compose ps -q filebrowser'."
fi

print_debug "Status Adminer (Pós-Inspect): [${ADM_STATUS}]"
print_debug "Status FileBrowser (Pós-Inspect): [${FB_STATUS}]"
print_line # Linha separadora

ALL_SERVICES_RUNNING=true
if [ "$ADM_STATUS" == "running" ]; then print_info "Serviço Adminer está ATIVO (running)."; else
    print_warn "Serviço Adminer NÃO está 'running'. Status atual: ${ADM_STATUS}"
    print_info "Exibindo últimos 50 logs para o serviço Adminer:"
    sudo docker compose logs --tail="50" adminer || print_warn "Não foi possível obter logs para o serviço Adminer."
    ALL_SERVICES_RUNNING=false
fi
if [ "$FB_STATUS" == "running" ]; then print_info "Serviço FileBrowser está ATIVO (running)."; else
    print_warn "Serviço FileBrowser NÃO está 'running'. Status atual: ${FB_STATUS}"
    print_info "Exibindo últimos 50 logs para o serviço FileBrowser:"
    sudo docker compose logs --tail="50" filebrowser || print_warn "Não foi possível obter logs para o serviço FileBrowser."
    ALL_SERVICES_RUNNING=false
fi
echo ""

# --- Conclusão ---
print_header "Conclusão do Script de Setup"

# Construção da URL do Adminer
ADMINER_URL_PARAMS=""
if [ -n "${SCRIPT_INTERNAL_RDS_ENDPOINT}" ] && [ -n "${RDS_DB_USER_VAL}" ]; then
    ADMINER_URL_PARAMS="server=${SCRIPT_INTERNAL_RDS_ENDPOINT}&username=${RDS_DB_USER_VAL}"
    if [ -n "${SCRIPT_INTERNAL_RDS_DB_NAME}" ]; then
        ADMINER_URL_PARAMS="${ADMINER_URL_PARAMS}&db=${SCRIPT_INTERNAL_RDS_DB_NAME}"
    fi
else
    print_warn "Não foi possível construir a URL completa pré-preenchida do Adminer devido a variáveis RDS faltando."
fi
ADMINER_FULL_URL="http://<IP_DA_EC2_OU_DNS>:${SCRIPT_INTERNAL_ADMINER_PORT}/?${ADMINER_URL_PARAMS}"

print_info "Adminer (Interface Web para RDS MySQL):"
if [ -n "$ADMINER_URL_PARAMS" ]; then
    print_info "      Opção 1 (Recomendada): Acesse a URL abaixo e digite APENAS a senha do RDS:"
    print_format "         %s" "${ADMINER_FULL_URL}"
else
    print_warn "      AVISO: URL pré-preenchida do Adminer não pôde ser gerada."
fi
print_info "      Opção 2: Acesse a URL base e preencha todos os campos manualmente:"
print_format "         http://<IP_DA_EC2_OU_DNS>:%s" "$SCRIPT_INTERNAL_ADMINER_PORT"
print_info "      Detalhes para login manual no Adminer (Opção 2):"
print_format "      -> Sistema: MySQL"
print_format "      -> Servidor (Server): %s" "${SCRIPT_INTERNAL_RDS_ENDPOINT}"
print_format "      -> Usuário (Username): %s" "${RDS_DB_USER_VAL}"
print_info "      -> Senha (Password): (Use a senha do RDS obtida do Secrets Manager)"
print_format "      -> Banco de Dados (Database - opcional): %s" "${SCRIPT_INTERNAL_RDS_DB_NAME}"
echo ""

print_info "FileBrowser (Gerenciador de Arquivos Web para EFS):"
print_format "      URL de Acesso: http://<IP_DA_EC2_OU_DNS>:%s" "$SCRIPT_INTERNAL_FB_PORT"
print_format "      Admin User: %s" "$SCRIPT_INTERNAL_FB_ADMIN_USER"
print_format "      Admin Password: %s" "(Conforme definido ou 'DefaultInsecureFbPassword123!')"
if [ "$EFS_MOUNTED_SUCCESSFULLY_ON_HOST" != true ]; then
    print_warn "      AVISO CRÍTICO: FileBrowser pode não funcionar ou mostrar dados, pois a montagem EFS em '${EFS_MOUNT_POINT}' FALHOU no host."
else
    print_info "      FileBrowser deve ter permissões de leitura/escrita no EFS em '${EFS_MOUNT_POINT}'."
fi
echo ""

print_info "Para gerenciar os serviços Docker:"
print_format "      cd %s" "$(dirname "${DOCKER_COMPOSE_FILE}")"
print_info "      Comandos: sudo docker compose [ps|logs|stop|start|down|pull|up -d]"
echo ""
print_info "Logs deste script:"
print_format "      Log Principal: %s" "${LOG_FILE}"
print_format "      Log Montagem EFS no Host: %s" "${EFS_SETUP_LOG_FILE}"
print_line # Linha separadora final

# --- Lógica de Saída Final ---
FINAL_EXIT_CODE=0
if [ "$ALL_SERVICES_RUNNING" != true ]; then
    print_warn "AVISO GERAL: Um ou mais serviços Docker (Adminer, FileBrowser) não estão rodando corretamente."
    FINAL_EXIT_CODE=1
fi

if [ "$EFS_MOUNTED_SUCCESSFULLY_ON_HOST" != true ]; then
    print_error "AVISO CRÍTICO GERAL: A montagem do EFS no host em '${EFS_MOUNT_POINT}' falhou."
    if [ "$FB_STATUS" == "running" ]; then
        print_warn "FileBrowser está rodando, mas provavelmente não funcional devido à falha na montagem EFS no host."
    fi
    FINAL_EXIT_CODE=1 # Considerar falha na montagem EFS como crítica
fi


if [ $FINAL_EXIT_CODE -eq 0 ]; then
    print_info "Script concluído com SUCESSO! Adminer e FileBrowser devem estar operacionais."
else
    print_error "Script concluído com UM OU MAIS PROBLEMAS. Verifique os avisos e erros nos logs acima."
fi

exit $FINAL_EXIT_CODE
