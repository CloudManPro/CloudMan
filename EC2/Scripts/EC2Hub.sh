# Este script assume que já está sendo executado dentro de um contexto de user_data
# e que as variáveis de ambiente (ACCOUNT, REGION, etc.) já foram exportadas.

# --- PARTE 1: Criação do Arquivo .env a partir das Variáveis Existentes ---
# Garante que o diretório home exista e tenha as permissões corretas
mkdir -p /home/ec2-user
chown ec2-user:ec2-user /home/ec2-user

# CORREÇÃO CRÍTICA: Cria o arquivo .env a partir das variáveis de ambiente já exportadas pelo user_data.
# Isso resolve o crash da aplicação por falta da variável REGION.
printenv | grep -E '^(AWS_|ACCOUNT|NAME|REGION|SERIALCONSOLE)' | sudo tee /home/ec2-user/.env > /dev/null

# Garante que o arquivo .env pertença ao ec2-user
sudo chown ec2-user:ec2-user /home/ec2-user/.env


# --- INÍCIO DA SUA LÓGICA ORIGINAL (com ajustes mínimos) ---

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

# Tenta acesso à internet por até 2 minutos.
max_attempts=30
wait_time=4
test_address="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $max_attempts); do
        echo "Tentativa $attempt de $max_attempts: Testando a conectividade com $test_address..." >>$LOG_FILE
        if curl -s --head $test_address >/dev/null; then
            echo "Conectividade com a Internet estabelecida." >>$LOG_FILE
            return 0
        else
            echo "Conectividade com a Internet falhou. Aguardando $wait_time segundos..." >>$LOG_FILE
            sleep $wait_time
        fi
    done
    echo "Falha ao estabelecer conectividade com a Internet após $max_attempts tentativas." >>$LOG_FILE
    return 1
}
test_connectivity || exit 1

# Atualizar pacotes e instalar dependências (usando DNF para AL2023)
sudo dnf update -y
sudo dnf install -y python3 python3-pip

# Instalação das bibliotecas Python
sudo pip3 install --upgrade pip awscli boto3 fastapi uvicorn python-dotenv requests

# Verificar e instalar o dnspython se a descoberta de serviço DNS estiver configurada
DNS_DISCOVERY_VAR="AWS_SERVICE_DISCOVERY_SERVICE_TARGET_NAME_0"
DNS_DISCOVERY=$(eval echo \$$DNS_DISCOVERY_VAR)
if [ -n "$DNS_DISCOVERY" ] && [ "$DNS_DISCOVERY" != "None" ]; then
    sudo pip3 install dnspython
fi

# Instalar pymysql condicionalmente se existir RDS
RDS_NAME_VAR="AWS_DB_INSTANCE_TARGET_NAME_0"
RDS_NAME=$(eval echo \$$RDS_NAME_VAR)
if [ -n "$RDS_NAME" ] && [ "$RDS_NAME" != "None" ]; then
    sudo pip3 install pymysql
fi

# Instalar AWS X-Ray SDK condicionalmente
XRAY_ENABLED_VAR="XRAY_ENABLED"
XRAY_ENABLED=$(eval echo \$$XRAY_ENABLED_VAR)
if [ "$XRAY_ENABLED" = "True" ]; then
    sudo pip3 install aws-xray-sdk
    curl https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-3.x.rpm -o /tmp/xray.rpm
    sudo dnf install -y /tmp/xray.rpm
fi

# Instalar o Agente Unificado do CloudWatch
sudo dnf install -y amazon-cloudwatch-agent

# Configurar o Agente do CloudWatch
LOG_GROUP=$(grep 'AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0' /home/ec2-user/.env | cut -d '=' -f2)
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{
  "agent": {"run_as_user": "root"},
  "logs": { "logs_collected": { "files": { "collect_list": [
    {"file_path": "/home/ec2-user/EC2Hub.log", "log_group_name": "$LOG_GROUP", "log_stream_name": "{instance_id}-python-app"}
  ]}}}}
}
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent

# Verificar e instalar dependências para EFS e RDS (usando DNF)
sudo dnf install -y amazon-efs-utils mysql

# Baixar e preparar o script Python do S3
S3_BUCKET=$(grep 'AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE' /home/ec2-user/.env | cut -d '=' -f2)
if [ -n "$S3_BUCKET" ] && [ "$S3_BUCKET" != "None" ]; then
    echo "$(date): Iniciando o download do script Python do bucket $S3_BUCKET." >>$LOG_FILE
    
    FIRST_PY_FILE=$(aws s3 ls "s3://$S3_BUCKET/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "$(date): Nenhum arquivo .py encontrado no bucket S3: $S3_BUCKET. Abortando." >>$LOG_FILE
        exit 1
    else
        FILENAME=$(basename "$FIRST_PY_FILE")
        echo "$(date): Usando $FILENAME como script Python." >>$LOG_FILE
        aws s3 cp "s3://$S3_BUCKET/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
        sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
        
        FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

        # Criar um arquivo de serviço systemd
        sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<EOF
[Unit]
Description=EC2Hub FastAPI Application
After=network-online.target amazon-cloudwatch-agent.service
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

        # Cria o arquivo de log e define as permissões corretas
        sudo touch /home/ec2-user/EC2Hub.log
        sudo chown ec2-user:ec2-user /home/ec2-user/EC2Hub.log

        # Ativar e iniciar o serviço
        sudo systemctl daemon-reload
        sudo systemctl enable --now ec2hub.service
        echo "$(date): Aplicação ${FILENAME_WITHOUT_EXT} iniciada e gerenciada pelo systemd." >>$LOG_FILE
    fi
else
    echo "$(date): Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida. Pulando configuração do script Python." >>$LOG_FILE
fi

echo "Script de inicialização (anexo) concluído!" >> $LOG_FILE
