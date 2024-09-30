#!/bin/bash

# Load environment variables
source /home/ec2-user/.env

# Install Apache
yum install -y httpd

# Start Apache and enable it to start on boot
systemctl start httpd
systemctl enable httpd

# Create a configuration file for mod_rewrite
cat <<EOF >/etc/httpd/conf.d/rewrite.conf
RewriteEngine on
RewriteRule ^/?.* /var/www/html/index.html [L]
EOF

# Restart Apache to apply the configuration
systemctl restart httpd

# Create a session token for IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

cw_installed="No"

# Obtain the availability zone, instance ID, private IP address, and IPv6 address using the session token
availability_zone=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

private_ip_address=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
ipv6_address=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/network/interfaces/macs/$(curl -s http://169.254.169.254/latest/meta-data/mac)/ipv6s)
public_ip_address=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
if [ ! -z "$private_ip_address" ]; then
  echo "  <p>Private IP Address: $private_ip_address</p>" >>/var/www/html/index.html
fi
if [ ! -z "$ipv6_address" ]; then
  echo "  <p>IPv6 Address: $ipv6_address</p>" >>/var/www/html/index.html
fi
if [ ! -z "$public_ip_address" ]; then
  echo "  <p>Public IP Address: $public_ip_address</p>" >>/var/www/html/index.html
fi

# Check if the environment variable for the CloudWatch logs group ARN is defined and valid
if [ -n "$aws_cloudwatch_log_group_Target_ARN_" ]; then
  # Install the CloudWatch logs agent
  yum install -y awslogs
  cw_installed="Yes"

  # Extract the log group name from the ARN
  log_group_name=$(echo $aws_cloudwatch_log_group_Target_ARN_ | awk -F':' '{print $7}')

  # Configure the CloudWatch logs agent
  cat <<EOF >/etc/awslogs/awslogs.conf
[general]
state_file = /var/lib/awslogs/agent-state

[/var/log/httpd/access_log]
file = /var/log/httpd/access_log
log_group_name = $log_group_name
log_stream_name = $instance_id-access_log

[/var/log/httpd/error_log]
file = /var/log/httpd/error_log
log_group_name = $log_group_name
log_stream_name = $instance_id-error_log
EOF

  sudo rm /etc/awslogs/awscli.conf
  # Add the AWS region to awscli.conf
  echo -e "[plugins]\ncwlogs = cwlogs\n[default]\nregion = $(echo $availability_zone | sed 's/[a-z]$//')" | sudo tee /etc/awslogs/awscli.conf

  # Enable and start the CloudWatch logs agent service
  systemctl enable awslogsd.service
  systemctl start awslogsd.service
fi

# Create a custom logging script
cat <<'EOF' >/usr/local/bin/custom_logging.sh
#!/bin/bash
while true; do
  echo "$(date) - Logging data from instance $instance_id" >> /var/log/custom_log.log
  sleep 10
done
EOF

chmod +x /usr/local/bin/custom_logging.sh

# Run the custom logging script in the background
nohup /usr/local/bin/custom_logging.sh &

# Additional CloudWatch configuration to monitor the custom log
if [ "$cw_installed" = "Yes" ]; then
  cat <<EOF >>/etc/awslogs/awslogs.conf
[/var/log/custom_log]
file = /var/log/custom_log.log
log_group_name = $log_group_name
log_stream_name = $instance_id-custom_log
EOF

  # Restart the CloudWatch Logs service to apply the new configuration
  systemctl restart awslogsd.service
fi

disk_devices=$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | awk '{if(NR>1)print}')

# Create the HTML page with instance information, private IP address, and IPv6 address
echo "<!DOCTYPE html>" >/var/www/html/index.html
echo "<html>" >>/var/www/html/index.html
echo "<head>" >>/var/www/html/index.html
echo "  <title>EC2 Instance Information</title>" >>/var/www/html/index.html
echo "</head>" >>/var/www/html/index.html
echo "<body>" >>/var/www/html/index.html
echo "  <p>Current Date and Time: $(date '+%Y-%m-%d %H:%M:%S')</p>" >>/var/www/html/index.html
echo "  <h1>EC2 Instance Information</h1>" >>/var/www/html/index.html
echo "  <p>Availability Zone: $availability_zone</p>" >>/var/www/html/index.html
echo "  <p>Instance ID: $instance_id</p>" >>/var/www/html/index.html
echo "  <p>Public IP Address: $public_ip_address</p>" >>/var/www/html/index.html
echo "  <p>Private IP Address: $private_ip_address</p>" >>/var/www/html/index.html
echo "  <p>IPv6 Address: $ipv6_address</p>" >>/var/www/html/index.html
echo "  <p>CloudWatch Log Group: $log_group_name</p>" >>/var/www/html/index.html
echo "  <p>CloudWatch Installed: $cw_installed</p>" >>/var/www/html/index.html
echo "  <h2>Disk Devices</h2>" >>/var/www/html/index.html
echo "  <pre>$disk_devices</pre>" >>/var/www/html/index.html
echo "  <h2>CloudMan CICD Information</h2>" >>/var/www/html/index.html
echo "  <p>AppName: $CloudManCICDAppName</p>" >>/var/www/html/index.html
echo "  <p>Stage: $CloudManCICDStage</p>" >>/var/www/html/index.html
echo "  <p>Version: $CloudManCICDVersion</p>" >>/var/www/html/index.html
echo "</body>" >>/var/www/html/index.html
echo "</html>" >>/var/www/html/index.html
