#!/bin/bash
set -e  # 脚本中任何命令失败都立即退出

# 函数定义
check_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "错误：未找到命令 $1"
        exit 1
    }
}

backup_config() {
    local config_file="$1"
    [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
}

write_config() {
    local file="$1"
    cat > "$file"
}

setup_ssh_key() {
    local key_type="$1"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    case $key_type in
        "generate")
            local ssh_key_file="/root/.ssh/id_rsa"
            ssh-keygen -t rsa -b 4096 -f "$ssh_key_file" -N ""
            cat "${ssh_key_file}.pub" >> /root/.ssh/authorized_keys
            local temp_key_file="/tmp/ssh_key_$(date +%s).txt"
            cat "$ssh_key_file" > "$temp_key_file"
            chmod 600 "$temp_key_file"
            echo "SSH 密钥已生成，私钥保存在: ${temp_key_file}"
            ;;
        "import")
            read -r -p "请输入 SSH 公钥: " pubkey
            [[ $pubkey == ssh-rsa* ]] || {
                echo "错误：无效的公钥格式"
                return 1
            }
            echo "$pubkey" >> /root/.ssh/authorized_keys
            echo "公钥已添加"
            ;;
    esac
    chmod 600 /root/.ssh/authorized_keys
}

# 变量定义
COWRIE_INSTALL_DIR="/opt/cowrie"
LOG_RETENTION_DAYS=30
CLEANUP_LOG_SCRIPT="/usr/local/bin/cleanup_logs.sh"
CRON_SCHEDULE="0 2 * * *"  # 修正 cron 表达式

# 环境检查
for cmd in apt systemctl netstat grep awk; do
    check_command "$cmd"
done

[ "$EUID" -eq 0 ] || {
    echo "请使用 root 权限运行此脚本"
    exit 1
}

[ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ] || {
    echo "此脚本仅支持 Debian/Ubuntu 系统"
    exit 1
}

# 添加系统源更新函数
update_sources() {
    local os_version
    if [ -f /etc/debian_version ]; then
        os_version=$(cat /etc/debian_version)
        case $os_version in
            10*)
                echo "检测到 Debian 10 (Buster)，更新软件源..."
                # 备份当前源
                cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d)
                # 更新为 Debian 11 源
                cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
                echo "已更新软件源为 Debian 11 (Bullseye)"
                ;;
        esac
    fi
}

# 在环境检查后，系统更新前添加
echo "检查系统软件源..."
update_sources

# 系统依赖安装和 Python 环境检查
echo "安装依赖..."
apt install -y fail2ban python3-virtualenv git curl netstat-nat || {
    echo "依赖安装失败，请检查系统配置"
    exit 1
}

# 检查 Python 环境
if ! python3 -c "import distutils" 2>/dev/null; then
    echo "正在安装 Python 兼容环境..."
    apt install -y python3.7 python3.7-distutils
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.7 1
fi

apt upgrade -y
apt install -y fail2ban python3-virtualenv git curl netstat-nat

# Fail2ban 配置
echo "====开始配置 fail2ban===="

# 备份配置
echo "1. 备份 fail2ban 配置..."
if [ -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak.$(date +%s) || {
        echo "错误：无法备份 fail2ban 配置文件"
        exit 1
    }
    echo "备份完成：/etc/fail2ban/jail.local.bak.$(date +%s)"
fi

# 写入新配置
echo "2. 写入新配置..."
if ! cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 86400
findtime = 300
maxretry = 3
action = %(action_)s

[sshd]
enabled = true
logpath = /var/log/auth.log
EOF
then
    echo "错误：无法写入 fail2ban 配置文件"
    exit 1
fi
echo "配置文件写入成功"

# 测试配置
echo "3. 测试配置文件..."
if ! fail2ban-client -t; then
    echo "错误：fail2ban 配置测试失败"
    exit 1
fi
echo "配置文件测试通过"

# 重启服务
echo "4. 重启 fail2ban 服务..."
if ! systemctl restart fail2ban; then
    echo "错误：fail2ban 服务重启失败"
    journalctl -u fail2ban --no-pager -n 50
    exit 1
fi

# 检查服务状态
echo "5. 检查服务状态..."
if ! systemctl is-active --quiet fail2ban; then
    echo "错误：fail2ban 服务未能正常启动"
    systemctl status fail2ban
    exit 1
fi

echo "====fail2ban 配置完成===="

# 日志清理脚本
echo "创建日志清理脚本..."
cat > "$CLEANUP_LOG_SCRIPT" <<'EOL' || {
    echo "创建日志清理脚本失败"
    exit 1
}
#!/bin/bash
find /var/log -type f -name "*.log" -mtime +30 -exec rm -f {} \;
echo "$(date): Logs older than 30 days have been deleted." >> /var/log/cleanup.log
EOL

chmod +x "$CLEANUP_LOG_SCRIPT" || {
    echo "设置日志清理脚本权限失败"
    exit 1
}

echo "日志清理脚本创建完成"

# 配置定时任务
echo "配置定时任务..."
if ! crontab -l | grep -q "$CLEANUP_LOG_SCRIPT"; then
    (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CLEANUP_LOG_SCRIPT") | crontab - || {
        echo "配置定时任务失败"
        exit 1
    }
    echo "定时任务已配置"
else
    echo "定时任务已存在"
fi

echo "开始安装 Cowrie..."

# 安装 Cowrie 蜜罐
echo "安装 Cowrie 蜜罐..."
rm -rf "$COWRIE_INSTALL_DIR" # 确保目录干净
if ! git clone https://github.com/cowrie/cowrie.git "$COWRIE_INSTALL_DIR"; then
    echo "安装 Cowrie 蜜罐失败！"
    exit 1
fi

echo "配置 Cowrie 环境..."
cd "$COWRIE_INSTALL_DIR" || {
    echo "无法进入 Cowrie 目录！"
    exit 1
}

# 设置虚拟环境
python3 -m virtualenv cowrie-env || {
    echo "创建虚拟环境失败！"
    exit 1
}

# 激活虚拟环境并安装依赖
. cowrie-env/bin/activate || {
    echo "激活虚拟环境失败！"
    exit 1
}

echo "安装 Python 依赖..."
pip install --upgrade pip || {
    echo "升级 pip 失败！"
    exit 1
}

pip install -r requirements.txt || {
    echo "安装依赖失败！"
    exit 1
}

# 配置 Cowrie
echo "配置 Cowrie..."
cp etc/cowrie.cfg.dist etc/cowrie.cfg
sed -i 's/hostname = svr04/hostname = fake-ssh-server/' etc/cowrie.cfg
sed -i 's/^#listen_port=2222/listen_port=2222/' etc/cowrie.cfg
sed -i 's/^#download_limit_size=10485760/download_limit_size=1048576/' etc/cowrie.cfg

deactivate

# 配置 Cowrie 服务
echo "配置 Cowrie 服务..."
cat <<EOF > /etc/systemd/system/cowrie.service
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
cat <<EOF > /etc/logrotate.d/cowrie
$COWRIE_INSTALL_DIR/var/log/cowrie/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
}
EOF

systemctl daemon-reload

systemctl start cowrie

# 配置 fail2ban 监控 Cowrie 日志
echo "配置 fail2ban 监控 Cowrie 日志..."
cat <<EOF > /etc/fail2ban/jail.d/cowrie.conf
[cowrie]
enabled = true
filter = cowrie
logpath = $COWRIE_INSTALL_DIR/var/log/cowrie/cowrie.log
maxretry = 3
bantime = 86400
EOF

cat <<'EOF' > /etc/fail2ban/filter.d/cowrie.conf
failregex = .*Failed login for .* from <HOST>
EOF

# SSH 安全配置
echo "配置 SSH 安全选项..."

# 检测当前 SSH 配置
current_ssh_config() {
    local port=$(grep -E "^Port\s+" /etc/ssh/sshd_config | awk '{print $2}')
    echo "${port:-22}"
}

CURRENT_SSH_PORT=$(current_ssh_config)
CURRENT_PASSWORD_AUTH=$(grep -E "^PasswordAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_PASSWORD_AUTH=${CURRENT_PASSWORD_AUTH:-yes}
CURRENT_PUBKEY_AUTH=$(grep -E "^PubkeyAuthentication\s+" /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_PUBKEY_AUTH=${CURRENT_PUBKEY_AUTH:-yes}

echo "当前 SSH 配置："
echo "- 端口: $CURRENT_SSH_PORT"
echo "- 密码认证: $CURRENT_PASSWORD_AUTH"
echo "- 密钥认证: $CURRENT_PUBKEY_AUTH"
echo ""

# SSH 端口配置
echo "0) 保持当前配置 (端口: $CURRENT_SSH_PORT)"
echo "1) 随机生成新端口"
echo "2) 手动输入新端口"
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
        # 禁用密码认证
        sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

        # 启用密钥认证
        sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config

        # 配置 SSH 密钥
        setup_ssh_key "generate"

        # 重启 SSH 服务
        systemctl restart sshd

        echo "新的 SSH 端口: ${NEW_SSH_PORT}"
        echo "密码认证已禁用，仅允许密钥登录"
        echo "=========================="
        ;;
    2)
        # 启用密码和密钥认证
        sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        ;;
    *)
        echo "无效的选择！保持当前认证配置"
        ;;
esac

# 防火墙配置
setup_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    
    echo "检测到 UFW 防火墙..."
    [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] || return 0
    
    read -p "是否配置防火墙规则？[y/N]: " -r SETUP_UFW
    [[ $SETUP_UFW =~ ^[Yy]$ ]] || return 0
    
    ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'
    ufw allow 2222/tcp comment 'Cowrie Honeypot'
    ufw --force enable
}

setup_firewall

# 如果端口已更改，则更新 SSH 配置
if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
    sed -i "s/^#\?Port.*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
fi

if [ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] || [ "$AUTH_CHOICE" != "0" ]; then
    systemctl restart sshd
fi

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

echo "==== 安装完成 ===="
echo "配置总结："
[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] && echo "- 新 SSH 端口: $NEW_SSH_PORT"
[ -n "$TEMP_KEY_FILE" ] && echo "- SSH 密钥位置: $TEMP_KEY_FILE"
echo "- Cowrie 端口: 2222"
echo "- 日志位置: $COWRIE_INSTALL_DIR/var/log/cowrie/"