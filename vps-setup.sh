#!/bin/bash

# ============================================================
#  Вспомогательные функции
# ============================================================

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

log_info()  { echo -e "${blue}🔄 $*${plain}"; }
log_ok()    { echo -e "${green}✅ $*${plain}"; }
log_warn()  { echo -e "${yellow}⚠️  $*${plain}"; }
log_error() { echo -e "${red}❌ $*${plain}"; }
die()       { log_error "$*"; exit 1; }

ask_yn() {
    echo -n "$1 (y/n): "
    read -r -n 1 REPLY
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ============================================================
#  1. Проверка прав root
# ============================================================
if [[ $EUID -ne 0 ]]; then
    log_error "Пожалуйста, запустите этот скрипт с правами root"
    log_warn  "Используйте: sudo -i, затем запустите скрипт повторно"
    exit 1
fi
log_ok "Скрипт запущен от root. Продолжаем настройку..."

# ============================================================
#  2. Определение операционной системы
# ============================================================
[ -f /etc/os-release ] || die "Не удалось определить ОС. Поддерживаются только Ubuntu 22.04 и 24.04"

. /etc/os-release
OS_NAME=$NAME
OS_VERSION=$VERSION_ID
echo -e "${blue}Операционная система: $OS_NAME $OS_VERSION${plain}"

if [[ "$OS_NAME" == *"Ubuntu"* ]] && [[ "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]]; then
    log_ok "Скрипт поддерживает Ubuntu $OS_VERSION"
elif [[ "$OS_NAME" == *"Debian"* ]]; then
    log_warn "Скрипт тестировался только на Ubuntu и не поддерживает Debian"
    die "Работа скрипта прервана"
else
    die "Скрипт не поддерживает: $OS_NAME $OS_VERSION. Поддерживаются только Ubuntu 22.04 и 24.04"
fi

# ============================================================
#  3. Функция перезапуска SSH (зависит от версии Ubuntu)
# ============================================================
# Ubuntu 22.04: сервис называется sshd, управляется напрямую
# Ubuntu 24.04: введён socket-based activation — ssh.socket слушает порт сам,
#               поэтому при смене порта нужно перезагрузить юниты через daemon-reload
restart_ssh() {
    log_info "Перезапуск SSH-сервиса..."
    if [[ "$OS_VERSION" == "24.04" ]]; then
        # Перечитываем юниты (нужно при смене порта в конфиге)
        systemctl daemon-reload
        # Перезапускаем сокет и сервис
        systemctl restart ssh.socket ssh \
            || die "Ошибка при перезапуске SSH на Ubuntu 24.04"
    else
        # Ubuntu 22.04
        systemctl restart sshd \
            || die "Ошибка при перезапуске SSH на Ubuntu 22.04"
    fi
    log_ok "SSH-сервис успешно перезапущен"
}

# ============================================================
#  4. Таймзона
# ============================================================
TIMEZONE=$(timedatectl show -p Timezone --value)
log_info "Текущая таймзона: $TIMEZONE"

if [[ "$TIMEZONE" == "Europe/Moscow" ]]; then
    log_ok "Таймзона уже установлена как Europe/Moscow"
else
    if ask_yn "Хотите установить таймзону Europe/Moscow?"; then
        timedatectl set-timezone Europe/Moscow
        log_ok "Таймзона изменена на Europe/Moscow"
    else
        log_warn "Таймзона оставлена без изменений"
    fi
fi

# ============================================================
#  5. Обновление системы
# ============================================================
UPDATE_MARKER="/root/.system_updated"

if [ -f "$UPDATE_MARKER" ]; then
    log_ok "Система уже была обновлена ранее — пропускаем"
else
    log_info "Начинаем обновление системы..."
    apt update && apt upgrade -y || die "Ошибка при обновлении системы"

    touch "$UPDATE_MARKER"
    log_ok "Система успешно обновлена"

    log_warn "Рекомендуется перезагрузка после обновления"
    if ask_yn "Перезагрузить систему сейчас?"; then
        log_ok "Перезагрузка системы..."
        reboot
        exit 0
    else
        log_warn "Перезагрузка отложена. Рекомендуется перезагрузить сервер вручную перед продолжением"
    fi
fi

# ============================================================
#  6. Смена пароля root
# ============================================================
log_warn "Сейчас будет предложено сменить пароль root"
while true; do
    passwd root && { log_ok "Пароль root успешно изменён"; break; } \
        || log_error "Не удалось изменить пароль root. Попробуем ещё раз."
done

# ============================================================
#  7. Создание нового пользователя
# ============================================================
log_info "Создание нового пользователя"

while true; do
    read -r -p "Введите имя нового пользователя: " username
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        break
    else
        log_error "Недопустимое имя. Используйте строчные буквы, цифры, '-' или '_' (не более 32 символов)"
    fi
done

if id "$username" &>/dev/null; then
    log_warn "Пользователь $username уже существует — пропускаем создание"
else
    useradd -m -s /bin/bash "$username" || die "Ошибка при создании пользователя $username"
    log_ok "Пользователь $username успешно создан"
fi

if groups "$username" | grep -q '\bsudo\b'; then
    log_ok "Пользователь $username уже в группе sudo"
else
    usermod -aG sudo "$username"
    log_ok "Пользователь $username добавлен в группу sudo"
fi

# ============================================================
#  8. Настройка SSH-ключа для нового пользователя
# ============================================================
log_info "Настройка SSH для пользователя $username"

mkdir -p /home/$username/.ssh
chmod 700 /home/$username/.ssh
touch /home/$username/.ssh/authorized_keys
chmod 600 /home/$username/.ssh/authorized_keys
chown -R "$username":"$username" /home/$username/.ssh

log_warn "Введите SSH-ключ для пользователя $username"
echo -e "${yellow}Поддерживаются форматы:${plain}"
echo -e "${yellow}  - RSA:     ssh-rsa AAAAB3NzaC1yc2E...${plain}"
echo -e "${yellow}  - ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...${plain}"
echo -e "${yellow}  - ECDSA:   ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI...${plain}"

validate_ssh_key() {
    local key="$1"
    [[ -z "$key" ]] && return 1
    [[ "$key" =~ ^ssh-rsa\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]                      && return 0
    [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]                  && return 0
    [[ "$key" =~ ^ecdsa-sha2-nistp256\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]          && return 0
    [[ "$key" =~ ^ecdsa-sha2-nistp384\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]          && return 0
    [[ "$key" =~ ^ecdsa-sha2-nistp521\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]          && return 0
    [[ "$key" =~ ^sk-ssh-ed25519@openssh\.com\ [A-Za-z0-9+/]+={0,2}(\ .*)?$ ]]  && return 0
    return 1
}

while true; do
    read -r -p "Введите SSH ключ: " ssh_key
    if validate_ssh_key "$ssh_key"; then
        echo "$ssh_key" >> /home/$username/.ssh/authorized_keys
        log_ok "SSH-ключ успешно добавлен для пользователя $username"
        break
    else
        log_error "Неверный формат SSH-ключа. Попробуйте снова."
    fi
done

log_ok "Настройка пользователя завершена"

# ============================================================
#  9. Настройка SSH-демона
# ============================================================
MAIN_CONFIG="/etc/ssh/sshd_config"
CONFIG_DIR="/etc/ssh/sshd_config.d"

log_warn "Сейчас будет предложено сменить SSH-порт"
echo -e "${yellow}Выбрать порт можно на сайте: https://www.shodan.io/search/facet?query=ssh&facet=port${plain}"

while true; do
    read -r -p "Введите номер порта SSH (1024–65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1024 && NEW_PORT <= 65535 )); then
        if ss -tlnp | grep -q ":${NEW_PORT} "; then
            OCCUPANT=$(ss -tlnp | grep ":${NEW_PORT} " | awk '{print $NF}')
            log_error "Порт $NEW_PORT уже занят: $OCCUPANT. Выберите другой."
        else
            log_info "Устанавливаю порт $NEW_PORT..."
            break
        fi
    else
        log_error "Неверный номер порта. Введите число от 1024 до 65535."
    fi
done

# Редактирование основного конфига
TMP_FILE=$(mktemp)
awk -v new_port="$NEW_PORT" '
BEGIN { port_set=0; password_auth_set=0 }
/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+/ {
    if (!port_set) { print "Port", new_port; port_set=1; next }
}
/^[[:space:]]*#?[[:space:]]*PermitRootLogin/      { print "PermitRootLogin no";       next }
/^[[:space:]]*#?[[:space:]]*MaxAuthTries/         { print "MaxAuthTries 3";           next }
/^[[:space:]]*#?[[:space:]]*MaxSessions/          { print "MaxSessions 2";            next }
/^[[:space:]]*#?[[:space:]]*PubkeyAuthentication/ { print "PubkeyAuthentication yes"; next }
/^[[:space:]]*#?[[:space:]]*PasswordAuthentication/ {
    if (!password_auth_set) { print "PasswordAuthentication no"; password_auth_set=1; next }
}
/^[[:space:]]*#?[[:space:]]*X11Forwarding/ { print "X11Forwarding no"; next }
{ print }
END {
    if (!port_set)          print "Port", new_port
    if (!password_auth_set) print "PasswordAuthentication no"
}
' "$MAIN_CONFIG" > "$TMP_FILE" && mv "$TMP_FILE" "$MAIN_CONFIG"

# Обработка дополнительных конфигов
if [ -d "$CONFIG_DIR" ]; then
    log_info "Обработка дополнительных конфигов в $CONFIG_DIR..."
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        if grep -Eq "^[[:space:]]*PasswordAuthentication" "$config_file"; then
            log_info "  -> Исправляем PasswordAuthentication в $config_file"
            sed -i "0,/^[[:space:]]*PasswordAuthentication .*/s//PasswordAuthentication no/" "$config_file"
        fi
    done
fi

# Проверка конфига и перезапуск SSH
log_info "Проверка конфигурации SSH..."
sshd -t || die "Ошибки в конфигурации SSH. Проверьте $MAIN_CONFIG вручную"
log_ok "Конфигурация SSH корректна"

restart_ssh
log_ok "SSH настроен на порту $NEW_PORT"

# ============================================================
#  10. Настройка UFW
# ============================================================
log_info "Настройка UFW..."

# Установка если отсутствует
if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
    apt install ufw -y || die "Ошибка при установке ufw"
    log_ok "UFW установлен"
else
    log_ok "UFW уже установлен"
fi

# Базовая политика: запретить все входящие, разрешить все исходящие
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
log_ok "Базовая политика UFW: входящие запрещены, исходящие разрешены"

# Правило для SSH — спрашиваем про белый IP
log_warn "Если у вас есть статический (белый) IP-адрес, SSH-доступ можно"
log_warn "ограничить только им — это значительно повысит безопасность"

UFW_SSH_MODE="any"
if ask_yn "Ограничить SSH-доступ только с вашего IP-адреса?"; then
    while true; do
        read -r -p "Введите ваш статический IP-адрес (например, 1.2.3.4 или 1.2.3.0/24): " WHITE_IP
        # Проверяем формат: IPv4-адрес или CIDR
        if [[ "$WHITE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
            ufw allow from "$WHITE_IP" to any port "$NEW_PORT" proto tcp \
                || die "Ошибка при добавлении правила UFW для белого IP"
            log_ok "SSH-доступ разрешён только с $WHITE_IP на порт $NEW_PORT/tcp"
            UFW_SSH_MODE="$WHITE_IP"
            break
        else
            log_error "Неверный формат IP-адреса. Введите корректный IPv4-адрес или CIDR (например, 1.2.3.4 или 1.2.3.0/24)"
        fi
    done
else
    ufw allow "$NEW_PORT"/tcp || die "Ошибка при добавлении правила UFW для SSH"
    log_ok "SSH-доступ разрешён с любого IP на порт $NEW_PORT/tcp"
fi

# Включаем UFW
ufw --force enable || die "Ошибка при включении UFW"
log_ok "UFW включён"

# ============================================================
#  11. Установка и настройка CrowdSec
# ============================================================
log_info "Установка CrowdSec..."

if command -v cscli &>/dev/null; then
    log_ok "CrowdSec уже установлен — пропускаем"
else
    # Сохраняем установщик во временный файл, чтобы корректно поймать ошибку curl
    # (в конструкции curl | sh код возврата curl теряется)
    CROWDSEC_INSTALLER=$(mktemp)
    curl -fsSL https://install.crowdsec.net -o "$CROWDSEC_INSTALLER" \
        || die "Не удалось загрузить установщик CrowdSec"
    sh "$CROWDSEC_INSTALLER" || die "Ошибка при выполнении установщика CrowdSec"
    rm -f "$CROWDSEC_INSTALLER"

    apt update
    apt install crowdsec -y || die "Ошибка при установке пакета crowdsec"
    log_ok "CrowdSec установлен"
fi

# Убеждаемся, что сервис запущен перед установкой боунсера
systemctl enable crowdsec --now || die "Не удалось запустить CrowdSec"
log_ok "Сервис CrowdSec запущен"

# Установка firewall-боунсера (iptables)
# dpkg-query надёжнее dpkg -l: не обрезает длинные имена пакетов
if dpkg-query -W -f='${Status}' crowdsec-firewall-bouncer-iptables 2>/dev/null \
        | grep -q "install ok installed"; then
    log_ok "crowdsec-firewall-bouncer-iptables уже установлен — пропускаем"
else
    apt install crowdsec-firewall-bouncer-iptables -y \
        || die "Ошибка при установке crowdsec-firewall-bouncer-iptables"
    log_ok "Firewall-боунсер CrowdSec установлен"
fi

systemctl enable crowdsec-firewall-bouncer --now \
    || die "Не удалось запустить crowdsec-firewall-bouncer"
log_ok "CrowdSec firewall-bouncer запущен"

# ============================================================
#  12. Автоматические обновления безопасности (unattended-upgrades)
# ============================================================
log_info "Настройка автоматических обновлений безопасности..."

if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null \
        | grep -q "install ok installed"; then
    apt install unattended-upgrades -y || die "Ошибка при установке unattended-upgrades"
    log_ok "unattended-upgrades установлен"
else
    log_ok "unattended-upgrades уже установлен — пропускаем установку"
fi

# 20auto-upgrades — записываем программно
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
log_ok "Файл 20auto-upgrades настроен"

# 50unattended-upgrades — правим три параметра через sed
# Используем точный паттерн окончания строки, чтобы Automatic-Reboot
# не перекрывался с Automatic-Reboot-Time
UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

# Remove-Unused-Dependencies
if grep -q "Unattended-Upgrade::Remove-Unused-Dependencies" "$UNATTENDED_CONF"; then
    sed -i 's|.*Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
        "$UNATTENDED_CONF"
else
    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' >> "$UNATTENDED_CONF"
fi

# Automatic-Reboot (точный паттерн — без подстроки -Time)
if grep -qE 'Unattended-Upgrade::Automatic-Reboot[[:space:]]*"' "$UNATTENDED_CONF"; then
    sed -i -E 's|.*Unattended-Upgrade::Automatic-Reboot[[:space:]]+".*";|Unattended-Upgrade::Automatic-Reboot "true";|' \
        "$UNATTENDED_CONF"
else
    echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "$UNATTENDED_CONF"
fi

# Automatic-Reboot-Time
if grep -q "Unattended-Upgrade::Automatic-Reboot-Time" "$UNATTENDED_CONF"; then
    sed -i 's|.*Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time "04:00";|' \
        "$UNATTENDED_CONF"
else
    echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> "$UNATTENDED_CONF"
fi

log_ok "Файл 50unattended-upgrades настроен"

systemctl enable unattended-upgrades --now
systemctl restart unattended-upgrades || die "Не удалось перезапустить unattended-upgrades"
log_ok "Сервис unattended-upgrades запущен и включён в автозапуск"

# ============================================================
#  Итоговая сводка
# ============================================================
echo
echo -e "${green}========================================"
echo -e "  ✅ Настройка сервера завершена!"
echo -e "========================================${plain}"
echo
echo -e "${yellow}📋 Итоговые параметры:${plain}"
echo -e "${blue}  Пользователь:        $username${plain}"
echo -e "${blue}  SSH порт:            $NEW_PORT/tcp${plain}"
if [[ "$UFW_SSH_MODE" == "any" ]]; then
    echo -e "${blue}  UFW SSH-доступ:      с любого IP${plain}"
else
    echo -e "${blue}  UFW SSH-доступ:      только с $UFW_SSH_MODE${plain}"
fi
echo -e "${blue}  CrowdSec:            активен${plain}"
echo -e "${blue}  Авто-обновления:     включены (перезагрузка в 04:00)${plain}"
echo
echo -e "${yellow}⚠️  Не закрывайте текущую сессию, пока не убедитесь,"
echo -e "    что можете подключиться с новыми параметрами!${plain}"
echo
