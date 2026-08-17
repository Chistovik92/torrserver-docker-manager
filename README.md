# TorrServer Docker Manager

**Текущая версия менеджера: v1.3.1**  
Автор: **Chistovik92**

Docker-менеджер для TorrServer с двумя сценариями развёртывания:

- **LAN** — HTTP-доступ только через выбранный приватный IPv4 сервера. Домен, Caddy и Let's Encrypt не требуются.
- **PUBLIC** — HTTPS через Caddy. Домен обязателен, DNS проверяется, сертификат выпускается и продлевается через **Let's Encrypt**.

## Установка

Рекомендуемый вариант устанавливает менеджер как системную команду `torrserver`:

```bash
curl -fsSL https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/install.sh | sudo bash
```

После этого:

```bash
sudo torrserver
```

Также `manager.sh` можно запускать локально из каталога проекта:

```bash
chmod +x manager.sh
sudo ./manager.sh
```

## Режим LAN

При установке выберите `LAN`, укажите приватный IPv4, реально назначенный интерфейсу сервера, и порт. Например:

```text
192.168.1.10:8090
```

Доступ:

```text
http://192.168.1.10:8090
```

Docker привязывает опубликованный порт именно к выбранному LAN-IP, а UFW разрешает подключение к нему только из приватных IPv4-сетей `10.0.0.0/8`, `172.16.0.0/12` и `192.168.0.0/16`.

## Режим PUBLIC

Для внешнего сервера выберите `PUBLIC`. Скрипт обязательно запросит:

1. домен с A-записью на публичный IPv4 сервера;
2. email ACME/Let's Encrypt.

Порты TCP `80` и `443` должны быть свободны на сервере и доступны извне. TorrServer не публикует порт `8090` наружу: запросы идут через Caddy.

В v1.3.1 Caddy использует явный ACME issuer Let's Encrypt. И основной `dir`, и retry `test_dir` закреплены за production endpoint, поэтому после неудачного challenge менеджер не переводит Caddy на staging CA:

```text
https://acme-v02.api.letsencrypt.org/directory
```

Перед запуском PUBLIC выполняется preflight: проверяется публичный IPv4, A-запись домена и отсутствие локальных конфликтов на TCP 80/443. После старта менеджер ждёт фактического получения сертификата Let's Encrypt. Пока сертификат не получен, PUBLIC-установка не объявляется успешно завершённой.

Доступ:

```text
https://torr.example.com
```

## Команды управления

```bash
sudo torrserver                 # интерактивное меню
sudo torrserver status          # состояние и URL
sudo torrserver update          # обновить/понизить TorrServer
sudo torrserver restart         # перезапустить контейнеры
sudo torrserver logs            # логи Docker Compose
sudo torrserver check-le        # проверить DNS/Caddy/сертификат Let's Encrypt
sudo torrserver check-update    # проверить новую версию менеджера на GitHub
sudo torrserver self-update     # обновить manager.sh с GitHub
sudo torrserver doctor          # комплексная диагностика проекта
sudo torrserver version         # показать версию менеджера
```

## Обновление TorrServer

Команда:

```bash
sudo torrserver update
```

принимает `latest` или тег образа, например `MatriX.142.2`. Перед изменением создаётся резервная копия `/opt/torr-docker/config`. Если `docker compose pull/up` завершается ошибкой, менеджер восстанавливает предыдущий тег TorrServer и пытается поднять прежнюю версию.

Текущий тег хранится в:

```text
/opt/torr-docker/.env
```

## Проверка Let's Encrypt

```bash
sudo torrserver check-le
```

Проверяются:

- A-запись домена и публичный IPv4 сервера;
- наличие запущенного Caddy;
- `caddy validate` для активного Caddyfile;
- наличие сертификата для домена непосредственно в локальном Caddy на `127.0.0.1:443` с правильным SNI;
- issuer и сроки действия сертификата через OpenSSL;
- последние ACME/TLS-сообщения Caddy.

Проверка через `127.0.0.1` намеренная: серверу не требуется поддержка NAT loopback/hairpin для самодиагностики уже полученного сертификата. Внешняя доступность TCP 80/443 всё равно обязательна для прохождения challenge Let's Encrypt.

Команда предназначена только для режима `PUBLIC`.

## Самообновление менеджера

Версия проекта хранится одновременно в `VERSION` и `MANAGER_VERSION` внутри `manager.sh`.

Проверка:

```bash
sudo torrserver check-update
```

Обновление:

```bash
sudo torrserver self-update
```

Перед заменой менеджер:

1. получает `VERSION` из GitHub;
2. скачивает новый `manager.sh` во временный файл;
3. выполняет `bash -n`;
4. сверяет `VERSION` с `MANAGER_VERSION` скачанного файла;
5. создаёт резервную копию текущего скрипта;
6. устанавливает новую версию и обновляет `/opt/torr-docker/VERSION`.

Автоматический downgrade самого менеджера запрещён.

## Диагностика

```bash
sudo torrserver doctor
```

Проверяет основные утилиты, Docker Compose, текущий `docker-compose.yml`, JSON базы пользователей и, в PUBLIC-режиме, дополнительно запускает проверку Let's Encrypt.

## Пользователи

TorrServer запускается с HTTP-аутентификацией. База пользователей:

```text
/opt/torr-docker/config/accs.db
```

Права файла после создания, добавления пользователя, смены пароля и удаления пользователя принудительно устанавливаются в `0600`. Главного пользователя удалить через менеджер нельзя.

## Переключение LAN / PUBLIC

Менеджер поддерживает оба направления. При переключении конфигурация Compose создаётся заново, стек перезапускается, а устаревшие UFW-правила предыдущего режима удаляются. При ошибке запуска выполняется попытка возврата к предыдущей конфигурации.

## Данные

```text
/opt/torr-docker/manager.sh       # установленный менеджер
/opt/torr-docker/VERSION          # установленная версия менеджера
/opt/torr-docker/manager.conf     # режим и параметры
/opt/torr-docker/docker-compose.yml
/opt/torr-docker/config/          # данные TorrServer и accs.db
/opt/torr-docker/.env             # тег TorrServer
```

Caddy хранит ACME-состояние и сертификаты в Docker volumes `caddy_data` и `caddy_config`.

## Требования

- Debian/Ubuntu с `apt` и `systemd`;
- root или `sudo`;
- Docker Engine + Docker Compose plugin (при отсутствии Docker устанавливается автоматически);
- интернет для образов и GitHub;
- в PUBLIC-режиме — корректный DNS и доступные TCP 80/443.

## Структура репозитория

```text
.
├── manager.sh
├── install.sh
├── torrserver
├── VERSION
├── README.md
├── LICENSE
├── .gitignore
├── examples/
│   └── docker-compose.public.yml
└── tests/
    └── smoke.sh
```

## Версионность

Проект использует формат **Semantic Versioning**: `MAJOR.MINOR.PATCH`.

- `MAJOR` — несовместимые изменения поведения/конфигурации;
- `MINOR` — новые совместимые функции;
- `PATCH` — исправления без изменения интерфейса.

### v1.3.1 — 2026-08-17

- добавлен PUBLIC preflight перед запуском Caddy: публичный IPv4, DNS A-запись и локальная доступность портов 80/443;
- PUBLIC-установка больше не сообщает об успехе до фактического получения сертификата Let's Encrypt;
- после запуска Caddy менеджер до 120 секунд ожидает сертификат и выводит диагностические ACME-логи при неудаче;
- при переключении LAN → PUBLIC применяется та же проверка готовности сертификата;
- Caddy переведён на явный `issuer acme`; `dir` и `test_dir` закреплены за production Let's Encrypt, чтобы ретраи не уходили на staging CA;
- `check-le` проверяет сертификат локально через `127.0.0.1:443` с SNI домена, поэтому диагностика не зависит от NAT loopback/hairpin;
- сообщения об ошибках challenge теперь прямо указывают на внешний firewall/security group/NAT как вероятную причину;
- обновлены smoke-тесты и README.

### v1.3.0 — 2026-08-17

- исправлена свежая установка через `install.sh`: каталог `/opt/torr-docker` больше не считается признаком установленного TorrServer; признак установки — `manager.conf`;
- PUBLIC-режим закреплён именно за Let's Encrypt через `acme_ca`;
- `check-le` теперь проверяет реальный сертификат, issuer, сроки, Caddyfile и ACME/TLS-логи;
- добавлена команда `doctor`;
- усилена проверка LAN IPv4: адрес должен быть приватным, валидным и назначенным интерфейсу хоста;
- исправлена очистка UFW при переключении LAN ↔ PUBLIC и удалении;
- добавлен rollback при неудачной смене версии TorrServer;
- добавлен rollback конфигурации при неудачном переключении режима;
- self-update сверяет `VERSION` и `MANAGER_VERSION` до замены файла;
- `install.sh` проверяет синтаксис скачанного менеджера и согласованность версий;
- после изменения пользователей `accs.db` снова принудительно получает права `0600`;
- добавлены локальные smoke-тесты.

### v1.2.0

- добавлены `VERSION`, `check-update` и `self-update`;
- добавлено обновление менеджера непосредственно с GitHub;
- менеджер устанавливается как команда `torrserver`.

### v1.1.0

- добавлен LAN-режим без Let's Encrypt;
- Docker-порт LAN привязан к конкретному приватному IPv4;
- добавлено переключение LAN/PUBLIC.

### v1.0.0

- базовая Docker-установка TorrServer;
- PUBLIC-доступ через Caddy;
- управление пользователями и версией TorrServer.

## Безопасность

Не добавляйте в GitHub реальные `manager.conf`, `.env`, `accs.db`, резервные копии конфигурации или другие файлы с учётными данными. LAN-режим не предназначен для публикации TorrServer в Интернет.

## Лицензия

MIT. См. `LICENSE`.

Проект не содержит исходный код TorrServer или Caddy; используются внешние контейнерные образы.
