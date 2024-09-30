#!/bin/sh
# Carrega as variáveis de ambiente
set -a
source /etc/environment
set +a

if [ "${XRay_Enabled}" = "True" ]; then
    echo "Instalando AWS X-Ray Daemon..."
    curl -o /tmp/aws-xray-daemon-linux-3.x.zip https://s3.dualstack.us-east-1.amazonaws.com/aws-xray-assets.us-east-1/xray-daemon/aws-xray-daemon-linux-3.x.zip
    unzip /tmp/aws-xray-daemon-linux-3.x.zip -d /tmp/
    mv /tmp/xray /usr/bin/
    rm -rf /tmp/aws-xray-daemon-linux-3.x.zip
else
    echo "AWS X-Ray Daemon não será instalado."
fi
