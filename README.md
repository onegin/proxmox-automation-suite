# Proxmox Automation Suite

Универсальный набор скриптов и конфигураций для полной автоматизации развертывания и администрирования инфраструктуры на базе **Proxmox VE**. Включает инструменты для создания LXC-контейнеров, установки и настройки различных сервисов (веб-стек, DirectoryServices, мониторинга и т.д.).

> **Язык интерфейса:** Русский  
> **Целевая платформа:** Linux (Debian/Ubuntu derivatives)  
> **Требуемый минимум:** Proxmox VE 7.x+, Bash 4.x+

---

## 📋 Содержание

- [Быстрый старт](#-быстрый-старт)
- [Структура проекта](#-структура-проекта)
- [Компоненты](#-компоненты)
- [Требования](#-требования)
- [Установка и использование](#-установка-и-использование)
- [Примеры](#-примеры)
- [Архитектура](#-архитектура)
- [Часто задаваемые вопросы](#-часто-задаваемые-вопросы)
- [Поддержка и вклад](#-поддержка-и-вклад)
- [Лицензия](#-лицензия)

---

## 🚀 Быстрый старт

### Для создания нового LXC-контейнера:

```bash
cd Create-Contaner/
cp config.conf.example config.conf
# Отредактируйте config.conf под свои параметры
bash main.sh
```

### Для начальной настройки машины/контейнера:

```bash
# На узле Proxmox или внутри контейнера
bash Install-Roles/basic-setting-machine.sh
```

### Для развертывания веб-стека:

```bash
cd Install-Roles/web-stack/
docker-compose up -d
bash install-web-server --create mysite.example.com
```

---

## 📁 Структура проекта

```
proxmox-automation-suite/
│
├── README.md                              ← вы здесь
│
├── Create-Contaner/                       # Модуль создания LXC-контейнеров
│   ├── main.sh                            # Главный интерактивный скрипт
│   ├── config.conf.example                # Пример конфигурации (копировать → config.conf)
│   └── README.md                          # Подробная документация
│
├── Install-Roles/                         # Роли/профили настройки систем
│   │
│   ├── basic-setting-machine.sh           # Базовая настройка "iron" машин
│   ├── basic-setting-contaner.sh          # Базовая настройка LXC-контейнеров
│   │
│   ├── install_samba_ad.sh                # Развертывание Samba4 AD DC
│   ├── ldap_ssh.sh                        # Интеграция SSH + LDAP-клиент
│   │
│   ├── web-stack/                         # Изолированный Docker-проект
│   │   ├── docker-compose.yml             # Конфигурация сервисов
│   │   ├── install-web-server             # Утилита управления сайтами/БД
│   │   ├── README.md                      # Документация веб-стека
│   │   │
│   │   └── app/
│   │       ├── nginx/
│   │       │   └── nginx.conf             # Шаблон конфигурации nginx
│   │       └── www/                       # Корень документов (монтируется в контейнер)
│   │
│   └── extract.sh                         # Вспомогательные утилиты
│
└── Other_scripts/                         # Дополнительные вспомогательные скрипты
    └── ...
```

---

## 🛠️ Компоненты

### 1. **Create-Contaner** – Автозаполнение LXC-контейнеров

Интерактивный Bash-скрипт для быстрого создания контейнеров LXC на хосте Proxmox.

**Возможности:**
- ✅ Автоматический подбор свободного CTID
- ✅ Выбор шаблона ОС из доступных
- ✅ Интерактивная конфигурация (имя, CPU, RAM, диск, сеть, IP)
- ✅ Поддержка VLAN и статических IP-адресов
- ✅ Установка VNC-сервера (опционально)
- ✅ Запуск пользовательского скрипта внутри контейнера
- ✅ Отправка уведомления в Telegram
- ✅ Логирование всех операций

**Требуется конфиг:** `config.conf.example`

📖 **Подробнее:** см. [Create-Contaner/README.md](Create-Contaner/README.md)

---

### 2. **Install-Roles** – Роли настройки окружения

Модульные Bash-скрипты для установки и настройки различных стеков и сервисов.

#### **A. Базовая настройка**

- **`basic-setting-machine.sh`** – для физических машин и VPS
  - Установка базовых пакетов
  - Конфигурация локали и timezone
  - Настройка SSH
  - Создание системного пользователя
  - Конфигурация сетевых интерфейсов

- **`basic-setting-contaner.sh`** – оптимизирована для LXC
  - Аналогичная функциональность
  - Логирование в `/var/log/post_install.log`
  - Учет особенностей LXC-окружения

#### **B. Directory Services & Authentication**

- **`install_samba_ad.sh`** – Развертывание Samba4 AD Domain Controller
  - Создание Active Directory домена
  - Инструменты управления пользователями и группами
  - Интеграция с POSIX-совместимостью

- **`ldap_ssh.sh`** – Интеграция SSH с LDAP-аутентификацией
  - Конфигурация SSH для работы с LDAP
  - Настройка NSS и PAM модулей
  - Создание домашних директорий при первом входе

#### **C. Веб-сервисы (web-stack)**

Полностью контейнеризованный стек: **nginx + PHP-FPM + MySQL/MariaDB**

**Особенности:**
- 🐳 Docker Compose для управления сервисами
- 🔐 Автоматический запрос и управление сертификатами Let's Encrypt
- 📂 Удобная утилита `install-web-server` для добавления новых сайтов
- 🚀 Масштабируемая архитектура

**Быстрый старт:**
```bash
cd Install-Roles/web-stack/
docker-compose up -d
bash install-web-server --create example.com
```

📖 **Подробнее:** см. [Install-Roles/web-stack/README.md](Install-Roles/web-stack/README.md)

---

## 📦 Требования

### На узле Proxmox:
- **Proxmox VE 7.x** или выше
- **Bash 4.x** или выше
- Права доступа **root** для создания контейнеров
- Минимум **2 ГБ** свободной памяти
- Доступ в интернет (для загрузки шаблонов и обновлений)

### На целевых машинах/контейнерах:
- **Debian 10+** или **Ubuntu 18.04+**
- **Bash 4.x**, стандартные утилиты (curl, wget, openssl)
- Для веб-стека: **Docker 20.x+**, **Docker Compose 1.29+**
- Для Samba AD: **2+ ГБ** RAM, **1+ ГБ** диск

### Опциональные зависимости:
- **curl** – для отправки уведомлений в Telegram
- **Docker** и **Docker Compose** – для веб-стека

---

## ⚙️ Установка и использование

### Шаг 1: Клонирование репозитория

```bash
git clone https://github.com/your-org/proxmox-automation-suite.git
cd proxmox-automation-suite
```

### Шаг 2: Выбор нужного компонента

#### Вариант A: Создание контейнера

```bash
cd Create-Contaner/
cp config.conf.example config.conf

# Отредактируйте конфиг
nano config.conf

# Запустите скрипт
bash main.sh
```

#### Вариант B: Настройка существующей системы

```bash
# Для виртуальной машины
bash Install-Roles/basic-setting-machine.sh

# Для LXC-контейнера
bash Install-Roles/basic-setting-contaner.sh
```

#### Вариант C: Развертывание веб-стека

```bash
cd Install-Roles/web-stack/

# Запустить все сервисы
docker-compose up -d

# Добавить первый сайт
bash install-web-server --create example.com

# Добавить БД
bash install-web-server --db mysite_db mysite_user
```

### Шаг 3: Проверка и начальная конфигурация

```bash
# Для web-stack
curl https://example.com  # должен вернуть 200 OK

# Для контейнера
pct exec <CTID> bash      # подключение в контейнер
```

---

## 💡 Примеры использования

### Пример 1: Создание трехслойной инфраструктуры

```bash
# Шаг 1: На Proxmox создаем контейнер
cd Create-Contaner/
# Отредактировать config.conf
bash main.sh
# Создаем контейнер "webserver-01" с 4 CPU, 4GB RAM

# Шаг 2: Базовая настройка внутри контейнера
pct exec 100 "bash /mnt/pve/install_scripts/basic-setting-contaner.sh"

# Шаг 3: Развератывание веб-стека
pct exec 100 "cd /root/web-stack && docker-compose up -d"
pct exec 100 "bash /root/web-stack/install-web-server --create myapp.example.com"
```

### Пример 2: Интеграция с Active Directory

```bash
# Шаг 1: Развертывание Samba AD контроллера
bash Install-Roles/install_samba_ad.sh

# Шаг 2: Конфигурация клиента для SSH над LDAP
bash Install-Roles/ldap_ssh.sh

# Результат: пользователи AD могут входить по SSH
ssh domain_user@client-machine.example.com
```

### Пример 3: Автоматизированное развертывание при создании контейнера

В `config.conf`:
```bash
EXTERNAL_SCRIPT_URL="https://example.com/setup.sh"
```

Скрипт `setup.sh`:
```bash
#!/bin/bash
bash /root/Install-Roles/basic-setting-contaner.sh
cd /root/web-stack && docker-compose up -d
```

Результат: контейнер будет полностью готов к работе сразу после создания.

---

## 🏗️ Архитектура

```
┌─────────────────────────────────────────────────────────┐
│                    Proxmox Cluster                       │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌──────────────────┐      ┌──────────────────┐         │
│  │  Узел 1          │      │  Узел 2          │         │
│  ├──────────────────┤      ├──────────────────┤         │
│  │ [LXC 100]        │      │ [LXC 200]        │         │
│  │ ├─ web-stack    │      │ ├─ Samba AD DC   │         │
│  │ └─ nginx/PHP    │      │ └─ LDAP Auth     │         │
│  │                  │      │                  │         │
│  │ [LXC 101]        │      │ [LXC 201]        │         │
│  │ ├─ MySQL DB     │      │ ├─ Backup        │         │
│  │ └─ Monitoring   │      │ └─ Storage       │         │
│  └──────────────────┘      └──────────────────┘         │
│          ↓                          ↓                     │
│    ┌─────────────────────────────────────┐              │
│    │  Create-Contaner Scripts            │              │
│    │  Автоматизация развертывания        │              │
│    └─────────────────────────────────────┘              │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

---

## ❓ Часто задаваемые вопросы

### **Q: Можно ли запускать скрипты не из Proxmox?**
A: Да, но не все модули. `Install-Roles` можно использовать на любой Debian/Ubuntu машине. `Create-Contaner` требует прямого доступа к Proxmox API/хосту.

### **Q: Что делать, если скрипт ошибается?**
A: 
1. Проверьте логи: `tail -f /var/log/post_install.log`
2. Убедитесь что запускаете от root: `whoami` должна вернуть `root`
3. Прочитайте соответствующий README в подсекции модуля
4. Откройте issue в репозитории с лог-файлом

### **Q: Как отключить уведомление в Telegram?**
A: В `config.conf` установите `TELEGRAM_ENABLED="false"` или оставьте `TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID` пустыми.

### **Q: Может ли веб-стек работать на контейнере с 512 МБ RAM?**
A: Теоретически да, но рекомендуется минимум **1-2 ГБ** для стабильной работы MySQL+PHP+nginx.

### **Q: Как обновить скрипты?**
A: 
```bash
git pull origin main
# или если у вас свои изменения
git fetch origin && git merge origin/main
```

### **Q: Поддерживаются ли другие дистрибутивы Linux?**
A: Основной фокус на Debian/Ubuntu. Для AlmaLinux/CentOS требуются адаптации скриптов.

---

## 📚 Дополнительные ресурсы

- 📖 [Proxmox VE Documentation](https://pve.proxmox.com/wiki/Main_Page)
- 📖 [Docker Documentation](https://docs.docker.com/)
- 📖 [Samba AD Documentation](https://wiki.samba.org/index.php/Samba4/HOWTO)
- 💬 [Proxmox Forum](https://forum.proxmox.com/)

---

## 🤝 Поддержка и вклад

### Сообщение об ошибках

Если вы нашли ошибку или у вас есть предложение:

1. Проверьте [существующие issues](https://github.com/your-org/proxmox-automation-suite/issues)
2. Откройте [новый issue](https://github.com/your-org/proxmox-automation-suite/issues/new) с описанием проблемы
3. Приложите логи ошибок и информацию о среде (версия Proxmox, ОС и т.д.)

### Вклад в код

Если у вас есть улучшения или исправления:

1. **Fork** репозиторий
2. Создайте **ветку** для вашего функционала (`git checkout -b feature/my-feature`)
3. **Commit** ваши изменения (`git commit -m 'Add some feature'`)
4. **Push** в ветку (`git push origin feature/my-feature`)
5. Откройте **Pull Request**

Пожалуйста, следуйте стилю кода проекта и добавляйте комментарии к сложным операциям.

---

## 📋 Лицензия

Этот проект распространяется под лицензией **MIT**. Подробнее см. [LICENSE](LICENSE) файл.

Для коммерческого применения рекомендуется связаться с автором проекта.

---

## ✉️ Контакты

- 📧 **Email:** ae@dcea.ru
- 🐛 **Issues:** [GitHub Issues](https://github.com/your-org/proxmox-automation-suite/issues)
- 📱 **Telegram:** [@antonov_e](https://t.me/antonov_e)

---

**Последнее обновление:** февраль 2026 г.  
**Версия:** 2.0.0  
**Статус:** ✅ Активно поддерживается
