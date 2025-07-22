#!/bin/bash
# ==============================================================================
# EC2Hub - Script de Inicialização Robusto para Amazon Linux 2023
#
# Versão: 2.1 (Produção-Pronta com venv e systemd)
# Descrição:
# Este script provisiona uma instância EC2 para rodar uma aplicação Python (FastAPI).
# Ele é projetado para ser executado como parte do `user_data` do cloud-init.
#
# Principais Características:
#   - Isola dependências com um Ambiente Virtual Python (`venv`).
#   - Instala e configura o Agente do CloudWatch para coleta de logs.
#   - Baixa o código da aplicação de um bucket S3.
#   - Configura e executa a aplicação como um serviço `systemd` resiliente.
# ==============================================================================

# Para o script imediatamente se qualquer comando falhar. Essencial para depuração.
set -e

# Arquivo de log central para depurar a execução do cloud-init.
LOG_FILE="/var/log/cloud-init-output.log"
echo "--- [EC2Hub] Iniciando script de provisionamento v2.1 (venv) ---" >> $LOG_FILE

# --- ETAPA 1: Carregar Variáveis de Ambiente ---
# O arquivo .env é gerado pela primeira parte do user_data (via Terraform/Cloudman).
echo "[EC2Hub] Etapa 1/6: Carregando variáveis de ambiente..." >> $LOG_FILE
if [ -f /home/ec2-user/.env ]; then
    set -a # Exporta automaticamente as variáveis lidas para o ambiente do script.
    source /home/ec2-user/.env
    set +a # Para de exportar.
    echo "[EC2Hub] Sucesso: Arquivo .env carregado." >> $LOG_FILE
else
    echo "[EC2Hub] ERRO CRÍTICO: Arquivo /home/ec2-user/.env não encontrado! Abortando." >> $LOG_FILE
    exit 1
fi

# --- ETAPA 2: Instalação de Pacotes do Sistema ---
echo "[EC2Hub] Etapa 2/6: Instalando pacotes do sistema (DNF)..." >> $LOG_FILE
sudo dnf update -y
sudo dnf install -y python3-pip amazon-cloudwatch-agent
echo "[EC2Hub] Sucesso: Pacotes do sistema instalados." >> $LOG_FILE

# --- ETAPA 3: Configuração do Ambiente Virtual Python (MELHOR PRÁTICA) ---
APP_ENV_PATH="/home/ec2-user/app_env"
echo "[EC2Hub] Etapa 3/6: Configurando ambiente virtual Python em ${APP_ENV_PATH}..." >> $LOG_FILE
# Cria o ambiente como o usuário 'ec2-user' para evitar problemas de permissão.
sudo -u ec2-user python3 -m venv ${APP_ENV_PATH}

echo "[EC2Hub] Instalando bibliotecas Python dentro do venv..." >> $LOG_FILE
# Ativa o venv, instala os pacotes (sem sudo!) e desativa.
source ${APP_ENV_PATH}/bin/activate
pip install --upgrade pip
pip install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
deactivate
echo "[EC2Hub] Sucesso: Bibliotecas Python instaladas no ambiente virtual." >> $LOG_FILE

# --- ETAPA 4: Configuração do Agente CloudWatch ---
APP_LOG_PATH="/home/ec2-user/EC2Hub.log"
echo "[EC2Hub] Etapa 4/6: Configurando Agente CloudWatch para monitorar ${APP_LOG_PATH}..." >> $LOG_FILE
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
            "log_stream_name": "{instance_id}-app-log",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOF
# Aplica a configuração e habilita o agente para iniciar no boot.
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent
echo "[EC2Hub] Sucesso: Agente CloudWatch configurado e iniciado." >> $LOG_FILE

# --- ETAPA 5: Download e Configuração da Aplicação ---
echo "[EC2Hub] Etapa 5/6: Baixando código da aplicação do S3..." >> $LOG_FILE
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    # Encontra o primeiro arquivo .py no bucket/prefixo especificado.
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "[EC2Hub] ERRO CRÍTICO: Nenhum arquivo .py encontrado no bucket S3. A aplicação não pode ser iniciada." >> $LOG_FILE
        exit 1
    fi

    FILENAME=$(basename "$FIRST_PY_FILE")
    aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
    sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
    FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)
    echo "[EC2Hub] Sucesso: Aplicação '${FILENAME}' baixada." >> $LOG_FILE

    # --- ETAPA 6: Criação do Serviço Systemd para a Aplicação ---
    echo "[EC2Hub] Etapa 6/6: Criando serviço systemd 'ec2hub.service'..." >> $LOG_FILE
    
    # Caminho para o executável uvicorn DENTRO do ambiente virtual.
    UVICORN_PATH="${APP_ENV_PATH}/bin/uvicorn"

    sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<EOF
[Unit]
Description=EC2Hub FastAPI Application
After=network-online.target
Wants=network-online.target

[Service]
# Executa a aplicação como um usuário não-privilegiado.
User=ec2-user
Group=ec2-user

# Diretório de trabalho onde o código e o .env estão.
WorkingDirectory=/home/ec2-user

# Carrega as variáveis de ambiente necessárias para a aplicação.
EnvironmentFile=/home/ec2-user/.env

# Comando para iniciar a aplicação usando o uvicorn do ambiente virtual.
ExecStart=${UVICORN_PATH} ${FILENAME_WITHOUT_EXT}:app --host 0.0.0.0 --port 80 --workers 2

# Política de reinício para garantir que o serviço volte em caso de falha.
Restart=on-failure
RestartSec=10s

# Redireciona a saída padrão (logs da aplicação) para o arquivo que o CloudWatch monitora.
StandardOutput=append:${APP_LOG_PATH}
StandardError=inherit

[Install]
# Habilita o serviço para iniciar no boot do sistema.
WantedBy=multi-user.target
EOF
    
    # Cria o arquivo de log e define as permissões corretas para o usuário da aplicação.
    sudo touch ${APP_LOG_PATH}
    sudo chown ec2-user:ec2-user ${APP_LOG_PATH}

    # Recarrega a configuração do systemd, habilita e inicia nosso novo serviço.
    sudo systemctl daemon-reload
    sudo systemctl enable --now ec2hub.service
    echo "[EC2Hub] Sucesso: Serviço '${FILENAME_WITHOUT_EXT}' criado e iniciado." >>$LOG_FILE

else
    echo "[EC2Hub] Aviso: Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida. Pulando etapas 5 e 6." >>$LOG_FILE
fi

echo "--- [EC2Hub] Script de provisionamento concluído com sucesso! ---" >> $LOG_FILE
