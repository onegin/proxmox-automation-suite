#!/bin/bash

# ======================================================================
# 🐧 Debian Basic-Setting script - Contaner LXC
# ======================================================================
# 
# 👨‍💻 Автор: Антонов Евгений
# 📧 Контакты: ae@dcea.ru
# 
# 📜 ЛИЦЕНЗИЯ:
# ✅ Бесплатно для некоммерческого использования
# 
# ======================================================================

# Проверка прав администратора
if [ "$EUID" -ne 0 ]; then
    echo "Этот скрипт требует права суперпользователя. Запустите с sudo."
    exit 1
fi

#Создание файла log
touch /var/log/post_install.log
# Обновление списка пакетов
echo "Обновление списка пакетов..."
echo "Обновление списка пакетов..." >> /var/log/post_install.log
apt update >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Обновление установленных пакетов
echo "Обновление системы..."
echo "Обновление системы..." >> /var/log/post_install.log
apt upgrade -y >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Установка пакетов (добавлены locales, rsyslog, net-tools, tzdata, logrotate, screen)
echo "Установка дополнительных пакетов..."
echo "Установка дополнительных пакетов..." >> /var/log/post_install.log
apt install -y vim git wget curl mc zip openssh-server htop iftop sudo zabbix-agent locales rsyslog net-tools tzdata logrotate screen >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Настройка локали
echo "Настройка локали..."
echo "Настройка локали..." >> /var/log/post_install.log
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen >> /var/log/post_install.log
update-locale LANG=en_US.UTF-8 >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Настройка часового пояса
echo "Настройка часового пояса..."
echo "Настройка часового пояса..." >> /var/log/post_install.log
echo "Europe/Moscow" | sudo tee /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Настройка SSH - разрешение подключения root
echo "Настройка SSH..."
echo "Настройка SSH..." >> /var/log/post_install.log
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh >> /var/log/post_install.log
echo "--------DONE------------" >> /var/log/post_install.log
# Перезапуск служб
echo "Перезапуск системных служб..."
echo "Перезапуск системных служб..." >> /var/log/post_install.log
systemctl restart rsyslog >> /var/log/post_install.log
echo "------------------------" >> /var/log/post_install.log
echo "Настройка завершена" >> /var/log/post_install.log
echo "------------------------" >> /var/log/post_install.log
echo "=================================================="
echo "Настройка завершена!"
echo "Root доступ по SSH разрешен"
echo "Для применения всех изменений рекомендуется перезагрузить систему"
echo "=================================================="
