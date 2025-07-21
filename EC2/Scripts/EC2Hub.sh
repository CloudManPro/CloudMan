# Este script é ANEXADO a um user_data já existente.

# --- CORREÇÃO DEFINITIVA ---
# Carrega as variáveis do arquivo .env que foi criado na etapa anterior do user_data.
# Isso torna as variáveis (REGION, NAME, etc.) disponíveis para este script.
if [ -f /home/ec2-user/.env ]; then
    set -a
    source /home/ec2-user/.env
    set +a
    echo "Arquivo .env carregado com sucesso no ambiente do script." >> /var/log/cloud-init-output.log
else
    echo "ERRO CRÍTICO: Arquivo /home/ec2-user/.env não encontrado. Abortando." >> /var/log/cloud-init-output.log
    exit 1
fi

# --- INÍCIO DA SUA LÓGICA ORIGINAL (com ajustes para AL2023) ---
LOG_FILE="/var/log/cloud-init-output.log"

# Atribui uma senha padrão para uso em serial console
SERIALCONSOLEUSERNAME=${SERIALCONSOLEUSERNAME:-}
SERIALCONSOLEPASSWORD=${SERIALCONSOLEPASSWORD:-}
configure_serial_console_access() {
    echo "Configurando acesso ao Serial Console para o usuário $1..." >>$LOG_FILE
    if ! id "$1" &>/dev/null; then
        sudo useradd "$1"
    fi
    echo "$1:$2" | sudo chpasswd
    sudo usermod -aG adm,wheel,systemd-journal,dialout "$1"
    echo "$1 ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-cloud-init-users > /dev/null
}
if [[ -n "$SERIALCONSOLEUSERNAME" && -n "$SERIALCONSOLEPASSWORD" ]]; then
    configure_serial_console_access "$SERIALCONSOLEUSERNAME" "$SERIALCONSOLEPASSWORD"
fi

# Tenta acesso à internet
max_attempts=30
wait_time=4
test_address="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $max_attempts); do
        if curl -s --head $test_address >/dev/null; then
            echo "Conectividade com a Internet estabelecida." >>$LOG_FILE
            return 0
        fi
        echo "Aguardando conectividade... tentativa $attempt/$max_attempts" >>$LOG_FILE
        sleep $wait_time
    done
    echo "Falha ao estabelecer conectividade com a Internet." >>$LOG_FILE
    return 1
}
test_connectivity || exit 1

# Atualizar pacotes e instalar dependências (usando DNF para AL2023)
sudo dnf update -y
sudo dnf install -y python3-pip

# Instalação das bibliotecas Python
sudo pip3 install --upgrade pip awscli boto3 fastapi uvicorn python-dotenv requests

# Instalações condicionais baseadas nas variáveis que agora estão no ambiente
if [ -n "$AWS_SERVICE_DISCOVERY_SERVICE_TARGET_NAME_0" ]; then sudo pip3 install dnspython; fi
if [ -n "$AWS_DB_INSTANCE_TARGET_NAME_0" ]; then sudo pip3 install pymysql; fi
if [ "$XRAY_ENABLED" = "True" ]; then
    sudo pip3 install aws-xray-sdk
    curl https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-3.x.rpm -o /tmp/xray.rpm
    sudo dnf install -y /tmp/xray.rpm
fi

# Instalar o Agente Unificado do CloudWatch
sudo dnf install -y amazon-cloudwatch-agent

# Configurar o Agente do CloudWatch
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{
  "agent": {"run_as_user": "root"},
  "logs": { "logs_collected": { "files": { "collect_list": [
    {"file_path": "/home/ec2-user/EC2Hub.log", "log_group_name": "$AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0", "log_stream_name": "{instance_id}-app"}
  ]}}}}
}
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent

# Instalar outras dependências
sudo dnf install -y amazon-efs-utils mariadb

# Baixar e preparar o script Python do S3
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    echo "Iniciando download do script do bucket S3: $AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE." >>$LOG_FILE
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "ERRO: Nenhum arquivo .py encontrado no bucket S3. Abortando." >>$LOG_FILE
        exit 1
    else
        FILENAME=$(basename "$FIRST_PY_FILE")
        aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
        sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
        FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

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
ExecStart=/usr/local/bin/uvicorn ${FILENAME_WITHOUT_EXT}:app --host 0.0.0.0 --port 80 --workers 2
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
    echo "Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida. Pulando configuração do script Python." >>$LOG_FILE
fi

echo "Script de inicialização (anexo) concluído!" >> $LOG_FILE
