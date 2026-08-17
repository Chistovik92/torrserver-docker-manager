# TorrServer Docker Manager

Docker-менеджер для **TorrServer** с двумя режимами установки:

- **LAN** — TorrServer доступен по обычному HTTP только на выбранном приватном IPv4-адресе локальной сети. **Let's Encrypt, домен и Caddy не используются.**
- **PUBLIC** — TorrServer работает за Caddy и доступен по HTTPS. Скрипт требует домен, проверяет DNS и настраивает автоматическое получение/продление сертификата Let's Encrypt.

Автор: **Chistovik92**

## Что изменено

Исходный вариант был рассчитан только на публичный сервер с доменом и выпуском сертификата через `acme.sh`. В этой версии добавлен отдельный LAN-сценарий и переключение между LAN/PUBLIC после установки.

В LAN-режиме порт контейнера привязывается не к `0.0.0.0`, а к указанному приватному IPv4-адресу сервера. UFW дополнительно разрешает TCP-порт только из приватных IPv4-сетей.

В PUBLIC-режиме используется Caddy с автоматическим HTTPS/Let's Encrypt. Публичный интерфейс — `443`, HTTP `80` нужен Caddy для ACME/redirect.

## Требования

- Debian/Ubuntu с `apt` и `systemd`.
- root или `sudo`.
- Интернет для установки Docker/образов.
- Для LAN: сервер должен иметь приватный IPv4 в LAN.
- Для PUBLIC: домен должен иметь A-запись на публичный IP сервера; порты TCP 80/443 должны быть доступны извне.

## Быстрая установка

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/manager.sh -o manager.sh
chmod +x manager.sh
sudo ./manager.sh
```

Или:

```bash
wget -O manager.sh https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/manager.sh
chmod +x manager.sh
sudo ./manager.sh
```

## LAN-режим

При установке выбрать `1. LAN`, затем указать приватный IP сервера, например:

```text
192.168.1.10
```

После установки доступ:

```text
http://192.168.1.10:8090
```

Порт можно изменить в процессе установки.

**Важно:** LAN-режим не является способом публикации TorrServer в Интернет. Если сервер находится у VPS-провайдера и его адрес публичный, не указывайте публичный IP как `BIND_IP`.

## PUBLIC-режим

Выбрать `2. PUBLIC` и указать:

1. домен, например `torr.example.com`;
2. email для Let's Encrypt.

После проверки DNS Caddy будет получать и автоматически продлевать сертификат.

Доступ:

```text
https://torr.example.com
```

## Управление

После установки снова запускайте:

```bash
sudo /path/to/manager.sh
```

Меню позволяет:

1. установить TorrServer;
2. обновить/понизить версию;
3. управлять пользователями;
4. переключить LAN/PUBLIC;
5. перезапустить сервисы;
6. смотреть логи;
7. удалить установку.

Для прямого управления Docker также доступны:

```bash
cd /opt/torr-docker
docker compose ps
docker compose logs --tail=200 -f
docker compose restart
docker compose pull
docker compose up -d
docker compose down
```

## Данные

Конфигурация TorrServer:

```text
/opt/torr-docker/config
```

Состояние менеджера:

```text
/opt/torr-docker/manager.conf
```

В PUBLIC-режиме данные Caddy хранятся в Docker volumes `caddy_data` и `caddy_config`.

## Версия TorrServer

Менеджер поддерживает тег образа через `.env`:

```bash
cd /opt/torr-docker
printf 'TORRSERVER_VERSION=latest\n' > .env
docker compose pull torrserver
docker compose up -d torrserver
```

Например:

```text
TORRSERVER_VERSION=MatriX.142.2
```

Перед сменой версии менеджер создаёт резервную копию каталога конфигурации.

## Безопасность

- В TorrServer включена HTTP-аутентификация.
- Пароль при установке не сохраняется в `manager.conf`.
- LAN-порт разрешается UFW только из приватных IPv4-сетей.
- В PUBLIC-режиме TorrServer не публикуется напрямую наружу: внешний доступ идёт через Caddy.
- Не храните `manager.conf`, `accs.db` или резервные копии конфигурации в публичном Git-репозитории.
- Не коммитьте реальные пароли, домены внутренней инфраструктуры или приватные ключи.

## Структура

```text
.
├── manager.sh
├── README.md
├── LICENSE
├── .gitignore
└── examples/
    └── docker-compose.public.yml
```

## Лицензия

MIT. См. `LICENSE`.

> Примечание: проект не содержит исходники TorrServer/Caddy. Используются официальные контейнерные образы, указанные в конфигурации.

## Управление после установки

Менеджер устанавливается в `/opt/torr-docker/manager.sh` и вызывается командой `torrserver`.

```bash
torrserver menu        # интерактивное меню
torrserver status      # состояние контейнеров
torrserver update      # обновить/понизить TorrServer
torrserver restart     # перезапустить стек
torrserver logs        # посмотреть логи
torrserver check-le    # проверить DNS, HTTP challenge и Caddy/Let's Encrypt
```

В LAN-режиме Docker публикует TorrServer только на указанный приватный IP-адрес сервера, например `192.168.1.10:8090`.
