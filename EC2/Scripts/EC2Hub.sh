#!/bin/bash
# ==============================================================================
# EC2Hub - Script de Inicialização Definitivo para Amazon Linux 2023
#
# Versão: 2.6 (Hardened - Corrigido para Permissões de Log, Rede e Portas)
# Descrição:
# Esta versão é projetada para ser a solução final, abordando todos os
# pontos de falha de permissão conhecidos no AL2023 para esta arquitetura:
#   1. Corrige a condição de corrida do systemd ao criar o arquivo de log.
#   2. Define o contexto SELinux correto para o diretório de log.
#   3. Habilita explicitamente o acesso à rede para o serviço via SELinux.
#   4. Concede ao serviço a capacidade de se vincular à porta 80 sem ser root.
# ==============================================================================

set -e
LOG_FILE="/var/log/cloud-init-output.log"
echo "--- [EC2Hub] Iniciando script de provisionamento v2.6 (Hardened) ---" >> $LOG_FILE

# --- ETAPA 1: Carregar Variáveis de Ambiente ---
echo "[EC2Hub] Etapa 1/7: Carregando variáveis de ambiente..." >> $LOG_FILE
if [ -f /home/ec2-user/.env ]; then
    set -a; source /home/ec2-user/.env; set +a
else
    echo "[EC2Hub] ERRO: /home/ec2-user/.env não encontrado!" >> $LOG_FILE; exit 1
fi

# --- ETAPA 2: Instalação de Pacotes do Sistema ---
echo "[EC2Hub] Etapa 2/7: Instalando pacotes do sistema..." >> $LOG_FILE
sudo dnf install -y python3-pip amazon-cloudwatch-agent policycoreutils-python-utils
echo "[EC2Hub] Sucesso: Pacotes do sistema instalados." >> $LOG_FILE

# --- ETAPA 3: Configuração do Ambiente Virtual Python ---
APP_ENV_PATH="/home/ec2-user/app_env"
echo "[EC2Hub] Etapa 3/7: Configurando ambiente virtual Python..." >> $LOG_FILE
sudo -u ec2-user python3 -m venv ${APP_ENV_PATH}
source ${APP_ENV_PATH}/bin/activate
pip install --upgrade pip
pip install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
deactivate
echo "[EC2Hub] Sucesso: Bibliotecas Python instaladas no venv." >> $LOG_FILE

# --- ETAPA 4: Configuração de Logs e Correção do SELinux ---
APP_LOG_DIR="/var/log/ec2hub"
APP_LOG_PATH="${APP_LOG_DIR}/EC2Hub.log"
echo "[EC2Hub] Etapa 4/7: Configurando diretório de log e corrigindo contexto SELinux..." >> $LOG_FILE
sudo mkdir -p ${APP_LOG_DIR}
sudo semanage fcontext -a -t httpd_log_t "${APP_LOG_DIR}(/.*)?"
sudo restorecon -R -v ${APP_LOG_DIR}
sudo touch ${APP_LOG_PATH}
sudo chown -R ec2-user:ec2-user ${APP_LOG_DIR}
# CORREÇÃO DE REDE: Permite que serviços façam conexões de rede de saída.
sudo setsebool -P httpd_can_network_connect 1
echo "[EC2Hub] Sucesso: Contexto SELinux para log e rede corrigido." >> $LOG_FILE

# --- ETAPA 5: Configuração do Agente CloudWatch ---
echo "[EC2Hub] Etapa 5/7: Configurando Agente CloudWatch..." >> $LOG_FILE
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
{ "agent":{ "run_as_user":"root" }, "logs":{ "logs_collected":{ "files":{ "collect_list":[ { "file_path":"${APP_LOG_PATH}", "log_group_name":"${AWS_CLOUDWATCH_LOG_GROUP_TARGET_NAME_0}", "log_stream_name":"{instance_id}-app-log" } ] } } } }
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent
echo "[EC2Hub] Sucesso: Agente CloudWatch configurado." >> $LOG_FILE

# --- ETAPA 6: Download da Aplicação ---
echo "[EC2Hub] Etapa 6/7: Baixando código da aplicação..." >> $LOG_FILE
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    if [ -z "$FIRST_PY_FILE" ]; then echo "[EC2Hub] ERRO: Nenhum .py no S3." >> $LOG_FILE; exit 1; fi
    FILENAME=$(basename "$FIRST_PY_FILE")
    aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
    sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
    FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

    # --- ETAPA 7: Criação do Serviço Systemd ---
    echo "[EC2Hub] Etapa 7/7: Criando serviço systemd 'ec2hub.service'..." >> $LOG_FILE
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
StandardOutput=append:${APP_LOG_PATH}
StandardError=inherit

# CORREÇÃO DE PORTA: Concede capacidade de se vincular a portas < 1024.
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable --now ec2hub.service
    echo "[EC2Hub] Sucesso: Serviço '${FILENAME_WITHOUT_EXT}' criado e iniciado." >>$LOG_FILE
fi

echo "--- [EC2Hub] Script de provisionamento concluído com sucesso! ---" >> $LOG_FILE
