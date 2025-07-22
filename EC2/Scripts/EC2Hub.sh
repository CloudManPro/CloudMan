# Este script é ANEXADO a um user_data já existente.
# Ele assume que o arquivo /home/ec2-user/.env já foi criado pela primeira parte do user_data.

set -e # Para o script se qualquer comando falhar.
LOG_FILE="/var/log/cloud-init-output.log"

# Carrega as variáveis de ambiente para uso neste script.
if [ -f /home/ec2-user/.env ]; then
    set -a
    source /home/ec2-user/.env
    set +a
    echo "Arquivo .env carregado com sucesso no ambiente do script." >> $LOG_FILE
else
    echo "ERRO CRÍTICO: /home/ec2-user/.env não encontrado!" >> $LOG_FILE
    exit 1
fi

# --- INSTALAÇÃO DE PACOTES DE SISTEMA ---
echo "Instalando pacotes do sistema com DNF..." >> $LOG_FILE
sudo dnf update -y
# CORREÇÃO: mariadb-client agora é mariadb10.5-common ou pode ser omitido se não for usado na CLI.
# Para simplificar, vamos instalar apenas os pacotes essenciais.
sudo dnf install -y python3-pip amazon-cloudwatch-agent

# --- INSTALAÇÃO GLOBAL DE PACOTES PYTHON ---
# Instala as bibliotecas Python globalmente usando sudo. Isso garante que
# fiquem disponíveis no PATH padrão do sistema (/usr/local/bin), que o systemd pode encontrar.
echo "Instalando bibliotecas Python globalmente..." >> $LOG_FILE
sudo pip3 install --upgrade pip
sudo pip3 install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython

# --- CONFIGURAÇÃO DO AGENTE CLOUDWATCH ---
echo "Configurando Agente CloudWatch..." >> $LOG_FILE
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{
  "agent": {"run_as_user": "root"},
  "logs": { "logs_collected": { "files": { "collect_list": [
    {"file_path": "/home/ec2-user/EC2Hub.log", "log_group_name": "$AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0", "log_stream_name": "{instance_id}-app"}
  ]}}}}
}
EOF
sudo systemctl enable --now amazon-cloudwatch-agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s


# --- DOWNLOAD E CONFIGURAÇÃO DA APLICAÇÃO ---
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    echo "Baixando script do S3: $AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" >> $LOG_FILE
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "ERRO: Nenhum arquivo .py encontrado no bucket S3. Abortando." >> $LOG_FILE
        exit 1
    else
        FILENAME=$(basename "$FIRST_PY_FILE")
        aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
        sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
        FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

        # O caminho para o uvicorn agora é o global, que o systemd encontrará automaticamente.
        UVICORN_PATH="/usr/local/bin/uvicorn"

        sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<EOF
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
EOF
        
        sudo touch /home/ec2-user/EC2Hub.log
        sudo chown ec2-user:ec2-user /home/ec2-user/EC2Hub.log

        sudo systemctl daemon-reload
        sudo systemctl enable --now ec2hub.service
        echo "Aplicação ${FILENAME_WITHOUT_EXT} iniciada e gerenciada pelo systemd." >>$LOG_FILE
    fi
else
    echo "Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida." >>$LOG_FILE
fi

echo "Script de inicialização (anexo) concluído!" >> $LOG_FILE
