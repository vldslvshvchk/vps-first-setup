#!/bin/bash

# Скрипт первоначальной настройки Ubuntu сервера
# Используйте его в два этапа:
# 1. Запустите первый раз - выполнит обновление и перезагрузку
# 2. После перезагрузки запустите второй раз - завершит настройку

echo "Начинаем первоначальную настройку сервера..."

# Проверяем, был ли уже выполнен первый этап
# Используем более постоянное место для маркера
MARKER_FILE="/etc/first_stage_completed"

if [ ! -f "$MARKER_FILE" ]; then
    # 1. Обновляем систему и устанавливаем часовой пояс
    echo "Обновляем систему и устанавливаем часовой пояс..."
    sudo timedatectl set-timezone Europe/Moscow
    sudo apt update && sudo apt upgrade -y
    
    # Создаем маркер для отметки выполнения первого этапа
    sudo touch "$MARKER_FILE"
    
    echo "Перезагрузите сервер вручную и запустите скрипт снова."
    echo "После перезагрузки скрипт продолжит настройку..."
    exit 0
else
    # Второй этап - после перезагрузки
    echo "Продолжаем настройку после перезагрузки..."
    
    # 2. Поменять пароль на root
    echo "Установите пароль для root пользователя"
    sudo passwd root

    # 3. Создать пользователя вместо root (опционально)
    echo "Хотите создать нового пользователя? (y/n):"
    read create_user
    if [[ "$create_user" =~ ^[Yy]$ ]]; then
        echo "Введите имя нового пользователя:"
        read username
        sudo adduser $username
        sudo usermod -aG sudo $username
    else
        echo "Пропускаем создание пользователя"
        username="root"
    fi

    # 4. Добавить ключ для подключения по SSH
    echo "Настройка SSH ключей..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    echo "Введите ваш публичный SSH ключ (введите ключ и нажмите Enter):"
    read public_key
    echo "$public_key" >> ~/.ssh/authorized_keys

    # 5. Настройка SSH конфигурации
    echo "Настройка SSH конфигурации..."
    
    # Запрашиваем порт для SSH
    echo "Введите порт для SSH:"
    echo "Порт или придумываем самостоятельно или выбираем любой понравившийся на https://www.shodan.io/search/facet?query=ssh&facet=port"
    read ssh_port
    
    # Устанавливаем порт в основной конфиг
    sudo sed -i "/^Port /c\Port $ssh_port" /etc/ssh/sshd_config
    # Если порт не найден, добавляем строку
    if ! grep -q "^Port $ssh_port" /etc/ssh/sshd_config; then
        echo "Port $ssh_port" | sudo tee -a /etc/ssh/sshd_config
    fi
    
    # Устанавливаем остальные настройки в основном конфиге
    sudo sed -i '/^PermitRootLogin/c\PermitRootLogin no' /etc/ssh/sshd_config
    sudo sed -i '/^MaxAuthTries/c\MaxAuthTries 3' /etc/ssh/sshd_config
    sudo sed -i '/^MaxSessions/c\MaxSessions 2' /etc/ssh/sshd_config
    sudo sed -i '/^PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config
    sudo sed -i '/^PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
    sudo sed -i '/^X11Forwarding/c\X11Forwarding no' /etc/ssh/sshd_config
    
    # Проверяем и настраиваем дополнительный конфиг, если он существует
    if [ -f "/etc/ssh/sshd_config.d/50-cloud-init.conf" ]; then
        echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config.d/50-cloud-init.conf
    fi
    
    # Перезагружаем SSH сервис
    sudo systemctl daemon-reload
    sudo systemctl restart ssh.socket

    # 6. Проверяем установлен ли ufw
    echo "Устанавливаем UFW..."
    if ! dpkg -l | grep -q ufw; then
        sudo apt install ufw -y
    fi

    # Настраиваем брандмауэр
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow $ssh_port/tcp
    echo "Если у вас есть статический IP, введите его (или нажмите Enter для пропуска):"
    read static_ip
    if [ -n "$static_ip" ]; then
        sudo ufw allow from $static_ip to any port $ssh_port proto tcp
    fi
    sudo ufw enable

    # 7. Выбор брандмауэра для защиты от атак (fail2ban или crowdsec)
    echo "Выберите инструмент для защиты от атак:"
    echo "1) fail2ban"
    echo "2) crowdsec"
    echo "Введите номер (1 или 2):"
    read choice

    if [[ "$choice" == "1" ]]; then
        # Установка и настройка fail2ban
        echo "Устанавливаем fail2ban..."
        sudo apt install fail2ban -y
        
        # Создаём локальный конфиг fail2ban
        sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        
        # Настройка fail2ban для SSH
        sudo tee -a /etc/fail2ban/jail.local > /dev/null <<EOF

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

        # Перезапуск fail2ban
        sudo systemctl restart fail2ban
        sudo systemctl enable fail2ban
        
        echo "fail2ban успешно установлен и настроен!"
        
    elif [[ "$choice" == "2" ]]; then
        # Установка Crowdsec (оставляем существующие настройки)
        echo "Устанавливаем Crowdsec..."
        curl -s https://install.crowdsec.net | sudo sh
        sudo apt update
        sudo apt install crowdsec -y
        sudo apt install crowdsec-firewall-bouncer-iptables -y
        
        echo "Crowdsec успешно установлен!"
        
    else
        echo "Некорректный выбор. Устанавливаем Crowdsec по умолчанию..."
        curl -s https://install.crowdsec.net | sudo sh
        sudo apt update
        sudo apt install crowdsec -y
        sudo apt install crowdsec-firewall-bouncer-iptables -y
        echo "Crowdsec успешно установлен!"
    fi

    # 8. Включаем автоматические обновления безопасности
    echo "Устанавливаем автоматические обновления..."
    if ! dpkg -l | grep -q unattended-upgrades; then
        sudo apt install unattended-upgrades -y
    fi

    # Настройка автоматических обновлений
    sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<EOF
// Do automatic removal of unused packages after the upgrade  
// (equivalent to apt-get autoremove)  
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatically reboot _WITHOUT CONFIRMATION_ if  
// the file /var/run/reboot-required is found after the upgrade  
Unattended-Upgrade::Automatic-Reboot "true";

// If automatic reboot is enabled and needed, reboot at the specific  
// time instead of immediately  
// Default: "now"  
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

    # Удаляем маркер после завершения
    sudo rm -f "$MARKER_FILE"
    
    echo "Настройка завершена!"
    echo "Перезагрузите сервер для применения всех изменений:"
    echo "sudo reboot"
fi
