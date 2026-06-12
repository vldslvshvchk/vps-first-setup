#!/bin/bash

# Объявление цветов
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

# check root
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
