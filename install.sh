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

check_installed() {
    local component="$1"
    local check_command="$2"
    echo "检查 $component 是否已安装..."
    if eval "$check_command"; then
        echo "$component 已安装，跳过配置"
        return 0
    fi
    return 1
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
echo "检查 fail2ban 配置..."
if ! check_installed "fail2ban" "systemctl is-active --quiet fail2ban"; then
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
else
    echo "fail2ban 已安装，跳过配置"
fi

# 日志清理脚本配置
echo "检查日志清理配置..."
if [ ! -f "$CLEANUP_LOG_SCRIPT" ]; then
    echo "配置日志清理..."
    cat > "$CLEANUP_LOG_SCRIPT" <<'EOFF'
#!/bin/bash
find /var/log -type f -name "*.log" -mtime +30 -exec rm -f {} \;
echo "$(date): Logs older than 30 days have been deleted." >> /var/log/cleanup.log
EOFF

    chmod +x "$CLEANUP_LOG_SCRIPT"
    
    # 配置定时任务
    if ! crontab -l | grep -q "$CLEANUP_LOG_SCRIPT"; then
        (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $CLEANUP_LOG_SCRIPT") | crontab -
        echo "定时任务已配置"
    fi
    echo "日志清理配置完成"
else
    echo "日志清理已配置，跳过"
fi

echo "开始安装 Cowrie..."

# Cowrie 配置
echo "检查 Cowrie 安装状态..."
COWRIE_INSTALLED=false
if [ -d "$COWRIE_INSTALL_DIR" ] && [ -f "$COWRIE_INSTALL_DIR/cowrie-env/bin/cowrie" ]; then
    echo "检测到现有 Cowrie 安装，检查完整性..."
    if [ -f "/etc/systemd/system/cowrie.service" ] && [ -d "$COWRIE_INSTALL_DIR/var/log/cowrie" ]; then
        COWRIE_INSTALLED=true
        echo "Cowrie 已完整安装"
    fi
fi

if [ "$COWRIE_INSTALLED" = "false" ]; then
    echo "开始安装 Cowrie..."
    # 创建 Cowrie 用户和目录
    echo "创建 Cowrie 用户和目录..."
    if ! id cowrie &>/dev/null; then
        useradd -r -m -d "$COWRIE_INSTALL_DIR" -s /bin/bash cowrie || {
            echo "创建 cowrie 用户失败"
            exit 1
        }
    fi

    # 清理并创建目录
    rm -rf "$COWRIE_INSTALL_DIR"
    mkdir -p "$COWRIE_INSTALL_DIR"
    mkdir -p "$COWRIE_INSTALL_DIR/var/log/cowrie"
    chown -R cowrie:cowrie "$COWRIE_INSTALL_DIR"

    # 克隆仓库
    echo "克隆 Cowrie 仓库..."
    cd "$COWRIE_INSTALL_DIR"
    sudo -u cowrie git clone https://github.com/cowrie/cowrie.git .

    # 配置 Python 环境和安装依赖
    echo "配置 Python 环境..."
    sudo -u cowrie python3 -m virtualenv cowrie-env
    sudo -u cowrie bash -c "
        source cowrie-env/bin/activate
        pip install --upgrade pip
        pip install -r requirements.txt
        cp etc/cowrie.cfg.dist etc/cowrie.cfg
        deactivate
    "

    # 配置 Cowrie
    echo "配置 Cowrie..."
    sudo -u cowrie bash -c "
        cd $COWRIE_INSTALL_DIR
        sed -i 's/hostname = svr04/hostname = fake-ssh-server/' etc/cowrie.cfg
        sed -i 's/^#listen_port=2222/listen_port=2222/' etc/cowrie.cfg
        sed -i 's/^#download_limit_size=10485760/download_limit_size=1048576/' etc/cowrie.cfg
    "

    # 设置权限
    chown -R cowrie:cowrie "$COWRIE_INSTALL_DIR"
    chmod -R 755 "$COWRIE_INSTALL_DIR"
fi

# 更新 Cowrie 服务配置
cat <<EOF > /etc/systemd/system/cowrie.service
[Unit]
Description=Cowrie SSH Honeypot
After=network.target

[Service]
Type=simple
User=cowrie
Group=cowrie
WorkingDirectory=$COWRIE_INSTALL_DIR
Environment="PATH=$COWRIE_INSTALL_DIR/cowrie-env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$COWRIE_INSTALL_DIR/cowrie-env/lib/python3.9/site-packages"
ExecStart=$COWRIE_INSTALL_DIR/cowrie-env/bin/python3 $COWRIE_INSTALL_DIR/bin/cowrie start foreground
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 重新加载和启动服务
systemctl daemon-reload
systemctl enable cowrie
systemctl restart cowrie

# SSH 安全配置
echo "检查 SSH 配置..."
if [ -f "/root/.ssh/id_rsa" ] && grep -q "^Port" /etc/ssh/sshd_config; then
    read -p "SSH 已配置，是否重新配置？[y/N]: " RECONFIGURE_SSH
    if [[ ! $RECONFIGURE_SSH =~ ^[Yy]$ ]]; then
        echo "保持当前 SSH 配置"
        SSH_CONFIGURED=true
    fi
fi

if [ "$SSH_CONFIGURED" != "true" ]; then
    echo "配置 SSH..."
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
            sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

            # 启用密钥认证
            sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
            sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config

            # 密钥配置选项
            echo "SSH 密钥配置："
            echo "0) 保持现有密钥"
            echo "1) 使用新的公钥"
            echo "2) 自动生成新密钥对"
            read -p "请选择 [0/1/2] (默认: 0): " KEY_CHOICE
            KEY_CHOICE=${KEY_CHOICE:-0}

            case $KEY_CHOICE in
                0)
                    echo "保持现有密钥配置"
                    ;;
                1)
                    setup_ssh_key "import"
                    ;;
                2)
                    echo "生成新的密钥对..."
                    echo "注意：这将覆盖现有的密钥"
                    read -p "是否继续？[y/N]: " CONFIRM
                    if [[ $CONFIRM =~ ^[Yy]$ ]]; then
                        setup_ssh_key "generate"
                    else
                        echo "取消生成新密钥"
                    fi
                    ;;
                *)
                    echo "无效的选择！保持现有密钥配置"
                    ;;
            esac

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
fi

# 检查服务状态
echo "检查服务状态..."
SERVICE_CHECK_FAILED=false

check_service() {
    local service_name="$1"
    echo "检查 $service_name 服务状态..."
    
    if ! systemctl is-active --quiet "$service_name"; then
        echo "服务未运行，查看详细日志..."
        if [ "$service_name" = "cowrie" ]; then
            echo "===== Cowrie 服务状态 ====="
            systemctl status cowrie
            echo "===== Cowrie 目录权限 ====="
            ls -la "$COWRIE_INSTALL_DIR"
            ls -la "$COWRIE_INSTALL_DIR/bin"
            ls -la "$COWRIE_INSTALL_DIR/cowrie-env/bin"
            echo "===== Cowrie 日志 ====="
            tail -n 50 "$COWRIE_INSTALL_DIR/var/log/cowrie/cowrie.log" 2>/dev/null || echo "无法读取日志"
            echo "===== Python 版本 ====="
            sudo -u cowrie "$COWRIE_INSTALL_DIR/cowrie-env/bin/python3" -V
            echo "===== 系统日志 ====="
            journalctl -u cowrie --no-pager -n 50
        fi
        return 1
    fi
    
    echo "$service_name 服务运行正常"
    return 0
}

# 检查各个服务
check_service "cowrie"
check_service "fail2ban"

# 最终状态报告
echo "==== 安装完成 ===="
if [ "$SERVICE_CHECK_FAILED" = "true" ]; then
    echo "警告：某些服务启动失败，请检查上述日志"
    echo "可以使用以下命令查看详细日志："
    echo "journalctl -u cowrie -f"
    echo "journalctl -u fail2ban -f"
else
    echo "所有服务运行正常！"
fi

echo "配置总结："
[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ] && echo "- 新 SSH 端口: $NEW_SSH_PORT"
[ -n "$TEMP_KEY_FILE" ] && echo "- SSH 密钥位置: $TEMP_KEY_FILE"
echo "- Cowrie 端口: 2222"
echo "- 日志位置: $COWRIE_INSTALL_DIR/var/log/cowrie/"

if [ "$SERVICES_STATUS" != "OK" ]; then
    echo "提示：使用以下命令查看详细日志："
    echo "journalctl -u cowrie -f"
    echo "journalctl -u fail2ban -f"
fi