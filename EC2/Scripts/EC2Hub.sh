#!/bin/bash
# ==============================================================================
# EC2Hub - Script de Inicialização Genérico e Seguro
#
# Versão: 3.0 (Final - com Suporte Obrigatório a IMDSv2/Token)
# Descrição:
# Esta é a versão definitiva e segura, projetada para instâncias EC2 modernas
# que exigem o uso do IMDSv2 (http_tokens = "required").
#   - Obtém um token de sessão antes de fazer qualquer chamada ao serviço de metadados.
#   - Usa o token em todas as chamadas para obter o ID da instância, IP e região.
# ==============================================================================

set -e
LOG_FILE="/var/log/cloud-init-output.log"
echo "--- [EC2Hub] Iniciando script de provisionamento v3.0 (IMDSv2 Secure) ---" >> $LOG_FILE

# --- ETAPAS 1 a 7: Instalação, Configuração e Início do Serviço ---
# (As etapas 1 a 7 da versão anterior são copiadas aqui sem alterações)

# ETAPA 1: Carregar Variáveis
echo "[EC2Hub] Etapa 1/8: Carregando .env" >> $LOG_FILE
if [ -f /home/ec2-user/.env ]; then set -a; source /home/ec2-user/.env; set +a; else echo "ERRO: .env não encontrado!" >> $LOG_FILE; exit 1; fi

# ETAPA 2: Instalar Pacotes
echo "[EC2Hub] Etapa 2/8: Instalando pacotes" >> $LOG_FILE
sudo dnf install -y python3-pip amazon-cloudwatch-agent policycoreutils-python-utils

# ETAPA 3: Configurar venv
echo "[EC2Hub] Etapa 3/8: Configurando venv" >> $LOG_FILE
APP_ENV_PATH="/home/ec2-user/app_env"
sudo -u ec2-user python3 -m venv ${APP_ENV_PATH}
source ${APP_ENV_PATH}/bin/activate
pip install --upgrade pip
pip install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
deactivate

# ETAPA 4: Configurar Logs e SELinux
echo "[EC2Hub] Etapa 4/8: Configurando logs e SELinux" >> $LOG_FILE
APP_LOG_DIR="/var/log/ec2hub"
APP_LOG_PATH="${APP_LOG_DIR}/EC2Hub.log"
sudo mkdir -p ${APP_LOG_DIR}
sudo semanage fcontext -a -t httpd_log_t "${APP_LOG_DIR}(/.*)?"
sudo restorecon -R -v ${APP_LOG_DIR}
sudo touch ${APP_LOG_PATH}
sudo chown -R ec2-user:ec2-user ${APP_LOG_DIR}
sudo setsebool -P httpd_can_network_connect 1

# ETAPA 5: Configurar Agente CloudWatch
echo "[EC2Hub] Etapa 5/8: Configurando Agente CloudWatch" >> $LOG_FILE
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{ "agent":{ "run_as_user":"root" }, "logs":{ "logs_collected":{ "files":{ "collect_list":[ { "file_path":"${APP_LOG_PATH}", "log_group_name":"${AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0}", "log_stream_name":"{instance_id}-app-log" } ] } } } }
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent

# ETAPA 6: Download da Aplicação
echo "[EC2Hub] Etapa 6/8: Baixando aplicação" >> $LOG_FILE
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    if [ -z "$FIRST_PY_FILE" ]; then echo "ERRO: Nenhum .py no S3." >> $LOG_FILE; exit 1; fi
    FILENAME=$(basename "$FIRST_PY_FILE"); aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"; sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
    FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

# ETAPA 7: Criar Serviço Systemd
    echo "[EC2Hub] Etapa 7/8: Criando serviço systemd" >> $LOG_FILE
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
Restart=on-failure; RestartSec=10s
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload; sudo systemctl enable --now ec2hub.service
fi

# --- ETAPA 8: Registro Genérico e Seguro (IMDSv2) no Cloud Map ---
echo "[EC2Hub] Etapa 8/8: Iniciando processo de registro genérico no Cloud Map (com IMDSv2)..." >> $LOG_FILE

# CORREÇÃO DE SEGURANÇA: Obter o token de sessão do IMDSv2. TTL de 21600 segundos (6 horas).
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Verificar se o token foi obtido. Se não, a instância pode não ter acesso aos metadados.
if [ -z "$TOKEN" ]; then
    echo "[EC2Hub] ERRO CRÍTICO: Falha ao obter token do IMDSv2. Não é possível obter metadados." >> $LOG_FILE
    exit 1
fi

# Obter metadados da instância UMA VEZ, usando o token.
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_IPV4=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
# A variável de ambiente REGION já foi definida na Etapa 1, então não precisamos pegá-la dos metadados.

# Itera de 0 a 9 para verificar todas as possíveis variáveis de ambiente.
for i in {0..9}
do
    VAR_NAME="AWS_SERVICE_DISCOVERY_SERVICE_TARGET_ARN_${i}"
    SERVICE_ARN="${!VAR_NAME}"
    
    if [ -n "$SERVICE_ARN" ]; then
        echo "[EC2Hub] Encontrado: ${VAR_NAME}. Registrando instância no serviço..." >> $LOG_FILE
        
        # Tenta registrar a instância com retentativas.
        n=0
        until [ "$n" -ge 3 ]
        do
           /home/ec2-user/app_env/bin/aws servicediscovery register-instance \
             --service-id "$SERVICE_ARN" \
             --instance-id "$INSTANCE_ID" \
             --attributes "AWS_INSTANCE_IPV4=${INSTANCE_IPV4},AWS_INSTANCE_PORT=80" \
             --region "$REGION" && break
           
           n=$((n+1))
           echo "[EC2Hub] Falha no registro para ${VAR_NAME}. Tentativa ${n}/3. Aguardando 15s..." >> $LOG_FILE
           sleep 15
        done

        if [ "$n" -ge 3 ]; then
            echo "[EC2Hub] ERRO CRÍTICO: Falha ao registrar em ${VAR_NAME} após 3 tentativas." >> $LOG_FILE
        else
            echo "[EC2Hub] Sucesso: Instância '${INSTANCE_ID}' registrada no serviço (ARN: ${SERVICE_ARN})." >> $LOG_FILE
        fi
    fi
done

echo "--- [EC2Hub] Script de provisionamento concluído com sucesso! ---" >> $LOG_FILE
