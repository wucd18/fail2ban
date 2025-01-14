#!/bin/bash
set -e

# Root check
[ "$EUID" -eq 0 ] || {
    echo "Please run with root privileges"
    exit 1
}

# OS check
[ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ] || {
    echo "This script only supports Debian/Ubuntu systems"
    exit 1
}

# Update system and install basic tools
echo "Updating system..."
apt update && apt upgrade -y
apt install -y net-tools fail2ban python3-virtualenv git curl netstat-nat

# Function definitions
backup_config() {
    local config_file="$1"
    [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
}

# Fail2ban configuration
echo "Configuring fail2ban..."
if [ -f /etc/fail2ban/jail.local ]; then
    backup_config "/etc/fail2ban/jail.local"
fi

cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 86400
findtime = 300
maxretry = 3
action = %(action_)s

[sshd]
enabled = true
logpath = /var/log/auth.log
EOF

# Test and restart fail2ban
fail2ban-client -t && systemctl restart fail2ban

# SSH security configuration
echo "Configuring SSH..."
NEW_SSH_PORT=22222

# Backup sshd config
backup_config "/etc/ssh/sshd_config"

# Update SSH configuration
sed -i 's/^#\?Port.*/Port '"$NEW_SSH_PORT"'/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Setup SSH key
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "SSH key generated. Private key location: /root/.ssh/id_rsa"
fi

# Configure firewall
echo "Configuring firewall..."
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'
ufw allow 2222/tcp comment 'Honeypot'
ufw --force enable

# Install and configure Cowrie
echo "Installing Cowrie..."
COWRIE_INSTALL_DIR="/opt/cowrie"

# Create Cowrie user
useradd -r -s /sbin/nologin cowrie || true

# Prepare directory
rm -rf "$COWRIE_INSTALL_DIR"
mkdir -p "$COWRIE_INSTALL_DIR"
chown cowrie:cowrie "$COWRIE_INSTALL_DIR"

# Install Cowrie
runuser -l cowrie -s /bin/bash -c "
    cd $COWRIE_INSTALL_DIR
    git clone https://github.com/cowrie/cowrie.git .
    python3 -m virtualenv cowrie-env
    source cowrie-env/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt
    cp etc/cowrie.cfg.dist etc/cowrie.cfg
    sed -i 's/hostname = svr04/hostname = fake-ssh-server/' etc/cowrie.cfg
    sed -i 's/^#listen_port=2222/listen_port=2222/' etc/cowrie.cfg
    mkdir -p var/log/cowrie
"

# Configure Cowrie service
cat > /etc/systemd/system/cowrie.service <<EOF
[Unit]
Description=Cowrie SSH Honeypot
After=network.target

[Service]
Type=simple
User=cowrie
Group=cowrie
WorkingDirectory=$COWRIE_INSTALL_DIR
ExecStart=/bin/bash -c 'cd $COWRIE_INSTALL_DIR && source cowrie-env/bin/activate && bin/cowrie start -n'
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# Start services
systemctl daemon-reload
systemctl enable cowrie
systemctl restart cowrie
systemctl restart sshd

echo "Installation complete!"
echo "SSH port: $NEW_SSH_PORT"
echo "SSH private key: /root/.ssh/id_rsa"
echo "Cowrie logs: $COWRIE_INSTALL_DIR/var/log/cowrie/cowrie.log"