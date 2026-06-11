#!/bin/bash
# ================================================
# Скрипт первоначальной настройки Ubuntu сервера
# Двухэтапный: обновление → перезагрузка → остальная настройка
# ================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт от root (sudo su - или sudo -i)" >&2
    exit 1
fi

MARKER_FILE="/etc/first_stage_completed"

echo "=== Начинаем первоначальную настройку Ubuntu сервера ==="

# ====================== ПЕРВЫЙ ЭТАП ======================
if [ ! -f "$MARKER_FILE" ]; then
    echo "=== Этап 1: Обновление системы ==="

    read -rp "Введите таймзону (по умолчанию Europe/Moscow): " timezone
    if [ -z "$timezone" ]; then
        timezone="Europe/Moscow"
        echo "✅ Установлена таймзона по умолчанию: $timezone"
    fi

    timedatectl set-timezone "$timezone" || echo "⚠️ Не удалось установить таймзону"

    echo "Обновляем систему..."
    apt-get update && apt-get upgrade -y

    touch "$MARKER_FILE"
    echo "✅ Первый этап завершён."
    echo "Перезагрузите сервер: reboot"
    echo "После перезагрузки запустите скрипт снова."
    exit 0
fi

# ====================== ВТОРОЙ ЭТАП ======================
echo "=== Этап 2: Основная настройка ==="

# 1. Создание пользователя
echo "Хотите создать нового пользователя? (y/n)"
read -r create_user

if [[ "$create_user" =~ ^[Yy]$ ]]; then
    read -rp "Введите имя нового пользователя: " username
    if id "$username" >/dev/null 2>&1; then
        echo "❌ Пользователь $username уже существует!" >&2
        exit 1
    fi
    adduser --gecos "" "$username"
    usermod -aG sudo "$username"
    echo "✅ Пользователь $username создан."
else
    while true; do
        read -rp "Введите имя существующего пользователя (не root): " username
        if [ "$username" = "root" ]; then
            echo "❌ Нельзя использовать root."
            continue
        fi
        if ! id "$username" >/dev/null 2>&1; then
            echo "❌ Пользователь не существует."
            continue
        fi
        break
    done
fi

# 2. Смена пароля root
echo "Установите новый пароль для root:"
passwd root

# 3. SSH-ключ
echo "Вставьте ваш публичный SSH ключ (одной строкой):"
read -r public_key

if [ -z "$public_key" ]; then
    echo "❌ Ключ не введён!" >&2
    exit 1
fi

if [ "$username" != "root" ]; then
    home="/home/$username"
    user="$username"
else
    home="/root"
    user="root"
fi

mkdir -p "$home/.ssh"
echo "$public_key" > "$home/.ssh/authorized_keys"
chown -R "$user:$user" "$home/.ssh"
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/authorized_keys"
echo "✅ SSH-ключ установлен"

# 4. Настройка SSH
read -rp "Введите новый порт SSH (1024-65535): " ssh_port
if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1024 ] || [ "$ssh_port" -gt 65535 ]; then
    echo "❌ Некорректный порт!" >&2
    exit 1
fi

sed -i 's/^#*Port .*/Port '"$ssh_port"'/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#*MaxSessions.*/MaxSessions 2/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

grep -q "^Port $ssh_port" /etc/ssh/sshd_config || echo "Port $ssh_port" >> /etc/ssh/sshd_config

sshd -t && echo "✅ SSH конфигурация проверена"

# 5. UFW
apt-get install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow "$ssh_port"/tcp

read -rp "Статический IP для SSH (Enter — пропустить): " static_ip
if [ -n "$static_ip" ]; then
    ufw allow from "$static_ip" to any port "$ssh_port" proto tcp
fi

ufw --force enable
echo "✅ UFW настроен"

# 6. CrowdSec / fail2ban
echo "Выберите инструмент защиты:"
echo "1) fail2ban"
echo "2) crowdsec (рекомендуется)"
read -r choice

if [[ "$choice" == "1" ]]; then
    apt-get install fail2ban -y
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
ignoreip = 127.0.0.1/8 ::1
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban
    echo "✅ fail2ban установлен"
else
    echo "Устанавливаем CrowdSec..."
    curl -s https://install.crowdsec.net | sh
    apt-get update
    apt-get install crowdsec -y
    apt-get install crowdsec-firewall-bouncer-iptables -y
    echo "✅ CrowdSec установлен"
fi

# 7. Автоматические обновления (улучшенная версия)
echo "Настраиваем автоматические обновления..."
apt-get install unattended-upgrades -y

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

CONFIG_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"

# Раскомментировать и исправить значения
sed -i 's|//[[:space:]]*Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' "$CONFIG_FILE"
sed -i 's|//[[:space:]]*Unattended-Upgrade::Automatic-Reboot.*|Unattended-Upgrade::Automatic-Reboot "true";|' "$CONFIG_FILE"
sed -i 's|//[[:space:]]*Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time "04:00";|' "$CONFIG_FILE"

# Добавить, если строк нет
grep -q 'Remove-Unused-Dependencies' "$CONFIG_FILE" || echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' >> "$CONFIG_FILE"
grep -q 'Automatic-Reboot ' "$CONFIG_FILE" || echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "$CONFIG_FILE"
grep -q 'Automatic-Reboot-Time' "$CONFIG_FILE" || echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> "$CONFIG_FILE"

# Завершение
rm -f "$MARKER_FILE"
echo "=================================================="
echo "✅ Настройка сервера успешно завершена!"
echo "Рекомендуется выполнить: reboot"
echo "=================================================="
