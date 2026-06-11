#!/bin/bash
# ================================================
# Скрипт первоначальной настройки Ubuntu сервера
# ================================================

set -euo pipefail

# Неинтерактивный режим для apt
export DEBIAN_FRONTEND=noninteractive

# ==================== Цвета ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    local width=60
    local line

    line=$(printf '%*s' "$width" '' | tr ' ' '=')

    echo
    echo -e "${BLUE}${line}${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}${line}${NC}"
    echo
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

# Проверка root
if [ "$EUID" -ne 0 ]; then
    print_error "Запустите скрипт от root (sudo su - или sudo -i)"
    exit 1
fi

# Проверка Ubuntu (исправленная проверка)
if [ ! -f /etc/os-release ]; then
    print_error "Файл /etc/os-release отсутствует"
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    print_error "Скрипт протестирован только на Ubuntu"
    exit 1
fi

MARKER_FILE="/etc/first_stage_completed"

print_header "НАЧИНАЕМ ПЕРВОНАЧАЛЬНУЮ НАСТРОЙКУ UBUNTU СЕРВЕРА"

# ====================== ПЕРВЫЙ ЭТАП ======================
if [ ! -f "$MARKER_FILE" ]; then
    print_header "ЭТАП 1 — ОБНОВЛЕНИЕ СИСТЕМЫ"

    read -rp "Введите таймзону (по умолчанию Europe/Moscow): " timezone
    if [ -z "$timezone" ]; then
        timezone="Europe/Moscow"
        print_success "Установлена таймзона по умолчанию: $timezone"
    fi

    # Упрощённая проверка таймзоны
    if ! timedatectl set-timezone "$timezone" 2>/dev/null; then
        print_warning "Таймзона не найдена, используем Europe/Moscow"
        timedatectl set-timezone Europe/Moscow
    else
        print_success "Таймзона установлена: $timezone"
    fi

    echo -e "${CYAN}Обновляем систему...${NC}"
    apt-get update && apt-get upgrade -y

    touch "$MARKER_FILE"
    print_success "Первый этап успешно завершён"
    echo -e "\n${YELLOW}Перезагрузите сервер: reboot${NC}"
    echo -e "${YELLOW}После перезагрузки запустите скрипт снова.${NC}"
    exit 0
fi

# ====================== ВТОРОЙ ЭТАП ======================
print_header "ЭТАП 2 — ОСНОВНАЯ НАСТРОЙКА"

# 1. Создание пользователя
echo -e "${CYAN}→ Создание пользователя:${NC}"
echo "Хотите создать нового пользователя? (y/n)"
read -r create_user

if [[ "$create_user" =~ ^[Yy]$ ]]; then
    read -rp "Введите имя нового пользователя: " username
    if id "$username" >/dev/null 2>&1; then
        print_error "Пользователь $username уже существует!"
        exit 1
    fi
    echo -e "${CYAN}Создаём пользователя $username...${NC}"
    # Используем useradd вместо интерактивного adduser
    useradd -m -s /bin/bash "$username"
    
    # Устанавливаем пароль через chpasswd (без интерактива)
    read -rsp "Введите пароль для пользователя $username: " password
    echo
    echo "$username:$password" | chpasswd
    
    usermod -aG sudo "$username"
    print_success "Пользователь $username создан и добавлен в группу sudo"
else
    while true; do
        read -rp "Введите имя существующего пользователя (не root): " username
        if [ "$username" = "root" ]; then
            print_error "Нельзя использовать root"
            continue
        fi
        if ! id "$username" >/dev/null 2>&1; then
            print_error "Пользователь $username не существует"
            continue
        fi
        print_success "Используем пользователя: $username"
        break
    done
fi

# 2. Пароль root
echo -e "\n${CYAN}→ Установка пароля root:${NC}"
read -rsp "Введите пароль для root: " root_password
echo
echo "root:$root_password" | chpasswd
print_success "Пароль root установлен"

# 3. SSH ключ
echo -e "\n${CYAN}→ Добавление SSH-ключа:${NC}"
echo "Вставьте ваш публичный SSH ключ (одной строкой):"
IFS= read -r public_key

if [ -z "$public_key" ]; then
    print_error "Ключ не введён!"
    exit 1
fi

# Расширенная проверка SSH ключа
if ! echo "$public_key" | grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-ssh-)'; then
    print_error "Некорректный SSH ключ"
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
touch "$home/.ssh/authorized_keys"

# Проверка на существование ключа
if ! grep -Fxq "$public_key" "$home/.ssh/authorized_keys"; then
    echo "$public_key" >> "$home/.ssh/authorized_keys"
    print_success "SSH-ключ успешно добавлен"
else
    print_warning "SSH-ключ уже существует в списке"
fi

chown -R "$user:$user" "$home/.ssh"
chmod 700 "$home/.ssh"
chmod 600 "$home/.ssh/authorized_keys"
print_success "SSH-ключи настроены"

# 4. Настройка SSH
echo -e "\n${CYAN}→ Настройка SSH:${NC}"
read -rp "Введите новый порт SSH (1024-65535): " ssh_port
if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1024 ] || [ "$ssh_port" -gt 65535 ]; then
    print_error "Некорректный порт!"
    exit 1
fi

# Бэкап конфигурации SSH
if [ ! -f /etc/ssh/sshd_config.bak ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
else
    print_warning "Бэкап уже существует"
fi

# Функция для безопасной установки параметров sshd_config
sshd_cfg_set() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*$key[[:space:]]" /etc/ssh/sshd_config; then
        sed -i "s|^[[:space:]]*#*[[:space:]]*$key[[:space:]].*|$key $val|" /etc/ssh/sshd_config
    else
        echo "$key $val" >> /etc/ssh/sshd_config
    fi
}

# Определяем PermitRootLogin в зависимости от выбранного пользователя
if [ "$username" = "root" ]; then
    root_login="prohibit-password"
else
    root_login="no"
fi

sshd_cfg_set Port "$ssh_port"
sshd_cfg_set PermitRootLogin "$root_login"
sshd_cfg_set PasswordAuthentication no
sshd_cfg_set PubkeyAuthentication yes
sshd_cfg_set MaxAuthTries 3
sshd_cfg_set MaxSessions 2
sshd_cfg_set X11Forwarding no

# Проверка конфигурации SSH и перезапуск
if sshd -t; then
    # Определяем правильное имя сервиса
    if systemctl is-active --quiet ssh; then
        ssh_service="ssh"
    elif systemctl is-active --quiet sshd; then
        ssh_service="sshd"
    else
        print_warning "Не удалось определить SSH-сервис, попробуйте перезапустить вручную"
        exit 1
    fi
    
    systemctl restart "$ssh_service"
    print_success "SSH успешно перезапущен"
else
    print_error "Ошибка конфигурации SSH"
    print_error "Восстановите бэкап: cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config"
    exit 1
fi

# Настройка UFW с правильным ограничением SSH
echo -e "\n${CYAN}→ Настройка UFW:${NC}"
if ! dpkg -l | grep -q "^ii  ufw "; then
    echo "UFW не найден — устанавливаем..."
    apt-get install ufw -y
else
    print_success "UFW уже установлен"
fi

ufw default deny incoming
ufw default allow outgoing

read -rp "Статический IP для ограничения SSH (Enter — пропустить): " static_ip
if [ -n "$static_ip" ]; then
    echo -e "${YELLOW}ВНИМАНИЕ: доступ будет разрешён ТОЛЬКО с IP: $static_ip${NC}"
    read -rp "Вы уверены, что это ваш IP? (y/n): " confirm_ip
    if [[ "$confirm_ip" =~ ^[Yy]$ ]]; then
        ufw allow from "$static_ip" to any port "$ssh_port" proto tcp
        print_success "SSH доступ разрешён только с IP: $static_ip"
    else
        print_warning "IP не подтверждён, разрешаем доступ со всех IP"
        ufw allow "$ssh_port"/tcp
    fi
else
    ufw allow "$ssh_port"/tcp
fi

ufw --force enable
print_success "UFW включён и настроен"

# 5. Защита
echo -e "\n${CYAN}→ Выбор системы защиты:${NC}"
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
    print_success "fail2ban установлен и настроен"
else
    echo -e "${CYAN}Устанавливаем CrowdSec...${NC}"
    
    # Установка CrowdSec
    if ! curl -fsSL https://install.crowdsec.net | sh; then
        print_error "Не удалось установить CrowdSec"
        exit 1
    fi
    
    # CrowdSec установщик сам ставит пакеты, просто включаем сервис
    systemctl enable --now crowdsec
    sleep 3
    
    # Установка SSH коллекции для CrowdSec
    if command -v cscli >/dev/null 2>&1; then
        cscli collections install crowdsecurity/sshd
        print_success "CrowdSec SSH коллекция установлена"
    else
        print_warning "cscli не найден, коллекция SSH не установлена"
    fi
    
    # Установка и запуск firewall bouncer
    apt-get install crowdsec-firewall-bouncer-iptables -y
    systemctl enable --now crowdsec-firewall-bouncer-iptables
    
    systemctl restart crowdsec
    print_success "CrowdSec успешно установлен и настроен"
fi

# 6. Автообновления
echo -e "\n${CYAN}→ Настройка автоматических обновлений...${NC}"
apt-get install unattended-upgrades -y

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

CONFIG_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"

# Исправленная настройка unattended-upgrades
for directive in \
    'Unattended-Upgrade::Remove-Unused-Dependencies "true"' \
    'Unattended-Upgrade::Automatic-Reboot "true"' \
    'Unattended-Upgrade::Automatic-Reboot-Time "04:00"'; do
    key="${directive%% *}"
    # Удаляем старые строки (закомментированные и нет)
    sed -i "\|^[[:space:]]*//\?[[:space:]]*$key|d" "$CONFIG_FILE"
    # Добавляем новые
    echo "$directive;" >> "$CONFIG_FILE"
done

print_success "Автоматические обновления настроены"

# ====================== ЗАВЕРШЕНИЕ ======================
rm -f "$MARKER_FILE"

print_header "НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!"
echo -e "${GREEN}Сервер готов к работе.${NC}"
echo -e "${YELLOW}Рекомендуется выполнить: reboot${NC}"
echo -e "\n${CYAN}Хорошей работы!${NC}"
