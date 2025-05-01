#!/bin/bash

# Script de teste simples baixado do S3

LOG_FILE="/tmp/script_s3_executado.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "-------------------------------------" >> "$LOG_FILE"
echo "[$TIMESTAMP] O script baixado do S3 foi executado com sucesso!" >> "$LOG_FILE"
echo "[$TIMESTAMP] Usuário atual: $(whoami)" >> "$LOG_FILE"
echo "[$TIMESTAMP] Diretório atual: $(pwd)" >> "$LOG_FILE"
echo "[$TIMESTAMP] Variáveis de ambiente do .env (se exportadas):" >> "$LOG_FILE"
# Tenta mostrar as variáveis que o script fetch_and_run carregou (ele usa 'set -a')
echo "[$TIMESTAMP]   AWS_S3_BUCKET_TARGET_NAME_SCRIPT = ${AWS_S3_BUCKET_TARGET_NAME_SCRIPT:-Nao definida}" >> "$LOG_FILE"
echo "[$TIMESTAMP]   AWS_S3_BUCKET_TARGET_REGION_SCRIPT = ${AWS_S3_BUCKET_TARGET_REGION_SCRIPT:-Nao definida}" >> "$LOG_FILE"
echo "[$TIMESTAMP]   AWS_S3_SCRIPT_KEY = ${AWS_S3_SCRIPT_KEY:-Nao definida}" >> "$LOG_FILE"
echo "-------------------------------------" >> "$LOG_FILE"

# Mensagem para o log principal (do fetch_and_run)
echo "Script de teste S3: Execução concluída. Verifique $LOG_FILE para detalhes."

exit 0 # Importante sinalizar que terminou com sucesso
