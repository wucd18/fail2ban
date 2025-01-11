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

# 添加 SSH 安全配置函数（在最后的服务状态检查之前添加）
echo "配置 SSH 安全选项..."

# 检测当前 SSH 配置
CURRENT_SSH_PORT=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
CURRENT_PASSWORD_AUTH=$(grep -E "^PasswordAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_PASSWORD_AUTH=${CURRENT_PASSWORD_AUTH:-yes}
CURRENT_PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_PUBKEY_AUTH=${CURRENT_PUBKEY_AUTH:-yes}

# SSH 配置部分
echo "当前 SSH 配置："
echo "- 端口: $CURRENT_SSH_PORT"
echo "- 密码认证: $CURRENT_PASSWORD_AUTH"
echo "- 密钥认证: $CURRENT_PUBKEY_AUTH"
echo ""

# SSH 端口配置
echo "SSH 端口配置："
echo "0) 保持当前配置 (端口: $CURRENT_SSH_PORT)"
echo "1) 随机生成端口 (10000-65535)"
echo "2) 手动指定端口"
read -p "请选择 [0/1/2] (默认: 0): " PORT_CHOICE
PORT_CHOICE=${PORT_CHOICE:-0}

case $PORT_CHOICE in
    0)
        NEW_SSH_PORT=$CURRENT_SSH_PORT
        echo "保持当前 SSH 端口: $NEW_SSH_PORT"
        ;;
    1)
        NEW_SSH_PORT=$((RANDOM % 55535 + 10000))
        while netstat -tuln | grep ":$NEW_SSH_PORT " > /dev/null; do
            NEW_SSH_PORT=$((RANDOM % 55535 + 10000))
        done
        echo "已随机生成 SSH 端口: $NEW_SSH_PORT"
        ;;
    2)
        while true; do
            read -p "请输入要使用的 SSH 端口 (1024-65535): " NEW_SSH_PORT
            if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1024 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
                # 检查端口是否被占用
                if ! netstat -tuln | grep ":$NEW_SSH_PORT " > /dev/null; then
                    break
                else
                    echo "错误：端口 $NEW_SSH_PORT 已被占用，请选择其他端口"
                fi
            else
                echo "错误：请输入 1024-65535 之间的有效端口号"
            fi
        done
        ;;
    *)
        NEW_SSH_PORT=$CURRENT_SSH_PORT
        echo "无效的选择！保持当前端口: $NEW_SSH_PORT"
        ;;
esac

# SSH 认证配置
echo "SSH 认证配置："
echo "0) 保持当前配置"
echo "1) 仅使用密钥认证（禁用密码）"
echo "2) 同时启用密码和密钥认证"
read -p "请选择 [0/1/2] (默认: 0): " AUTH_CHOICE
AUTH_CHOICE=${AUTH_CHOICE:-0}

case $AUTH_CHOICE in
    0)
        echo "保持当前认证配置"
        ;;
    1)
        echo "配置仅密钥认证..."
        # SSH 密钥配置
        echo "SSH 密钥配置："
        echo "1) 自动生成新的 SSH 密钥对"
        echo "2) 使用现有公钥"
        echo "3) 保持现有密钥配置"
        read -p "请选择 [1/2/3] (默认: 3): " KEY_CHOICE
        KEY_CHOICE=${KEY_CHOICE:-3}

        mkdir -p /root/.ssh
        chmod 700 /root/.ssh

        case $KEY_CHOICE in
            1|2)
                echo "SSH 密钥配置："
                echo "1) 自动生成新的 SSH 密钥对"
                echo "2) 使用现有公钥（需要手动输入）"
                read -p "请选择 [1/2]: " KEY_CHOICE

                # 备份 SSH 配置
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

                # 禁用密码登录
                sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
                sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

                # 启用密钥认证
                sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config

                # 配置 SSH 密钥
                mkdir -p /root/.ssh
                chmod 700 /root/.ssh

                case $KEY_CHOICE in
                    1)
                        # 自动生成密钥对
                        SSH_KEY_FILE="/root/.ssh/id_rsa"
                        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_FILE" -N ""
                        cat "${SSH_KEY_FILE}.pub" >> /root/.ssh/authorized_keys
                        
                        # 保存私钥到临时文件
                        TEMP_KEY_FILE="/tmp/ssh_key_$(date +%s).txt"
                        cat "$SSH_KEY_FILE" > "$TEMP_KEY_FILE"
                        chmod 600 "$TEMP_KEY_FILE"
                        
                        echo "=========================="
                        echo "SSH 密钥已自动生成！"
                        echo "私钥已保存到: ${TEMP_KEY_FILE}"
                        echo "请立即保存私钥并删除临时文件！"
                        echo "=========================="
                        ;;
                    2)
                        # 手动输入公钥
                        echo "请输入您的 SSH 公钥（以 ssh-rsa 开头的完整内容）："
                        read -r PUBKEY
                        
                        if [[ $PUBKEY == ssh-rsa* ]]; then
                            echo "$PUBKEY" >> /root/.ssh/authorized_keys
                            echo "公钥已成功添加！"
                        else
                            echo "错误：无效的公钥格式！"
                            exit 1
                        fi
                        ;;
                    *)
                        echo "无效的选择！"
                        exit 1
                        ;;
                esac

                chmod 600 /root/.ssh/authorized_keys

                # 重启 SSH 服务
                systemctl restart sshd

                echo "=========================="
                echo "SSH 安全配置完成！"
                echo "新的 SSH 端口: ${NEW_SSH_PORT}"
                echo "密码认证已禁用，仅允许密钥登录"
                echo "=========================="
                ;;
            3)
                echo "保持现有密钥配置"
                ;;
        esac
        
        # 更新 SSH 配置
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        ;;
    2)
        # 更新 SSH 配置
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        ;;
esac

# 防火墙配置
if command -v ufw >/dev/null 2>&1; then
    echo "检测到 UFW 防火墙..."
    if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
        read -p "是否配置 UFW 防火墙规则？[y/N]: " SETUP_UFW
        SETUP_UFW=${SETUP_UFW:-n}
        if [[ $SETUP_UFW =~ ^[Yy]$ ]]; then
            ufw allow $NEW_SSH_PORT/tcp comment 'SSH'
            ufw allow 2222/tcp comment 'Cowrie Honeypot'
            ufw --force enable
        fi
    fi
fi

# 如果端口已更改，则更新 SSH 配置
if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    sed -i "s/^#\?Port.*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
fi

# 重启 SSH 服务（仅在配置发生更改时）
if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] || [ "$AUTH_CHOICE" != "0" ]; then
    systemctl restart sshd
fi

echo "=========================="
echo "SSH 配置状态："
[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] && echo "- SSH 端口已更改为: ${NEW_SSH_PORT}"
[ "$AUTH_CHOICE" != "0" ] && echo "- SSH 认证配置已更新"
[ "$SETUP_UFW" = "y" ] && echo "- 防火墙规则已更新"
echo "=========================="

# 检查服务状态
if systemctl is-active --quiet cowrie && systemctl is-active --quiet fail2ban; then
    echo "所有组件安装完成！Fail2Ban 和 Cowrie 蜜罐服务已成功启动。"
else 
    echo "服务启动失败，请检查系统日志"
    exit 1
fi