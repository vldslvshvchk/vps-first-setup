#!/bin/bash

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
