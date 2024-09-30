#!/bin/bash

# Update packages
sudo yum update -y

# Install Apache and PHP
sudo amazon-linux-extras install -y php7.2
sudo yum install -y httpd

# Start and enable Apache to start on system boot
sudo systemctl start httpd
sudo systemctl enable httpd

# Download and unpack WordPress
wget https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

# Move WordPress to the web server directory
sudo mv wordpress/* /var/www/html/

# Adjust permissions
sudo chown -R apache:apache /var/www/html
sudo chmod -R 755 /var/www/html

# Configure the wp-config.php file
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

# Update the settings in wp-config.php to use RDS
# Ensure the environment variables DB_NAME, DB_USER, DB_PASSWORD, and DB_ENDPOINT
# are set correctly before running this script
sudo sed -i "s/database_name_here/$DB_NAME/" /var/www/html/wp-config.php
sudo sed -i "s/username_here/$DB_USER/" /var/www/html/wp-config.php
sudo sed -i "s/password_here/$DB_PASSWORD/" /var/www/html/wp-config.php
sudo sed -i "s/localhost/$DB_ENDPOINT/" /var/www/html/wp-config.php

# Allow HTTP traffic through the firewall
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
