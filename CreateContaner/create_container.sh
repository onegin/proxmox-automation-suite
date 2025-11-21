#!/bin/bash

# === Конфигурация по умолчанию ===
DEFAULT_TEMPLATE_DIR="/var/lib/vz/template/cache"
DEFAULT_TEMPLATE="debian-13-standard_13.1-2_amd64.tar.zst"
TEMPLATE_FILE="$DEFAULT_TEMPLATE_DIR/$DEFAULT_TEMPLATE"
TARGET_NODE="pve"
STORAGE="local"
DEFAULT_VCPU=2
DEFAULT_RAM_GB=4
DEFAULT_DISK_GB=8
DEFAULT_BRIDGE="vmbr1"
DEFAULT_INSTALL_VNC="n"

# === Функция выбора шаблона ===
select_template() {
    echo "📁 Проверяем доступные шаблоны в: $DEFAULT_TEMPLATE_DIR"
    
    # Получаем список доступных шаблонов
    local templates=()
    while IFS= read -r -d $'\0' file; do
        templates+=("$(basename "$file")")
    done < <(find "$DEFAULT_TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.tar.zst" -o -name "*.tar.gz" -o -name "*.tar.xz" \) -print0 2>/dev/null)
    
    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "❌ Ошибка: В папке $DEFAULT_TEMPLATE_DIR не найдено шаблонов контейнеров"
        echo "💡 Доступные форматы: .tar.zst, .tar.gz, .tar.xz"
        exit 1
    fi
    
    echo "📋 Доступные шаблоны:"
    echo "┌─────────────────────────────────────────────────────"
    for i in "${!templates[@]}"; do
        printf "│ %2d. %s\n" $((i+1)) "${templates[i]}"
    done
    echo "└─────────────────────────────────────────────────────"
    
    # Запрос выбора шаблона
    while true; do
        read -p "💬 Выберите шаблон (1-${#templates[@]}) [1]: " choice
        choice=${choice:-1}
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#templates[@]}" ]; then
            SELECTED_TEMPLATE="${templates[$((choice-1))]}"
            TEMPLATE_FILE="$DEFAULT_TEMPLATE_DIR/$SELECTED_TEMPLATE"
            echo "✅ Выбран шаблон: $SELECTED_TEMPLATE"
            break
        else
            echo "❌ Ошибка: Введите число от 1 до ${#templates[@]}"
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

# === Проверка наличия ZST файла ===
check_template_file() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        echo "❌ Ошибка: Файл шаблона не найден: $TEMPLATE_FILE"
        echo "📁 Доступные шаблоны в $DEFAULT_TEMPLATE_DIR:"
        find "$DEFAULT_TEMPLATE_DIR" -maxdepth 1 -type f \( -name "*.tar.zst" -o -name "*.tar.gz" -o -name "*.tar.xz" \) -exec basename {} \; 2>/dev/null | while read -r file; do
            echo "  📄 - $file"
        done
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
            # Получаем описание моста из конфигурации Proxmox
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

# === Исправленная функция поиска свободного CTID ===
find_available_ctid() {
    for id in {700..750}; do
        # Проверяем существует ли контейнер с таким ID
        if ! pct list 2>/dev/null | awk '{print $1}' | grep -q "^$id$"; then
            echo $id
            return 0
        fi
        echo "🔄 CTID $id занят, проверяем следующий..." >&2
    done
    echo "❌ Ошибка: Не удалось найти свободный CTID в диапазоне 700-750" >&2
    return 1
}

# === Функция для настройки пароля root ===
setup_root_password() {
    local mode=$1
    
    if [[ "$mode" == "defaults" ]]; then
        # В режиме defaults генерируем случайный пароль
        ROOT_PASSWORD=$(generate_password)
        echo "🔐 Сгенерирован пароль root: $ROOT_PASSWORD"
        return 0
    fi
    
    # В интерактивном режиме предлагаем выбор
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
                    echo "❌ Ошибка: Пароли не совпадают. Попробуйте снова."
                elif [[ ${#PASSWORD1} -lt 8 ]]; then
                    echo "❌ Ошибка: Пароль должен содержать минимум 8 символов."
                else
                    ROOT_PASSWORD="$PASSWORD1"
                    echo "✅ Пароль установлен."
                    break
                fi
            done
            ;;
        *)
            echo "⚠️ Неверный выбор. Будет сгенерирован случайный пароль."
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
    
    # Пытаемся установить пароль через несколько попыток
    for attempt in {1..5}; do
        echo "🔄 Попытка $attempt установки пароля..."
        if pct exec $ctid -- bash -c "echo 'root:${password}' | chpasswd" 2>/dev/null; then
            echo "✅ Пароль root успешно установлен."
            return 0
        fi
        echo "⏳ Не удалось установить пароль. Ждем 3 секунды перед повторной попыткой..."
        sleep 3
    done
    
    echo "⚠️ ВНИМАНИЕ: Не удалось установить пароль root автоматически."
    echo "💡 Вы можете установить его вручную после подключения к контейнеру:"
    echo "  pct enter $ctid"
    echo "  passwd root"
    return 1
}

# === Функция для использования значений по умолчанию ===
use_defaults() {
    echo "🚀 Режим использования значений по умолчанию ==="
    echo
    
    # Проверяем наличие шаблона по умолчанию
    check_template_file
    echo
    
    # Запрос только имени контейнера
    while true; do
        read -p "💬 Введите имя контейнера (будет использоваться как hostname): " CT_NAME
        if [[ -n "$CT_NAME" ]]; then
            # Проверяем, что имя содержит только допустимые символы для hostname
            if [[ "$CT_NAME" =~ ^[a-zA-Z0-9\-]+$ ]]; then
                break
            else
                echo "❌ Ошибка: Имя может содержать только латинские буквы, цифры и дефисы"
            fi
        else
            echo "❌ Ошибка: Имя не может быть пустым"
        fi
    done
    
    # Устанавливаем значения по умолчанию
    VCPU=$DEFAULT_VCPU
    RAM_GB=$DEFAULT_RAM_GB
    RAM_MB=$((RAM_GB * 1024))
    DISK_SIZE=$DEFAULT_DISK_GB
    BRIDGE=$DEFAULT_BRIDGE
    INSTALL_VNC=$DEFAULT_INSTALL_VNC
    
    # Используем DHCP по умолчанию
    NET_OPTION="name=eth0,bridge=$BRIDGE,ip=dhcp"
    
    # Настраиваем пароль root
    setup_root_password "defaults"
    
    # Проверяем существование сетевого моста
    if [[ ! -d "/sys/class/net/$BRIDGE" ]]; then
        echo "❌ Ошибка: Мост по умолчанию '$BRIDGE' не существует. Доступные мосты:"
        get_available_bridges
        exit 1
    fi
    
    # Выводим параметры
    echo
    echo "📋 Параметры контейнера (используются значения по умолчанию) ==="
    echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
    echo "🏷️ Имя контейнера (hostname): $CT_NAME"
    echo "⚡ vCPU: $VCPU"
    echo "💾 RAM: ${RAM_GB}GB (${RAM_MB}MB)"
    echo "💿 Диск: ${DISK_SIZE}GB"
    echo "🌐 Сетевой мост: $BRIDGE"
    echo "📡 IP-адрес: DHCP"
    echo "🖥️ Установка VNC: $INSTALL_VNC"
    echo "🔐 Пароль root: $ROOT_PASSWORD"
    echo
}

# === Функция для интерактивного ввода ===
interactive_input() {
    echo "🐧 Создание нового контейнера в Proxmox ==="
    echo

    # Выбор шаблона
    select_template
    echo

    # Запрос имени контейнера (будет использоваться как hostname)
    while true; do
        read -p "💬 Введите имя контейнера (будет использоваться как hostname): " CT_NAME
        if [[ -n "$CT_NAME" ]]; then
            # Проверяем, что имя содержит только допустимые символы для hostname
            if [[ "$CT_NAME" =~ ^[a-zA-Z0-9\-]+$ ]]; then
                break
            else
                echo "❌ Ошибка: Имя может содержать только латинские буквы, цифры и дефисы"
            fi
        else
            echo "❌ Ошибка: Имя не может быть пустым"
        fi
    done

    # Настраиваем пароль root
    setup_root_password "interactive"

    # Запрос количества vCPU (с значением по умолчанию)
    get_available_cores
    TOTAL_CORES=$?
    read -p "💬 Введите количество vCPU [по умолчанию: $DEFAULT_VCPU]: " VCPU
    VCPU=${VCPU:-$DEFAULT_VCPU}
    if [[ ! "$VCPU" =~ ^[0-9]+$ ]] || [ "$VCPU" -lt 1 ] || [ "$VCPU" -gt "$TOTAL_CORES" ]; then
        echo "❌ Ошибка: Введите число от 1 до $TOTAL_CORES"
        exit 1
    fi

    # Запрос объема RAM (с значением по умолчанию)
    get_available_memory
    TOTAL_MEM_GB=$?
    read -p "💬 Введите объем RAM в GB [по умолчанию: $DEFAULT_RAM_GB]: " RAM_GB
    RAM_GB=${RAM_GB:-$DEFAULT_RAM_GB}
    if [[ ! "$RAM_GB" =~ ^[0-9]+$ ]] || [ "$RAM_GB" -lt 1 ] || [ "$RAM_GB" -gt "$TOTAL_MEM_GB" ]; then
        echo "❌ Ошибка: Введите число от 1 до $TOTAL_MEM_GB"
        exit 1
    fi
    RAM_MB=$((RAM_GB * 1024))

    # Запрос размера диска (с значением по умолчанию)
    read -p "💬 Введите размер диска в GB [по умолчанию: $DEFAULT_DISK_GB]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_GB}
    if [[ ! "$DISK_SIZE" =~ ^[0-9]+$ ]] || [ "$DISK_SIZE" -lt 2 ]; then
        echo "❌ Ошибка: Введите число не менее 2 GB"
        exit 1
    fi

    # Запрос сетевых параметров (с значением по умолчанию)
    get_available_bridges
    read -p "💬 Введите имя сетевого моста [по умолчанию: $DEFAULT_BRIDGE]: " BRIDGE
    BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}
    if [[ -n "$BRIDGE" ]] && [[ ! -d "/sys/class/net/$BRIDGE" ]]; then
        echo "❌ Ошибка: Мост '$BRIDGE' не существует. Доступные мосты:"
        get_available_bridges
        exit 1
    fi

    # Запрос IP-адреса
    read -p "💬 Введите IP-адрес в формате CIDR (например: 192.168.1.100/24) или оставьте пустым для DHCP: " IP_ADDRESS
    if [[ -n "$IP_ADDRESS" ]]; then
        # Проверка формата IP-адреса
        if [[ ! "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "❌ Ошибка: Неверный формат IP-адреса. Используйте формат: 192.168.1.100/24"
            exit 1
        fi
        # Запрос шлюза, если указан IP
        read -p "💬 Введите IP-адрес шлюза: " GATEWAY
        if [[ -z "$GATEWAY" ]]; then
            echo "❌ Ошибка: Шлюз не может быть пустым при указании статического IP"
            exit 1
        fi
        NET_OPTION="name=eth0,bridge=$BRIDGE,ip=$IP_ADDRESS,gw=$GATEWAY"
    else
        NET_OPTION="name=eth0,bridge=$BRIDGE,ip=dhcp"
    fi

    # Запрос VLAN (опционально)
    read -p "💬 Введите VLAN ID (оставьте пустым если не требуется): " VLAN_ID
    if [[ -n "$VLAN_ID" ]] && [[ "$VLAN_ID" =~ ^[0-9]+$ ]]; then
        NET_OPTION="${NET_OPTION},tag=$VLAN_ID"
    fi

    # Настройки для VNC консоли с автовыбором на "n" (2 пункт)
    echo
    echo "🖥️ Настройка VNC консоли ==="
    echo "ℹ️ Для работы VNC консоли в веб-интерфейсе Proxmox необходимо:"
    echo "1. Установить пакеты для графической среды внутри контейнера"
    echo "2. Настроить VNC сервер"
    echo
    read -p "💬 Установить базовые пакеты для VNC (xorg, xfce4, tigervnc)? (y/n) [n]: " INSTALL_VNC
    INSTALL_VNC=${INSTALL_VNC:-$DEFAULT_INSTALL_VNC}

    # Подтверждение параметров
    echo
    echo "📋 Параметры контейнера ==="
    echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
    echo "🏷️ Имя контейнера (hostname): $CT_NAME"
    echo "⚡ vCPU: $VCPU"
    echo "💾 RAM: ${RAM_GB}GB (${RAM_MB}MB)"
    echo "💿 Диск: ${DISK_SIZE}GB"
    echo "🌐 Сетевой мост: $BRIDGE"
    if [[ -n "$IP_ADDRESS" ]]; then
        echo "📡 IP-адрес: $IP_ADDRESS"
        echo "🛣️ Шлюз: $GATEWAY"
    else
        echo "📡 IP-адрес: DHCP"
    fi
    if [[ -n "$VLAN_ID" ]]; then
        echo "🏷️ VLAN: $VLAN_ID"
    fi
    echo "🖥️ Установка VNC: $INSTALL_VNC"
    if [[ -n "$ROOT_PASSWORD" ]]; then
        if [[ "$PASSWORD_CHOICE" == "1" ]] || [[ "$mode" == "defaults" ]]; then
            echo "🔐 Пароль root: $ROOT_PASSWORD"
        else
            echo "🔐 Пароль root: ******* (установлен вручную)"
        fi
    fi
    echo

    read -p "💬 Все параметры верны? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "❌ Создание контейнера отменено"
        exit 1
    fi
}

# === Основная логика скрипта ===
main() {
    # Проверяем наличие ключа --defaults
    if [[ "$1" == "--defaults" ]]; then
        use_defaults
    else
        interactive_input
    fi

    # === Поиск свободного CTID ===
    echo "🔍 Ищем свободный CTID в диапазоне 700-750..."
    NEW_CTID=$(find_available_ctid)
    EXIT_CODE=$?
    if [[ $EXIT_CODE -ne 0 ]]; then
        echo "❌ Не удалось найти свободный CTID"
        exit 1
    fi

    echo "✅ Выбран CTID: $NEW_CTID"

    # === Создание контейнера ===
    echo "🛠️ Создаем контейнер..."

    # Формируем команду создания контейнера
    CREATE_CMD="pct create $NEW_CTID \"$TEMPLATE_FILE\" --storage \"$STORAGE\" --rootfs \"${STORAGE}:${DISK_SIZE}\" --hostname \"$CT_NAME\" --cores \"$VCPU\" --memory \"$RAM_MB\" --net0 \"$NET_OPTION\" --onboot 1 --unprivileged 0 --features nesting=1"

    # Выводим команду для отладки
    echo "⚙️ Выполняем: $CREATE_CMD"

    # Выполняем создание контейнера
    eval $CREATE_CMD

    if [ $? -eq 0 ]; then
        echo "✅ Контейнер успешно создан!"
        
        # === Запуск контейнера ===
        echo "🚀 Запускаем контейнер..."
        pct start $NEW_CTID
        
        # Ждем немного для инициализации
        echo "⏳ Ждем инициализации контейнера..."
        sleep 10
        
        # === Установка пароля root ===
        if [[ -n "$ROOT_PASSWORD" ]]; then
            set_root_password $NEW_CTID "$ROOT_PASSWORD"
        fi
        
        # Установка пакетов для VNC, если запрошено
        if [[ "$INSTALL_VNC" =~ ^[Yy]$ ]]; then
            echo "📦 Устанавливаем пакеты для VNC..."
            pct exec $NEW_CTID -- apt-get update
            pct exec $NEW_CTID -- apt-get install -y xorg xfce4 tigervnc-standalone-server firefox-esr
            pct exec $NEW_CTID -- bash -c 'echo -e "#!/bin/bash\nvncserver :1 -geometry 1280x800 -depth 24" > /usr/local/bin/start-vnc'
            pct exec $NEW_CTID -- chmod +x /usr/local/bin/start-vnc
            echo "✅ VNC пакеты установлены. Для запуска VNC выполните внутри контейнера: start-vnc"
        fi
        
        # Проверяем статус
        echo "📊 Проверяем статус контейнера..."
        pct status $NEW_CTID
        
        echo
        echo "🎉 Контейнер успешно создан и запущен! ==="
        echo "🆔 CTID: $NEW_CTID"
        echo "🏷️ Имя: $CT_NAME"
        echo "🏠 Hostname: $CT_NAME"
        echo "⚡ vCPU: $VCPU"
        echo "💾 RAM: ${RAM_GB}GB"
        echo "💿 Диск: ${DISK_SIZE}GB"
        echo "🌐 Сеть: $BRIDGE"
        echo "📡 IP-адрес: DHCP"
        echo "📦 Шаблон: $(basename "$TEMPLATE_FILE")"
        if [[ -n "$ROOT_PASSWORD" ]]; then
            if [[ "$PASSWORD_CHOICE" == "1" ]] || [[ "$1" == "--defaults" ]]; then
                echo "🔐 Пароль root: $ROOT_PASSWORD"
            else
                echo "🔐 Пароль root: установлен вручную"
            fi
        fi
        echo
        echo "🔧 Для подключения: pct enter $NEW_CTID"
        echo "📊 Для просмотра статуса: pct status $NEW_CTID"
        echo "📝 Для просмотра логов: pct logs $NEW_CTID"
        echo "🛑 Для остановки: pct stop $NEW_CTID"
        echo "🔄 Для перезагрузки: pct reboot $NEW_CTID"
        
        # Дополнительная диагностика
        echo
        echo "🔍 Диагностическая информация ==="
        echo "🌐 Проверка сети в контейнере:"
        pct exec $NEW_CTID -- ip addr show eth0 2>/dev/null || echo "⚠️ Не удалось выполнить команду в контейнере"
        
        # Информация о VNC
        if [[ "$INSTALL_VNC" =~ ^[Yy]$ ]]; then
            echo
            echo "🖥️ Информация о VNC ==="
            echo "💡 Для работы VNC через веб-интерфейс Proxmox:"
            echo "1. 🔌 Подключитесь к контейнеру: pct enter $NEW_CTID"
            echo "2. 🚀 Запустите VNC сервер: start-vnc"
            echo "3. 🔢 VNC будет доступен на порту 5901"
            echo "4. 🌐 Для доступа через веб используйте SPICE или настройте отдельный VNC клиент"
        fi
        
    else
        echo "❌ Ошибка при создании контейнера!"
        echo "📝 Проверьте логи для диагностики:"
        pct logs $NEW_CTID 2>/dev/null || echo "⚠️ Не удалось получить логи контейнера"
        exit 1
    fi
}

# === Запуск основной функции ===
main "$@"