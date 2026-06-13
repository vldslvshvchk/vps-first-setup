#!/bin/bash
# ==============================================================================
#  Настройка Ubuntu-сервера
#  Поддерживаемые ОС: Ubuntu 22.04, Ubuntu 24.04
#
#  Шаги:
#   1.  Проверка прав root
#   2.  Определение ОС
#   3.  Таймзона
#   4.  Обновление системы
#   5.  Смена пароля root
#   6.  Создание нового пользователя
#   7.  Проверка ssh-keygen
#   8.  Настройка SSH-ключа
#   9.  Настройка SSH-демона
#   10. Настройка UFW
#   11. Настройка swap
#   12. Установка CrowdSec
#   13. Автообновления (unattended-upgrades)
#   14. [Опционально] sudo без пароля
# ==============================================================================

# --- Строгий режим ---
# -e         : выход при ошибке (кроме мест с явной обработкой кода возврата)
# -u         : выход при обращении к необъявленной переменной
# -o pipefail: ошибка в пайпе = ошибка всей команды
set -euo pipefail

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

# ask_yn: возвращает 0 при y, 1 при n.
# Явный return нужен чтобы set -e не прервал скрипт при ответе "n" (ненулевой код).
ask_yn() {
    echo -n "$1 (y/n): "
    local REPLY=''
    read -r -n 1 REPLY
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# set_password: устанавливает пароль с повтором при ошибке.
# passwd оборачиваем в if, а не && — чтобы set -e не сработал при ошибке ввода.
set_password() {
    local target_user="$1"
    log_warn "Установка пароля для пользователя: $target_user"
    while true; do
        if passwd "$target_user"; then
            log_ok "Пароль пользователя $target_user успешно установлен"
            break
        else
            log_error "Не удалось установить пароль. Попробуем ещё раз."
        fi
    done
}

# pkg_installed: проверяет установлен ли пакет через dpkg-query.
# Надёжнее dpkg -l: не обрезает длинные имена пакетов.
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# restart_ssh: перезапускает SSH с учётом наличия socket activation.
# Не полагаемся слепо на версию ОС — проверяем реальное состояние ssh.socket.
restart_ssh() {
    log_info "Перезапуск SSH-сервиса..."
    if systemctl is-enabled ssh.socket &>/dev/null; then
        # Socket activation активна: daemon-reload обязателен при смене порта
        systemctl daemon-reload
        systemctl restart ssh.socket ssh \
            || die "Ошибка при перезапуске SSH (socket activation)"
    else
        # Классический режим: пробуем sshd, затем ssh
        if ! systemctl restart sshd 2>/dev/null; then
            systemctl restart ssh \
                || die "Ошибка при перезапуске SSH"
        fi
    fi
    log_ok "SSH-сервис успешно перезапущен"
}

# cleanup_tmpfiles: удаляет временные файлы при выходе.
# Единый глобальный trap вместо множественных trap-/EXIT.
_TMPFILES=()
cleanup_tmpfiles() {
    local f
    for f in "${_TMPFILES[@]:-}"; do
        rm -f "$f"
    done
}
trap cleanup_tmpfiles EXIT

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

# shellcheck source=/dev/null
. /etc/os-release
OS_NAME="${NAME:-}"
OS_VERSION="${VERSION_ID:-}"
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
#  3. Таймзона
# ============================================================
TIMEZONE=$(timedatectl show -p Timezone --value)
log_info "Текущая таймзона: $TIMEZONE"

if ask_yn "Хотите изменить таймзону?"; then
    echo -e "${yellow}Введите таймзону в формате Region/City (например, Europe/Moscow, Asia/Yekaterinburg)${plain}"
    echo -e "${yellow}Полный список: timedatectl list-timezones${plain}"
    local_tz=''
    while true; do
        read -r -p "Таймзона: " local_tz
        if timedatectl list-timezones | grep -qx "$local_tz"; then
            timedatectl set-timezone "$local_tz"
            log_ok "Таймзона изменена на $local_tz"
            break
        else
            log_error "Неизвестная таймзона: $local_tz. Попробуйте снова."
            log_warn  "Подсказка: timedatectl list-timezones | grep -i <название>"
        fi
    done
else
    log_ok "Таймзона оставлена без изменений: $TIMEZONE"
fi

# ============================================================
#  4. Обновление системы
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
#  5. Смена пароля root
# ============================================================
set_password root

# ============================================================
#  6. Создание нового пользователя
# ============================================================
log_info "Создание нового пользователя"

username=''
while true; do
    read -r -p "Введите имя нового пользователя: " username
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        break
    else
        log_error "Недопустимое имя. Используйте строчные буквы, цифры, '-' или '_' (не более 32 символов)"
    fi
done

USER_IS_NEW=false
if id "$username" &>/dev/null; then
    log_warn "Пользователь $username уже существует — пропускаем создание и установку пароля"
else
    useradd -m -s /bin/bash "$username" || die "Ошибка при создании пользователя $username"
    log_ok "Пользователь $username успешно создан"
    USER_IS_NEW=true
fi

if [[ "$USER_IS_NEW" == true ]]; then
    set_password "$username"
fi

if groups "$username" | grep -q '\bsudo\b'; then
    log_ok "Пользователь $username уже в группе sudo"
else
    usermod -aG sudo "$username" \
        || die "Не удалось добавить пользователя $username в группу sudo"
    log_ok "Пользователь $username добавлен в группу sudo"
fi

# ============================================================
#  7. Проверка наличия ssh-keygen
# ============================================================
if ! command -v ssh-keygen &>/dev/null; then
    log_warn "ssh-keygen не найден — устанавливаем пакет openssh-client..."
    apt install openssh-client -y \
        || die "Не удалось установить openssh-client"
    log_ok "openssh-client установлен"
fi

# ============================================================
#  8. Настройка SSH-ключа для нового пользователя
# ============================================================
log_info "Настройка SSH для пользователя $username"

mkdir -p "/home/$username/.ssh"
chmod 700 "/home/$username/.ssh"
touch "/home/$username/.ssh/authorized_keys"
chmod 600 "/home/$username/.ssh/authorized_keys"
chown -R "$username":"$username" "/home/$username/.ssh"

log_warn "Введите SSH-ключ для пользователя $username"
echo -e "${yellow}Поддерживаются форматы:${plain}"
echo -e "${yellow}  - RSA:     ssh-rsa AAAAB3NzaC1yc2E...${plain}"
echo -e "${yellow}  - ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...${plain}"
echo -e "${yellow}  - ECDSA:   ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI...${plain}"

# Валидация через ssh-keygen — надёжнее regex: отклонит битый base64 и неверную длину.
# Файл регистрируем в глобальном cleanup-массиве — удалится при любом выходе.
SSH_KEY_TMP=$(mktemp /tmp/sshkey_validate.XXXXXX)
_TMPFILES+=("$SSH_KEY_TMP")

validate_ssh_key() {
    local key="$1"
    [[ -z "$key" ]] && return 1
    # printf надёжнее echo для строк начинающихся с '-'
    printf '%s\n' "$key" > "$SSH_KEY_TMP"
    ssh-keygen -l -f "$SSH_KEY_TMP" &>/dev/null
}

ssh_key=''
while true; do
    read -r -p "Введите SSH ключ: " ssh_key
    if validate_ssh_key "$ssh_key"; then
        # -qxF: точное совпадение строки целиком без интерпретации как regex.
        # Предотвращает дублирование при повторном запуске скрипта.
        if grep -qxF "$ssh_key" "/home/$username/.ssh/authorized_keys" 2>/dev/null; then
            log_warn "Этот SSH-ключ уже есть в authorized_keys — пропускаем добавление"
        else
            echo "$ssh_key" >> "/home/$username/.ssh/authorized_keys"
            log_ok "SSH-ключ успешно добавлен для пользователя $username"
        fi
        break
    else
        log_error "Ключ не прошёл проверку ssh-keygen. Убедитесь, что ключ скопирован полностью и без лишних символов."
    fi
done

# Проверяем что authorized_keys содержит валидный ключ после записи
log_info "Проверка authorized_keys..."
if ssh-keygen -l -f "/home/$username/.ssh/authorized_keys" &>/dev/null; then
    log_ok "authorized_keys содержит валидный ключ — проверка пройдена"
else
    log_warn "ssh-keygen не смог прочитать ключ из authorized_keys — проверьте файл вручную:"
    log_warn "  cat /home/$username/.ssh/authorized_keys"
fi

log_ok "Настройка SSH-ключа завершена"

# ============================================================
#  9. Настройка SSH-демона
# ============================================================
MAIN_CONFIG="/etc/ssh/sshd_config"
CONFIG_DIR="/etc/ssh/sshd_config.d"

log_warn "Сейчас будет предложено сменить SSH-порт"
echo -e "${yellow}Выбрать порт можно на сайте: https://www.shodan.io/search/facet?query=ssh&facet=port${plain}"

NEW_PORT=''
while true; do
    read -r -p "Введите номер порта SSH (1024–65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1024 && NEW_PORT <= 65535 )); then
        # Нативный фильтр ss по sport — точное совпадение, без ложных срабатываний на подстроки
        if ss -tlnH "( sport = :$NEW_PORT )" | grep -q .; then
            OCCUPANT=$(ss -tlnH "( sport = :$NEW_PORT )" | awk '{print $NF}')
            log_error "Порт $NEW_PORT уже занят: $OCCUPANT. Выберите другой."
        else
            log_info "Устанавливаю порт $NEW_PORT..."
            break
        fi
    else
        log_error "Неверный номер порта. Введите число от 1024 до 65535."
    fi
done

TMP_FILE=$(mktemp)
_TMPFILES+=("$TMP_FILE")
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
# После mv файл перемещён, удалять нечего — убираем из очереди
_TMPFILES=("${_TMPFILES[@]/$TMP_FILE}")

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

log_info "Проверка конфигурации SSH..."
sshd -t || die "Ошибки в конфигурации SSH. Проверьте $MAIN_CONFIG вручную"
log_ok "Конфигурация SSH корректна"

restart_ssh
log_ok "SSH настроен на порту $NEW_PORT"

# ============================================================
#  10. Настройка UFW
# ============================================================
log_info "Настройка UFW..."

if ! pkg_installed ufw; then
    apt install ufw -y || die "Ошибка при установке ufw"
    log_ok "UFW установлен"
else
    log_ok "UFW уже установлен"
fi

# Сбрасываем правила только если UFW ещё не активен —
# не затираем существующие правила при повторном запуске
if ! ufw status | grep -q "^Status: active"; then
    ufw --force reset
    log_info "Правила UFW сброшены (UFW не был активен)"
fi

ufw default deny incoming
ufw default allow outgoing
log_ok "Базовая политика UFW: входящие запрещены, исходящие разрешены"

# validate_ip: проверяет IPv4-адрес или CIDR с проверкой каждого октета
validate_ip() {
    local ip="${1%%/*}"
    local has_mask=false
    [[ "$1" == *"/"* ]] && has_mask=true
    local mask="${1#*/}"

    if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        return 1
    fi
    local IFS='.'
    local octets
    read -ra octets <<< "$ip"
    local octet
    for octet in "${octets[@]}"; do
        (( octet > 255 )) && return 1
    done
    if [[ "$has_mask" == true ]]; then
        [[ ! "$mask" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]] && return 1
    fi
    return 0
}

log_warn "Если у вас есть статический (белый) IP-адрес, SSH-доступ можно"
log_warn "ограничить только им — это значительно повысит безопасность"

UFW_SSH_MODE="any"
if ask_yn "Ограничить SSH-доступ только с вашего IP-адреса?"; then
    WHITE_IP=''
    while true; do
        read -r -p "Введите ваш статический IP-адрес (например, 1.2.3.4 или 1.2.3.0/24): " WHITE_IP
        if validate_ip "$WHITE_IP"; then
            ufw allow from "$WHITE_IP" to any port "$NEW_PORT" proto tcp \
                || die "Ошибка при добавлении правила UFW для белого IP"
            log_ok "SSH-доступ разрешён только с $WHITE_IP на порт $NEW_PORT/tcp"
            UFW_SSH_MODE="$WHITE_IP"
            break
        else
            log_error "Неверный IP-адрес. Введите корректный IPv4 или CIDR (например, 1.2.3.4 или 1.2.3.0/24)"
        fi
    done
else
    ufw allow "$NEW_PORT"/tcp || die "Ошибка при добавлении правила UFW для SSH"
    log_ok "SSH-доступ разрешён с любого IP на порт $NEW_PORT/tcp"
fi

ufw --force enable || die "Ошибка при включении UFW"
log_ok "UFW включён"

# ============================================================
#  11. Настройка swap
# ============================================================
log_info "Проверка swap..."

SWAP_TOTAL=$(swapon --show --noheadings 2>/dev/null | wc -l)
SWAP_ACTIVE=false

if (( SWAP_TOTAL > 0 )); then
    log_ok "Swap уже настроен:"
    swapon --show
    SWAP_ACTIVE=true
else
    log_warn "Swap не обнаружен"
    if ask_yn "Создать swap-файл?"; then
        SWAP_SIZE=''
        while true; do
            read -r -p "Введите размер swap (например, 1G, 2G, 512M): " SWAP_SIZE
            if [[ "$SWAP_SIZE" =~ ^[0-9]+[MGmg]$ ]]; then
                break
            else
                log_error "Неверный формат. Примеры: 512M, 1G, 2G"
            fi
        done

        SWAPFILE="/swapfile"

        # Конвертируем введённый размер в мегабайты для dd (bs=1M универсально)
        swap_num="${SWAP_SIZE%[MGmg]}"
        swap_unit="${SWAP_SIZE: -1}"
        swap_mb="$swap_num"
        if [[ "${swap_unit,,}" == "g" ]]; then
            swap_mb=$(( swap_num * 1024 ))
        fi

        # fallocate быстрее dd, но не работает на некоторых ФС (btrfs, tmpfs).
        # При ошибке автоматически падаем обратно на dd с bs=1M.
        if fallocate -l "${swap_mb}M" "$SWAPFILE" 2>/dev/null; then
            log_ok "Swap-файл создан через fallocate"
        else
            log_warn "fallocate недоступен или не поддерживается ФС — используем dd..."
            dd if=/dev/zero of="$SWAPFILE" bs=1M count="$swap_mb" status=progress \
                || die "Ошибка при создании swap-файла"
        fi

        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE"   || die "Ошибка при форматировании swap-файла"
        swapon "$SWAPFILE"   || die "Ошибка при подключении swap-файла"

        # Добавляем в /etc/fstab только если записи ещё нет
        if ! grep -qF "$SWAPFILE" /etc/fstab; then
            echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
            log_ok "Запись о swap добавлена в /etc/fstab (автомонтирование при перезагрузке)"
        else
            log_ok "Запись о swap уже есть в /etc/fstab"
        fi

        # Пересчитываем SWAP_TOTAL после создания — не полагаемся на старое значение
        SWAP_TOTAL=$(swapon --show --noheadings 2>/dev/null | wc -l)
        log_ok "Swap-файл $SWAPFILE ($SWAP_SIZE) создан и активирован"
        swapon --show
        SWAP_ACTIVE=true
    else
        log_warn "Создание swap пропущено"
    fi
fi

# ============================================================
#  12. Установка и настройка CrowdSec
# ============================================================
log_info "Установка CrowdSec..."

if command -v cscli &>/dev/null; then
    log_ok "CrowdSec уже установлен — пропускаем"
else
    # Скачиваем во временный файл — в конструкции curl | sh код возврата curl
    # теряется даже при pipefail, если sh завершился успешно.
    CROWDSEC_INSTALLER=$(mktemp)
    _TMPFILES+=("$CROWDSEC_INSTALLER")

    curl -fsSL https://install.crowdsec.net -o "$CROWDSEC_INSTALLER" \
        || die "Не удалось загрузить установщик CrowdSec"
    sh "$CROWDSEC_INSTALLER" \
        || die "Ошибка при выполнении установщика CrowdSec"

    apt update || die "Ошибка apt update после установки CrowdSec"
    apt install crowdsec -y || die "Ошибка при установке пакета crowdsec"
    log_ok "CrowdSec установлен"
fi

# Запускаем сервис до установки боунсера — боунсер регистрируется через LAPI
systemctl enable crowdsec --now || die "Не удалось запустить CrowdSec"
log_ok "Сервис CrowdSec запущен"

if pkg_installed crowdsec-firewall-bouncer-iptables; then
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
#  13. Автоматические обновления безопасности (unattended-upgrades)
# ============================================================
log_info "Настройка автоматических обновлений безопасности..."

if ! pkg_installed unattended-upgrades; then
    apt install unattended-upgrades -y || die "Ошибка при установке unattended-upgrades"
    log_ok "unattended-upgrades установлен"
else
    log_ok "unattended-upgrades уже установлен"
fi

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
log_ok "Файл 20auto-upgrades настроен"

UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

# Remove-Unused-Dependencies
if grep -q "Unattended-Upgrade::Remove-Unused-Dependencies" "$UNATTENDED_CONF"; then
    sed -i 's|.*Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
        "$UNATTENDED_CONF"
else
    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' >> "$UNATTENDED_CONF"
fi

# Automatic-Reboot — точный паттерн чтобы не задеть Automatic-Reboot-Time
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

systemctl enable unattended-upgrades --now \
    || die "Не удалось включить unattended-upgrades"
systemctl restart unattended-upgrades \
    || die "Не удалось перезапустить unattended-upgrades"
log_ok "Сервис unattended-upgrades запущен и включён в автозапуск"

# ============================================================
#  14. [Опционально] sudo без пароля
# ============================================================
log_warn "Некоторые сервисы (например, AmneziaVPN) требуют возможности выполнять"
log_warn "sudo-команды без ввода пароля при подключении по SSH-ключу."

if ask_yn "Разрешить $username выполнять sudo без пароля?"; then
    SUDOERS_FILE="/etc/sudoers.d/$username"

    # Формируем правило
    SUDOERS_LINE="$username ALL=(ALL) NOPASSWD:ALL"

    # Записываем во временный файл и проверяем через visudo -c ДО активации.
    # Битый sudoers-файл заблокирует sudo полностью — это критично.
    SUDOERS_TMP=$(mktemp)
    _TMPFILES+=("$SUDOERS_TMP")
    echo "$SUDOERS_LINE" > "$SUDOERS_TMP"

    if visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
        # Файл корректен — копируем на место с правильными правами
        cp "$SUDOERS_TMP" "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        log_ok "Файл $SUDOERS_FILE создан, sudo без пароля для $username активировано"
        log_warn "Рекомендация: отключите эту опцию, если она не нужна постоянно"
    else
        log_error "visudo не принял сгенерированный файл — sudo без пароля не настроено"
        log_warn  "Проверьте правило вручную: $SUDOERS_LINE"
    fi
else
    log_ok "sudo без пароля не настраивается"
fi

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
if [[ "$SWAP_ACTIVE" == true ]]; then
    echo -e "${blue}  Swap:                активен${plain}"
else
    echo -e "${blue}  Swap:                не настроен${plain}"
fi
echo -e "${blue}  CrowdSec:            активен${plain}"
echo -e "${blue}  Авто-обновления:     включены (перезагрузка в 04:00)${plain}"
echo
echo -e "${yellow}⚠️  Не закрывайте текущую сессию, пока не убедитесь,"
echo -e "    что можете подключиться с новыми параметрами!${plain}"
echo
