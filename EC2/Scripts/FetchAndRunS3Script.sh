# --- 2. Ajuste de Permissões ---
echo "INFO: Ajustando permissões para $ENV_FILE..."
# Garante que o usuário root (que executa cloud-init) possa ler o arquivo
chmod 644 "$ENV_FILE"
# Garante que o diretório /home/ec2-user seja acessível (geralmente é, mas por segurança)
chmod o+x /home/ec2-user
echo "INFO: Permissões ajustadas."

# --- 3. Carregamento e Exportação das Variáveis do .env ---
echo "INFO: Carregando e exportando variáveis de $ENV_FILE..."
set -a # Habilita a exportação automática de variáveis subsequentes
source "$ENV_FILE"
set +a # Desabilita a exportação automática
echo "INFO: Variáveis carregadas e marcadas para exportação."

# --- 4. Debugging (Opcional, mas útil) ---
# Verifica se as variáveis S3 foram carregadas neste ponto
DEBUG_LOG="/var/log/user-data-debug.log"
echo "--- Debug User Data Vars ---" > "$DEBUG_LOG"
echo "Timestamp: $(date)" >> "$DEBUG_LOG"
echo "AWS_S3_BUCKET_TARGET_NAME_SCRIPT = ${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "AWS_S3_BUCKET_TARGET_REGION_SCRIPT = ${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "AWS_S3_SCRIPT_KEY = ${AWS_S3_SCRIPT_KEY:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "---------------------------" >> "$DEBUG_LOG"
echo "INFO: Log de debug das variáveis S3 gravado em $DEBUG_LOG"

# --- 5. Lógica para Baixar e Executar Script do S3 ---
FETCH_LOG_FILE="/var/log/fetch_and_run_s3_script.log"
TMP_DIR="/tmp"

# --- Funções Auxiliares (Escopo Local para esta seção) ---
_log_fetch() {
    # Note o uso de _log_fetch para evitar conflito se o script S3 tiver uma função log
    echo "$(date '+%Y-%m-%d %H:%M:%S') - FETCH_RUN - $1" | tee -a "$FETCH_LOG_FILE"
}

# --- Início da Execução Fetch/Run ---
# Redireciona a saída desta seção específica para seu próprio log
# Usamos chaves {} para agrupar os comandos e redirecionar a saída deles
{
    _log_fetch "INFO: Iniciando lógica para buscar e executar script do S3."

    # 5.1. Verifica se o AWS CLI está instalado
    if ! command -v aws &>/dev/null; then
        _log_fetch "ERRO: AWS CLI não encontrado. Tentando instalar..."
        # Tenta instalar - ajuste 'yum' se usar outra distro (ex: 'apt-get' para Ubuntu)
        if command -v yum &> /dev/null; then
             yum install -y aws-cli
        elif command -v apt-get &> /dev/null; then
             apt-get update && apt-get install -y awscli
        else
            _log_fetch "ERRO: Gerenciador de pacotes não suportado para instalar AWS CLI automaticamente."
             exit 1 # Falha o User Data
        fi
        # Verifica novamente após a tentativa de instalação
        if ! command -v aws &> /dev/null; then
           _log_fetch "ERRO: Falha ao instalar AWS CLI."
           exit 1 # Falha o User Data
        fi
    fi
    _log_fetch "INFO: AWS CLI encontrado."

    # 5.2. Verifica se as variáveis necessárias ESTÃO NO AMBIENTE (foram exportadas acima)
    # Esta verificação agora deve funcionar corretamente
    if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || \
       [ -z "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}" ] || \
       [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
        _log_fetch "ERRO: Uma ou mais variáveis S3 necessárias não estão definidas no ambiente."
        _log_fetch "ERRO: Verifique se AWS_S3_BUCKET_TARGET_NAME_SCRIPT, AWS_S3_BUCKET_TARGET_REGION_SCRIPT, e AWS_S3_SCRIPT_KEY foram carregadas e exportadas corretamente."
        _log_fetch "ERRO: Valores atuais: BUCKET='${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}', REGION='${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}', KEY='${AWS_S3_SCRIPT_KEY:-}'"
        exit 1 # Falha o User Data
    fi
    _log_fetch "INFO: Variáveis S3 necessárias encontradas no ambiente: BUCKET=${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}, REGION=${AWS_S3_BUCKET_TARGET_REGION_SCRIPT}, KEY=${AWS_S3_SCRIPT_KEY}"

    # 5.3. Define o caminho de destino local para o script baixado
    LOCAL_SCRIPT_PATH=$(mktemp "$TMP_DIR/s3_script.XXXXXX.sh")
    _log_fetch "INFO: Script S3 será baixado para: $LOCAL_SCRIPT_PATH"

    # Garante a limpeza do script temporário na saída (normal ou erro)
    trap '_log_fetch "INFO: Limpando script temporário $LOCAL_SCRIPT_PATH"; rm -f "$LOCAL_SCRIPT_PATH"' EXIT SIGHUP SIGINT SIGTERM

    # 5.4. Constrói o URI S3
    S3_URI="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"
    _log_fetch "INFO: Tentando baixar de: $S3_URI"

    # 5.5. Baixa o script do S3 usando AWS CLI
    # As variáveis exportadas ($AWS_...) são usadas aqui implicitamente pelo CLI (se Role estiver correto) ou explicitamente pela região
    if ! aws s3 cp "$S3_URI" "$LOCAL_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
        _log_fetch "ERRO: Falha ao baixar o script de '$S3_URI'."
        _log_fetch "ERRO: Verifique as permissões do IAM Role da instância (s3:GetObject), o nome/existência do bucket/chave S3 e a região."
        exit 1 # Falha o User Data
    fi
    _log_fetch "INFO: Script S3 baixado com sucesso."

    # 5.6. Torna o script baixado executável
    chmod +x "$LOCAL_SCRIPT_PATH"
    _log_fetch "INFO: Permissão de execução adicionada a '$LOCAL_SCRIPT_PATH'."

    # 5.7. Executa o script baixado
    # O script baixado herdará as variáveis exportadas na seção 3
    _log_fetch "INFO: Executando o script baixado: $LOCAL_SCRIPT_PATH"
    if "$LOCAL_SCRIPT_PATH"; then
        _log_fetch "INFO: Script baixado ($LOCAL_SCRIPT_PATH) executado com sucesso."
    else
        # Captura o código de saída do script baixado
        EXIT_CODE=$?
        _log_fetch "ERRO: O script baixado ($LOCAL_SCRIPT_PATH) falhou com o código de saída: $EXIT_CODE."
        # Decide se o script principal deve falhar também.
        # Se o script S3 falhar, provavelmente queremos que o User Data falhe.
        exit $EXIT_CODE
    fi

    _log_fetch "INFO: Lógica fetch_and_run_s3_script concluída com sucesso."

} > >(tee -a "$FETCH_LOG_FILE") 2>&1 # Fim do bloco redirecionado para FETCH_LOG_FILE

# A limpeza do arquivo temporário será feita pelo 'trap' configurado dentro do bloco

echo "--- Script User Data concluído com sucesso ---"
exit 0
