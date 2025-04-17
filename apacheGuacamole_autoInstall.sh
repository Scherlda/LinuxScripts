#!/bin/bash

set -e

############################################
# Configurable variables
############################################

GUAC_VERSION="1.5.5"
DB_NAME="guac_db"
DB_USER="guac"
DB_PASS="MYsecureP@ssw0rd"
TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

############################################
# System update and dependencies
############################################

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing required packages..."
sudo apt install -y build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev \
libtool-bin libossp-uuid-dev libvncserver-dev freerdp2-dev libssh2-1-dev \
libtelnet-dev libwebsockets-dev libpulse-dev libvorbis-dev libwebp-dev \
libssl-dev libpango1.0-dev libswscale-dev libavcodec-dev libavutil-dev \
libavformat-dev mariadb-server openjdk-17-jdk wget curl unzip

############################################
# Manually install Tomcat 9
############################################

echo "Downloading Tomcat 9..."
cd /tmp
wget https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.82/bin/apache-tomcat-9.0.82.tar.gz

echo "Extracting Tomcat..."
sudo mkdir -p /opt/tomcat
sudo tar xzvf apache-tomcat-9.0.82.tar.gz -C /opt/tomcat --strip-components=1

echo "Creating Tomcat user and group..."
sudo groupadd --system $TOMCAT_GROUP
sudo useradd -s /bin/false -g $TOMCAT_GROUP -d /opt/tomcat $TOMCAT_USER
sudo chown -R $TOMCAT_USER:$TOMCAT_GROUP /opt/tomcat
sudo chmod +x /opt/tomcat/bin/*.sh

echo "Creating systemd service for Tomcat..."
sudo tee /etc/systemd/system/tomcat.service > /dev/null <<EOF
[Unit]
Description=Apache Tomcat 9
After=network.target

[Service]
Type=forking

User=$TOMCAT_USER
Group=$TOMCAT_GROUP

Environment=JAVA_HOME=$JAVA_HOME
Environment=CATALINA_PID=/opt/tomcat/temp/tomcat.pid
Environment=CATALINA_HOME=/opt/tomcat
Environment=CATALINA_BASE=/opt/tomcat
Environment='CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC'
Environment='JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom'

ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "Starting Tomcat..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat

############################################
# Install Guacamole Server
############################################

echo "Downloading Guacamole Server..."
cd /opt
sudo wget https://downloads.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz
sudo tar -xzf guacamole-server-${GUAC_VERSION}.tar.gz
cd guacamole-server-${GUAC_VERSION}
./configure --with-init-dir=/etc/init.d
make
sudo make install
sudo ldconfig
sudo systemctl daemon-reexec
sudo systemctl enable guacd
sudo systemctl start guacd
cd ..

############################################
# Install Guacamole Web Application
############################################

echo "Installing Guacamole Web Application..."
sudo wget https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war
sudo mv guacamole-${GUAC_VERSION}.war /opt/tomcat/webapps/guacamole.war
sudo chown $TOMCAT_USER:$TOMCAT_GROUP /opt/tomcat/webapps/guacamole.war

############################################
# Configure MariaDB
############################################

echo "Configuring MariaDB..."
sudo systemctl enable mariadb
sudo systemctl start mariadb

echo "Creating database and user..."
sudo mysql <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT SELECT,INSERT,UPDATE,DELETE ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

############################################
# Install JDBC Authentication Module
############################################

echo "Installing MySQL Connector/J..."
cd /opt
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j-8.0.33.tar.gz
tar -xzf mysql-connector-j-8.0.33.tar.gz
sudo mkdir -p /etc/guacamole/lib
sudo cp mysql-connector-j-8.0.33/mysql-connector-j-8.0.33.jar /etc/guacamole/lib/

echo "Installing Guacamole JDBC authentication module..."
wget https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
tar -xzf guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz
sudo mkdir -p /etc/guacamole/extensions
sudo cp guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar /etc/guacamole/extensions/

############################################
# Import database schema
############################################

echo "Importing database schema..."
cat guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/*.sql | sudo mysql -u root $DB_NAME

############################################
# Create guacamole.properties
############################################

echo "Creating guacamole.properties..."
sudo mkdir -p /etc/guacamole
sudo tee /etc/guacamole/guacamole.properties > /dev/null <<EOF
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: $DB_NAME
mysql-username: $DB_USER
mysql-password: $DB_PASS
EOF

echo "Creating symbolic link..."
sudo mkdir -p /opt/tomcat/.guacamole
sudo ln -s /etc/guacamole/

############################################
# Restart services
############################################

echo "Restarting services"
sudo systemctl restart guacd
sudo systemctl restart tomcat

echo "Installation complete!"
echo "Access via: http://<Server-IP>:8080/guacamole"
echo "Default login: Username: guacadmin | Password: guacadmin"

############################################
# Reset password for guacadmin
############################################

echo "Resetting default password for 'guacadmin' to 'guacadmin' (no salt)..."

mysql --user="$DB_USER" --password="$DB_PASS" <<EOF
USE $DB_NAME;
UPDATE guacamole_user
SET password_hash = UNHEX(SHA2('guacadmin', 256)),
    password_salt = NULL,
    password_date = NOW()
WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = 'guacadmin');
EOF

echo "-------------------------------------------------------------"
echo "You can now log in with: Username: guacadmin | Password: guacadmin"
echo "Tip: Log in, create a new user and change the admin password"
echo "manually via the web interface."
echo "-------------------------------------------------------------"
