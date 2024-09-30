#!/bin/bash

# Atualizar pacotes
yum update -y

# Instalar repositório EPEL
yum install -y epel-release

# Instalar o sistema X Window e XFCE
yum groupinstall -y "X Window System"
yum install -y xfce4-session

# Instalar e configurar o TigerVNC Server
yum install -y tigervnc-server
mkdir -p ~/.vnc
echo 'password' | vncpasswd -f >~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Criar script de inicialização do VNC Server
cat >/etc/systemd/system/vncserver@:1.service <<EOF
[Unit]
Description=Remote desktop service (VNC)
After=syslog.target network.target

[Service]
Type=simple
User=ec2-user
PAMName=login
PIDFile=/home/ec2-user/.vnc/%H%i.pid
ExecStartPre=-/usr/bin/vncserver -kill %i
ExecStart=/usr/bin/vncserver %i -geometry 1280x1024
ExecStop=/usr/bin/vncserver -kill %i

[Install]
WantedBy=multi-user.target
EOF

# Ativar e iniciar o serviço VNC Server
systemctl daemon-reload
systemctl enable vncserver@:1
systemctl start vncserver@:1

# Instalar e configurar o Apache JMeter
wget https://apache.mirror.digitalpacific.com.au/jmeter/binaries/apache-jmeter-5.5.tgz -P /tmp/
tar -xzf /tmp/apache-jmeter-5.5.tgz -C /opt/
rm /tmp/apache-jmeter-5.5.tgz

# Definir variáveis de ambiente globalmente para JMeter
echo 'export JMETER_HOME=/opt/apache-jmeter-5.5' >>/etc/profile.d/jmeter.sh
echo 'export PATH=$PATH:$JMETER_HOME/bin' >>/etc/profile.d/jmeter.sh

# Instalar Python 3 e websockify
yum install -y python3 python3-pip
pip3 install websockify

# Localizar o caminho do websockify
WEB_SOCKET_PATH=$(which websockify)

# Instalar noVNC via Snap
yum install -y snapd
systemctl enable --now snapd.socket
ln -s /var/lib/snapd/snap /snap
snap install novnc

# Criar um serviço para o websockify
cat >/etc/systemd/system/websockify.service <<EOF
[Unit]
Description=Websockify for noVNC

[Service]
ExecStart=$WEB_SOCKET_PATH --web=/snap/novnc/current/usr/share/novnc/ 6080 localhost:5900

[Install]
WantedBy=multi-user.target
EOF

# Iniciar e habilitar o serviço websockify
systemctl start websockify
systemctl enable websockify

# Configuração do firewall para permitir o tráfego noVNC
firewall-cmd --zone=public --add-port=6080/tcp --permanent
firewall-cmd --reload

# Mensagem final
echo "Instalação e configuração concluídas. Acesse o JMeter via navegador em http://[Seu-IP-EC2]:6080/vnc.html"
