#!/bin/bash
# ==============================================================================
#  Настройка Ubuntu-сервера после первичного развёртывания
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

set -euo pipefail

# Подавляем интерактивные диалоги apt (tzdata, postfix и т.п.)
export DEBIAN_FRONTEND=noninteractive

# ============================================================
#  Цвета и базовые утилиты вывода
# ============================================================
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
cyan='\033[0;36m'
bold='\033[1m'
plain='\033[0m'

TOTAL_STEPS=14
CURRENT_STEP=0
CURRENT_STEP_NAME="инициализация"

log_info()  { echo -e "${blue}   ➜  $*${plain}"; }
log_ok()    { echo -e "${green}   ✓  $*${plain}"; }
log_warn()  { echo -e "${yellow}   ⚠  $*${plain}"; }
log_error() { echo -e "${red}   ✗  $*${plain}"; }
log_step()  { echo -e "${cyan}   •  $*${plain}"; }

# section: визуальный разделитель шага с номером и названием.
# Не используем printf %-Ns для выравнивания: при кириллице (2 байта/символ)
# ширина считается в БАЙТАХ, а не символах — рамка перестаёт совпадать
# по краям и "ломается" на длинных названиях. Поэтому строка простая,
# без зависимости от длины текста.
section() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    CURRENT_STEP_NAME="$*"
    echo
    echo -e "${bold}${blue}═══ Шаг $CURRENT_STEP/$TOTAL_STEPS ═══ $* ═══════════════════════${plain}"
}

# die: завершение с ошибкой, контекстной подсказкой и инструкцией для повтора
die() {
    local message="$1"
    local hint="${2:-}"
    echo
    echo -e "${red}${bold}══════════════════════════════════════════════════════${plain}"
    log_error "ОШИБКА на шаге $CURRENT_STEP: $CURRENT_STEP_NAME"
    log_error "$message"
    if [[ -n "$hint" ]]; then
        echo
        echo -e "${yellow}${bold}  Что делать перед повторным запуском:${plain}"
        echo -e "${yellow}$hint${plain}"
    fi
    echo
    echo -e "${yellow}  Повторный запуск: sudo bash $(realpath "$0")${plain}"
    echo -e "${red}${bold}══════════════════════════════════════════════════════${plain}"
    echo
    exit 1
}

# ============================================================
#  Вспомогательные функции
# ============================================================

# ask_yn: возвращает 0 при y, 1 при n.
# Явный return нужен чтобы set -e не прервал скрипт при ответе "n".
ask_yn() {
    echo -ne "${yellow}  ?  $1 (y/n): ${plain}"
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
# passwd оборачиваем в if — чтобы set -e не сработал при ошибке ввода.
set_password() {
    local target_user="$1"
    log_info "Установка пароля для пользователя: ${bold}$target_user${plain}"
    while true; do
        if passwd "$target_user"; then
            log_ok "Пароль пользователя $target_user установлен"
            break
        else
            log_error "Не удалось установить пароль — попробуем ещё раз"
        fi
    done
}

# pkg_installed: проверяет установлен ли пакет через dpkg-query.
# Надёжнее dpkg -l: не обрезает длинные имена пакетов.
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# user_in_group: проверяет членство пользователя в группе.
# Надёжнее groups | grep: читает через id, сравнивает строку целиком (-x).
user_in_group() {
    id -nG "$1" | tr ' ' '\n' | grep -qx "$2"
}

# restart_ssh: применяет новый sshd_config и перезапускает SSH.
#
# ВАЖНО про Ubuntu 24.04+: по умолчанию SSH работает через socket activation
# (юнит ssh.socket). В этом режиме порт, который реально слушает systemd,
# берётся из директивы ListenStream= в ssh.socket, а директива Port в
# sshd_config ПОЛНОСТЬЮ ИГНОРИРУЕТСЯ. Если просто перезапустить
# "ssh.socket ssh", сервер продолжит слушать порт 22, при этом UFW будет
# разрешать только новый порт — пользователь окажется заблокирован.
#
# Поэтому при обнаружении ssh.socket мы отключаем socket activation и
# переходим на классический сервис ssh.service (как в Ubuntu 22.04) —
# тогда Port из sshd_config становится единственным источником правды.
restart_ssh() {
    if systemctl is-enabled ssh.socket &>/dev/null; then
        log_info "Обнаружена socket activation (ssh.socket)"
        log_info "Порт из sshd_config игнорируется в этом режиме — переключаемся на ssh.service"
        systemctl disable --now ssh.socket || die \
            "Не удалось отключить ssh.socket" \
            "  systemctl status ssh.socket
  systemctl disable --now ssh.socket"
        systemctl daemon-reload
        log_ok "ssh.socket отключён — Port из sshd_config теперь применяется"
    fi

    log_info "Перезапуск SSH-сервиса..."
    # enable создаёт автозапуск на будущие перезагрузки. Идемпотентно:
    # если уже включён — просто ничего не меняет.
    systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null || true

    # restart применяет новый конфиг независимо от текущего состояния сервиса
    # (даже если он был неактивен — restart его запустит).
    if ! systemctl restart ssh.service 2>/dev/null; then
        systemctl restart sshd.service || die \
            "Не удалось перезапустить SSH-сервис" \
            "  journalctl -u ssh --no-pager -n 30
  systemctl status ssh"
    fi
    log_ok "SSH-сервис перезапущен и включён в автозагрузку"
}

# check_internet: проверяет доступность интернета перед сетевыми операциями
check_internet() {
    log_info "Проверка подключения к интернету..."
    if ! curl -fsSL --max-time 5 https://1.1.1.1 &>/dev/null \
        && ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        die \
            "Нет подключения к интернету" \
            "  Проверьте сетевые настройки сервера:
  ip a
  ip route
  ping 8.8.8.8
  cat /etc/resolv.conf"
    fi
    log_ok "Интернет доступен"
}

# ============================================================
#  Управление временными файлами
# ============================================================
# Единый глобальный trap — множественные trap EXIT перезаписывают друг друга.
_TMPFILES=()
cleanup_tmpfiles() {
    local f
    [ "${#_TMPFILES[@]}" -eq 0 ] && return 0
    for f in "${_TMPFILES[@]}"; do
        rm -f "$f"
    done
}
trap cleanup_tmpfiles EXIT

# tmpfile_remove: немедленно удалить файл и убрать из очереди cleanup.
# Удаление по точному совпадению индекса (не подстроки) — единственный надёжный способ.
tmpfile_remove() {
    local target="$1"
    rm -f "$target"
    local i
    for i in "${!_TMPFILES[@]}"; do
        [[ "${_TMPFILES[$i]}" == "$target" ]] && unset '_TMPFILES[i]'
    done
}

# ============================================================
#  1. Проверка прав root
# ============================================================
section "Проверка прав root"

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}${bold}"
    echo "  Скрипт должен быть запущен с правами root."
    echo "  Выполните: sudo -i"
    echo "  Затем запустите скрипт повторно."
    echo -e "${plain}"
    exit 1
fi
log_ok "Запущен от root"

# ============================================================
#  2. Определение операционной системы
# ============================================================
section "Определение ОС"

[ -f /etc/os-release ] || die \
    "Файл /etc/os-release не найден — невозможно определить ОС" \
    "  Поддерживаются только Ubuntu 22.04 и 24.04"

# shellcheck source=/dev/null
. /etc/os-release
OS_NAME="${NAME:-}"
OS_VERSION="${VERSION_ID:-}"
log_step "Обнаружена ОС: ${bold}$OS_NAME $OS_VERSION${plain}"

if [[ "$OS_NAME" == *"Ubuntu"* ]] && [[ "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]]; then
    log_ok "Ubuntu $OS_VERSION поддерживается"
elif [[ "$OS_NAME" == *"Debian"* ]]; then
    die "Debian не поддерживается. Скрипт тестировался только на Ubuntu 22.04 и 24.04"
else
    die "ОС не поддерживается: $OS_NAME $OS_VERSION" \
        "  Установите Ubuntu 22.04 или 24.04 и запустите скрипт заново"
fi

# ============================================================
#  3. Таймзона
# ============================================================
section "Таймзона"

TIMEZONE=$(timedatectl show -p Timezone --value)
log_step "Текущая таймзона: ${bold}$TIMEZONE${plain}"

if ask_yn "Хотите изменить таймзону?"; then
    log_info "Полный список: timedatectl list-timezones"
    log_info "Пример поиска: timedatectl list-timezones | grep -i moscow"
    local_tz=''
    while true; do
        read -r -p "  Введите таймзону (Region/City): " local_tz
        if timedatectl list-timezones | grep -qx "$local_tz"; then
            timedatectl set-timezone "$local_tz"
            log_ok "Таймзона установлена: $local_tz"
            break
        else
            log_error "Неизвестная таймзона: '$local_tz' — попробуйте снова"
        fi
    done
else
    log_ok "Таймзона оставлена: $TIMEZONE"
fi

# ============================================================
#  4. Обновление системы
# ============================================================
section "Обновление системы"

UPDATE_MARKER="/root/.setup_system_updated"

if [ -f "$UPDATE_MARKER" ]; then
    log_ok "Система уже была обновлена (маркер найден) — пропускаем"
else
    check_internet
    log_info "Обновление списка пакетов..."
    apt-get update -q || die \
        "Ошибка при apt-get update" \
        "  1. Проверьте интернет: ping 8.8.8.8
  2. Проверьте sources.list: cat /etc/apt/sources.list
  3. Исправьте повреждённые пакеты: dpkg --configure -a
  4. Удалите маркер если он остался: rm -f $UPDATE_MARKER"

    log_info "Установка обновлений (это может занять несколько минут)..."
    # --force-confdef/--force-confold: если обновление пакета (например,
    # openssh-server) принесёт новый конфиг-файл — dpkg НЕ будет спрашивать
    # что делать (это могло бы "подвесить" неинтерактивный скрипт), а
    # автоматически оставит текущую версию файла.
    apt-get upgrade -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        || die \
        "Ошибка при apt-get upgrade" \
        "  1. Исправьте повреждённые зависимости: apt-get install -f
  2. Исправьте незавершённые установки: dpkg --configure -a
  3. Повторите обновление вручную: apt-get upgrade -y"

    touch "$UPDATE_MARKER"
    log_ok "Система успешно обновлена"

    log_warn "Рекомендуется перезагрузка (особенно если обновлялось ядро)"
    if ask_yn "Перезагрузить сервер сейчас?"; then
        log_ok "Перезагрузка..."
        log_warn "После перезагрузки запустите скрипт повторно — он продолжит со следующего шага"
        reboot
        exit 0
    else
        log_warn "Перезагрузка отложена — рекомендуется перезагрузить вручную до продолжения"
    fi
fi

# ============================================================
#  5. Смена пароля root
# ============================================================
section "Смена пароля root"
set_password root

# ============================================================
#  6. Создание нового пользователя
# ============================================================
section "Создание нового пользователя"

username=''
while true; do
    read -r -p "  Имя пользователя: " username
    if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        break
    else
        log_error "Недопустимое имя. Строчные буквы, цифры, '-' или '_', до 32 символов"
    fi
done

USER_IS_NEW=false
if id "$username" &>/dev/null; then
    log_warn "Пользователь ${bold}$username${plain} уже существует — пропускаем создание"
else
    useradd -m -s /bin/bash "$username" || die \
        "Не удалось создать пользователя $username" \
        "  Проверьте вручную: cat /etc/passwd | grep $username
  Если пользователь повреждён: userdel -r $username"
    log_ok "Пользователь $username создан"
    USER_IS_NEW=true
fi

# Пароль устанавливаем только для нового пользователя
if [[ "$USER_IS_NEW" == true ]]; then
    set_password "$username"
fi

if user_in_group "$username" sudo; then
    log_ok "$username уже в группе sudo"
else
    usermod -aG sudo "$username" || die \
        "Не удалось добавить $username в группу sudo" \
        "  Выполните вручную: usermod -aG sudo $username"
    log_ok "$username добавлен в группу sudo"
fi

# ============================================================
#  7. Проверка наличия ssh-keygen
# ============================================================
section "Проверка ssh-keygen"

if ! command -v ssh-keygen &>/dev/null; then
    log_warn "ssh-keygen не найден — устанавливаем openssh-client..."
    apt-get install -y -q openssh-client || die \
        "Не удалось установить openssh-client" \
        "  apt-get install -y openssh-client"
    log_ok "openssh-client установлен"
else
    log_ok "ssh-keygen доступен: $(command -v ssh-keygen)"
fi

# ============================================================
#  8. Настройка SSH-ключа
# ============================================================
section "Настройка SSH-ключа"

SSH_DIR="/home/$username/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R "$username":"$username" "$SSH_DIR"

# Показываем уже добавленные ключи если есть — полезно при повторном запуске
EXISTING_KEYS=0
if [[ -s "$AUTH_KEYS" ]]; then
    EXISTING_KEYS=$(ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | wc -l || echo 0)
    if (( EXISTING_KEYS > 0 )); then
        log_warn "В authorized_keys уже есть ключей: $EXISTING_KEYS"
        log_step "Текущие ключи:"
        ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | while read -r line; do
            log_step "  $line"
        done
    fi
fi

log_info "Поддерживаемые форматы ключей:"
log_step "RSA:     ssh-rsa AAAAB3NzaC1yc2E..."
log_step "ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...  (рекомендуется)"
log_step "ECDSA:   ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI..."

# Валидация через ssh-keygen — надёжнее regex.
# Временный файл в _TMPFILES — удалится при любом выходе.
SSH_KEY_TMP=$(mktemp /tmp/sshkey_validate.XXXXXX)
_TMPFILES+=("$SSH_KEY_TMP")

validate_ssh_key() {
    local key="$1"
    [[ -z "$key" ]] && return 1
    printf '%s\n' "$key" > "$SSH_KEY_TMP"
    ssh-keygen -l -f "$SSH_KEY_TMP" &>/dev/null
}

ssh_key=''
while true; do
    read -r -p "  Введите SSH-ключ: " ssh_key
    if validate_ssh_key "$ssh_key"; then
        if grep -qxF "$ssh_key" "$AUTH_KEYS" 2>/dev/null; then
            log_warn "Этот ключ уже есть в authorized_keys — пропускаем"
        else
            echo "$ssh_key" >> "$AUTH_KEYS"
            log_ok "SSH-ключ добавлен"
        fi
        break
    else
        log_error "Ключ не прошёл проверку ssh-keygen — скопируйте его полностью, без переносов строк"
    fi
done

# Финальная проверка файла
if ssh-keygen -l -f "$AUTH_KEYS" &>/dev/null; then
    KEY_COUNT=$(ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | wc -l)
    log_ok "authorized_keys валиден, ключей: $KEY_COUNT"
else
    log_warn "Не удалось прочитать authorized_keys — проверьте вручную: cat $AUTH_KEYS"
fi

# ============================================================
#  9. Настройка SSH-демона
# ============================================================
section "Настройка SSH-демона"

MAIN_CONFIG="/etc/ssh/sshd_config"
CONFIG_DIR="/etc/ssh/sshd_config.d"
MAIN_CONFIG_BACKUP="${MAIN_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

# Показываем текущий порт SSH чтобы пользователь не запутался
CURRENT_SSH_PORT=$(ss -tlnH "( sport = :22 )" | grep -q . && echo "22" \
    || grep -E "^Port " "$MAIN_CONFIG" 2>/dev/null | awk '{print $2}' || echo "неизвестен")
log_step "Текущий SSH-порт: ${bold}$CURRENT_SSH_PORT${plain}"
log_step "Подобрать незанятый порт: https://www.shodan.io/search/facet?query=ssh&facet=port"

NEW_PORT=''
while true; do
    read -r -p "  Введите новый порт SSH (1024–65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1024 && NEW_PORT <= 65535 )); then
        # Если пользователь оставляет ТЕКУЩИЙ SSH-порт (например, повторный
        # запуск после ошибки на более позднем шаге) — пропускаем проверку
        # занятости: порт "занят" самим sshd, и это ожидаемо и нормально.
        if [[ "$NEW_PORT" == "$CURRENT_SSH_PORT" ]]; then
            log_info "Порт $NEW_PORT совпадает с текущим SSH-портом — оставляем без изменений"
            break
        fi
        if ss -tlnH "( sport = :$NEW_PORT )" | grep -q .; then
            OCCUPANT=$(ss -tlnH "( sport = :$NEW_PORT )" | awk '{print $NF}')
            log_error "Порт $NEW_PORT занят: $OCCUPANT — выберите другой"
        else
            log_info "Буду использовать порт $NEW_PORT"
            break
        fi
    else
        log_error "Неверный порт — введите число от 1024 до 65535"
    fi
done

# Бэкап оригинального конфига перед любыми изменениями
cp "$MAIN_CONFIG" "$MAIN_CONFIG_BACKUP"
log_ok "Бэкап сохранён: $MAIN_CONFIG_BACKUP"

# Редактируем через временный файл.
# cp вместо mv — работает между разными ФС (/tmp на tmpfs, /etc на rootfs).
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
' "$MAIN_CONFIG" > "$TMP_FILE" \
    && cp "$TMP_FILE" "$MAIN_CONFIG" \
    || die \
        "Ошибка при обновлении $MAIN_CONFIG" \
        "  Оригинал сохранён в: $MAIN_CONFIG_BACKUP
  Восстановить: cp $MAIN_CONFIG_BACKUP $MAIN_CONFIG"

tmpfile_remove "$TMP_FILE"

# Обработка дополнительных конфигов в sshd_config.d/
if [ -d "$CONFIG_DIR" ]; then
    log_info "Проверка дополнительных конфигов в $CONFIG_DIR..."
    for config_file in "$CONFIG_DIR"/*.conf; do
        [ -f "$config_file" ] || continue
        if grep -Eq "^[[:space:]]*PasswordAuthentication" "$config_file"; then
            log_info "  → Исправляем PasswordAuthentication в $(basename "$config_file")"
            sed -i "0,/^[[:space:]]*PasswordAuthentication .*/s//PasswordAuthentication no/" \
                "$config_file"
        fi
    done
fi

# Валидация конфига — при ошибке восстанавливаем бэкап автоматически
log_info "Проверка конфигурации sshd..."
if ! sshd -t 2>&1; then
    log_error "Конфигурация SSH содержит ошибки — восстанавливаем бэкап..."
    cp "$MAIN_CONFIG_BACKUP" "$MAIN_CONFIG"
    die \
        "sshd -t обнаружил ошибки. Конфиг восстановлен из бэкапа." \
        "  Бэкап: $MAIN_CONFIG_BACKUP
  Текущий конфиг восстановлен автоматически.
  Проверьте вручную: sshd -t
  Логи: journalctl -u ssh --no-pager -n 20"
fi
log_ok "Конфигурация SSH корректна"

echo
log_warn "════════════════════════════════════════════════════════"
log_warn "  ВАЖНО: сейчас изменится SSH-порт и режим работы службы."
log_warn "  НЕ закрывайте текущую сессию!"
log_warn "  После перезапуска откройте НОВОЕ окно и проверьте:"
log_warn "    ssh $username@<IP-сервера> -p $NEW_PORT"
log_warn "  Закрывайте текущую сессию только после успешного входа."
log_warn "════════════════════════════════════════════════════════"
echo

restart_ssh
log_ok "SSH работает на порту ${bold}$NEW_PORT${plain}"

# ============================================================
#  10. Настройка UFW
# ============================================================
section "Настройка UFW"

if ! pkg_installed ufw; then
    apt-get install -y -q ufw || die \
        "Не удалось установить ufw" \
        "  apt-get install -y ufw"
    log_ok "UFW установлен"
else
    log_ok "UFW уже установлен"
fi

# validate_ip: проверяет IPv4-адрес или CIDR с проверкой каждого октета
validate_ip() {
    local input="$1"
    [[ -z "$input" || "$input" == "/" ]] && return 1

    local ip="${input%%/*}"
    local has_mask=false
    [[ "$input" == *"/"* ]] && has_mask=true
    local mask="${input#*/}"

    [[ -z "$ip" ]] && return 1
    [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && return 1

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

# Сбрасываем правила только если UFW ещё не активен
if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw --force reset
    log_info "Правила UFW сброшены (UFW не был активен)"
fi

ufw default deny incoming
ufw default allow outgoing
log_ok "Политика: входящие запрещены, исходящие разрешены"

log_warn "Статический (белый) IP повысит безопасность — SSH будет доступен только с него"
UFW_SSH_MODE="any"
if ask_yn "Ограничить SSH только с вашего IP?"; then
    WHITE_IP=''
    while true; do
        read -r -p "  Ваш IP-адрес (например, 1.2.3.4 или 1.2.3.0/24): " WHITE_IP
        if validate_ip "$WHITE_IP"; then
            ufw allow from "$WHITE_IP" to any port "$NEW_PORT" proto tcp || die \
                "Ошибка при добавлении правила UFW" \
                "  ufw allow from $WHITE_IP to any port $NEW_PORT proto tcp"
            log_ok "SSH разрешён только с $WHITE_IP → порт $NEW_PORT/tcp"
            UFW_SSH_MODE="$WHITE_IP"
            break
        else
            log_error "Неверный IP — введите корректный IPv4 или CIDR (1.2.3.4 или 1.2.3.0/24)"
        fi
    done
else
    ufw allow "$NEW_PORT"/tcp || die \
        "Ошибка при добавлении правила UFW для SSH" \
        "  ufw allow $NEW_PORT/tcp"
    log_ok "SSH разрешён с любого IP → порт $NEW_PORT/tcp"
fi

log_warn "Включаем файрвол — держите текущую сессию открытой на случай ошибки"
ufw --force enable || die \
    "Не удалось включить UFW" \
    "  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow $NEW_PORT/tcp
  ufw --force enable"
log_ok "UFW включён"

# ============================================================
#  11. Настройка swap
# ============================================================
section "Настройка swap"

SWAP_TOTAL=$(swapon --show --noheadings 2>/dev/null | wc -l)
SWAP_ACTIVE=false

if (( SWAP_TOTAL > 0 )); then
    log_ok "Swap уже настроен:"
    swapon --show | while read -r line; do log_step "$line"; done
    SWAP_ACTIVE=true
else
    log_warn "Swap не обнаружен"
    if ask_yn "Создать swap-файл?"; then
        SWAP_SIZE=''
        while true; do
            read -r -p "  Размер swap (например, 1G, 2G, 512M): " SWAP_SIZE
            if [[ "$SWAP_SIZE" =~ ^[0-9]+[MGmg]$ ]]; then
                break
            else
                log_error "Неверный формат — примеры: 512M, 1G, 2G"
            fi
        done

        SWAPFILE="/swapfile"

        # Если файл уже существует (незавершённый предыдущий запуск) — убираем его
        if [ -f "$SWAPFILE" ]; then
            log_warn "Найден существующий $SWAPFILE — удаляем (незавершённый предыдущий запуск)"
            swapoff "$SWAPFILE" 2>/dev/null || true
            rm -f "$SWAPFILE"
        fi

        # Конвертируем в мегабайты для dd (bs=1M универсально для всех версий dd)
        swap_num="${SWAP_SIZE%[MGmg]}"
        swap_unit="${SWAP_SIZE: -1}"
        swap_mb="$swap_num"
        if [[ "${swap_unit,,}" == "g" ]]; then
            swap_mb=$(( swap_num * 1024 ))
        fi

        # fallocate быстрее dd, но не работает на btrfs/tmpfs/NFS
        if fallocate -l "${swap_mb}M" "$SWAPFILE" 2>/dev/null; then
            log_ok "Swap-файл создан через fallocate"
        else
            log_warn "fallocate не поддерживается ФС — используем dd (медленнее)..."
            dd if=/dev/zero of="$SWAPFILE" bs=1M count="$swap_mb" status=progress \
                || die \
                    "Ошибка при создании swap-файла" \
                    "  Проверьте свободное место: df -h
  Удалите незавершённый файл: rm -f $SWAPFILE"
        fi

        chmod 600 "$SWAPFILE"
        mkswap "$SWAPFILE" || die "Ошибка при форматировании swap" "  mkswap $SWAPFILE"
        swapon "$SWAPFILE" || die "Ошибка при подключении swap" "  swapon $SWAPFILE"

        # Добавляем в fstab только если записи ещё нет
        # "defaults" вместо устаревшего "sw" (BSD-флаг, не нужен в Linux)
        if ! grep -qF "$SWAPFILE" /etc/fstab; then
            echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
            log_ok "Запись добавлена в /etc/fstab — swap подключится автоматически после перезагрузки"
        else
            log_ok "Запись о swap уже есть в /etc/fstab"
        fi

        # Пересчитываем — не полагаемся на старое значение 0
        SWAP_TOTAL=$(swapon --show --noheadings 2>/dev/null | wc -l)
        log_ok "Swap $SWAP_SIZE активирован:"
        swapon --show | while read -r line; do log_step "$line"; done
        SWAP_ACTIVE=true
    else
        log_warn "Создание swap пропущено"
    fi
fi

# ============================================================
#  12. Установка CrowdSec
# ============================================================
section "Установка CrowdSec"

if command -v cscli &>/dev/null; then
    log_ok "CrowdSec уже установлен — пропускаем"
else
    check_internet

    # Скачиваем во временный файл — в curl | sh код возврата curl
    # теряется даже при pipefail если sh завершился успешно
    CROWDSEC_INSTALLER=$(mktemp)
    _TMPFILES+=("$CROWDSEC_INSTALLER")

    log_info "Загрузка установщика CrowdSec..."
    curl -fsSL https://install.crowdsec.net -o "$CROWDSEC_INSTALLER" || die \
        "Не удалось загрузить установщик CrowdSec" \
        "  Проверьте интернет: ping 8.8.8.8
  Или установите вручную: https://docs.crowdsec.net/docs/getting_started/install_crowdsec/"

    log_info "Запуск установщика CrowdSec..."
    sh "$CROWDSEC_INSTALLER" || die \
        "Ошибка установщика CrowdSec" \
        "  Попробуйте установить вручную:
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
  apt-get install crowdsec"

    log_info "Установка пакета crowdsec..."
    apt-get update -q || die "Ошибка apt-get update" "  apt-get update"
    apt-get install -y -q crowdsec || die \
        "Ошибка при установке crowdsec" \
        "  apt-get install -f
  dpkg --configure -a
  apt-get install -y crowdsec"
    log_ok "CrowdSec установлен"
fi

# Запускаем до установки боунсера — боунсер регистрируется через LAPI
systemctl enable crowdsec --now || die \
    "Не удалось запустить CrowdSec" \
    "  journalctl -u crowdsec --no-pager -n 30
  systemctl status crowdsec"
log_ok "Сервис CrowdSec запущен"

if pkg_installed crowdsec-firewall-bouncer-iptables; then
    log_ok "crowdsec-firewall-bouncer-iptables уже установлен — пропускаем"
else
    log_info "Установка firewall-боунсера..."
    apt-get install -y -q crowdsec-firewall-bouncer-iptables || die \
        "Ошибка при установке crowdsec-firewall-bouncer-iptables" \
        "  apt-get install -y crowdsec-firewall-bouncer-iptables"
    log_ok "Firewall-боунсер установлен"
fi

systemctl enable crowdsec-firewall-bouncer --now || die \
    "Не удалось запустить crowdsec-firewall-bouncer" \
    "  journalctl -u crowdsec-firewall-bouncer --no-pager -n 30"
log_ok "CrowdSec firewall-bouncer запущен"

# ============================================================
#  13. Автообновления (unattended-upgrades)
# ============================================================
section "Автоматические обновления безопасности"

if ! pkg_installed unattended-upgrades; then
    apt-get install -y -q unattended-upgrades || die \
        "Ошибка при установке unattended-upgrades" \
        "  apt-get install -y unattended-upgrades"
    log_ok "unattended-upgrades установлен"
else
    log_ok "unattended-upgrades уже установлен"
fi

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
log_ok "20auto-upgrades настроен"

UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

# Функция для правки параметра в 50unattended-upgrades:
# если строка есть (в т.ч. закомментированная) — заменяем; нет — дописываем.
set_unattended_param() {
    local pattern="$1"
    local replacement="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        sed -i -E "s|$pattern|$replacement|" "$file"
    else
        echo "$replacement" >> "$file"
    fi
}

set_unattended_param \
    '.*Unattended-Upgrade::Remove-Unused-Dependencies.*' \
    'Unattended-Upgrade::Remove-Unused-Dependencies "true";' \
    "$UNATTENDED_CONF"

# Точный паттерн для Automatic-Reboot — не задевает Automatic-Reboot-Time
set_unattended_param \
    '.*Unattended-Upgrade::Automatic-Reboot[[:space:]]+".*".*;' \
    'Unattended-Upgrade::Automatic-Reboot "true";' \
    "$UNATTENDED_CONF"

set_unattended_param \
    '.*Unattended-Upgrade::Automatic-Reboot-Time.*' \
    'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' \
    "$UNATTENDED_CONF"

log_ok "50unattended-upgrades настроен (авторестарт в 04:00)"

systemctl enable unattended-upgrades --now || die \
    "Не удалось включить unattended-upgrades" \
    "  systemctl enable unattended-upgrades --now"
# reload-or-restart: перечитает конфиг если сервис уже работал, иначе запустит
systemctl reload-or-restart unattended-upgrades || die \
    "Не удалось перезапустить unattended-upgrades" \
    "  systemctl restart unattended-upgrades"
log_ok "unattended-upgrades запущен"

# ============================================================
#  14. [Опционально] sudo без пароля
# ============================================================
section "sudo без пароля (опционально)"

log_warn "Некоторые сервисы (например, AmneziaVPN) требуют sudo без пароля"
log_warn "при подключении по SSH-ключу."

NOPASSWD_ACTIVE=false
SUDOERS_FILE="/etc/sudoers.d/$username"

if [ -f "$SUDOERS_FILE" ]; then
    log_ok "Файл $SUDOERS_FILE уже существует — пропускаем"
    NOPASSWD_ACTIVE=true
elif ask_yn "Разрешить $username выполнять sudo без пароля?"; then
    SUDOERS_LINE="$username ALL=(ALL) NOPASSWD:ALL"

    # Проверяем через visudo -c ДО записи — битый sudoers заблокирует sudo полностью
    SUDOERS_TMP=$(mktemp)
    _TMPFILES+=("$SUDOERS_TMP")
    echo "$SUDOERS_LINE" > "$SUDOERS_TMP"

    if visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
        cp "$SUDOERS_TMP" "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        log_ok "sudo без пароля активировано: $SUDOERS_FILE"
        log_warn "Отключить при необходимости: rm $SUDOERS_FILE"
        NOPASSWD_ACTIVE=true
    else
        die \
            "visudo отклонил сгенерированное правило" \
            "  Добавьте вручную: echo '$SUDOERS_LINE' | visudo -c -f /dev/stdin
  Или: echo '$SUDOERS_LINE' > $SUDOERS_FILE && chmod 0440 $SUDOERS_FILE"
    fi
else
    log_ok "sudo без пароля не настраивается"
fi

# ============================================================
#  Удаление маркера обновления
# ============================================================
# Скрипт успешно завершил все шаги — маркер больше не нужен.
# При следующем запуске система будет обновлена заново (apt-get upgrade идемпотентен).
if [ -f "$UPDATE_MARKER" ]; then
    rm -f "$UPDATE_MARKER"
    log_ok "Маркер обновления удалён"
fi

# ============================================================
#  Итоговая сводка
# ============================================================
echo
echo -e "${bold}${green}╔══════════════════════════════════════════════════════╗"
echo -e "║          ✅  Настройка сервера завершена!           ║"
echo -e "╚══════════════════════════════════════════════════════╝${plain}"
echo
echo -e "${bold}${yellow}  Параметры подключения:${plain}"
echo -e "${bold}${cyan}  ┌─────────────────────────────────────────────────────┐${plain}"
echo -e "${bold}${cyan}  │  ssh $username@<IP-сервера> -p $NEW_PORT${plain}"
echo -e "${bold}${cyan}  └─────────────────────────────────────────────────────┘${plain}"
echo
echo -e "${yellow}  📋 Итоговые параметры:${plain}"
echo -e "${blue}     Пользователь:        ${bold}$username${plain}"
echo -e "${blue}     SSH порт:            ${bold}$NEW_PORT/tcp${plain}"
if [[ "$UFW_SSH_MODE" == "any" ]]; then
    echo -e "${blue}     UFW SSH-доступ:     с любого IP${plain}"
else
    echo -e "${blue}     UFW SSH-доступ:     только с ${bold}$UFW_SSH_MODE${plain}"
fi
if [[ "$SWAP_ACTIVE" == true ]]; then
    echo -e "${blue}     Swap:               активен${plain}"
else
    echo -e "${blue}     Swap:               не настроен${plain}"
fi
echo -e "${blue}     CrowdSec:           активен${plain}"
echo -e "${blue}     Авто-обновления:    включены (перезагрузка в 04:00)${plain}"
if [[ "$NOPASSWD_ACTIVE" == true ]]; then
    echo -e "${blue}     sudo без пароля:   ${bold}включено${plain}"
else
    echo -e "${blue}     sudo без пароля:   не настроено${plain}"
fi
echo -e "${blue}     Бэкап sshd_config:  $MAIN_CONFIG_BACKUP${plain}"
echo
echo -e "${yellow}  ⚠  Не закрывайте эту сессию, пока не проверите"
echo -e "     подключение с новыми параметрами!${plain}"
echo
