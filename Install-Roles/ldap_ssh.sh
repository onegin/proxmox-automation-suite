#!/bin/bash

# ======================================================================
# 🐧 Настройка SSH + LDAP аутентификация
# ======================================================================
# 
# Этот скрипт устанавливает и настраивает клиент LDAP на Debian/Ubuntu,
# правит конфигурацию SSH для работы через PAM и добавляет пользователей
# из группы "admins" в sudoers.
#
# Валидация параметров производится интерактивно, но их можно задать
# через переменные окружения перед запуском:
#   LDAP_URI, LDAP_BASE_DN, LDAP_BIND_DN, LDAP_BIND_PW
#
# Запустить от root (sudo).
#
# Пример:
#   sudo LDAP_URI="ldap://ldap.example.local" \
#        LDAP_BASE_DN="dc=example,dc=local" \
#        LDAP_BIND_DN="cn=readonly,dc=example,dc=local" \
#        LDAP_BIND_PW="secret" \
#        bash ldap_ssh.sh
#
# ======================================================================

set -euo pipefail

# проверка прав
if [ "$EUID" -ne 0 ]; then
    echo "Этот скрипт нужно запускать от имени root." >&2
    exit 1
fi

# переменные с LDAP-конфигурацией (можно также задать через env, но ниже мы спросим их у пользователя)
LDAP_URI=${LDAP_URI:-}
LDAP_BASE_DN=${LDAP_BASE_DN:-}
LDAP_BIND_DN=${LDAP_BIND_DN:-}
LDAP_BIND_PW=${LDAP_BIND_PW:-}

# спросим пользователя о значениях (если переменные уже заданы через окружение, они будут предложены как значения по умолчанию)
read -rp "LDAP URI [${LDAP_URI}]: " input
LDAP_URI=${input:-$LDAP_URI}

read -rp "Base DN [${LDAP_BASE_DN}]: " input
LDAP_BASE_DN=${input:-$LDAP_BASE_DN}

read -rp "Bind DN [${LDAP_BIND_DN}]: " input
LDAP_BIND_DN=${input:-$LDAP_BIND_DN}

# пароль скрываем
read -srp "Bind password: " input
echo
LDAP_BIND_PW=${input:-$LDAP_BIND_PW}

echo
# Валидация простая: требуем заполнения
for var in LDAP_URI LDAP_BASE_DN LDAP_BIND_DN LDAP_BIND_PW; do
    if [ -z "${!var}" ]; then
        echo "Переменная $var не задана, выход." >&2
        exit 1
    fi
 done

# пакеты клиента LDAP
echo "Устанавливаем пакеты ldap-клиента..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq libnss-ldap libpam-ldap ldap-utils nscd

# debconf может спросить много вопросов, но пакеты уже установлены.
# В некоторых случаях /etc/ldap.conf конфигурируется автоматически.

# Прописать основные параметры в /etc/ldap/ldap.conf (OpenLDAP client)
cat > /etc/ldap/ldap.conf <<EOF
URI $LDAP_URI
BASE $LDAP_BASE_DN
BINDDN $LDAP_BIND_DN
BINDPW $LDAP_BIND_PW
SIZELIMIT 0
TIMELIMIT 0
TLS_REQCERT allow
EOF

# Настроим NSS, чтобы "passwd/group/shadow" искались в LDAP
grep -q "ldap" /etc/nsswitch.conf || \
    sed -i "s/^passwd:.*/& ldap/; s/^group:.*/& ldap/; s/^shadow:.*/& ldap/" /etc/nsswitch.conf

# PAM: добавим ldap в возможностей
if [ -x /usr/sbin/pam-auth-update ]; then
    echo "ldap\npam_ldap" | pam-auth-update --package --force
else
    # примитивное добавление строчек в common-*
    for tgt in common-auth common-account common-password common-session; do
        grep -q pam_ldap /etc/pam.d/$tgt || \
            sed -i "/^@include common-${tgt#/common-}$/a auth    sufficient   pam_ldap.so" /etc/pam.d/$tgt 2>/dev/null || true
    done
fi

# SSH: разрешить PAM-аутентификацию и пароли
sed -i 's/^#\?UsePAM .*/UsePAM yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Группа admins -> sudoers
if ! getent group admins >/dev/null; then
    groupadd admins
    echo "Группа admins создана"
fi
cat > /etc/sudoers.d/admins <<'EOF'
%admins ALL=(ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/admins

# Итоговое сообщение
cat <<EOF
Настройка LDAP-клиента завершена.
Проверьте /etc/ldap/ldap.conf и /etc/nsswitch.conf при необходимости.
Пользователи из группы "admins" получают права sudo.
Перезапустите контейнер/сервер или перелогиньтесь, чтобы изменения вступили в силу.
EOF
