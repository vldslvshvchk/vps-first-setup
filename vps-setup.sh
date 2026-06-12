#!/bin/bash

# Объявление цветов
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

# Проверка запуска из под root
if [[ $EUID -ne 0 ]]; then
   echo -e "${red}❌ Пожалуйста, запустите этот скрипт с правами root${plain}"
   echo -e "${yellow}💡 Используйте sudo -i${plain}"
   echo -e "${yellow}🔄 Затем запустите скрипт повторно${plain}"
   exit 1
fi

echo -e "${green}✅ Скрипт запущен от root пользователя. Продолжаем настройку...${plain}"

# Определение операционной системы
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID
    
    echo -e "${blue}Операционная система: $OS_NAME $OS_VERSION${plain}"
    
    # Проверка на Ubuntu 22.04 или 24.04
    if [[ "$OS_NAME" == *"Ubuntu"* ]] && [[ "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]]; then
        echo -e "${green}✅ Скрипт поддерживает Ubuntu $OS_VERSION${plain}"
    # Проверка на Debian
    elif [[ "$OS_NAME" == *"Debian"* ]]; then
        echo -e "${yellow}⚠️  Внимание: скрипт тестировался только на Ubuntu${plain}"
        echo -e "${yellow}⚠️  Скрипт не поддерживает Debian${plain}"
        echo -e "${red}❌ Работа скрипта прервана${plain}"
        exit 1
    else
        echo -e "${red}❌ Скрипт не поддерживает операционную систему: $OS_NAME $OS_VERSION${plain}"
        echo -e "${red}⚠️  Поддерживаются только Ubuntu 22.04 и 24.04${plain}"
        exit 1
    fi
else
    echo -e "${red}❌ Не удалось определить операционную систему${plain}"
    echo -e "${red}⚠️  Поддерживаются только Ubuntu 22.04 и 24.04${plain}"
    exit 1
fi

# Определение таймзоны
TIMEZONE=$(timedatectl show -p Timezone --value)
echo -e "${blue}Текущая таймзона: $TIMEZONE${plain}"

# Проверка если уже Москва
if [[ "$TIMEZONE" == "Europe/Moscow" ]]; then
    echo -e "${green}✅ Таймзона уже установлена как Europe/Moscow${plain}"
else
    # Предложение изменить на Москву
    read -p "Хотите установить таймзону Europe/Moscow? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        timedatectl set-timezone Europe/Moscow
        echo -e "${green}✅ Таймзона изменена на Europe/Moscow${plain}"
    else
        echo -e "${yellow}🔄 Таймзона оставлена без изменений${plain}"
    fi
fi

# Проверка наличия маркера обновления
UPDATE_MARKER="/root/.system_updated"

if [ -f "$UPDATE_MARKER" ]; then
    echo -e "${green}✅ Система уже была обновлена ранее${plain}"
else
    echo -e "${blue}🔄 Начинаем обновление системы...${plain}"
    
    # Обновление пакетов
    apt update && apt upgrade -y
    
    if [ $? -eq 0 ]; then
        echo -e "${green}✅ Система успешно обновлена${plain}"
        
        # Создание маркера для пропуска шага при повторном запуске
        touch "$UPDATE_MARKER"
        
        echo -e "${blue}🔄 Требуется перезагрузка системы${plain}"
        read -p "Хотите перезагрузить систему сейчас? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${green}✅ Перезагрузка системы...${plain}"
            reboot
        else
            echo -e "${yellow}🔄 Перезагрузка отложена. Пожалуйста, перезагрузите систему вручную${plain}"
        fi
    else
        echo -e "${red}❌ Ошибка при обновлении системы${plain}"
        exit 1
    fi
fi

# Смена пароля root
echo -e "${yellow}⚠️  Сейчас будет предложено сменить пароль root${plain}"
passwd root

# Проверка, что пароль был успешно изменён
if [ $? -eq 0 ]; then
    echo -e "${green}✅ Пароль root успешно изменён${plain}"
else
    echo -e "${red}❌ Не удалось изменить пароль root${plain}"
fi

# Создание нового пользователя
echo -e "${blue}🔄 Создание нового пользователя${plain}"

# Запрашиваем имя пользователя
read -p "Введите имя нового пользователя: " username

# Проверяем, существует ли пользователь
if id "$username" &>/dev/null; then
    echo -e "${yellow}⚠️  Пользователь $username уже существует${plain}"
else
    # Создаем пользователя без интерактивных вопросов
    useradd "$username"
    if [ $? -eq 0 ]; then
        echo -e "${green}✅ Пользователь $username успешно создан${plain}"
    else
        echo -e "${red}❌ Ошибка при создании пользователя $username${plain}"
        exit 1
    fi
fi

# Добавляем пользователя в группу sudo если его там нет
if groups "$username" | grep -q '\bsudo\b'; then
    echo -e "${green}✅ Пользователь $username уже в группе sudo${plain}"
else
    usermod -aG sudo "$username"
    echo -e "${green}✅ Пользователь $username добавлен в группу sudo${plain}"
fi

# Настройка SSH для нового пользователя
echo -e "${blue}🔄 Настройка SSH для пользователя $username${plain}"

# Создание директории .ssh и файлов с правами
mkdir -p /home/$username/.ssh
chmod 700 /home/$username/.ssh
touch /home/$username/.ssh/authorized_keys
chmod 600 /home/$username/.ssh/authorized_keys

echo -e "${yellow}⚠️  Введите SSH ключ для пользователя $username${plain}"
echo -e "${yellow}Поддерживаются следующие форматы:${plain}"
echo -e "${yellow}  - RSA: ssh-rsa AAAAB3NzaC1yc2E...${plain}"
echo -e "${yellow}  - ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...${plain}"
echo -e "${yellow}  - ECDSA: ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI...${plain}"

# Функция для проверки валидности SSH ключа
validate_ssh_key() {
    local key="$1"

    # Проверяем, что строка не пустая
    if [[ -z "$key" ]]; then
        return 1
    fi

    # Проверяем форматы ключей
    if [[ "$key" =~ ^ssh-rsa\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]] || \
       [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]] || \
       [[ "$key" =~ ^ecdsa-sha2-nistp256\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]] || \
       [[ "$key" =~ ^ecdsa-sha2-nistp384\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]] || \
       [[ "$key" =~ ^ecdsa-sha2-nistp521\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]] || \
       [[ "$key" =~ ^sk-ssh-ed25519@openssh.com\ [A-Za-z0-9+/]+={0,2}\ (.*)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Запрашиваем SSH ключ с повторным вводом при ошибке
while true; do
    read -p "Введите SSH ключ: " ssh_key

    if validate_ssh_key "$ssh_key"; then
        echo "$ssh_key" >> /home/$username/.ssh/authorized_keys
        echo -e "${green}✅ SSH ключ успешно добавлен для пользователя $username${plain}"
        break
    else
        echo -e "${red}❌ Неверный формат SSH ключа${plain}"
        echo -e "${yellow}Пожалуйста, убедитесь, что ввели корректный SSH ключ${plain}"
        echo -e "${yellow}Поддерживаются следующие форматы:${plain}"
        echo -e "${yellow}  - RSA: ssh-rsa AAAAB3NzaC1yc2E...${plain}"
        echo -e "${yellow}  - ED25519: ssh-ed25519 AAAAC3NzaC1lZDI1N...${plain}"
        echo -e "${yellow}  - ECDSA: ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTI...${plain}"
    fi
done

echo -e "${green}✅ Настройка пользователя завершена${plain}"

# Настройка SSH
MAIN_CONFIG="/etc/ssh/sshd_config"
CONFIG_DIR="/etc/ssh/sshd_config.d/"

    # Запрос порта с проверкой (диапазон 1024-65535)
echo -e "${yellow}⚠️  Сейчас будет предложено сменить SSH порт${plain}"
echo -e "${yellow}Выбрать порт можно на сайте https://www.shodan.io/search/facet?query=ssh&facet=port${plain}"
while true; do
    read -p "Введите номер порта SSH (рекомендуется диапазон от 1024 до 65535): " NEW_PORT

    # Проверка, что ввод состоит только из цифр и находится в допустимом диапазоне
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ]; then
        echo "Устанавливаю порт $NEW_PORT..."
        break
    else
        echo "Ошибка: Неверный номер порта. Пожалуйста, введите число от 1024 до 65535."
    fi
done

# Редактирование основного конфига
# Используем ключ 'i' для редактирования файла на месте.
sed -i "s/^\\s*Port.*/Port $NEW_PORT/" "$MAIN_CONFIG"
sed -i "s/^\\s*PermitRootLogin .*/PermitRootLogin no/" "$MAIN_CONFIG"
sed -i "s/^\\s*MaxAuthTries .*/MaxAuthTries 3/" "$MAIN_CONFIG"
sed -i "s/^\\s*MaxSessions .*/MaxSessions 2/" "$MAIN_CONFIG"
sed -i "s/^\\s*PubkeyAuthentication .*/PubkeyAuthentication yes/" "$MAIN_CONFIG"
sed -i "s/^\\s*PasswordAuthentication .*/PasswordAuthentication no/" "$MAIN_CONFIG"
sed -i "s/^\\s*X11Forwarding .*/X11Forwarding no/" "$MAIN_CONFIG"

# Обработка дополнительных конфигов
if [ -d "$CONFIG_DIR" ]; then
    for config_file in "$CONFIG_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            if grep -q "^[[:space:]]*PasswordAuthentication" "$config_file"; then
                echo "Обнаружена настройка PasswordAuthentication в $config_file. Устанавливаю значение 'no'..."
                sed -i "s/^[[:space:]]*PasswordAuthentication .*/PasswordAuthentication no/" "$config_file"
            else
                echo "Строка PasswordAuthentication не найдена в $config_file. Пропускаем."
            fi
        fi
    done
else
    echo "Директория $CONFIG_DIR не существует. Пропускаем обработку доп. конфигов."
fi
echo -e "${green}✅ Настройка SSH завершена${plain}"
