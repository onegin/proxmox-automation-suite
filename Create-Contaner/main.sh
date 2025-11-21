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

# === Проверка обязательных параметров ===
if [[ -z "$DEFAULT_TEMPLATE_DIR" || -z "$STORAGE" || -z "$DEFAULT_BRIDGE" ]]; then
    echo "❌ В конфигурации отсутствуют обязательные параметры"
    exit 1
fi

# === Функция получения IP-адреса контейнера ===
get_container_ip() {
    local ctid=$1
    for attempt in {1..10}; do
        local ip=$(pct exec $ctid -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
        [[ -n "$ip" && "$ip" != "127.0.0.1" ]] && echo "$ip" && return 0
        sleep 3
    done
    echo "unknown"
}

# === Функция отправки уведомления в Telegram ===
send_telegram_message() {
    [[ "$TELEGRAM_ENABLED" != "y" ]] && return 0
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 1
    
    local escaped_message=$(echo "$1" | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g')
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"$escaped_message\",\"parse_mode\":\"Markdown\"}" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null && echo "✅ Уведомление отправлено в Telegram"
}

# === Функция генерации отчета для Telegram ===
generate_telegram_report() {
    local report="🎉 *Новый контейнер создан!* 🎉

*Основная информация:*
🆔 CTID: \`$1\`
🏷️ Имя: \`$2\`
🌐 IP-адрес: \`${10}\`
⚡ vCPU: \`$3\`
💾 RAM: \`${4}GB\`
💿 Диск: \`${5}GB\`
🔌 Сеть: \`$6\`
📦 Шаблон: \`$7\`

*Дополнительные настройки:*
🖥️ VNC: \`$9\`"

    [[ -n "$8" && "$PASSWORD_CHOICE" == "1" ]] && report="$report\n🔐 Пароль root: \`$8\`"
    [[ -n "$8" && "$PASSWORD_CHOICE" != "1" ]] && report="$report\n🔐 Пароль root: установлен вручную"

    report="$report

*Системная информация:*
🖥️ Узел: \`$(hostname)\`
🕐 Создан: $(date '+%Y-%m-%d %H:%M:%S')"

    echo -e "$report"
}

# === Функция выбора шаблона ===
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
    echo "┌─────────────────────────────────────────────────────"
    for i in "${!templates[@]}"; do
        printf "│ %2d. %s\n" $((i+1)) "${templates[i]}"
    done
    echo "└─────────────────────────────────────────────────────"
    
    while true; do
        read -p "💬 Выберите шаблон (1-${#templates[@]}) [1]: " choice
        choice=${choice:-1}
        
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

# === Функция генерации случайного пароля ===
generate_password() {
    local length=8
    local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    local password=$(head /dev/urandom | tr -dc "$chars" | head -c $length)
    echo "$password"
}

# === Проверка наличия шаблона ===
check_template_file() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        echo "❌ Файл шаблона не найден: $TEMPLATE_FILE"
        exit 1
    fi
    echo "📦 Используется шаблон: $(basename "$TEMPLATE_FILE")"
}

# === Функция для получения доступных ресурсов ===
get_available_bridges() {
    echo "🌐 Доступные сетевые мосты:"
    for bridge in /sys/class/net/vmbr*; do
        if [[ -d "$bridge" ]]; then
            bridge_name=$(basename "$bridge")
            bridge_alias=$(grep -A 10 "iface $bridge_name" /etc/network/interfaces 2>/dev/null | grep -oP 'alias\s+\K.*' | head -1)
            if [[ -n "$bridge_alias" ]]; then
                echo "  🔌 - $bridge_name (alias: $bridge_alias)"
            else
                echo "  🔌 - $bridge_name"
            fi
        fi
    done
}

get_available_cores() {
    local total_cores=$(nproc)
    echo "⚡ Доступно CPU ядер: $total_cores"
    return $total_cores
}

get_available_memory() {
    local total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem / 1024 / 1024))
    echo "💾 Доступно RAM: ${total_mem_gb}GB"
    return $total_mem_gb
}

# === Функция поиска свободного CTID ===
find_available_ctid() {
    for id in $(seq $CTID_MIN $CTID_MAX); do
        if ! pct list 2>/dev/null | awk '{print $1}' | grep -q "^$id$"; then
            echo $id
            return 0
        fi
        echo "🔄 CTID $id занят, проверяем следующий..." >&2
    done
    echo "❌ Не удалось найти свободный CTID в диапазоне $CTID_MIN-$CTID_MAX" >&2
    return 1
}

# === Функция для настройки пароля root ===
setup_root_password() {
    local mode=$1
    
    if [[ "$mode" == "defaults" ]]; then
        ROOT_PASSWORD=$(generate_password)
        echo "🔐 Сгенерирован пароль root: $ROOT_PASSWORD"
        return 0
    fi
    
    echo
    echo "🔐 Настройка пароля root ==="
    echo "1. Сгенерировать случайный пароль"
    echo "2. Ввести пароль вручную"
    read -p "💬 Выберите вариант [1]: " PASSWORD_CHOICE
    PASSWORD_CHOICE=${PASSWORD_CHOICE:-1}
    
    case $PASSWORD_CHOICE in
        1)
            ROOT_PASSWORD=$(generate_password)
            echo "🔐 Сгенерирован пароль root: $ROOT_PASSWORD"
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
            ;;
        *)
            echo "⚠️ Будет сгенерирован случайный пароль."
            ROOT_PASSWORD=$(generate_password)
            echo "🔐 Сгенерирован пароль root: $ROOT_PASSWORD"
            ;;
    esac
}

# === Функция для установки пароля в контейнере ===
set_root_password() {
    local ctid=$1
    local password=$2
    
    echo "🔐 Устанавливаем пароль root в контейнере..."
    
    for attempt in {1..5}; do
        echo "🔄 Попытка $attempt установки пароля..."
        if pct exec $ctid -- bash -c "echo 'root:${password}' | chpasswd" 2>/dev/null; then
            echo "✅ Пароль root успешно установлен."
            return 0
        fi
        sleep 3
    done
    
    echo "⚠️ Не удалось установить пароль root автоматически."
    return 1
}

# === Функция установки VNC ===
install_vnc_packages() {
    local ctid=$1
    echo "📦 Устанавливаем пакеты для VNC..."
    pct exec $ctid -- apt-get update
    pct exec $ctid -- apt-get install -y xorg xfce4 tigervnc-standalone-server firefox-esr
    pct exec $ctid -- bash -c 'echo -e "#!/bin/bash\nvncserver :1 -geometry 1280x800 -depth 24" > /usr/local/bin/start-vnc'
    pct exec $ctid -- chmod +x /usr/local/bin/start-vnc
    echo "✅ VNC пакеты установлены. Для запуска VNC выполните: start-vnc"
}

# === Функция для использования значений по умолчанию ===
use_defaults() {
    echo "🚀 Режим использования значений по умолчанию ==="
    echo
    
    TEMPLATE_FILE="$DEFAULT_TEMPLATE_DIR/$DEFAULT_TEMPLATE"
    check_template_file
    echo
    
    while true; do
        read -p "💬 Введите имя контейнера: " CT_NAME
        if [[ -n "$CT_NAME" && "$CT_NAME" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            break
        else
            echo "❌ Имя может содержать только латинские буквы, цифры и дефисы"
        fi
    done
    
    VCPU=$DEFAULT_VCPU
    RAM_GB=$DEFAULT_RAM_GB
    RAM_MB=$((RAM_GB * 1024))
    DISK_SIZE=$DEFAULT_DISK_GB
    BRIDGE=$DEFAULT_BRIDGE
    INSTALL_VNC=$DEFAULT_INSTALL_VNC
    NET_OPTION="name=eth0,bridge=$BRIDGE,ip=dhcp"
    
    setup_root_password "defaults"
    
    if [[ ! -d "/sys/class/net/$BRIDGE" ]]; then
        echo "❌ Мост '$BRIDGE' не существует."
        get_available_bridges
        exit 1
    fi
    
    echo
    echo "📋 Параметры контейнера (по умолчанию) ==="
    echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
    echo "🏷️ Имя: $CT_NAME"
    echo "⚡ vCPU: $VCPU"
    echo "💾 RAM: ${RAM_GB}GB"
    echo "💿 Диск: ${DISK_SIZE}GB"
    echo "🌐 Сеть: $BRIDGE"
    echo "🖥️ VNC: $INSTALL_VNC"
    echo "🔐 Пароль: $ROOT_PASSWORD"
    [[ "$TELEGRAM_ENABLED" == "y" ]] && echo "📱 Telegram: включены"
    echo
}

# === Функция для интерактивного ввода ===
interactive_input() {
    echo "🐧 Создание нового контейнера в Proxmox ==="
    echo

    select_template
    echo

    while true; do
        read -p "💬 Введите имя контейнера: " CT_NAME
        if [[ -n "$CT_NAME" && "$CT_NAME" =~ ^[a-zA-Z0-9\-]+$ ]]; then
            break
        else
            echo "❌ Имя может содержать только латинские буквы, цифры и дефисы"
        fi
    done

    setup_root_password "interactive"

    get_available_cores
    TOTAL_CORES=$?
    read -p "💬 Введите количество vCPU [по умолчанию: $DEFAULT_VCPU]: " VCPU
    VCPU=${VCPU:-$DEFAULT_VCPU}
    [[ ! "$VCPU" =~ ^[0-9]+$ ]] || [ "$VCPU" -lt 1 ] || [ "$VCPU" -gt "$TOTAL_CORES" ] && echo "❌ Введите число от 1 до $TOTAL_CORES" && exit 1

    get_available_memory
    TOTAL_MEM_GB=$?
    read -p "💬 Введите объем RAM в GB [по умолчанию: $DEFAULT_RAM_GB]: " RAM_GB
    RAM_GB=${RAM_GB:-$DEFAULT_RAM_GB}
    [[ ! "$RAM_GB" =~ ^[0-9]+$ ]] || [ "$RAM_GB" -lt 1 ] || [ "$RAM_GB" -gt "$TOTAL_MEM_GB" ] && echo "❌ Введите число от 1 до $TOTAL_MEM_GB" && exit 1
    RAM_MB=$((RAM_GB * 1024))

    read -p "💬 Введите размер диска в GB [по умолчанию: $DEFAULT_DISK_GB]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_GB}
    [[ ! "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 2 ] && echo "❌ Введите число не менее 2 GB" && exit 1

    get_available_bridges
    read -p "💬 Введите имя сетевого моста [по умолчанию: $DEFAULT_BRIDGE]: " BRIDGE
    BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}
    [[ -n "$BRIDGE" ]] && [[ ! -d "/sys/class/net/$BRIDGE" ]] && echo "❌ Мост '$BRIDGE' не существует." && exit 1

    read -p "💬 Введите IP-адрес в формате CIDR или оставьте пустым для DHCP: " IP_ADDRESS
    if [[ -n "$IP_ADDRESS" ]]; then
        [[ ! "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && echo "❌ Неверный формат IP-адреса" && exit 1
        read -p "💬 Введите IP-адрес шлюза: " GATEWAY
        [[ -z "$GATEWAY" ]] && echo "❌ Шлюз не может быть пустым" && exit 1
        NET_OPTION="name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY"
    else
        NET_OPTION="name=eth0,bridge=$BRIDGE,ip=dhcp"
    fi

    read -p "💬 Введите VLAN ID (оставьте пустым если не требуется): " VLAN_ID
    [[ -n "$VLAN_ID" ]] && [[ "$VLAN_ID" =~ ^[0-9]+$ ]] && NET_OPTION="${NET_OPTION},tag=$VLAN_ID"

    echo
    echo "🖥️ Настройка VNC консоли ==="
    read -p "💬 Установить базовые пакеты для VNC? (y/n) [n]: " INSTALL_VNC
    INSTALL_VNC=${INSTALL_VNC:-$DEFAULT_INSTALL_VNC}

    echo
    echo "📋 Параметры контейнера ==="
    echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
    echo "🏷️ Имя: $CT_NAME"
    echo "⚡ vCPU: $VCPU"
    echo "💾 RAM: ${RAM_GB}GB"
    echo "💿 Диск: ${DISK_SIZE}GB"
    echo "🌐 Сеть: $BRIDGE"
    [[ -n "$IP_ADDRESS" ]] && echo "📡 IP-адрес: $IP_ADDRESS"
    [[ -n "$VLAN_ID" ]] && echo "🏷️ VLAN: $VLAN_ID"
    echo "🖥️ VNC: $INSTALL_VNC"
    [[ -n "$ROOT_PASSWORD" ]] && echo "🔐 Пароль: $ROOT_PASSWORD"
    [[ "$TELEGRAM_ENABLED" == "y" ]] && echo "📱 Telegram: включены"
    echo

    read -p "💬 Все параметры верны? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "❌ Создание отменено" && exit 1
}

# === Основная логика ===
main() {
    [[ "$1" == "--defaults" ]] && use_defaults || interactive_input
    
    echo "🔍 Ищем свободный CTID..."
    NEW_CTID=$(find_available_ctid) || exit 1
    echo "✅ Выбран CTID: $NEW_CTID"

    echo "🛠️ Создаем контейнер..."
    eval "pct create $NEW_CTID \"$TEMPLATE_FILE\" --storage \"$STORAGE\" --rootfs \"${STORAGE}:${DISK_SIZE}\" --hostname \"$CT_NAME\" --cores \"$VCPU\" --memory \"$RAM_MB\" --net0 \"$NET_OPTION\" --onboot 1 --unprivileged 0 --features nesting=1"

    if [ $? -eq 0 ]; then
        echo "✅ Контейнер создан!"
        
        echo "🚀 Запускаем контейнер..."
        pct start $NEW_CTID
        sleep 10
        
        [[ -n "$ROOT_PASSWORD" ]] && set_root_password $NEW_CTID "$ROOT_PASSWORD"
        
        [[ "$INSTALL_VNC" =~ ^[Yy]$ ]] && install_vnc_packages $NEW_CTID
        
        CONTAINER_IP=$(get_container_ip $NEW_CTID)
        
        if [[ "$TELEGRAM_ENABLED" == "y" ]]; then
            echo "📤 Отправляем отчет в Telegram..."
            send_telegram_message "$(generate_telegram_report "$NEW_CTID" "$CT_NAME" "$VCPU" "$RAM_GB" "$DISK_SIZE" "$BRIDGE" "$(basename "$TEMPLATE_FILE")" "$ROOT_PASSWORD" "$INSTALL_VNC" "$CONTAINER_IP")"
        fi
        
        echo "🎉 Контейнер успешно создан и запущен!"
        echo "🆔 CTID: $NEW_CTID | 🏷️ Имя: $CT_NAME | 🌐 IP: $CONTAINER_IP"
        echo "⚡ vCPU: $VCPU | 💾 RAM: ${RAM_GB}GB | 💿 Диск: ${DISK_SIZE}GB"
        
    else
        echo "❌ Ошибка при создании контейнера!"
        exit 1
    fi
}

main "$@"