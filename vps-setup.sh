#!/bin/bash
# ==============================================================================
#  Настройка Ubuntu-сервера после первичного развёртывания
#  Поддерживаемые ОС: Ubuntu 22.04 LTS, 24.04 LTS, 26.04 LTS и новее
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
#  Цвета и утилиты вывода
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

# section: заголовок шага.
# Намеренно без рамок с фиксированной шириной — printf %-Ns считает ширину
# в байтах, а не символах, и кириллица (2 байта/символ) ломает выравнивание.
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
    # $0 указывает на реальный файл только если скрипт запущен как
    # "bash script.sh". Если он выполняется через пайп (curl ... | bash),
    # $0 — это что-то вроде /proc/12345/fd/pipe:[...], и предлагать
    # "sudo bash <этот путь>" бессмысленно: такого файла для повторного
    # запуска не существует. Проверяем реальность файла явно.
    if [[ -f "$0" ]]; then
        echo -e "${yellow}  Повторный запуск: sudo bash $(realpath "$0")${plain}"
    else
        echo -e "${yellow}  Скрипт был запущен через пайп — сохраните его в файл и запустите:${plain}"
        echo -e "${yellow}    sudo bash setup.sh${plain}"
    fi
    echo -e "${red}${bold}══════════════════════════════════════════════════════${plain}"
    echo
    exit 1
}

# ============================================================
#  Флаги завершённых шагов
# ============================================================
# Каждый шаг (кроме 1 и 2) после успешного выполнения создаёт флаг в
# /root/.setup/. При повторном запуске шаги с флагом пропускаются.
# Флаги удаляются только в самом конце — после полного успешного
# завершения ВСЕХ шагов.
#
# Шаги 1-2 (проверка root, определение ОС) флагов не имеют — они и так
# выполняются мгновенно и не меняют состояние сервера, повторный прогон
# ничего не стоит.
#
# Если шаг спрашивает что-то у пользователя и результат нужен на более
# поздних шагах (имя пользователя, SSH-порт, режим UFW и т.д.) — этот
# результат дополнительно сохраняется в отдельный файл рядом с флагом,
# чтобы при пропуске шага переменная восстанавливалась, а не терялась.
SETUP_DIR="/root/.setup"
mkdir -p "$SETUP_DIR"

step_done() {
    # Возвращает 0 (true) если флаг шага существует
    [ -f "$SETUP_DIR/step_${1}_done" ]
}

mark_done() {
    # Создаёт флаг завершённого шага
    touch "$SETUP_DIR/step_${1}_done"
    log_ok "Шаг $1 отмечен как выполненный"
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
# переходим на классический сервис ssh.service — тогда Port из sshd_config
# становится единственным источником правды.
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
    # enable: добавляет автозапуск. Идемпотентно — если уже включён, просто no-op.
    # Пробуем оба имени: ssh.service (Ubuntu/Debian) и sshd.service (некоторые дистрибутивы).
    systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null || true

    # restart применяет новый конфиг независимо от текущего состояния сервиса.
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

# apt_wait: ждёт освобождения dpkg/apt локов перед запуском apt-get.
# Проблема: unattended-upgrades, apt-daily.timer или apt-daily-upgrade.timer
# могут держать /var/lib/dpkg/lock-frontend в момент запуска скрипта.
# Без ожидания apt-get мгновенно падает с "Could not get lock".
# Решение: ждём до MAX_WAIT секунд, проверяя лок каждые INTERVAL секунд.
apt_wait() {
    # /var/lib/apt/lists/lock держится во время "apt-get update" —
    # без него гонка с фоновым apt update всё ещё возможна.
    local LOCK_FILES=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local MAX_WAIT=120
    local WAITED=0
    local INTERVAL=3
    local busy=true

    while $busy; do
        busy=false
        local lock
        for lock in "${LOCK_FILES[@]}"; do
            # fuser возвращает 0 если файл занят каким-либо процессом
            if [ -f "$lock" ] && fuser "$lock" &>/dev/null; then
                busy=true
                break
            fi
        done

        if $busy; then
            if (( WAITED == 0 )); then
                log_warn "apt заблокирован другим процессом — ждём освобождения (до ${MAX_WAIT}с)..."
            fi
            if (( WAITED >= MAX_WAIT )); then
                die \
                    "apt не освободился за ${MAX_WAIT} секунд" \
                    "  Найдите процесс, держащий лок:
  fuser /var/lib/dpkg/lock-frontend
  fuser /var/lib/dpkg/lock
  Или остановите фоновые обновления:
  systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service"
            fi
            sleep "$INTERVAL"
            WAITED=$(( WAITED + INTERVAL ))
        fi
    done

    if (( WAITED > 0 )); then
        log_ok "apt освободился (ждали ${WAITED}с)"
    fi

    "$@"
}

# ver_ge: возвращает 0 если $1 >= $2 (сравнение версий).
# Используется чтобы не перечислять конкретные версии Ubuntu —
# скрипт поддерживает 22.04 и все последующие LTS без изменений.
ver_ge() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
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

# tmpfile_remove: немедленно удаляет файл и убирает из очереди cleanup.
# Удаляем по точному совпадению индекса (не подстроки).
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
# Шаги 1 и 2 не требуют флагов — они мгновенные и всегда идемпотентны

# ============================================================
#  2. Определение ОС
# ============================================================
section "Определение ОС"

[ -f /etc/os-release ] || die \
    "Файл /etc/os-release не найден — невозможно определить ОС" \
    "  Поддерживается Ubuntu 22.04 LTS и новее"

# shellcheck source=/dev/null
. /etc/os-release
OS_NAME="${NAME:-}"
OS_VERSION="${VERSION_ID:-}"
log_step "Обнаружена ОС: ${bold}$OS_NAME $OS_VERSION${plain}"

if [[ "$OS_NAME" == *"Ubuntu"* ]]; then
    if [[ -z "$OS_VERSION" ]]; then
        die \
            "Не удалось определить версию Ubuntu (VERSION_ID пуст в /etc/os-release)" \
            "  Проверьте файл вручную: cat /etc/os-release"
    elif ver_ge "$OS_VERSION" "22.04"; then
        log_ok "Ubuntu $OS_VERSION — поддерживается"
    else
        die "Ubuntu $OS_VERSION не поддерживается" \
            "  Минимальная поддерживаемая версия: Ubuntu 22.04 LTS"
    fi
elif [[ "$OS_NAME" == *"Debian"* ]]; then
    die "Debian не поддерживается. Скрипт тестировался только на Ubuntu 22.04+"
else
    die "ОС не поддерживается: $OS_NAME $OS_VERSION" \
        "  Установите Ubuntu 22.04 LTS или новее"
fi

# ============================================================
#  3. Таймзона
# ============================================================
section "Таймзона"

if step_done 3; then
    log_ok "Шаг уже выполнен — пропускаем"
else
    TIMEZONE=$(timedatectl show -p Timezone --value)
    log_step "Текущая таймзона: ${bold}$TIMEZONE${plain}"

    if ask_yn "Хотите изменить таймзону?"; then
        echo
        echo -e "${cyan}   Популярные таймзоны:${plain}"
        echo -e "${cyan}   1) Europe/Moscow       — Москва (UTC+3)${plain}"
        echo -e "${cyan}   2) Europe/Kaliningrad  — Калининград (UTC+2)${plain}"
        echo -e "${cyan}   3) Asia/Yekaterinburg  — Екатеринбург (UTC+5)${plain}"
        echo -e "${cyan}   4) Asia/Novosibirsk    — Новосибирск (UTC+7)${plain}"
        echo -e "${cyan}   5) Asia/Krasnoyarsk    — Красноярск (UTC+7)${plain}"
        echo -e "${cyan}   6) Asia/Irkutsk        — Иркутск (UTC+8)${plain}"
        echo -e "${cyan}   7) Asia/Yakutsk        — Якутск (UTC+9)${plain}"
        echo -e "${cyan}   8) Asia/Vladivostok    — Владивосток (UTC+10)${plain}"
        echo -e "${cyan}   9) Europe/London       — Лондон (UTC+0/+1)${plain}"
        echo -e "${cyan}  10) Europe/Berlin       — Берлин (UTC+1/+2)${plain}"
        echo -e "${cyan}  11) America/New_York    — Нью-Йорк (UTC-5/-4)${plain}"
        echo -e "${cyan}  12) America/Los_Angeles — Лос-Анджелес (UTC-8/-7)${plain}"
        echo -e "${cyan}  13) UTC                 — UTC (без смещения)${plain}"
        echo -e "${cyan}   0) Ввести вручную${plain}"
        echo

        declare -A TZ_MAP=(
            [1]="Europe/Moscow"
            [2]="Europe/Kaliningrad"
            [3]="Asia/Yekaterinburg"
            [4]="Asia/Novosibirsk"
            [5]="Asia/Krasnoyarsk"
            [6]="Asia/Irkutsk"
            [7]="Asia/Yakutsk"
            [8]="Asia/Vladivostok"
            [9]="Europe/London"
            [10]="Europe/Berlin"
            [11]="America/New_York"
            [12]="America/Los_Angeles"
            [13]="UTC"
        )

        chosen_tz=''
        while true; do
            read -r -p "  Введите номер или 0 для ручного ввода: " tz_choice
            if [[ "$tz_choice" == "0" ]]; then
                log_info "Полный список: timedatectl list-timezones"
                log_info "Поиск по названию: timedatectl list-timezones | grep -i <название>"
                while true; do
                    read -r -p "  Введите таймзону (Region/City): " chosen_tz
                    if timedatectl list-timezones | grep -qx "$chosen_tz"; then
                        break
                    else
                        log_error "Неизвестная таймзона: '$chosen_tz' — попробуйте снова"
                    fi
                done
                break
            elif [[ "$tz_choice" =~ ^[0-9]+$ ]] && [[ -n "${TZ_MAP[$tz_choice]:-}" ]]; then
                chosen_tz="${TZ_MAP[$tz_choice]}"
                break
            else
                log_error "Введите число от 0 до 13"
            fi
        done

        timedatectl set-timezone "$chosen_tz"
        log_ok "Таймзона установлена: $chosen_tz"
    else
        log_ok "Таймзона оставлена: $TIMEZONE"
    fi

    mark_done 3
fi

# ============================================================
#  4. Обновление системы
# ============================================================
section "Обновление системы"

# После apt-get upgrade система может потребовать перезагрузку — флаг
# шага создаётся ДО reboot (см. mark_done 4 ниже), поэтому при повторном
# запуске после перезагрузки шаг 4 будет корректно пропущен.
if step_done 4; then
    log_ok "Шаг уже выполнен — пропускаем"
else
    check_internet
    log_info "Обновление списка пакетов..."
    apt_wait apt-get update -q || die \
        "Ошибка при apt-get update" \
        "  1. Проверьте интернет: ping 8.8.8.8
  2. Проверьте sources.list: cat /etc/apt/sources.list
  3. Исправьте повреждённые пакеты: dpkg --configure -a"

    log_info "Установка обновлений (это может занять несколько минут)..."
    # --force-confdef/--force-confold: при обновлении пакета с изменившимся конфигом
    # dpkg не будет показывать диалог — это могло бы "подвесить" скрипт.
    # Автоматически оставляем текущую версию конфигурационного файла.
    apt_wait apt-get upgrade -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        || die \
        "Ошибка при apt-get upgrade" \
        "  1. Исправьте повреждённые зависимости: apt-get install -f
  2. Исправьте незавершённые установки: dpkg --configure -a
  3. Повторите обновление вручную: apt-get upgrade -y"

    mark_done 4
    log_ok "Система успешно обновлена"

    log_warn "Рекомендуется перезагрузка (особенно если обновлялось ядро)"
    if ask_yn "Перезагрузить сервер сейчас?"; then
        log_ok "Перезагрузка..."
        log_warn "После перезагрузки запустите скрипт повторно — он продолжит с шага 5"
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
# Пароль root не кэшируем флагом — это интерактивное действие безопасности,
# которое должно выполняться каждый раз если шаг не был пройден ранее.
# При повторном запуске пользователь может просто установить тот же пароль.
if step_done 5; then
    log_ok "Шаг уже выполнен — пропускаем"
else
    set_password root
    mark_done 5
fi

# ============================================================
#  6. Создание нового пользователя
# ============================================================
section "Создание нового пользователя"

# Имя пользователя нужно знать на следующих шагах (SSH-ключ, sudoers).
# Читаем его из флага если шаг уже выполнен.
USERNAME_FILE="$SETUP_DIR/step_6_username"

if step_done 6; then
    log_ok "Шаг уже выполнен — пропускаем"
    username=$(cat "$USERNAME_FILE" 2>/dev/null || true)
    if [[ -z "$username" ]]; then
        die \
            "Шаг помечен как выполненный, но файл с именем пользователя не найден" \
            "  Удалите флаг и повторите: rm -f $SETUP_DIR/step_6_done $USERNAME_FILE"
    fi
    log_step "Пользователь из предыдущего запуска: ${bold}$username${plain}"
else
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
            "  Проверьте: getent passwd $username
  Если запись повреждена: userdel -r $username"
        log_ok "Пользователь $username создан"
        USER_IS_NEW=true
    fi

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

    # Сохраняем имя пользователя для последующих шагов при повторном запуске
    echo "$username" > "$USERNAME_FILE"
    mark_done 6
fi

# ============================================================
#  7. Проверка ssh-keygen
# ============================================================
section "Проверка ssh-keygen"

if step_done 7; then
    log_ok "Шаг уже выполнен — пропускаем"
else
    if ! command -v ssh-keygen &>/dev/null; then
        log_warn "ssh-keygen не найден — устанавливаем openssh-client..."
        apt_wait apt-get install -y -q openssh-client || die \
            "Не удалось установить openssh-client" \
            "  apt-get install -y openssh-client"
        log_ok "openssh-client установлен"
    else
        log_ok "ssh-keygen доступен: $(command -v ssh-keygen)"
    fi
    mark_done 7
fi

# ============================================================
#  8. Настройка SSH-ключа
# ============================================================
section "Настройка SSH-ключа"

SSH_DIR="/home/$username/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if step_done 8; then
    log_ok "Шаг уже выполнен — пропускаем"
    log_step "Текущее содержимое authorized_keys:"
    ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | while read -r line; do
        log_step "$line"
    done || log_warn "  (не удалось прочитать ключи)"
else
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown -R "$username":"$username" "$SSH_DIR"

    # Показываем уже добавленные ключи — полезно при повторном запуске
    if [[ -s "$AUTH_KEYS" ]]; then
        EXISTING_KEYS=$(ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | wc -l || echo 0)
        if (( EXISTING_KEYS > 0 )); then
            log_warn "В authorized_keys уже есть ключей: $EXISTING_KEYS"
            ssh-keygen -l -f "$AUTH_KEYS" 2>/dev/null | while read -r line; do
                log_step "$line"
            done
        fi
    fi

    log_info "Поддерживаемые форматы ключей:"
    log_step "RSA:     ssh-rsa AAAAB3NzaC1yc2E..."
    log_step "ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...  (рекомендуется)"
    log_step "ECDSA:   ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI..."

    # Валидация через ssh-keygen — надёжнее regex: проверяет реальную структуру ключа.
    # Временный файл регистрируется в _TMPFILES — удалится при любом выходе из скрипта.
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
        read -r -p "  Введите SSH-ключ: " ssh_key
        if validate_ssh_key "$ssh_key"; then
            # -qxF: совпадение строки целиком (-x), без regex (-F).
            # Предотвращает дублирование при повторном запуске.
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

    mark_done 8
fi

# ============================================================
#  9. Настройка SSH-демона
# ============================================================
section "Настройка SSH-демона"

MAIN_CONFIG="/etc/ssh/sshd_config"
CONFIG_DIR="/etc/ssh/sshd_config.d"

# Порт и путь к бэкапу сохраняем в файлы — нужны в шаге 10 (UFW) и в
# итоговой сводке. Без этого при пропуске уже выполненного шага 9
# переменные NEW_PORT/MAIN_CONFIG_BACKUP останутся пустыми или (для
# бэкапа) перезапишутся новым несуществующим путём с текущей меткой
# времени, и сводка в конце покажет неверные данные.
SSH_PORT_FILE="$SETUP_DIR/step_9_port"
BACKUP_PATH_FILE="$SETUP_DIR/step_9_backup_path"

if step_done 9; then
    log_ok "Шаг уже выполнен — пропускаем"
    NEW_PORT=$(cat "$SSH_PORT_FILE" 2>/dev/null || true)
    MAIN_CONFIG_BACKUP=$(cat "$BACKUP_PATH_FILE" 2>/dev/null || true)
    if [[ -z "$NEW_PORT" ]]; then
        die \
            "Шаг помечен как выполненный, но файл с портом не найден" \
            "  Удалите флаг и повторите: rm -f $SETUP_DIR/step_9_done $SSH_PORT_FILE"
    fi
    log_step "SSH-порт из предыдущего запуска: ${bold}$NEW_PORT${plain}"
else
    MAIN_CONFIG_BACKUP="${MAIN_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    # Определяем текущий SSH-порт: сначала ищем слушающий процесс,
    # затем читаем из конфига. Работает независимо от того, какой порт
    # был установлен при предыдущем запуске скрипта.
    #
    # ВАЖНО: извлечение делается через awk (только фильтрация и вывод
    # поля, без match() с массивом захвата) + sed -E для парсинга порта.
    # Трёхаргументная форма match(str, re, arr) — расширение GNU awk;
    # системный /usr/bin/awk на Ubuntu по умолчанию это mawk, который
    # её не поддерживает и молча ничего не находит. sed -E работает
    # одинаково с любой реализацией awk.
    CURRENT_SSH_PORT="неизвестен"
    SS_PORT=$(ss -tlnpH 2>/dev/null \
        | awk '/sshd|ssh/ && !/127\.|::1/ {print $4; exit}' \
        | sed -E 's/.*:([0-9]+)$/\1/' || true)
    if [[ -n "$SS_PORT" && "$SS_PORT" =~ ^[0-9]+$ ]]; then
        CURRENT_SSH_PORT="$SS_PORT"
    elif [[ -f "$MAIN_CONFIG" ]]; then
        CFG_PORT=$(grep -E "^Port " "$MAIN_CONFIG" 2>/dev/null \
            | awk '{print $2}' | head -n1 || true)
        [[ -n "$CFG_PORT" ]] && CURRENT_SSH_PORT="$CFG_PORT"
    fi
    log_step "Текущий SSH-порт: ${bold}$CURRENT_SSH_PORT${plain}"
    log_step "Посмотреть статистику портов: https://www.shodan.io/search/facet?query=ssh&facet=port"

    NEW_PORT=''
    while true; do
        read -r -p "  Введите новый порт SSH (1024–65535): " NEW_PORT
        # 10#$NEW_PORT форсирует десятичную базу: без этого "08080" (ведущий
        # ноль + цифра 8/9) сломает арифметику bash ошибкой "value too great
        # for base", т.к. bash по умолчанию трактует 0-префикс как восьмеричный.
        if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] \
            && (( 10#$NEW_PORT >= 1024 && 10#$NEW_PORT <= 65535 )); then
            # Приводим к канонической десятичной форме без ведущих нулей.
            # Важно не только для bash-арифметики: OpenSSH разбирает числовые
            # директивы sshd_config через strtol(cp, &cp, 0), где база 0
            # означает "определить по префиксу" — "Port 0080" был бы
            # воспринят как восьмеричное число и сломал бы sshd -t.
            NEW_PORT=$(( 10#$NEW_PORT ))

            # Если пользователь оставляет ТЕКУЩИЙ SSH-порт (повторный запуск после
            # ошибки на более позднем шаге) — пропускаем проверку занятости:
            # порт "занят" самим sshd, и это ожидаемо.
            if [[ "$NEW_PORT" == "$CURRENT_SSH_PORT" ]]; then
                log_info "Порт $NEW_PORT совпадает с текущим SSH-портом — оставляем"
                break
            fi
            # Нативный фильтр ss по sport — точное совпадение, без ложных срабатываний
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
                sed -i \
                    "0,/^[[:space:]]*PasswordAuthentication .*/s//PasswordAuthentication no/" \
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

    # Сохраняем порт для использования на шаге 10 (UFW) и в сводке
    echo "$NEW_PORT" > "$SSH_PORT_FILE"
    echo "$MAIN_CONFIG_BACKUP" > "$BACKUP_PATH_FILE"
    mark_done 9
fi

# ============================================================
#  10. Настройка UFW
# ============================================================
section "Настройка UFW"

# UFW_SSH_MODE нужен в итоговой сводке — читаем из файла при повторном запуске
UFW_MODE_FILE="$SETUP_DIR/step_10_ufw_mode"

if step_done 10; then
    log_ok "Шаг уже выполнен — пропускаем"
    UFW_SSH_MODE=$(cat "$UFW_MODE_FILE" 2>/dev/null || echo "any")
    log_step "UFW SSH-режим из предыдущего запуска: ${bold}$UFW_SSH_MODE${plain}"
else
    if ! pkg_installed ufw; then
        apt_wait apt-get install -y -q ufw || die \
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
            # Отклоняем ведущий ноль (кроме одиночного "0"): "010" в разных
            # сетевых утилитах (ufw/iptables/ip) исторически трактуется
            # неоднозначно — где-то как десятичное 10, где-то как восьмеричное
            # 8. Проще не пропускать неоднозначный ввод, чем гадать, как его
            # разберёт конкретный бэкенд.
            if [[ "$octet" =~ ^0[0-9]+$ ]]; then
                return 1
            fi
            # 10#$octet форсирует десятичную базу и в самой проверке диапазона —
            # иначе even корректный октет вроде "08" (не должен сюда попасть
            # из-за проверки выше, но проверка глубже одного слоя не помешает)
            # сломает арифметику bash ошибкой "value too great for base"
            (( 10#$octet > 255 )) && return 1
        done

        if [[ "$has_mask" == true ]]; then
            [[ ! "$mask" =~ ^([0-9]|[1-2][0-9]|3[0-2])$ ]] && return 1
        fi
        return 0
    }

    # Сбрасываем правила только если UFW ещё не активен —
    # не затираем существующие правила при повторном запуске
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
                log_error "Неверный IP — введите IPv4 или CIDR (1.2.3.4 или 1.2.3.0/24)"
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

    echo "$UFW_SSH_MODE" > "$UFW_MODE_FILE"
    mark_done 10
fi

# ============================================================
#  11. Настройка swap
# ============================================================
section "Настройка swap"

if step_done 11; then
    log_ok "Шаг уже выполнен — пропускаем"
    # Проверяем реальное состояние, а не считаем true "на слово": если в
    # предыдущем запуске пользователь отказался создавать swap, флаг шага
    # всё равно был установлен, и реальный swap мог так и не появиться.
    if (( $(swapon --show --noheadings 2>/dev/null | wc -l) > 0 )); then
        SWAP_ACTIVE=true
    else
        SWAP_ACTIVE=false
    fi
else
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
                    # Отклоняем нулевой размер ("0M", "0G") сразу здесь —
                    # иначе дойдёт до fallocate/mkswap на 0-байтном файле
                    # и упадёт там с гораздо менее понятной ошибкой.
                    size_check="${SWAP_SIZE%[MGmg]}"
                    if (( 10#$size_check == 0 )); then
                        log_error "Размер не может быть нулевым — введите положительное число"
                        continue
                    fi
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

            # Конвертируем в мегабайты для dd (bs=1M универсально для всех версий dd).
            # 10#$swap_num форсирует десятичную базу — иначе размер с ведущим
            # нулём (например "008G") сломает арифметику bash.
            swap_num="${SWAP_SIZE%[MGmg]}"
            swap_unit="${SWAP_SIZE: -1}"
            swap_mb=$(( 10#$swap_num ))
            if [[ "${swap_unit,,}" == "g" ]]; then
                swap_mb=$(( 10#$swap_num * 1024 ))
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
            swapon  "$SWAPFILE" || die "Ошибка при подключении swap"   "  swapon $SWAPFILE"

            # Добавляем в fstab только если записи ещё нет.
            # "defaults" вместо устаревшего BSD-флага "sw"
            if ! grep -qF "$SWAPFILE" /etc/fstab; then
                echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
                log_ok "Запись добавлена в /etc/fstab — swap подключится автоматически после перезагрузки"
            else
                log_ok "Запись о swap уже есть в /etc/fstab"
            fi

            SWAP_TOTAL=$(swapon --show --noheadings 2>/dev/null | wc -l)
            log_ok "Swap $SWAP_SIZE активирован:"
            swapon --show | while read -r line; do log_step "$line"; done
            SWAP_ACTIVE=true
        else
            log_warn "Создание swap пропущено"
        fi
    fi

    mark_done 11
fi

# ============================================================
#  12. Установка CrowdSec
# ============================================================
section "Установка CrowdSec"

CROWDSEC_ACTIVE=false

if step_done 12; then
    log_ok "Шаг уже выполнен — пропускаем"
    # Проверяем реальное состояние: если в предыдущем запуске пользователь
    # отказался от установки CrowdSec, флаг шага всё равно был установлен,
    # но cscli в системе так и не появится.
    if command -v cscli &>/dev/null; then
        CROWDSEC_ACTIVE=true
    else
        CROWDSEC_ACTIVE=false
    fi
else
    log_info "CrowdSec — система обнаружения и блокировки атак (бан-агент + firewall-боунсер)"
    INSTALL_CROWDSEC=false
    if command -v cscli &>/dev/null; then
        log_ok "CrowdSec уже установлен — пропускаем установку"
        INSTALL_CROWDSEC=true
    elif ask_yn "Установить CrowdSec?"; then
        INSTALL_CROWDSEC=true
    else
        log_warn "Установка CrowdSec пропущена"
    fi

    if [[ "$INSTALL_CROWDSEC" == true ]]; then
        if ! command -v cscli &>/dev/null; then
            check_internet

            # Скачиваем во временный файл — в curl | sh код возврата curl
            # теряется даже при pipefail если sh завершился успешно
            CROWDSEC_INSTALLER=$(mktemp)
            _TMPFILES+=("$CROWDSEC_INSTALLER")

            log_info "Загрузка официального установщика CrowdSec..."
            curl -fsSL https://install.crowdsec.net -o "$CROWDSEC_INSTALLER" || die \
                "Не удалось загрузить установщик CrowdSec" \
                "  Проверьте интернет: ping 8.8.8.8
  Документация: https://docs.crowdsec.net/docs/getting_started/install_crowdsec/"

            log_info "Запуск установщика (добавляет репозиторий CrowdSec)..."
            sh "$CROWDSEC_INSTALLER" || die \
                "Ошибка установщика CrowdSec" \
                "  Попробуйте добавить репозиторий вручную:
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
  Документация: https://docs.crowdsec.net/docs/getting_started/install_crowdsec/"

            log_info "Установка пакета crowdsec..."
            apt_wait apt-get update -q || die "Ошибка apt-get update" "  apt-get update"
            apt_wait apt-get install -y -q crowdsec || die \
                "Ошибка при установке crowdsec" \
                "  apt-get install -f
  dpkg --configure -a
  apt-get install -y crowdsec"
            log_ok "CrowdSec установлен"
        fi

        # Запускаем сервис до установки боунсера — боунсер регистрируется через LAPI
        systemctl enable crowdsec --now || die \
            "Не удалось запустить CrowdSec" \
            "  journalctl -u crowdsec --no-pager -n 30
  systemctl status crowdsec"
        log_ok "Сервис CrowdSec запущен"

        # Определяем подходящий пакет firewall-боунсера.
        # На Ubuntu 26.04+ iptables заменён на nftables как backend — проверяем оба.
        BOUNCER_PKG=""
        if apt-cache show crowdsec-firewall-bouncer-nftables &>/dev/null; then
            BOUNCER_PKG="crowdsec-firewall-bouncer-nftables"
        elif apt-cache show crowdsec-firewall-bouncer-iptables &>/dev/null; then
            BOUNCER_PKG="crowdsec-firewall-bouncer-iptables"
        fi

        # ВАЖНО: имя systemd-юнита НЕ совпадает с именем пакета. Оба варианта
        # пакета (iptables и nftables — они конфликтуют между собой и
        # устанавливаются как взаимоисключающие) ставят один и тот же юнит
        # "crowdsec-firewall-bouncer.service" без суффикса. Обращение к
        # systemctl по имени пакета привело бы к ошибке "unit not found".
        BOUNCER_UNIT="crowdsec-firewall-bouncer"

        if [[ -z "$BOUNCER_PKG" ]]; then
            log_warn "Пакет firewall-боунсера не найден в репозиториях"
            log_warn "Установите вручную после завершения скрипта:"
            log_warn "  cscli bouncers list"
            log_warn "  https://docs.crowdsec.net/docs/bouncers/firewall/"
        else
            if pkg_installed "$BOUNCER_PKG"; then
                log_ok "$BOUNCER_PKG уже установлен — пропускаем"
            else
                log_info "Установка firewall-боунсера ($BOUNCER_PKG)..."
                apt_wait apt-get install -y -q "$BOUNCER_PKG" || die \
                    "Ошибка при установке $BOUNCER_PKG" \
                    "  apt-get install -y $BOUNCER_PKG"
                log_ok "Firewall-боунсер установлен: $BOUNCER_PKG"
            fi

            systemctl enable "$BOUNCER_UNIT" --now || die \
                "Не удалось запустить $BOUNCER_UNIT" \
                "  journalctl -u $BOUNCER_UNIT --no-pager -n 30"
            log_ok "CrowdSec firewall-bouncer запущен"
        fi

        CROWDSEC_ACTIVE=true
    fi

    mark_done 12
fi

# ============================================================
#  13. Автообновления (unattended-upgrades)
# ============================================================
section "Автоматические обновления безопасности"

if step_done 13; then
    log_ok "Шаг уже выполнен — пропускаем"
else
    if ! pkg_installed unattended-upgrades; then
        apt_wait apt-get install -y -q unattended-upgrades || die \
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

    # set_unattended_param: правит параметр в 50unattended-upgrades.
    # Если строка есть (в т.ч. закомментированная) — заменяем; нет — дописываем в конец.
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

    mark_done 13
fi

# ============================================================
#  14. [Опционально] sudo без пароля
# ============================================================
section "sudo без пароля (опционально)"

NOPASSWD_ACTIVE=false
SUDOERS_FILE="/etc/sudoers.d/$username"

if step_done 14; then
    log_ok "Шаг уже выполнен — пропускаем"
    # Проверяем реальное состояние: если в предыдущем запуске пользователь
    # отказался включать sudo без пароля, флаг шага всё равно был
    # установлен, но файла в sudoers.d так и не появится.
    if [ -f "$SUDOERS_FILE" ]; then
        NOPASSWD_ACTIVE=true
    else
        NOPASSWD_ACTIVE=false
    fi
else
    log_warn "Некоторые сервисы (например, AmneziaVPN) требуют sudo без пароля"
    log_warn "при подключении по SSH-ключу."

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
                "  Добавьте вручную:
  echo '$SUDOERS_LINE' > $SUDOERS_FILE
  chmod 0440 $SUDOERS_FILE"
        fi
    else
        log_ok "sudo без пароля не настраивается"
    fi

    mark_done 14
fi

# ============================================================
#  Удаление всех флагов шагов
# ============================================================
# Скрипт успешно завершил ВСЕ шаги — флаги больше не нужны.
# При следующем запуске все операции идемпотентны и безопасны без флагов.
log_info "Удаляем флаги завершённых шагов..."
rm -rf "$SETUP_DIR"
log_ok "Флаги удалены"

# ============================================================
#  Итоговая сводка
# ============================================================
echo
echo -e "${bold}${green}  ✅  Настройка сервера завершена!${plain}"
echo -e "${bold}${green}════════════════════════════════════════${plain}"
echo
echo -e "${bold}${yellow}  Команда для подключения:${plain}"
echo -e "${bold}${cyan}  ssh $username@<IP-сервера> -p $NEW_PORT${plain}"
echo
echo -e "${yellow}  Итоговые параметры:${plain}"
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
if [[ "$CROWDSEC_ACTIVE" == true ]]; then
    echo -e "${blue}     CrowdSec:           активен${plain}"
else
    echo -e "${blue}     CrowdSec:           не установлен${plain}"
fi
echo -e "${blue}     Авто-обновления:    включены (перезагрузка в 04:00)${plain}"
if [[ "$NOPASSWD_ACTIVE" == true ]]; then
    echo -e "${blue}     sudo без пароля:   ${bold}включено${plain}"
else
    echo -e "${blue}     sudo без пароля:   не настроено${plain}"
fi
if [[ -f "$MAIN_CONFIG_BACKUP" ]]; then
    echo -e "${blue}     Бэкап sshd_config:  $MAIN_CONFIG_BACKUP${plain}"
fi
echo
echo -e "${yellow}  ⚠  Не закрывайте эту сессию, пока не проверите"
echo -e "     подключение с новыми параметрами!${plain}"
echo
