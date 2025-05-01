#!/bin/bash

# --- Configuração ---
# Arquivo de ambiente (ajuste o caminho se necessário)
# ATENÇÃO: User Data normalmente executa como root. Se o .env está em /home/ec2-user,
#          o root precisa ter permissão para lê-lo, ou você pode precisar copiar/mover
#          o .env para um local acessível por root (ex: /etc/environment ou /root/.env)
#          ou executar este script como ec2-user.
#          Para simplicidade, vamos assumir que é legível ou ajustar conforme necessidade.
ENV_FILE="/home/ec2-user/.env"

# Arquivo de log para depuração
LOG_FILE="/var/log/fetch_and_run_s3_script.log"

# Diretório temporário para baixar o script
TMP_DIR="/tmp"

# --- Funções Auxiliares ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- Início da Execução ---
# Redireciona toda a saída (stdout e stderr) para o arquivo de log E para o console
exec > >(tee -a "$LOG_FILE") 2>&1

log "INFO: Iniciando script para buscar e executar script do S3."

# 1. Verifica se o AWS CLI está instalado
if ! command -v aws &>/dev/null; then
    log "ERRO: AWS CLI não encontrado. Por favor, instale-o (ex: sudo yum install aws-cli -y)."
    exit 1
fi
log "INFO: AWS CLI encontrado."

# 2. Verifica se o arquivo .env existe
if [ ! -f "$ENV_FILE" ]; then
    log "ERRO: Arquivo de ambiente '$ENV_FILE' não encontrado."
    exit 1
fi
log "INFO: Arquivo de ambiente '$ENV_FILE' encontrado."

# 3. Carrega as variáveis de ambiente
# Usamos 'set -a' para exportar as variáveis lidas para sub-processos (como aws cli)
# e 'set +a' para parar de exportar depois. '.' (source) executa no shell atual.
set -a
. "$ENV_FILE"
set +a
log "INFO: Variáveis de ambiente carregadas de '$ENV_FILE'."

# 4. Verifica se as variáveis necessárias foram carregadas
if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] ||
    [ -z "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}" ] ||
    [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
    log "ERRO: Uma ou mais variáveis necessárias não estão definidas no arquivo '$ENV_FILE'."
    log "ERRO: Verifique AWS_S3_BUCKET_TARGET_NAME_SCRIPT, AWS_S3_BUCKET_TARGET_REGION_SCRIPT, e AWS_S3_SCRIPT_KEY."
    exit 1
fi
log "INFO: Variáveis necessárias encontradas: BUCKET=${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}, REGION=${AWS_S3_BUCKET_TARGET_REGION_SCRIPT}, KEY=${AWS_S3_SCRIPT_KEY}"

# 5. Define o caminho de destino local para o script baixado
LOCAL_SCRIPT_PATH=$(mktemp "$TMP_DIR/s3_script.XXXXXX.sh")
log "INFO: Script será baixado para: $LOCAL_SCRIPT_PATH"

# Garante a limpeza do script temporário na saída (normal ou erro)
trap 'rm -f "$LOCAL_SCRIPT_PATH"' EXIT SIGHUP SIGINT SIGTERM

# 6. Constrói o URI S3
S3_URI="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"
log "INFO: Tentando baixar de: $S3_URI"

# 7. Baixa o script do S3 usando AWS CLI
if ! aws s3 cp "$S3_URI" "$LOCAL_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
    log "ERRO: Falha ao baixar o script de '$S3_URI'."
    log "ERRO: Verifique as permissões do IAM Role da instância, o nome do bucket/chave e a região."
    exit 1
fi
log "INFO: Script baixado com sucesso."

# 8. Torna o script baixado executável
chmod +x "$LOCAL_SCRIPT_PATH"
log "INFO: Permissão de execução adicionada a '$LOCAL_SCRIPT_PATH'."

# 9. Executa o script baixado
log "INFO: Executando o script baixado: $LOCAL_SCRIPT_PATH"
if "$LOCAL_SCRIPT_PATH"; then
    log "INFO: Script baixado ($LOCAL_SCRIPT_PATH) executado com sucesso."
else
    # Captura o código de saída do script baixado
    EXIT_CODE=$?
    log "ERRO: O script baixado ($LOCAL_SCRIPT_PATH) falhou com o código de saída: $EXIT_CODE."
    # Decide se o script principal deve falhar também
    # exit $EXIT_CODE # Descomente esta linha se a falha do script baixado deve parar tudo.
fi

log "INFO: Script fetch_and_run_s3_script.sh concluído."

# A limpeza do arquivo temporário será feita pelo 'trap'

exit 0
