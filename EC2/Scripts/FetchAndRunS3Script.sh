#!/bin/bash

# Log principal do User Data (cloud-init)
# Redireciona stdout/stderr para o log do cloud-init E para o console/syslog
exec > >(tee /var/log/cloud-init-output.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- Iniciando script User Data ---"

# --- 1. Criação do Arquivo .env (Bloco fornecido pelo usuário) ---
echo "INFO: Criando o arquivo /home/ec2-user/.env com as variáveis fornecidas..."
echo "NAME=Gen-AMI-WordPress" > /home/ec2-user/.env
echo "REGION=us-east-1" >> /home/ec2-user/.env
echo "ACCOUNT=746669211265" >> /home/ec2-user/.env
echo "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_NAME_0=SecretWPress" >> /home/ec2-user/.env
echo "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_REGION_0=us-east-1" >> /home/ec2-user/.env
# Assumindo que Terraform substituirá esta variável antes de passar para UserData
echo "AWS_SECRETSMANAGER_SECRET_VERSION_SOURCE_ARN_0=${data.aws_secretsmanager_secret_version.SecretWPress.arn}" >> /home/ec2-user/.env
echo "AWS_S3_BUCKET_TARGET_NAME_SCRIPT=projeto1-script" >> /home/ec2-user/.env
echo "AWS_S3_BUCKET_TARGET_REGION_SCRIPT=us-east-1" >> /home/ec2-user/.env
# IMPORTANTE: Adicione a linha AWS_S3_SCRIPT_KEY aqui se ainda não estiver incluída pelo Terraform/ferramenta!
# Exemplo: echo "AWS_S3_SCRIPT_KEY=WodPressProfessional.sh" >> /home/ec2-user/.env
# Se a linha abaixo já define a chave, ótimo. Caso contrário, adicione acima.
# Verifique se 'WodPressProfessional.sh' é realmente o valor que você quer para AWS_S3_SCRIPT_KEY
echo "AWS_S3_SCRIPT_KEY=WodPressProfessional.sh" >> /home/ec2-user/.env # <-- Certifique-se que esta linha existe e está correta!
echo "AWS_AMI_FROM_INSTANCE_TARGET_NAME_0=AMI-WP" >> /home/ec2-user/.env
echo "AWS_AMI_FROM_INSTANCE_TARGET_REGION_0=us-east-1" >> /home/ec2-user/.env
echo "AWS_S3_BUCKET_TARGET_NAME_0=s3-projeto1-wp-offload" >> /home/ec2-user/.env
echo "AWS_S3_BUCKET_TARGET_REGION_0=us-east-1" >> /home/ec2-user/.env
echo "AWS_DB_INSTANCE_TARGET_NAME_0=WPRDS" >> /home/ec2-user/.env
echo "AWS_DB_INSTANCE_TARGET_REGION_0=us-east-1" >> /home/ec2-user/.env
# Assumindo que Terraform substituirá esta variável
echo "AWS_DB_INSTANCE_TARGET_ENDPOINT_0=${data.aws_db_instance.WPRDS.endpoint}" >> /home/ec2-user/.env
echo "AWS_EFS_FILE_SYSTEM_TARGET_NAME_0=WPProjeto1" >> /home/ec2-user/.env
echo "AWS_EFS_FILE_SYSTEM_TARGET_REGION_0=us-east-1" >> /home/ec2-user/.env
# Assumindo que Terraform substituirá esta variável
echo "AWS_EFS_FILE_SYSTEM_TARGET_ID_0=${data.aws_efs_file_system.WPProjeto1.id}" >> /home/ec2-user/.env
# Assumindo que Terraform substituirá esta variável
echo "AWS_EFS_FILE_SYSTEM_TARGET_ARN_0=${data.aws_efs_file_system.WPProjeto1.arn}" >> /home/ec2-user/.env
# Assumindo que Terraform substituirá esta variável
echo "AWS_EFS_ACCESS_POINT_TARGET_ID_0=${aws_efs_access_point.EFS_Access_Point_Gen-AMI-WordPress_To_WPProjeto1.id}" >> /home/ec2-user/.env
echo "AWS_EFS_ACCESS_POINT_TARGET_PATH_0=/mnt" >> /home/ec2-user/.env
echo "AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0=/aws/ec2/Gen-AMI-WordPress" >> /home/ec2-user/.env
echo "AWS_CLOUDWATCH_LOG_GROUP_TARGET_REGION_0=us-east-1" >> /home/ec2-user/.env
echo "INFO: Arquivo /home/ec2-user/.env criado."

# --- 2. Ajuste de Permissões ---
# Usando caminho literal para evitar problemas com variáveis de shell
echo "INFO: Ajustando permissões para /home/ec2-user/.env..."
chmod 644 /home/ec2-user/.env
chmod o+x /home/ec2-user
echo "INFO: Permissões ajustadas."

# --- 3. Carregamento e Exportação das Variáveis do .env ---
# Usando caminho literal
echo "INFO: Carregando e exportando variáveis de /home/ec2-user/.env..."
set -a # Habilita a exportação automática
source /home/ec2-user/.env # <-- Caminho direto
set +a # Desabilita a exportação automática
echo "INFO: Variáveis carregadas e marcadas para exportação."

# --- 4. Debugging (Verificar se o source funcionou) ---
DEBUG_LOG="/var/log/user-data-debug.log"
echo "--- Debug User Data Vars (after source) ---" > "$DEBUG_LOG"
echo "Timestamp: $(date)" >> "$DEBUG_LOG"
echo "AWS_S3_BUCKET_TARGET_NAME_SCRIPT = ${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "AWS_S3_BUCKET_TARGET_REGION_SCRIPT = ${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "AWS_S3_SCRIPT_KEY = ${AWS_S3_SCRIPT_KEY:-NAO CARREGADA}" >> "$DEBUG_LOG"
echo "---------------------------" >> "$DEBUG_LOG"
echo "INFO: Log de debug das variáveis S3 gravado em $DEBUG_LOG"

# --- 5. Lógica para Baixar e Executar Script do S3 ---
FETCH_LOG_FILE="/var/log/fetch_and_run_s3_script.log"
TMP_DIR="/tmp"

# --- Funções Auxiliares (Escopo Local) ---
_log_fetch() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - FETCH_RUN - $1" | tee -a "$FETCH_LOG_FILE"
}

# --- Início da Execução Fetch/Run (Saída redirecionada para FETCH_LOG_FILE) ---
{
    _log_fetch "INFO: Iniciando lógica para buscar e executar script do S3."

    # 5.1. Verifica/Instala AWS CLI
    if ! command -v aws &>/dev/null; then
        _log_fetch "ERRO: AWS CLI não encontrado. Tentando instalar..."
        if command -v yum &> /dev/null; then
             yum install -y aws-cli
        elif command -v apt-get &> /dev/null; then
             apt-get update && apt-get install -y awscli
        else
            _log_fetch "ERRO: Gerenciador de pacotes não suportado para instalar AWS CLI."
             exit 1
        fi
        if ! command -v aws &> /dev/null; then
           _log_fetch "ERRO: Falha ao instalar AWS CLI."
           exit 1
        fi
    fi
    _log_fetch "INFO: AWS CLI encontrado."

    # 5.2. Verifica variáveis S3 NO AMBIENTE (devem ter sido exportadas na seção 3)
    if [ -z "${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}" ] || \
       [ -z "${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}" ] || \
       [ -z "${AWS_S3_SCRIPT_KEY:-}" ]; then
        _log_fetch "ERRO: Uma ou mais variáveis S3 necessárias (BUCKET/REGION/KEY) não estão definidas no ambiente APÓS source."
        _log_fetch "ERRO: Verifique o conteúdo de /home/ec2-user/.env, os logs de permissão/source e /var/log/user-data-debug.log."
        _log_fetch "ERRO: Valores atuais no ambiente: BUCKET='${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-}', REGION='${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-}', KEY='${AWS_S3_SCRIPT_KEY:-}'"
        exit 1 # Falha o User Data
    fi
    _log_fetch "INFO: Variáveis S3 necessárias encontradas no ambiente: BUCKET=${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}, REGION=${AWS_S3_BUCKET_TARGET_REGION_SCRIPT}, KEY=${AWS_S3_SCRIPT_KEY}"

    # 5.3. Define caminho local e trap de limpeza
    LOCAL_SCRIPT_PATH=$(mktemp "$TMP_DIR/s3_script.XXXXXX.sh")
    _log_fetch "INFO: Script S3 será baixado para: $LOCAL_SCRIPT_PATH"
    trap '_log_fetch "INFO: Limpando script temporário $LOCAL_SCRIPT_PATH"; rm -f "$LOCAL_SCRIPT_PATH"' EXIT SIGHUP SIGINT SIGTERM

    # 5.4. Constrói URI S3
    S3_URI="s3://${AWS_S3_BUCKET_TARGET_NAME_SCRIPT}/${AWS_S3_SCRIPT_KEY}"
    _log_fetch "INFO: Tentando baixar de: $S3_URI"

    # 5.5. Baixa o script do S3
    if ! aws s3 cp "$S3_URI" "$LOCAL_SCRIPT_PATH" --region "$AWS_S3_BUCKET_TARGET_REGION_SCRIPT"; then
        _log_fetch "ERRO: Falha ao baixar o script de '$S3_URI'."
        _log_fetch "ERRO: Verifique as permissões do IAM Role (s3:GetObject), o nome/existência do bucket/chave S3 ('$AWS_S3_BUCKET_TARGET_NAME_SCRIPT' / '$AWS_S3_SCRIPT_KEY') e a região ('$AWS_S3_BUCKET_TARGET_REGION_SCRIPT')."
        exit 1
    fi
    _log_fetch "INFO: Script S3 baixado com sucesso."

    # 5.6. Torna executável
    chmod +x "$LOCAL_SCRIPT_PATH"
    _log_fetch "INFO: Permissão de execução adicionada a '$LOCAL_SCRIPT_PATH'."

    # 5.7. Executa o script baixado
    _log_fetch "INFO: Executando o script baixado: $LOCAL_SCRIPT_PATH"
    # O script baixado herda as variáveis exportadas na seção 3
    if "$LOCAL_SCRIPT_PATH"; then
        _log_fetch "INFO: Script baixado ($LOCAL_SCRIPT_PATH) executado com sucesso."
    else
        EXIT_CODE=$?
        _log_fetch "ERRO: O script baixado ($LOCAL_SCRIPT_PATH) falhou com o código de saída: $EXIT_CODE."
        exit $EXIT_CODE # Propaga o erro do script S3
    fi

    _log_fetch "INFO: Lógica fetch_and_run_s3_script concluída com sucesso."

} > >(tee -a "$FETCH_LOG_FILE") 2>&1 # Fim do bloco redirecionado para FETCH_LOG_FILE

# Se chegou aqui, tudo (incluindo o script S3) foi executado com sucesso.
echo "--- Script User Data concluído com sucesso ---"
exit 0
