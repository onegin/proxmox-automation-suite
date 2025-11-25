#!/bin/bash

# ======================================================================
# 🐧 Proxmox LXC Container Auto-Creator
# ======================================================================
# 
# 👨‍💻 Автор: Антонов Евгений
# 📧 Контакты: ae@dcea.ru
# 
# 📜 ЛИЦЕНЗИЯ:
# ✅ Бесплатно для некоммерческого использования
# 🚫 Коммерческое использование требует лицензии
# 
# ======================================================================

# === Загрузка конфигурации ===
CONFIG_FILE="$(dirname "$0")/config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "✅ Конфигурация загружена из: $CONFIG_FILE"
else
    echo "❌ Файл конфигурации не найден: $CONFIG_FILE"
    echo "💡 Создайте файл config.conf на основе config.example.conf"
    exit 1
fi

# === Установка значений по умолчанию ===
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-"n"}
CTID_MIN=${CTID_MIN:-100}
CTID_MAX=${CTID_MAX:-999}
EXTERNAL_SCRIPT_URL=${EXTERNAL_SCRIPT_URL:-""}

# === Проверка обязательных параметров ===
if [[ -z "$DEFAULT_TEMPLATE_DIR" || -z "$STORAGE" || -z "$DEFAULT_BRIDGE" ]]; then
    echo "❌ В конфигурации отсутствуют обязательные параметры"
    exit 1
fi

# === Функции ===

# Получение IP-адреса контейнера
get_container_ip() {
    local ctid=$1
    for attempt in {1..10}; do
        local ip=$(pct exec $ctid -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 3
    done
    echo "unknown"
}

# Отправка уведомления в Telegram
send_telegram_message() {
    if [[ "$TELEGRAM_ENABLED" != "y" ]]; then
        return 0
    fi
    
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        echo "❌ Не указаны токен или chat_id для Telegram"
        return 1
    fi
    
    local message="$1"
    local escaped_message=$(echo "$message" | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g')
    
    if curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"$escaped_message\",\"parse_mode\":\"Markdown\"}" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null; then
        echo "✅ Уведомление отправлено в Telegram"
        return 0
    else
        echo "❌ Ошибка отправки в Telegram"
        return 1
    fi
}

# Генерация случайного пароля
generate_password() {
    local length=12
    local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    local password=$(head /dev/urandom | tr -dc "$chars" | head -c $length)
    echo "$password"
}

# Выбор шаблона
select_template() {
    echo "📁 Проверяем доступные шаблоны в: $DEFAULT_TEMPLATE_DIR"
    
    local templates=()
    while IFS= read -r -d $'\0' file; do
        templates+=("$(basename "$file")")
    done < <(find "$DEFAULT_TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.tar.zst" -o -name "*.tar.gz" -o -name "*.tar.xz" \) -print0 2>/dev/null)
    
    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "❌ В папке не найдено шаблонов контейнеров"
        exit 1
    fi
    
    echo "📋 Доступные шаблоны:"
    for i in "${!templates[@]}"; do
        printf "%2d. %s\n" $((i+1)) "${templates[i]}"
    done
    
    while true; do
        read -p "💬 Выберите шаблон (1-${#templates[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#templates[@]}" ]; then
            SELECTED_TEMPLATE="${templates[$((choice-1))]}"
            TEMPLATE_FILE="$DEFAULT_TEMPLATE_DIR/$SELECTED_TEMPLATE"
            echo "✅ Выбран шаблон: $SELECTED_TEMPLATE"
            break
        else
            echo "❌ Введите число от 1 до ${#templates[@]}"
        fi
    done
}

# Получение доступных сетевых мостов
get_available_bridges() {
    echo "🌐 Доступные сетевые мосты:"
    for bridge in /sys/class/net/vmbr*; do
        if [[ -d "$bridge" ]]; then
            bridge_name=$(basename "$bridge")
            echo "  - $bridge_name"
        fi
    done
}

# Поиск свободного CTID
find_available_ctid() {
    for id in $(seq $CTID_MIN $CTID_MAX); do
        if ! pct list 2>/dev/null | awk '{print $1}' | grep -q "^$id$"; then
            echo $id
            return 0
        fi
    done
    echo "❌ Не удалось найти свободный CTID в диапазоне $CTID_MIN-$CTID_MAX" >&2
    return 1
}

# Настройка пароля root
setup_root_password() {
    echo ""
    echo "🔐 Настройка пароля root:"
    echo "1. Сгенерировать случайный пароль"
    echo "2. Ввести пароль вручную"
    
    while true; do
        read -p "💬 Выберите вариант (1/2): " choice
        case $choice in
            1)
                ROOT_PASSWORD=$(generate_password)
                echo "✅ Сгенерирован пароль root: $ROOT_PASSWORD"
                break
                ;;
            2)
                while true; do
                    read -s -p "🔒 Введите пароль для root (минимум 8 символов): " PASSWORD1
                    echo
                    read -s -p "🔒 Повторите пароль: " PASSWORD2
                    echo
                    
                    if [[ "$PASSWORD1" != "$PASSWORD2" ]]; then
                        echo "❌ Пароли не совпадают. Попробуйте снова."
                    elif [[ ${#PASSWORD1} -lt 8 ]]; then
                        echo "❌ Пароль должен содержать минимум 8 символов."
                    else
                        ROOT_PASSWORD="$PASSWORD1"
                        echo "✅ Пароль установлен."
                        break
                    fi
                done
                break
                ;;
            *)
                echo "❌ Введите 1 или 2"
                ;;
        esac
    done
}

# Установка пароля в контейнере
set_root_password() {
    local ctid=$1
    local password=$2
    
    echo "🔐 Устанавливаем пароль root в контейнере..."
    
    for attempt in {1..5}; do
        if pct exec $ctid -- bash -c "echo 'root:${password}' | chpasswd" 2>/dev/null; then
            echo "✅ Пароль root успешно установлен."
            return 0
        fi
        sleep 3
    done
    
    echo "⚠️ Не удалось установить пароль root автоматически."
    return 1
}

# Установка VNC
install_vnc_packages() {
    local ctid=$1
    echo "📦 Устанавливаем пакеты для VNC..."
    
    if pct exec $ctid -- apt-get update >/dev/null 2>&1 && \
       pct exec $ctid -- apt-get install -y xorg xfce4 tigervnc-standalone-server firefox-esr >/dev/null 2>&1; then
        pct exec $ctid -- bash -c 'echo -e "#!/bin/bash\nvncserver :1 -geometry 1280x800 -depth 24" > /usr/local/bin/start-vnc'
        pct exec $ctid -- chmod +x /usr/local/bin/start-vnc
        echo "✅ VNC пакеты установлены. Для запуска VNC выполните: start-vnc"
        return 0
    else
        echo "❌ Ошибка установки VNC пакетов"
        return 1
    fi
}

# Запуск внешнего скрипта внутри контейнера
run_external_script() {
    local ctid=$1
    
    echo "🌐 Загружаем и запускаем внешний скрипт внутри контейнера..."
    echo "📥 URL скрипта: $EXTERNAL_SCRIPT_URL"
    
    # Ожидаем полный запуск контейнера
    echo "⏳ Ожидаем запуск контейнера..."
    sleep 10
    
    # Проверяем, запущен ли контейнер
    if ! pct status $ctid | grep -q "running"; then
        echo "❌ Контейнер не запущен. Не могу выполнить скрипт."
        return 1
    fi
    
    # Проверяем доступность сети
    echo "🔍 Проверяем доступность интернета в контейнере..."
    local network_ok=false
    for i in {1..10}; do
        if pct exec $ctid -- ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            network_ok=true
            break
        fi
        sleep 3
    done
    
    if [[ "$network_ok" != "true" ]]; then
        echo "⚠️ Контейнер не имеет доступа в интернет. Пропускаем запуск внешнего скрипта."
        return 1
    fi
    
    echo "✅ Интернет в контейнере доступен"
    
    # Обновляем пакеты и устанавливаем curl
    echo "📦 Обновляем пакеты и устанавливаем curl..."
    if ! pct exec $ctid -- apt-get update >/dev/null 2>&1; then
        echo "❌ Не удалось обновить список пакетов"
        return 1
    fi
    
    if ! pct exec $ctid -- which curl >/dev/null 2>&1; then
        if ! pct exec $ctid -- apt-get install -y curl >/dev/null 2>&1; then
            echo "❌ Не удалось установить curl. Пропускаем запуск скрипта."
            return 1
        fi
    fi
    
    echo "✅ Curl установлен"
    
    # Загружаем и запускаем скрипт
    local script_name="setup-script.sh"
    echo "📥 Загружаем скрипт..."
    if pct exec $ctid -- bash -c "curl -s -o /tmp/$script_name '$EXTERNAL_SCRIPT_URL' && chmod +x /tmp/$script_name"; then
        echo "✅ Скрипт успешно загружен"
        echo "🚀 Запускаем скрипт..."
        if pct exec $ctid -- /tmp/$script_name; then
            echo "✅ Внешний скрипт успешно выполнен"
            return 0
        else
            echo "⚠️ Внешний скрипт завершился с ошибкой"
            return 1
        fi
    else
        echo "❌ Ошибка загрузки внешнего скрипта"
        return 1
    fi
}

# Генерация отчета
generate_report() {
    local ctid=$1
    local name=$2
    local vcpu=$3
    local ram_gb=$4
    local disk_size=$5
    local bridge=$6
    local template=$7
    local password=$8
    local vnc=$9
    local ip=${10}
    local script_status=${11}
    
    local report="
🎉 НОВЫЙ КОНТЕЙНЕР СОЗДАН И ЗАПУЩЕН!

ОСНОВНАЯ ИНФОРМАЦИЯ:
🆔 CTID: $ctid
🏷️ Имя: $name
🌐 IP-адрес: $ip
⚡ vCPU: $vcpu
💾 RAM: ${ram_gb}GB
💿 Диск: ${disk_size}GB
🔌 Сеть: $bridge
📦 Шаблон: $template

ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ:
🖥️ VNC: $vnc
🔧 Скрипт настройки: $script_status
🔐 Пароль root: $password

СИСТЕМНАЯ ИНФОРМАЦИЯ:
🖥️ Узел: $(hostname)
🕐 Создан: $(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "$report"
}

# === Основная логика ===

echo "🐧 Proxmox LXC Container Auto-Creator"
echo "======================================"

# 1. Выбор шаблона
select_template

# 2. Ввод имени контейнера
echo ""
while true; do
    read -p "💬 Введите имя контейнера: " CT_NAME
    if [[ -n "$CT_NAME" && "$CT_NAME" =~ ^[a-zA-Z0-9\-]+$ ]]; then
        break
    else
        echo "❌ Имя может содержать только латинские буквы, цифры и дефисы"
    fi
done

# 3. Настройка параметров контейнера
echo ""
echo "⚙️ Настройка параметров контейнера:"

# vCPU
read -p "💬 Введите количество vCPU [по умолчанию: $DEFAULT_VCPU]: " VCPU
VCPU=${VCPU:-$DEFAULT_VCPU}

# RAM
read -p "💬 Введите объем RAM в GB [по умолчанию: $DEFAULT_RAM_GB]: " RAM_GB
RAM_GB=${RAM_GB:-$DEFAULT_RAM_GB}
RAM_MB=$((RAM_GB * 1024))

# Диск
read -p "💬 Введите размер диска в GB [по умолчанию: $DEFAULT_DISK_GB]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_GB}

# Сетевой мост
get_available_bridges
read -p "💬 Введите имя сетевого моста [по умолчанию: $DEFAULT_BRIDGE]: " BRIDGE
BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}

# Настройка сети
read -p "💬 Введите IP-адрес в формате CIDR или оставьте пустым для DHCP: " IP_ADDRESS
if [[ -n "$IP_ADDRESS" ]]; then
    if [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        read -p "💬 Введите IP-адрес шлюза: " GATEWAY
        if [[ -z "$GATEWAY" ]]; then
            echo "❌ Шлюз не может быть пустым"
            exit 1
        fi
        NET_OPTION="name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY"
    else
        echo "❌ Неверный формат IP-адреса"
        exit 1
    fi
else
    NET_OPTION="name=eth0,bridge=$BRIDGE,ip=dhcp"
fi

# VLAN
read -p "💬 Введите VLAN ID (оставьте пустым если не требуется): " VLAN_ID
if [[ -n "$VLAN_ID" && "$VLAN_ID" =~ ^[0-9]+$ ]]; then
    NET_OPTION="${NET_OPTION},tag=$VLAN_ID"
fi

# 4. Настройка пароля root
setup_root_password

# 5. Установка VNC
echo ""
read -p "💬 Установить базовые пакеты для VNC? (y/n) [n]: " INSTALL_VNC
INSTALL_VNC=${INSTALL_VNC:-$DEFAULT_INSTALL_VNC}

# 6. Подтверждение параметров
echo ""
echo "📋 Параметры контейнера:"
echo "========================"
echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
echo "🏷️ Имя: $CT_NAME"
echo "⚡ vCPU: $VCPU"
echo "💾 RAM: ${RAM_GB}GB"
echo "💿 Диск: ${DISK_SIZE}GB"
echo "🌐 Сеть: $BRIDGE"
[[ -n "$IP_ADDRESS" ]] && echo "📡 IP-адрес: $IP_ADDRESS"
[[ -n "$GATEWAY" ]] && echo "🌉 Шлюз: $GATEWAY"
[[ -n "$VLAN_ID" ]] && echo "🏷️ VLAN: $VLAN_ID"
echo "🖥️ VNC: $INSTALL_VNC"
echo "🔐 Пароль: $ROOT_PASSWORD"
echo ""

read -p "💬 Все параметры верны? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Создание отменено"
    exit 1
fi

# 7. Создание контейнера
echo ""
echo "🛠️ Создаем контейнер..."

# Поиск свободного CTID
NEW_CTID=$(find_available_ctid)
if [[ $? -ne 0 ]]; then
    echo "❌ $NEW_CTID"
    exit 1
fi
echo "✅ Выбран CTID: $NEW_CTID"

# Создание контейнера
if pct create $NEW_CTID "$TEMPLATE_FILE" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --hostname "$CT_NAME" \
    --cores "$VCPU" \
    --memory "$RAM_MB" \
    --net0 "$NET_OPTION" \
    --onboot 1 \
    --unprivileged 0 \
    --features nesting=1; then
    
    echo "✅ Контейнер создан!"
else
    echo "❌ Ошибка при создании контейнера!"
    exit 1
fi

# 8. Запуск контейнера
echo ""
echo "🚀 Запускаем контейнер..."
pct start $NEW_CTID
sleep 10

# Проверяем запуск
if ! pct status $NEW_CTID | grep -q "running"; then
    echo "❌ Контейнер не запустился"
    exit 1
fi
echo "✅ Контейнер запущен"

# 9. Установка пароля
set_root_password $NEW_CTID "$ROOT_PASSWORD"

# 10. Установка VNC (если нужно)
if [[ "$INSTALL_VNC" =~ ^[Yy]$ ]]; then
    install_vnc_packages $NEW_CTID
fi

# 11. Запуск внешнего скрипта (если URL указан)
EXTERNAL_SCRIPT_STATUS="не выполнялся"
if [[ -n "$EXTERNAL_SCRIPT_URL" ]]; then
    echo ""
    read -p "💬 Запустить скрипт настройки внутри контейнера? (y/n) [n]: " RUN_SCRIPT
    RUN_SCRIPT=${RUN_SCRIPT:-"n"}
    
    if [[ "$RUN_SCRIPT" =~ ^[Yy]$ ]]; then
        if run_external_script $NEW_CTID; then
            EXTERNAL_SCRIPT_STATUS="успешно выполнен"
        else
            EXTERNAL_SCRIPT_STATUS="завершился с ошибкой"
        fi
    else
        EXTERNAL_SCRIPT_STATUS="пропущен"
    fi
else
    EXTERNAL_SCRIPT_STATUS="URL не указан в конфигурации"
fi

# 12. Получение IP-адреса
CONTAINER_IP=$(get_container_ip $NEW_CTID)

# 13. Финальный отчет
echo ""
REPORT=$(generate_report "$NEW_CTID" "$CT_NAME" "$VCPU" "$RAM_GB" "$DISK_SIZE" "$BRIDGE" "$(basename "$TEMPLATE_FILE")" "$ROOT_PASSWORD" "$INSTALL_VNC" "$CONTAINER_IP" "$EXTERNAL_SCRIPT_STATUS")

# 14. Отправка в Telegram или вывод в консоль
if [[ "$TELEGRAM_ENABLED" == "y" ]]; then
    echo "📤 Отправляем отчет в Telegram..."
    send_telegram_message "$REPORT"
else
    echo "$REPORT"
fi

echo ""
echo "✅ Все операции завершены!"