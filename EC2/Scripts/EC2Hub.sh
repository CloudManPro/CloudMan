#!/bin/bash
# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

# Carregar variáveis de ambiente do arquivo .env
while IFS='=' read -r key value; do
    export "$key=$value"
done </home/ec2-user/.env

LOG_FILE="/var/log/cloud-init-output.log"

# Atribui uma senha padrão para uso em serial console, se as variáveis de ambiente SERIALCONSOLEUSERNAME e SERIALCONSOLEPASSWORD existirem
SERIALCONSOLEUSERNAME=${SERIALCONSOLEUSERNAME:-}
SERIALCONSOLEPASSWORD=${SERIALCONSOLEPASSWORD:-}
configure_serial_console_access() {
    echo "Configurando acesso ao Serial Console para o usuário $1..." >>$LOG_FILE
    if ! id "$1" &>/dev/null; then
        sudo adduser "$1"
    fi
    echo "$1:$2" | sudo chpasswd
    sudo usermod -aG dialout "$1"
    sudo bash -c "echo '$1 ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/$1"
}
if [[ -n "$SERIALCONSOLEUSERNAME" && -n "$SERIALCONSOLEPASSWORD" ]]; then
    configure_serial_console_access "$SERIALCONSOLEUSERNAME" "$SERIALCONSOLEPASSWORD"
fi

# Tenta acesso à internet por 10x a cada 30s. Objetivo é aguardar a inicialização, se houver alguma dependência de alguma
# instância, como um NAT por exemplo, para ter acesso à internet.
max_attempts=1000
wait_time=4
test_address="https://www.google.com"
test_connectivity() {
    for attempt in $(seq 1 $max_attempts); do
        echo "Tentativa $attempt de $max_attempts: Testando a conectividade com $test_address..." >>$LOG_FILE
        if curl -I $test_address >/dev/null 2>&1; then
            echo "Conectividade com a Internet estabelecida." >>$LOG_FILE
            return 0
        else
            echo "Conectividade com a Internet falhou. Aguardando $wait_time segundos para a próxima tentativa..." >>$LOG_FILE
            sleep $wait_time
        fi
    done
    return 1
}
test_connectivity

# Atualizar pacotes e instalar dependências
sudo yum update -y
sudo yum install python3 python3-pip -y
sudo pip3 install --upgrade pip awscli boto3 fastapi uvicorn python-dotenv watchtower requests

# Verificar e instalar o dnspython se DNS_DISCOVERY estiver presente
DNS_DISCOVERY_VAR="AWS_SERVICE_DISCOVERY_SERVICE_TARGET_NAME_0"
DNS_DISCOVERY=$(eval echo \$$DNS_DISCOVERY_VAR)
if [ "$DNS_DISCOVERY" != "None" ]; then
    sudo pip3 install dnspython
fi

# Instalar pymysql condicionalmente se existir RDS
RDS_NAME_VAR="AWS_DB_INSTANCE_TARGET_NAME_0"
RDS_NAME=$(eval echo \$$RDS_NAME_VAR)
logger "RDS Name ${RDS_NAME}"
if [ "$RDS_NAME" != "None" ]; then
    sudo pip3 install pymysql
fi

# Instalar AWS X-Ray SDK condicionalmente
XRAY_ENABLED_VAR="XRAY_ENABLED"
XRAY_ENABLED=$(eval echo \$$XRAY_ENABLED_VAR)
if [ "$XRAY_ENABLED" = "True" ]; then
    sudo pip3 install aws-xray-sdk
fi
curl https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-3.x.rpm -o /home/ec2-user/xray.rpm
sudo yum install -y /home/ec2-user/xray.rpm

# Verificar e corrigir o arquivo de serviço do X-Ray se necessário
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
if [ -f "$XRAY_SERVICE_FILE" ]; then
    sudo sed -i '/Type=/c\Type=simple' $XRAY_SERVICE_FILE
    sudo sed -i '/^LogsDirectory/d' $XRAY_SERVICE_FILE
    sudo sed -i '/^LogsDirectoryMode/d' $XRAY_SERVICE_FILE
    sudo sed -i '/^ConfigurationDirectory/d' $XRAY_SERVICE_FILE
    sudo sed -i '/^ConfigurationDirectoryMode/d' $XRAY_SERVICE_FILE
    sudo systemctl daemon-reload
fi

# Instalar o Watchtower
sudo pip3 install watchtower || {
    echo "Falha na instalação do Watchtower" >>$LOG_FILE
    exit 1
}


# --- INÍCIO DA SEÇÃO ATUALIZADA: CLOUDWATCH AGENT MODERNO ---

# Instalar o Agente Unificado do CloudWatch
sudo yum install -y amazon-cloudwatch-agent || {
    echo "Falha na instalação do Agente Unificado do CloudWatch" >>$LOG_FILE
    exit 1
}

# Configurar o Agente do CloudWatch para enviar os logs da aplicação Python
LOG_GROUP_VAR="AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0"
LOG_GROUP=$(eval echo \$$LOG_GROUP_VAR)

# Cria o arquivo de configuração do agente. Ele vai monitorar o arquivo de log da nossa aplicação.
sudo tee /opt/aws/amazon-cloudwatch-agent/bin/config.json >/dev/null <<EOF
{
  "agent": {
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/home/ec2-user/EC2Hub.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}-python-app"
          }
        ]
      }
    }
  }
}
EOF

# Ativar e iniciar o serviço do Agente CloudWatch
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s
sudo systemctl enable amazon-cloudwatch-agent
sudo systemctl start amazon-cloudwatch-agent || {
    echo "Falha ao configurar o Agente Unificado do CloudWatch" >>$LOG_FILE
    exit 1
}

# --- FIM DA SEÇÃO ATUALIZADA: CLOUDWATCH AGENT MODERNO ---


# Verificar se bind-utils (que contém nslookup) está instalado
if ! rpm -q bind-utils >/dev/null; then
    echo "Instalando bind-utils para habilitar o comando nslookup..." >>$LOG_FILE
    sudo yum install -y bind-utils
fi

# Verificar se alguma variável AWS_DB_INSTANCE_TARGET_NAME_{i} existe
for i in {0..9}; do
    VAR_NAME="AWS_DB_INSTANCE_TARGET_NAME_$i"
    if [ -n "${!VAR_NAME}" ]; then
        echo "$(date): Variável $VAR_NAME encontrada. Prosseguindo com a instalação." >>$LOG_FILE
        # Instalar o cliente MySQL
        echo "$(date): Instalando o cliente MySQL..." >>$LOG_FILE
        sudo yum install mysql -y
        echo "$(date): Cliente MySQL instalado." >>$LOG_FILE
        # Atualizar pip e instalar o conector MySQL para Python
        echo "$(date): Atualizando pip e instalando o conector MySQL para Python..." >>$LOG_FILE
        sudo pip3 install mysql-connector-python
        echo "$(date): Conector MySQL para Python instalado." >>$LOG_FILE
        # Saindo do loop após a primeira variável encontrada
        break
    else
        echo "$(date): Variável $VAR_NAME não encontrada." >>$LOG_FILE
    fi
done

# Instalar amazon-efs-utils
yum install -y amazon-efs-utils

# Função para montar um sistema EFS
mount_efs() {
    local efs_id=$1
    local access_point_id=$2
    local mount_point=$3
    local region=$4
    local efs_dns="$efs_id.efs.$region.amazonaws.com"
    local max_attempts=10
    local attempt=1
    sudo mkdir -p "$mount_point"
    # Tentar resolver o DNS do EFS e montar
    while true; do
        if nslookup "$efs_dns" >>"$LOG_FILE" 2>&1; then
            echo "Montando o EFS $efs_id no ponto de montagem $mount_point" >>"$LOG_FILE"
            sudo mount -t efs -o tls,accesspoint="$access_point_id" "$efs_id:/" "$mount_point" >>"$LOG_FILE" 2>&1
            echo "$efs_dns:/ $mount_point efs _netdev,tls,accesspoint=$access_point_id 0 0" | sudo tee -a /etc/fstab >>"$LOG_FILE" 2>&1
            break
        else
            echo "Tentativa $attempt de $max_attempts: Falha ao resolver $efs_dns. Tentando novamente em 30s." >>"$LOG_FILE"
            attempt=$((attempt + 1))
            if [ "$attempt" -le "$max_attempts" ]; then
                sleep 30
            else
                echo "Falha ao resolver o DNS do EFS após $max_attempts tentativas." >>"$LOG_FILE"
                exit 1
            fi
        fi
    done
}

# Loop para montar cada sistema de arquivos EFS
for i in {0..9}; do
    access_point_id_var="AWS_EFS_ACCESS_POINT_TARGET_ID_$i"
    efs_id_var="AWS_EFS_FILE_SYSTEM_TARGET_ID_$i"
    mount_point_var="AWS_EFS_ACCESS_POINT_TARGET_PATH_$i"
    region_var="AWS_EFS_FILE_SYSTEM_TARGET_REGION_$i"
    access_point_id=$(eval echo "\$$access_point_id_var")
    efs_id=$(eval echo "\$$efs_id_var")
    mount_point=$(eval echo "\$$mount_point_var")
    region=$(eval echo "\$$region_var")
    if [ ! -z "$access_point_id" ]; then
        mount_efs "$efs_id" "$access_point_id" "$mount_point" "$region"
    fi
done

# Baixar e preparar o script Python do S3
S3_BUCKET_VAR="AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE"
S3_BUCKET=$(eval echo \$$S3_BUCKET_VAR)

if [ "$S3_BUCKET" != "None" ]; then
    echo "$(date): Iniciando o processo." >>$LOG_FILE
    # Encontrar o primeiro arquivo .py no bucket S3
    FIRST_PY_FILE=$(aws s3 ls s3://$S3_BUCKET/ --recursive | grep '.py$' | head -n 1 | awk '{print $4}')
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "$(date): Nenhum arquivo .py encontrado no bucket S3: $S3_BUCKET. Abortando o processo." >>$LOG_FILE
        exit 1
    else
        FILENAME=$(basename $FIRST_PY_FILE)
        echo "$(date): Usando $FILENAME como script Python." >>$LOG_FILE
        aws s3 cp s3://$S3_BUCKET/$FIRST_PY_FILE /home/ec2-user/$FILENAME
        chmod +x /home/ec2-user/$FILENAME
        echo "$(date): Download e permissões configuradas para $FILENAME" >>$LOG_FILE
    fi

    # --- INÍCIO DA SEÇÃO ATUALIZADA: GERENCIAMENTO ROBUSTO DA APLICAÇÃO COM SYSTEMD ---

    FILENAME_WITHOUT_EXT=$(basename $FILENAME .py)

    # Criar um arquivo de serviço systemd para a aplicação
    # Isso garante que a aplicação seja reiniciada em caso de falha e gerenciada como um serviço do sistema
    sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<EOF
[Unit]
Description=EC2Hub FastAPI Application
After=network.target

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

    # Ativar e iniciar o serviço da aplicação
    sudo systemctl daemon-reload
    sudo systemctl enable ec2hub.service
    sudo systemctl start ec2hub.service
    echo "$(date): Aplicação ${FILENAME_WITHOUT_EXT} iniciada e gerenciada pelo systemd" >>$LOG_FILE

    # --- FIM DA SEÇÃO ATUALIZADA: GERENCIAMENTO ROBUSTO DA APLICAÇÃO COM SYSTEMD ---
    
else
    echo "$(date): Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE é None. Pulando a configuração do script Python" >>$LOG_FILE
fi
