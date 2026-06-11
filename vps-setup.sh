#!/bin/bash
# ================================================
# Скрипт первоначальной настройки Ubuntu сервера
# Двухэтапный: обновление → перезагрузка → остальная настройка
# ================================================

set -euo pipefail

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт от root (sudo su - или sudo -i)" >&2
    exit 1
fi

MARKER_FILE="/etc/first_stage_completed"

echo "=== Начинаем первоначальную настройку Ubuntu сервера ==="

# ====================== ПЕРВЫЙ ЭТАП ======================
if [ ! -f "$MARKER_FILE" ]; then
    echo "=== Этап 1: Обновление системы ==="

    read -rp "Введите таймзону (например Europe/Moscow): " timezone
    timedatectl set-timezone "$timezone" || echo "⚠️ Не удалось установить таймзону"

    echo "Обновляем систему..."
    apt-get update && apt-get upgrade -y

    touch "$MARKER_FILE"
    echo "✅ Первый этап завершён."
    echo "Перезагрузите сервер командой: reboot"
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
    adduser --quiet --disabled-password --gecos "" "$username"
    usermod -aG sudo "$username"
    echo "✅ Пользователь $username создан и добавлен в группу sudo."
else
    while true; do
        read -rp "Введите имя существующего пользователя (не root): " username
        if [ "$username" = "root" ]; then
            echo "❌ Нельзя использовать root. Попробуйте снова."
            continue
        fi
        if ! id "$username" >/dev/null 2>&1; then
            echo "❌ Пользователь $username не существует. Попробуйте снова."
            continue
        fi
        break
    done
fi

# 2. Смена пароля root
echo "Установите новый надёжный пароль для root:"
passwd root

# 3. Добавление SSH-ключа
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
echo "✅ SSH-ключ установлен для $username"

# 4. Настройка SSH
read -rp "Введите новый порт SSH (1024-65535): " ssh_port
if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1024 ] || [ "$ssh_port" -gt 65535 ]; then
    echo "❌ Некорректный порт!" >&2
    exit 1
fi

# Надёжная замена параметров
sed -i 's/^#*Port .*/Port '"$ssh_port"'/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#*MaxSessions.*/MaxSessions 2/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

# Добавляем порт, если sed не сработал
grep -q "^Port $ssh_port" /etc/ssh/sshd_config || echo "Port $ssh_port" >> /etc/ssh/sshd_config

sshd -t && echo "✅ Конфигурация SSH проверена"

# 5. UFW
apt-get install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow "$ssh_port"/tcp

read -rp "Ваш статический IP для ограничения SSH (Enter — пропустить): " static_ip
if [ -n "$static_ip" ]; then
    ufw allow from "$static_ip" to any port "$ssh_port" proto tcp
    echo "✅ Доступ по SSH ограничен IP $static_ip"
fi

ufw --force enable

# 6. Защита от брутфорса
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
    echo "✅ fail2ban установлен и настроен"

else
    curl -s https://install.crowdsec.net | sh
    apt-get update
    apt-get install crowdsec -y
    apt-get install crowdsec-firewall-bouncer-iptables -y

    echo "✅ CrowdSec успешно установлен!"
    echo "   После перезагрузки настройте его дальше по документации:"
    echo "   https://docs.crowdsec.net"
fi

# 7. Автоматические обновления
apt-get install unattended-upgrades -y
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# Завершение
rm -f "$MARKER_FILE"
echo "=================================================="
echo "✅ Настройка сервера успешно завершена!"
echo "Рекомендуется перезагрузить сервер: reboot"
echo "=================================================="
