# Este script é ANEXADO a um user_data já existente.

# Carrega as variáveis do arquivo .env que foi criado na etapa anterior do user_data.
if [ -f /home/ec2-user/.env ]; then
    set -a
    source /home/ec2-user/.env
    set +a
    echo "Arquivo .env carregado com sucesso no ambiente do script." >> /var/log/cloud-init-output.log
else
    echo "ERRO CRÍTICO: Arquivo /home/ec2-user/.env não encontrado. Abortando." >> /var/log/cloud-init-output.log
    exit 1
fi

LOG_FILE="/var/log/cloud-init-output.log"

# --- Instalação de pacotes do sistema como ROOT ---
echo "Instalando pacotes do sistema com DNF..." >> $LOG_FILE
# (Opcional) Teste de conectividade
for attempt in {1..10}; do if curl -s --head "https://www.google.com" >/dev/null; then break; fi; sleep 3; done

# Instalação de pacotes do sistema (executado como root)
sudo dnf update -y
# CORRIGIDO: usa mariadb-client
sudo dnf install -y python3-pip amazon-cloudwatch-agent amazon-efs-utils mariadb-client


# --- Instalação das bibliotecas Python como EC2-USER ---
echo "Instalando bibliotecas Python para o ec2-user..." >> $LOG_FILE
# CORREÇÃO DEFINITIVA: Executa o 'pip3 install' como o usuário 'ec2-user'
# Isso garante que as bibliotecas fiquem visíveis para a aplicação.
sudo -u ec2-user -i <<'EOF'
pip3 install --user --upgrade pip
pip3 install --user awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
EOF


# --- Configuração do Agente CloudWatch como ROOT ---
echo "Configurando Agente CloudWatch..." >> $LOG_FILE
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<CW_EOF
{
  "agent": {"run_as_user": "root"},
  "logs": { "logs_collected": { "files": { "collect_list": [
    {"file_path": "/home/ec2-user/EC2Hub.log", "log_group_name": "$AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0", "log_stream_name": "{instance_id}-app"}
  ]}}}}
}
CW_EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent


# --- Download e configuração da aplicação como ROOT ---
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    echo "Baixando script do S3: $AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" >> $LOG_FILE
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "ERRO: Nenhum arquivo .py encontrado no bucket S3. Abortando." >>$LOG_FILE
        exit 1
    else
        FILENAME=$(basename "$FIRST_PY_FILE")
        aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
        sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
        FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

        # O caminho para o uvicorn agora será no diretório local do usuário
        UVICORN_PATH="/home/ec2-user/.local/bin/uvicorn"

        sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<SERVICE_EOF
[Unit]
Description=EC2Hub FastAPI Application
After=network-online.target
Wants=network-online.target
[Service]
User=ec2-user
Group=ec2-user
WorkingDirectory=/home/ec2-user
EnvironmentFile=/home/ec2-user/.env
ExecStart=${UVICORN_PATH} ${FILENAME_WITHOUT_EXT}:app --host 0.0.0.0 --port 80 --workers 2
Restart=on-failure
StandardOutput=file:/home/ec2-user/EC2Hub.log
StandardError=inherit
[Install]
WantedBy=multi-user.target
SERVICE_EOF
        
        sudo touch /home/ec2-user/EC2Hub.log
        sudo chown ec2-user:ec2-user /home/ec2-user/EC2Hub.log

        sudo systemctl daemon-reload
        sudo systemctl enable --now ec2hub.service
        echo "Aplicação ${FILENAME_WITHOUT_EXT} iniciada e gerenciada pelo systemd." >>$LOG_FILE
    fi
else
    echo "Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida. Pulando configuração." >>$LOG_FILE
fi

echo "Script de inicialização (anexo) concluído!" >> $LOG_FILE
