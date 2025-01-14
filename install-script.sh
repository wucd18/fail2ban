#!/bin/bash
set -e

# Root & OS check
[ "$EUID" -eq 0 ] || { echo "请使用 root 权限运行此脚本"; exit 1; }
[ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ] || { echo "此脚本仅支持 Debian/Ubuntu 系统"; exit 1; }

# Update and install dependencies
apt update && apt upgrade -y
apt install -y fail2ban python3-virtualenv git curl netstat-nat ufw net-tools

# Configure fail2ban
backup_config() {
    [ -f "$1" ] && cp "$1" "${1}.bak"
}

echo "配置 fail2ban..."
backup_config "/etc/fail2ban/jail.local"
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

systemctl restart fail2ban

# Configure UFW
echo "配置防火墙..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 2222/tcp comment 'Honeypot'
ufw --force enable

# Install Cowrie
echo "安装 Cowrie..."
COWRIE_INSTALL_DIR="/opt/cowrie"
useradd -r -s /sbin/nologin cowrie || true
rm -rf "$COWRIE_INSTALL_DIR"
mkdir -p "$COWRIE_INSTALL_DIR"
chown cowrie:cowrie "$COWRIE_INSTALL_DIR"

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

systemctl daemon-reload
systemctl enable cowrie
systemctl restart cowrie

echo -e "\n\033[1;32m安装完成！\033[0m"
echo "Cowrie日志位置: $COWRIE_INSTALL_DIR/var/log/cowrie/"