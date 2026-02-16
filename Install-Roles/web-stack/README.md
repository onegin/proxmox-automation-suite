# Docker‑compose веб‑стек

В этой папке находится всё необходимое для запуска простого веб‑стека
в Docker‑контейнерах. Стек включает в себя:

* **nginx** — фронтенд‑вебсервер
* **php** — PHP‑FPM для обработки PHP‑запросов
* **mysql** — сервер баз данных
* **certbot** — автоматическая выдача и продление сертификатов Let's Encrypt

## Структура каталогов

```
web-stack/
├── docker-compose.yml    # описание всех сервисов
├── .env                 # переменные окружения (например MYSQL_ROOT_PASSWORD)
├── install-web-server   # вспомогательный скрипт для создания сайта
└── app/
    ├── nginx/
    │   └── nginx.conf   # общий конфиг nginx
    └── www/            # корень для папок сайтов (создаётся по требованию)
```

Каждый сайт располагается в `app/www/<имя_сайта>` и содержит две подпапки:

* `www` — документ‑рут, туда кладутся файлы приложения
* `config` — настройки nginx и php для конкретного сайта

Помощник (`install-web-server`) создаёт эту структуру, создаёт базу MySQL с
именем сайта и запрашивает TLS‑сертификат через certbot.

### Поддержка Let's Encrypt

* `app/nginx/letsencrypt` хранит конфигурацию и сертификаты Certbot
  (монтируется в nginx как `/etc/letsencrypt`)
* `app/nginx/letsencrypt-site` отдаёт файлы ACME‑челленджей через nginx
* Небольшой блок `server` в `nginx.conf` обрабатывает запросы к
  `/.well-known/acme-challenge`
* Сервис `certbot` запускает `certbot renew` каждые 12 часов для продления
  сертификатов

## Использование

1. заполните `.env`, например:

   ```bash
   MYSQL_ROOT_PASSWORD=ваш_пароль_root
   ```

2. запустите стек (из этой директории):

   ```bash
   docker-compose up -d
   ```

3. создайте новый сайт с помощью скрипта:

   ```bash
   chmod +x install-web-server
   ./install-web-server --create-site example.com
   ```

   Это:
   * создаст `/app/www/example.com/www` и `/app/www/example.com/config`
   * запишет там `nginx.conf` и `php.ini` для сайта
   * поднимет (если нужно) контейнеры docker‑compose
   * создаст базу MySQL с именем `example.com`
   * запросит TLS‑сертификат по HTTP‑челленджу
   * перезагрузит nginx внутри контейнера

4. разместите файлы сайта в `/app/www/example.com/www`.
5. чтобы остановить стек:

   ```bash
   docker-compose down
   ```

## Советы и замечания

* Сертификаты обновляются автоматически; журналы доступны через
  `docker logs certbot`.
* При необходимости модифицируйте конфиги сайта в папке `config`.
* Главный конфиг nginx (`app/nginx/nginx.conf`) преднамеренно минимален –
  блоки `server` находятся рядом с данными сайта.
* Для ручного управления базами выполните
  `docker-compose exec mysql mysql -uroot -p$MYSQL_ROOT_PASSWORD`.

---