#!/bin/bash
# ==============================================================================
# EC2Hub - Script de Inicialização para Amazon Linux 2023
#
# Versão: 2.0 (Robusta com Ambiente Virtual Python - venv)
# Descrição:
# Este script é projetado para ser executado como user_data em uma instância EC2.
# 1. Instala dependências do sistema (CloudWatch Agent, Python Pip).
# 2. Cria um ambiente virtual Python (`venv`) para isolar as dependências da aplicação.
# 3. Instala as bibliotecas Python necessárias dentro do venv.
# 4. Configura e inicia o Agente do CloudWatch para coletar logs da aplicação.
# 5. Baixa o código da aplicação de um bucket S3.
# 6. Cria e habilita um serviço systemd para rodar a aplicação FastAPI de forma
#    confiável e garantir que ela reinicie em caso de falha.
# ==============================================================================

# Para o script se qualquer comando falhar (essencial para depuração)
set -e

# Arquivo de log para depurar a execução do cloud-init
LOG_FILE="/var/log/cloud-init-output.log"
echo "--- Iniciando script de provisionamento EC2Hub (v2.0 - venv) ---" >> $LOG_FILE

# --- ETAPA 1: Carregar Variáveis de Ambiente ---
# Assume que a primeira parte do user_data (gerado pelo Cloudman) já criou este arquivo.
if [ -f /home/ec2-user/.env ]; then
    set -a # Exporta automaticamente as variáveis lidas
    source /home/ec2-user/.env
    set +a # Para de exportar
    echo "Sucesso: Arquivo .env carregado no ambiente do script." >> $LOG_FILE
else
    echo "ERRO CRÍTICO: Arquivo /home/ec2-user/.env não foi encontrado! Abortando." >> $LOG_FILE
    exit 1
fi

# --- ETAPA 2: Instalação de Pacotes do Sistema ---
echo "Instalando pacotes do sistema com DNF..." >> $LOG_FILE
sudo dnf update -y
sudo dnf install -y python3-pip amazon-cloudwatch-agent

# --- ETAPA 3: Configuração do Ambiente Virtual Python (Melhor Prática) ---
echo "Configurando ambiente virtual Python (venv) em /home/ec2-user/app_env..." >> $LOG_FILE
# Cria o ambiente como o usuário 'ec2-user' para evitar problemas de permissão
sudo -u ec2-user python3 -m venv /home/ec2-user/app_env

echo "Instalando bibliotecas Python dentro do venv..." >> $LOG_FILE
# Ativa o venv, instala os pacotes (sem sudo!) e desativa
source /home/ec2-user/app_env/bin/activate
pip install --upgrade pip
pip install awscli boto3 fastapi uvicorn python-dotenv requests pymysql dnspython
deactivate
echo "Sucesso: Bibliotecas Python instaladas no ambiente virtual." >> $LOG_FILE

# --- ETAPA 4: Configuração do Agente CloudWatch ---
echo "Configurando Agente CloudWatch para monitorar /home/ec2-user/EC2Hub.log..." >> $LOG_FILE
# Usa uma variável de ambiente para o nome do log group, conforme definido no .env
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/config.json >/dev/null <<EOF
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
# Aplica a configuração e habilita o agente para iniciar no boot
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
sudo systemctl enable --now amazon-cloudwatch-agent
echo "Sucesso: Agente CloudWatch configurado e iniciado." >> $LOG_FILE

# --- ETAPA 5: Download e Configuração da Aplicação ---
if [ -n "$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE" ]; then
    echo "Baixando código da aplicação do S3: s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" >> $LOG_FILE
    # Encontra o primeiro arquivo .py no bucket/prefixo especificado
    FIRST_PY_FILE=$(aws s3 ls "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/" --recursive | grep '\.py$' | head -n 1 | awk '{print $4}')
    
    if [ -z "$FIRST_PY_FILE" ]; then
        echo "ERRO CRÍTICO: Nenhum arquivo .py encontrado no bucket S3. A aplicação não pode ser iniciada." >> $LOG_FILE
        exit 1
    else
        # Extrai o nome do arquivo e o baixa
        FILENAME=$(basename "$FIRST_PY_FILE")
        aws s3 cp "s3://$AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE/$FIRST_PY_FILE" "/home/ec2-user/$FILENAME"
        sudo chown ec2-user:ec2-user "/home/ec2-user/$FILENAME"
        FILENAME_WITHOUT_EXT=$(basename "$FILENAME" .py)

        # --- ETAPA 6: Criação do Serviço Systemd ---
        echo "Criando serviço systemd 'ec2hub.service' para a aplicação..." >> $LOG_FILE
        
        # **APONTA PARA O EXECUTÁVEL DENTRO DO VENV**
        UVICORN_PATH="/home/ec2-user/app_env/bin/uvicorn"

        sudo tee /etc/systemd/system/ec2hub.service >/dev/null <<EOF
[Unit]
Description=EC2Hub FastAPI Application
After=network-online.target
Wants=network-online.target

[Service]
# Usuário que irá rodar a aplicação
User=ec2-user
Group=ec2-user

# Diretório de trabalho da aplicação
WorkingDirectory=/home/ec2-user

# Carrega as variáveis de ambiente do arquivo .env
EnvironmentFile=/home/ec2-user/.env

# Comando para iniciar a aplicação usando o uvicorn do venv
ExecStart=${UVICORN_PATH} ${FILENAME_WITHOUT_EXT}:app --host 0.0.0.0 --port 80 --workers 2

# Reinicia o serviço automaticamente em caso de falha
Restart=on-failure
RestartSec=5s

# Redireciona a saída padrão (logs) para um arquivo
StandardOutput=file:/home/ec2-user/EC2Hub.log
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF
        
        # Cria o arquivo de log e define as permissões corretas
        sudo touch /home/ec2-user/EC2Hub.log
        sudo chown ec2-user:ec2-user /home/ec2-user/EC2Hub.log

        # Recarrega o systemd, habilita e inicia o novo serviço
        sudo systemctl daemon-reload
        sudo systemctl enable --now ec2hub.service
        echo "Sucesso: Aplicação '${FILENAME_WITHOUT_EXT}' iniciada e gerenciada pelo systemd." >>$LOG_FILE
    fi
else
    echo "Aviso: Variável AWS_S3_BUCKET_TARGET_NAME_SOURCE_FILE não definida. Pulando a configuração da aplicação." >>$LOG_FILE
fi

echo "--- Script de provisionamento EC2Hub concluído com sucesso! ---" >> $LOG_FILE
