#!/bin/bash
set -e  # 脚本中任何命令失败都立即退出

# 定义变量 (提高可配置性)
COWRIE_INSTALL_DIR="/opt/cowrie"
LOG_RETENTION_DAYS=30
CLEANUP_LOG_SCRIPT="/usr/local/bin/cleanup_logs.sh"
CRON_SCHEDULE="0 2 * * *"  # 修正 cron 表达式

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

# 检查操作系统
if [ ! -f /etc/debian_version ] && [ ! -f /etc/ubuntu_version ]; then
    echo "此脚本仅支持 Debian/Ubuntu 系统"
    exit 1
fi

# 更新系统并安装必要的依赖
echo "更新系统并安装依赖..."
if ! sudo apt update && sudo apt upgrade -y; then
    echo "系统更新失败!"
    exit 1
fi

if ! sudo apt install -y fail2ban python3-virtualenv git curl; then
    echo "安装依赖失败!"
    exit 1
fi

# 配置 fail2ban
echo "配置 fail2ban..."
# 备份原配置
[ -f /etc/fail2ban/jail.local ] && cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak

sudo cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 86400
findtime = 300
maxretry = 3
action = %(action_)s

[sshd]
enabled = true
logpath = /var/log/auth.log
EOF

sudo systemctl restart fail2ban

# 设置日志清理脚本
echo "创建日志清理脚本..."
sudo cat <<'EOL' > "$CLEANUP_LOG_SCRIPT"
#!/bin/bash
LOG_DIR="/var/log"
RETENTION_DAYS="${LOG_RETENTION_DAYS}"

if find "$LOG_DIR" -type f -name "*.log" -mtime "+${RETENTION_DAYS}" -exec rm -f {} \; ; then
    echo "$(date): Logs older than ${RETENTION_DAYS} days have been deleted." >> /var/log/cleanup.log
else
    echo "$(date): Log cleanup failed!" >> /var/log/cleanup.log
fi
EOL

sudo chmod +x "$CLEANUP_LOG_SCRIPT"

# 配置定时任务清理日志 (确保幂等性)
echo "配置定时任务清理日志..."
CRON_TASK="$CRON_SCHEDULE $CLEANUP_LOG_SCRIPT"
if ! sudo crontab -l | grep -q "$CLEANUP_LOG_SCRIPT"; then
    (sudo crontab -l 2>/dev/null; echo "$CRON_TASK") | sudo crontab -
    echo "已配置定时任务清理日志。"
else
    echo "定时任务清理日志已存在，无需重复配置。"
fi

# 安装 Cowrie 蜜罐
echo "安装 Cowrie 蜜罐..."
if ! git clone https://github.com/cowrie/cowrie.git "$COWRIE_INSTALL_DIR"; then
    echo "安装 Cowrie 蜜罐失败！"
    exit 1
fi

cd "$COWRIE_INSTALL_DIR"
virtualenv cowrie-env
source cowrie-env/bin/activate
pip install -r requirements.txt
cp etc/cowrie.cfg.dist etc/cowrie.cfg

# 配置 Cowrie
sed -i 's/hostname = svr04/hostname = fake-ssh-server/' etc/cowrie.cfg
sed -i 's/^#listen_port=2222/listen_port=2222/' etc/cowrie.cfg
sed -i 's/^#download_limit_size=10485760/download_limit_size=1048576/' etc/cowrie.cfg

# 配置 Cowrie 服务
echo "配置 Cowrie 服务..."
sudo cat <<EOF > /etc/systemd/system/cowrie.service
[Unit]
Description=Cowrie SSH Honeypot
After=network.target

[Service]
User=root
WorkingDirectory=$COWRIE_INSTALL_DIR
ExecStart=$COWRIE_INSTALL_DIR/cowrie-env/bin/cowrie start
ExecStop=$COWRIE_INSTALL_DIR/cowrie-env/bin/cowrie stop
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 配置日志轮转
sudo cat <<EOF > /etc/logrotate.d/cowrie
$COWRIE_INSTALL_DIR/var/log/cowrie/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
}
EOF

sudo systemctl daemon-reload
sudo systemctl enable cowrie
sudo systemctl start cowrie

# 配置 fail2ban 监控 Cowrie 日志
echo "配置 fail2ban 监控 Cowrie 日志..."
sudo cat <<EOF > /etc/fail2ban/jail.d/cowrie.conf
[cowrie]
enabled = true
filter = cowrie
logpath = $COWRIE_INSTALL_DIR/var/log/cowrie/cowrie.log
maxretry = 3
bantime = 86400
EOF

sudo cat <<'EOF' > /etc/fail2ban/filter.d/cowrie.conf
[Definition]
failregex = .*Failed login for .* from <HOST>
ignoreregex =
EOF

sudo systemctl restart fail2ban

# 检查服务状态
if systemctl is-active --quiet cowrie && systemctl is-active --quiet fail2ban; then
    echo "所有组件安装完成！Fail2Ban 和 Cowrie 蜜罐服务已成功启动。"
else 
    echo "服务启动失败，请检查系统日志"
    exit 1
fi