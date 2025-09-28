#!/bin/bash
# ==============================================================================
# EC2Hub - Script de Provisionamento para Amazon Linux 2023
#
# Versão: 4.0
# Descrição:
#   - Adaptado para Amazon Linux 2023.
#   - Carrega variáveis de /home/ec2-user/.env.
#   - Resolve o problema de 'NoRegionError' do Boto3 exportando AWS_REGION.
#   - Configura e inicia a aplicação Python como um serviço systemd.
#   - Requer que o arquivo /home/ec2-user/.env já exista.
# ==============================================================================

set -e
LOG_FILE="/var/log/cloud-init-output.log"
echo "--- [EC2Hub] Iniciando script de provisionamento v4.0 (AL2023) ---" >> $LOG_FILE

# --- ETAPA 1: Carregar Variáveis de Ambiente e Configurar Região AWS ---
echo "[EC2Hub] Etapa 1/8: Carregando .env e configurando a região da AWS" >> $LOG_FILE
if [ ! -f /home/ec2-user/.env ]; then
    echo "[EC2Hub] ERRO CRÍTICO: O arquivo /home/ec2-user/.env não foi encontrado!" >> $LOG_FILE
    exit 1
fi
set -a
source /home/ec2-user/.env
set +a

# CORREÇÃO: Garante que o Boto3 encontre a região correta.
if [ -n "$REGION" ]; then
    export AWS_REGION="$REGION"
    echo "[EC2Hub] Sucesso: A variável de ambiente AWS_REGION foi exportada como '$AWS_REGION'." >> $LOG_FILE
else
    echo "[EC2Hub] AVISO: A variável REGION não foi encontrada no .env. A aplicação pode falhar." >> $LOG_FILE
fi

# --- ETAPA 2: Atualizar o Sistema e Instalar Pacotes Essenciais ---
echo "[EC2Hub] Etapa 2/8: Atualizando o sistema e instalando pacotes" >> $LOG_FILE
sudo dnf update -y
sudo dnf install -y python3-pip amazon-cloudwatch-agent policycoreutils-python-utils

# --- ETAPA 3: Configurar Ambiente Virtual Python (venv) ---
echo "[EC2Hub] Etapa 3/8: Configurando ambiente virtual Python" >> $LOG_FILE
APP_ENV_PATH="/home/ec2-user/app_env"
sudo -u ec2-user python3 -m venv ${APP_ENV_PATH}
source ${APP_ENV_PATH}/bin/activate
pip install --upgrade pip
pip install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
deactivate

# --- ETAPA 4: Configurar Diretório de Logs e Permissões do SELinux ---
echo "[EC2Hub] Etapa 4/8: Configurando logs e permissões do SELinux" >> $LOG_FILE
APP_LOG_DIR="/var/log/ec2hub"
APP_LOG_PATH="${APP_LOG_DIR}/EC2Hub.log"
sudo mkdir -p ${APP_LOG_DIR}
sudo touch ${APP_LOG_PATH}
sudo chown -R ec2-user:ec2-user ${APP_LOG_DIR}
sudo semanage fcontext -a -t httpd_log_t "${APP_LOG_DIR}(/.*)?"
sudo restorecon -R -v ${APP_LOG_DIR}
sudo setsebool -P httpd_can_network_connect 1

# --- ETAPA 5: Configurar e Iniciar o Agente do CloudWatch ---
echo "[EC2Hub] Etapa 5/8: Configurando o Agente do CloudWatch" >> $LOG_FILE
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "${APP_LOG_PATH}",
            "log_group_name": "${AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0}",
            "log_stream_name": "{instance_id}-app-log"
          }
        ]
      }
    }
  }
}
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent

# --- ETAPA 6: Fazer o Download da Aplicação a partir do S3 ---
echo "[EC2Hub] Etapa 6/8: Baixando o arquivo da aplicação do S3" >> $LOG_FILE
if [ -z "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    echo "[EC2Hub] ERRO: A variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não está definida no .env." >> $LOG_FILE
    exit 1
fi

FIRST_PY_FILE=$(${APP_ENV_PATH}/bin/aws s3 ls "s3://${AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE}/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
if [ -z "$FIRST_PY_FILE" ]; then
    echo "[EC2Hub] ERRO: Nenhum arquivo .py encontrado no bucket S3 '${AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE}'." >> $LOG_FILE
    exit 1
fi
FILENAME=$(basename "$FIRST_PY_FILE")
${APP_ENV_PATH}/bin/aws s3 cp "s3://${AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE}/${FIRST_PY_FILE}" "/home/ec2-user/${FILENAME}"
sudo chown ec2-user:ec2-user "/home/ec2-user/${FILENAME}"
FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)
echo "[EC2Hub] Sucesso: Aplicação '${FILENAME}' baixada." >> $LOG_FILE

# --- ETAPA 7: Criar e Iniciar o Serviço Systemd para a Aplicação ---
echo "[EC2Hub] Etapa 7/8: Criando o serviço systemd 'ec2hub.service'" >> $LOG_FILE
UVICORN_PATH="${APP_ENV_PATH}/bin/uvicorn"
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
RestartSec=10s
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ec2hub.service
echo "[EC2Hub] Sucesso: Serviço 'ec2hub.service' iniciado e habilitado." >> $LOG_FILE

# --- ETAPA 8: Registrar a Instância no AWS Cloud Map (via IMDSv2) ---
echo "[EC2Hub] Etapa 8/8: Registrando a instância no Cloud Map (IMDSv2)" >> $LOG_FILE
TOKEN=$(curl -s -X PUT "http://169.24.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [ -z "$TOKEN" ]; then
    echo "[EC2Hub] ERRO CRÍTICO: Falha ao obter token do IMDSv2. Não é possível obter metadados." >> $LOG_FILE
    exit 1
fi

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_IPV4=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

for i in {0..9}; do
    VAR_NAME="AWS_SERVICE_DISCOVERY_SERVICE_TARGET_ARN_${i}"
    SERVICE_ARN="${!VAR_NAME}"
    
    if [ -n "$SERVICE_ARN" ]; then
        echo "[EC2Hub] Encontrado: ${VAR_NAME}. Registrando instância..." >> $LOG_FILE
        n=0
        until [ "$n" -ge 3 ]; do
           ${APP_ENV_PATH}/bin/aws servicediscovery register-instance \
             --service-id "$SERVICE_ARN" \
             --instance-id "$INSTANCE_ID" \
             --attributes "AWS_INSTANCE_IPV4=${INSTANCE_IPV4},AWS_INSTANCE_PORT=80" \
             --region "$REGION" && break
           n=$((n+1))
           echo "[EC2Hub] Falha no registro para ${VAR_NAME}. Tentativa ${n}/3. Aguardando 15s..." >> $LOG_FILE
           sleep 15
        done

        if [ "$n" -lt 3 ]; then
            echo "[EC2Hub] Sucesso: Instância '${INSTANCE_ID}' registrada no serviço (ARN: ${SERVICE_ARN})." >> $LOG_FILE
        else
            echo "[EC2Hub] ERRO CRÍTICO: Falha ao registrar em ${VAR_NAME} após 3 tentativas." >> $LOG_FILE
        fi
    fi
done

echo "--- [EC2Hub] Script de provisionamento concluído com sucesso! ---" >> $LOG_FILE
