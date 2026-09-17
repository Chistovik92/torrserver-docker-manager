# TorrServer Docker Manager

**Текущая версия менеджера: v1.6.0**  
Автор: **Chistovik92**

Docker-менеджер TorrServer с интерактивным выбором внутреннего или внешнего доступа.

## Сценарии установки

Первый уровень мастера:

```text
1. Внутренняя сеть (LAN)
2. Внешний доступ (PUBLIC)
0. Назад
```

При выборе `PUBLIC` открывается второй уровень:

```text
1. Let's Encrypt (доверенный HTTPS, нужен домен)
2. Самоподписанный сертификат (HTTPS)
3. Без сертификата (HTTP)
4. Назад к выбору LAN / PUBLIC
```

### LAN

TorrServer публикуется только на выбранном приватном IPv4 интерфейсе, например:

```text
http://192.168.1.10:8090
```

UFW разрешает выбранный порт только из приватных IPv4-сетей `10.0.0.0/8`, `172.16.0.0/12` и `192.168.0.0/16`.

### PUBLIC + Let's Encrypt

Скрипт требует домен и email, проверяет A-запись, открывает TCP 80/443, запускает Caddy и ждёт фактического production-сертификата Let's Encrypt.

```text
https://torr.example.com
```

Caddy закреплён за production endpoint Let's Encrypt и для `dir`, и для `test_dir`.

### PUBLIC + самоподписанный сертификат

Домен не обязателен. Можно использовать публичный IPv4 или доменное имя. Менеджер сам создаёт RSA-2048 сертификат с SAN и сроком 825 дней, хранит его в `/opt/certs/torr` и публикует Caddy только на TCP 443.

```text
https://203.0.113.10
```

Браузер/клиент будет предупреждать о недоверенном сертификате, пока сертификат явно не добавлен в доверенные.

### PUBLIC без сертификата

Caddy не используется. TorrServer с включённой HTTP-аутентификацией публикуется напрямую на выбранном внешнем TCP-порту:

```text
http://203.0.113.10:8090
```

Этот вариант не шифрует логин, пароль и HTTP-трафик. Используйте его только осознанно, например за внешним VPN/reverse proxy или в доверенной сети.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/install.sh | sudo bash
```

После установки:

```bash
sudo torrserver
```

Локальный запуск клона репозитория:

```bash
chmod +x manager.sh
sudo ./manager.sh
```

## Команды

```bash
sudo torrserver                 # интерактивное меню
sudo torrserver status          # режим, тип TLS и URL
sudo torrserver start           # поднять сервер после сбоя, данные сохраняются
sudo torrserver update          # обновить/понизить TorrServer
sudo torrserver restart         # перезапустить текущий стек
sudo torrserver logs            # логи Docker Compose
sudo torrserver check-le        # диагностика Let's Encrypt
sudo torrserver check-update    # проверить версию менеджера на GitHub
sudo torrserver self-update     # обновить менеджер и выполнить миграцию
sudo torrserver doctor          # комплексная диагностика
sudo torrserver repair          # восстановить конфигурацию текущего режима
sudo torrserver version         # версия менеджера
```

## Автозапуск и восстановление после сбоя питания

Установка и `repair` создают systemd-unit `torrserver-docker.service`, который поднимает стек после каждой загрузки:

```ini
Requires=docker.service
After=docker.service network-online.target time-sync.target
Wants=network-online.target
ExecStart=/bin/bash /opt/torr-docker/manager.sh boot
```

Unit вызывает `manager.sh boot`, который перед стартом стека:

- ждёт готовности Docker (до 120 с);
- в LAN-режиме ждёт появления сохранённого `BIND_IP` (до 180 с). Это снимает гонку с DHCP: без ожидания Docker не может привязать порт к ещё не назначенному адресу и контейнер падает с `bind: cannot assign requested address`;
- если адрес в LAN изменился, подставляет текущий приватный IPv4, переписывает `manager.conf`, Compose и правила UFW;
- в режиме Let's Encrypt ждёт синхронизации времени по NTP (до 120 с) — на платах без RTC часы после отключения питания уезжают, и Caddy считает валидный сертификат ещё не наступившим;
- запускает `docker compose up -d --remove-orphans` без `pull`, поэтому восстановление работает и без интернета.

Контейнеры используют `restart: always`, поэтому они переживают и перезапуск самого демона Docker.

Ручной запуск того же сценария — `sudo torrserver start` или пункт 12 меню. Команда не удаляет ни данные, ни настройки: `config/`, `accs.db`, `.env` и сертификаты остаются на месте.

Установки версий до 1.6.0 получают unit автоматически: `sudo torrserver self-update` обновляет менеджер и запускает `repair`, который создаёт и включает unit, не трогая данные.

## Переключение режимов

Пункт `Переключить LAN / PUBLIC / TLS` запускает тот же двухуровневый мастер. Существующая `/opt/torr-docker/config/accs.db` сохраняется — повторно создавать администратора не требуется.

Перед переключением создаётся backup текущих `manager.conf`, Compose, Caddyfile, `.env` и каталога `config`. Если новая конфигурация не запускается, менеджер пытается вернуть предыдущую.

## repair

`sudo torrserver repair` учитывает сохранённые `MODE` и `PUBLIC_TLS`:

- LAN — восстанавливает bind на приватный IP и LAN UFW rules, а если адрес сервера сменился, подставляет актуальный;
- Let's Encrypt — пересоздаёт Compose/Caddyfile, очищает только staging ACME state и повторяет production issuance;
- self-signed — проверяет сертификат и пересоздаёт его, если он отсутствует или истекает менее чем через 7 дней;
- HTTP без TLS — удаляет Caddy из стека, восстанавливает прямой publish и правило UFW для выбранного порта.

`self-update` после обновления менеджера автоматически запускает `repair`, поэтому конфигурация старой версии мигрирует в текущий формат.

## doctor

`doctor` проверяет зависимости, Docker Compose, `accs.db`, состояние автозапуска `torrserver-docker.service`, соответствие сохранённого LAN-адреса реальному и конфигурацию активного режима. Для Let's Encrypt выполняется ACME/TLS диагностика, для self-signed проверяется сертификат, а для HTTP без TLS проверяется отсутствие лишнего Caddyfile.

## Данные

```text
/opt/torr-docker/manager.sh
/opt/torr-docker/VERSION
/opt/torr-docker/manager.conf
/opt/torr-docker/docker-compose.yml
/opt/torr-docker/Caddyfile              # только TLS-режимы
/opt/torr-docker/config/
/opt/torr-docker/.env
/opt/torr-docker/backups/
/opt/certs/torr/torr.crt                # self-signed
/opt/certs/torr/torr.key                # self-signed
/etc/systemd/system/torrserver-docker.service
```

`manager.conf` хранит в том числе `MODE`, `PUBLIC_TLS` и `PUBLIC_HOST`.

## Версионность

Проект использует Semantic Versioning: `MAJOR.MINOR.PATCH`.

### v1.6.0

- systemd-unit `torrserver-docker.service` — автозапуск стека после перезагрузки и аварийного отключения питания;
- команда `torrserver start` (пункт 12 меню) — запуск существующей установки без потери данных;
- `boot` ждёт Docker, сетевой адрес и, для Let's Encrypt, синхронизацию времени, затем поднимает стек без `pull`;
- автоматическая миграция LAN-конфигурации на новый адрес сервера, если DHCP выдал другой IP;
- `restart: always` вместо `unless-stopped`;
- `doctor` проверяет автозапуск и соответствие сохранённого LAN-адреса;
- `repair` больше не падает, если LAN-адрес изменился;
- `.gitattributes` фиксирует LF, CI получил исполняемый бит на `tests/smoke.sh`.

### v1.5.0

- добавлен двухуровневый мастер LAN/PUBLIC;
- PUBLIC разделён на Let's Encrypt, self-signed HTTPS и HTTP без TLS;
- добавлен пункт возврата из PUBLIC-меню на предыдущий уровень;
- `PUBLIC_TLS` и `PUBLIC_HOST` сохраняются в `manager.conf`;
- добавлена автоматическая генерация self-signed RSA-2048 сертификата с SAN;
- HTTP-вариант запускается без Caddy;
- UFW автоматически открывает только необходимые порты для выбранного типа PUBLIC;
- `status`, `repair`, `doctor` и миграция после `self-update` понимают все три PUBLIC-варианта;
- переключение режима сохраняет существующую базу пользователей;
- smoke-тесты расширены на все варианты установки.

### v1.4.0

- добавлен self-healing `repair`;
- автоматическая миграция после `self-update`;
- установка диагностических утилит;
- восстановление UFW/Compose/Caddy;
- автоматическая очистка устаревшего staging ACME state.

### v1.3.1

- PUBLIC preflight;
- ожидание фактического сертификата Let's Encrypt;
- улучшенная диагностика ACME.

### v1.3.0

- исправления установки, UFW, rollback и прав `accs.db`;
- добавлены `doctor`, smoke-тесты и GitHub Actions.

### v1.2.0

- self-update менеджера с GitHub.

### v1.1.0

- системная команда `torrserver` и разделение LAN/PUBLIC.

### v1.0.0

- первая версия Docker-менеджера TorrServer.

## Требования

Debian/Ubuntu, root/sudo, `apt`, systemd и доступ в интернет для установки Docker/образов. В Let's Encrypt режиме домен должен указывать на публичный IPv4, а TCP 80/443 должны быть доступны снаружи.

## Безопасность

Во всех режимах TorrServer запускается с `TS_HTTPAUTH=1`. База пользователей хранится в `/opt/torr-docker/config/accs.db` с правами `0600`. Самоподписанный HTTPS обеспечивает шифрование, но не публичную проверку доверия. PUBLIC HTTP не обеспечивает TLS-шифрование.

## Лицензия

См. `LICENSE`.
