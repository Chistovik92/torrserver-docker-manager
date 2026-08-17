#!/usr/bin/env bash
# ==============================================================================
# TorrServer Docker Manager v1.3.1
# Author: Chistovik92
# Supports:
#   1) LAN mode: TorrServer exposed over HTTP to the local network, no Let's Encrypt.
#   2) Public mode: Caddy reverse proxy + Let's Encrypt certificate, domain required.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/torr-docker"
MANAGER_VERSION="1.3.1"
MANAGER_REPO="Chistovik92/torrserver-docker-manager"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/main"
MANAGER_URL="${MANAGER_RAW_BASE}/manager.sh"
VERSION_URL="${MANAGER_RAW_BASE}/VERSION"
CONF="${APP_DIR}/manager.conf"
CONFIG_DIR="${APP_DIR}/config"
COMPOSE="${APP_DIR}/docker-compose.yml"
CADDYFILE="${APP_DIR}/Caddyfile"
CERT_DIR="/opt/certs/torr"
IMAGE="ghcr.io/yourok/torrserver"
DEFAULT_PORT="8090"
LE_ACME_CA="https://acme-v02.api.letsencrypt.org/directory"

die(){ echo -e "\e[31mОшибка: $*\e[0m" >&2; return 1; }
info(){ echo -e "\e[36m$*\e[0m"; }
ok(){ echo -e "\e[32m$*\e[0m"; }
warn(){ echo -e "\e[33m$*\e[0m"; }

version_is_valid(){ [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
version_compare(){
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$b" ]]
}
get_remote_manager_version(){
  curl -4fsSL --max-time 8 "$VERSION_URL" 2>/dev/null | tr -d '[:space:]' || true
}
check_manager_update(){
  local remote
  remote="$(get_remote_manager_version)"
  if [[ -z "$remote" ]]; then
    warn "Не удалось проверить обновление менеджера: GitHub недоступен."
    return 2
  fi
  if ! version_is_valid "$remote"; then
    warn "GitHub вернул некорректную версию менеджера: $remote"
    return 2
  fi
  if [[ "$remote" == "$MANAGER_VERSION" ]]; then
    ok "Менеджер актуален: v$MANAGER_VERSION"
    return 0
  fi
  if version_compare "$MANAGER_VERSION" "$remote"; then
    warn "Доступна новая версия менеджера: v$remote (установлена v$MANAGER_VERSION)"
    return 1
  fi
  warn "На GitHub версия v$remote старше текущей v$MANAGER_VERSION. Обновление не требуется."
  return 0
}
self_update(){
  require_root
  local remote tmp backup
  remote="$(get_remote_manager_version)"
  [[ -n "$remote" ]] || die "Не удалось получить версию с GitHub."
  version_is_valid "$remote" || die "Некорректная версия на GitHub: $remote"
  if [[ "$remote" == "$MANAGER_VERSION" ]]; then
    ok "Менеджер уже актуален: v$MANAGER_VERSION"
    return 0
  fi
  if ! version_compare "$MANAGER_VERSION" "$remote"; then
    warn "GitHub содержит v$remote, текущая версия v$MANAGER_VERSION. Откат через self-update не выполняется."
    return 0
  fi
  tmp="$(mktemp)"
  backup="${APP_DIR}/manager.sh.backup.$(date +%Y%m%d-%H%M%S)"
  trap 'rm -f "$tmp"' RETURN
  curl -4fsSL --max-time 30 "$MANAGER_URL" -o "$tmp" || die "Не удалось скачать manager.sh с GitHub."
  chmod 700 "$tmp"
  bash -n "$tmp" || die "Скачанный manager.sh содержит синтаксическую ошибку."
  [[ -s "$tmp" ]] || die "Скачанный manager.sh пустой."
  local embedded
  embedded="$(grep -E '^MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$tmp" | head -n1 | cut -d'"' -f2 || true)"
  [[ "$embedded" == "$remote" ]] || die "VERSION на GitHub ($remote) не совпадает с MANAGER_VERSION в manager.sh (${embedded:-не найден})."
  mkdir -p "$APP_DIR"
  if [[ -f "$APP_DIR/manager.sh" ]]; then cp -a "$APP_DIR/manager.sh" "$backup"; fi
  install -m 755 "$tmp" "$APP_DIR/manager.sh"
  printf '%s\n' "$remote" >"$APP_DIR/VERSION"
  chmod 644 "$APP_DIR/VERSION"
  rm -f "$tmp"
  trap - RETURN
  ok "Менеджер обновлён: v$MANAGER_VERSION → v$remote"
  ok "Резервная копия: $backup"
}

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash manager.sh"; }
load_config(){
  [[ -f "$CONF" ]] || return 1
  # shellcheck disable=SC1090
  source "$CONF"
  MODE="${MODE:-lan}"; PORT="${PORT:-$DEFAULT_PORT}"; DOMAIN="${DOMAIN:-}"; EMAIL="${EMAIL:-}"; BIND_IP="${BIND_IP:-}"
  PRIMARY_USER="${PRIMARY_USER:-}"
}
save_config(){
  mkdir -p "$APP_DIR"
  cat >"$CONF" <<EOF
MODE=${MODE}
PORT=${PORT}
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
PRIMARY_USER=${PRIMARY_USER}
BIND_IP=${BIND_IP}
EOF
  chmod 600 "$CONF"
}
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
port_free(){
  local p="$1" hex
  valid_port "$p" || return 1
  if command -v ss >/dev/null 2>&1; then
    ! ss -H -ltn "( sport = :$p )" 2>/dev/null | grep -q .
    return
  fi
  hex="$(printf '%04X' "$p")"
  ! awk -v p=":${hex}" '$2 ~ p"$" && $4 == "0A" {found=1} END{exit found?0:1}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}
valid_ipv4(){
  local ip="$1" IFS=. o
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  read -r -a o <<<"$ip"
  [[ ${#o[@]} -eq 4 ]] || return 1
  local n
  for n in "${o[@]}"; do [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n <= 255)) || return 1; done
}
valid_private_ipv4(){
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]
}
host_has_ipv4(){
  local needle="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$needle"
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF "$needle"
  fi
}
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
get_public_ip(){
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
  curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true
}
check_dns(){
  local d="$1" ip dnsips
  valid_domain "$d" || { warn "Некорректное доменное имя."; return 1; }
  ip="$(get_public_ip)"
  dnsips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)"
  [[ -n "$ip" && -n "$dnsips" ]] || { warn "Не удалось проверить DNS/IP."; return 1; }
  grep -qx "$ip" <<<"$dnsips" || { warn "A-запись $d не указывает на IP этого сервера: $ip"; return 1; }
}
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq ufw openssl cron iproute2
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin не найден."
}
setup_auth(){
  local login pass pass2
  while :; do
    read -rp "Логин TorrServer: " login
    [[ "$login" =~ ^[A-Za-z0-9_.-]+$ ]] && break
    warn "Используйте латиницу, цифры, ., _ или -."
  done
  while :; do
    read -rsp "Пароль TorrServer (минимум 8 символов): " pass; echo
    read -rsp "Повторите пароль: " pass2; echo
    [[ "$pass" == "$pass2" && ${#pass} -ge 8 ]] && break
    warn "Пароли не совпадают или короче 8 символов."
  done
  mkdir -p "$CONFIG_DIR"
  jq -n --arg u "$login" --arg p "$pass" '{($u):$p}' >"$CONFIG_DIR/accs.db"
  chmod 600 "$CONFIG_DIR/accs.db"
  PRIMARY_USER="$login"
}
remove_lan_firewall_rules(){
  local p="${1:-$PORT}"
  command -v ufw >/dev/null 2>&1 || return 0
  valid_port "$p" || return 0
  ufw --force delete allow from 10.0.0.0/8 to any port "$p" proto tcp >/dev/null 2>&1 || true
  ufw --force delete allow from 172.16.0.0/12 to any port "$p" proto tcp >/dev/null 2>&1 || true
  ufw --force delete allow from 192.168.0.0/16 to any port "$p" proto tcp >/dev/null 2>&1 || true
}
remove_public_firewall_rules(){
  command -v ufw >/dev/null 2>&1 || return 0
  ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
}
firewall_lan(){
  remove_public_firewall_rules
  command -v ufw >/dev/null 2>&1 || return 0
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH >/dev/null 2>&1 || true
  # Common private IPv4 ranges only. Do not expose LAN mode to the Internet.
  ufw allow from 10.0.0.0/8 to any port "$PORT" proto tcp
  ufw allow from 172.16.0.0/12 to any port "$PORT" proto tcp
  ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp
  ufw --force enable
}
firewall_public(){
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}
write_lan_compose(){
  valid_private_ipv4 "$BIND_IP" || die "Для LAN режима BIND_IP должен быть корректным приватным IPv4-адресом."
  host_has_ipv4 "$BIND_IP" || die "IP $BIND_IP не назначен ни одному IPv4-интерфейсу этого сервера."
  cat >"$COMPOSE" <<EOF
services:
  torrserver:
    image: ${IMAGE}:\${TORRSERVER_VERSION:-latest}
    container_name: torrserver
    restart: unless-stopped
    environment:
      TS_HTTPAUTH: "1"
      TS_CONF_PATH: /opt/ts/config
      TS_PORT: "8090"
    volumes:
      - ./config:/opt/ts/config
    ports:
      - "${BIND_IP}:${PORT}:8090"
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}
EOF
}
write_public_compose(){
  cat >"$COMPOSE" <<EOF
services:
  torrserver:
    image: ${IMAGE}:\${TORRSERVER_VERSION:-latest}
    container_name: torrserver
    restart: unless-stopped
    environment:
      TS_HTTPAUTH: "1"
      TS_CONF_PATH: /opt/ts/config
      TS_PORT: "8090"
    volumes:
      - ./config:/opt/ts/config
    expose:
      - "8090"
    networks: [internal]
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}

  caddy:
    image: caddy:2-alpine
    container_name: torrserver-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [internal]
    depends_on: [torrserver]

networks:
  internal:

volumes:
  caddy_data:
  caddy_config:
EOF
  cat >"$CADDYFILE" <<EOF
{
  email ${EMAIL}
}
${DOMAIN} {
  tls {
    issuer acme {
      dir ${LE_ACME_CA}
      test_dir ${LE_ACME_CA}
      email ${EMAIL}
    }
  }
  reverse_proxy torrserver:8090
}
EOF
}
public_preflight(){
  local failed=0 public_ip dnsips
  info "PUBLIC preflight для ${DOMAIN}"
  public_ip="$(get_public_ip)"
  dnsips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
  if [[ -n "$public_ip" ]]; then
    ok "Публичный IPv4 сервера: $public_ip"
  else
    warn "Не удалось определить публичный IPv4 сервера."; failed=1
  fi
  if [[ -n "$dnsips" ]] && grep -qx "$public_ip" <<<"$dnsips"; then
    ok "DNS A-запись домена указывает на этот сервер."
  else
    warn "DNS A-запись не совпадает с публичным IPv4 сервера."; failed=1
  fi
  port_free 80 && ok "TCP/80 свободен локально." || { warn "TCP/80 занят локальным процессом."; failed=1; }
  port_free 443 && ok "TCP/443 свободен локально." || { warn "TCP/443 занят локальным процессом."; failed=1; }
  if command -v ufw >/dev/null 2>&1; then
    info "UFW будет настроен на разрешение TCP/80 и TCP/443."
  fi
  if (( failed != 0 )); then
    warn "PUBLIC preflight не пройден."
    return 1
  fi
  warn "Важно: firewall/security group у VPS-провайдера и NAT/роутер тоже должны пропускать входящие TCP/80 и TCP/443."
}
local_le_certificate_ok(){
  local issuer
  issuer="$(timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
  [[ -n "$issuer" ]] && grep -qi "Let's Encrypt" <<<"$issuer"
}
wait_for_letsencrypt(){
  local timeout_seconds="${1:-120}" elapsed=0
  info "Ожидание сертификата Let's Encrypt для ${DOMAIN} (до ${timeout_seconds} секунд)..."
  while (( elapsed < timeout_seconds )); do
    if local_le_certificate_ok; then
      ok "Сертификат Let's Encrypt получен и загружен Caddy."
      return 0
    fi
    if docker logs --since 15s torrserver-caddy 2>&1 | grep -qiE 'acme:error:connection|challenge failed|authorization failed'; then
      warn "Let's Encrypt сообщает об ошибке внешнего подключения. Проверьте доступность TCP/80 и TCP/443 с Интернета."
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "Сертификат Let's Encrypt не получен за ${timeout_seconds} секунд."
  echo "Последние ACME/TLS сообщения Caddy:"
  docker logs --tail 120 torrserver-caddy 2>&1 | grep -Ei 'certificate|acme|challenge|authorization|tls|issuer' | tail -n 40 || true
  return 1
}
start_stack(){
  cd "$APP_DIR"
  docker compose pull
  docker compose up -d
  docker compose ps
}
install_torr(){
  [[ ! -f "$CONF" ]] || { warn "TorrServer уже установлен. Используйте управление."; return; }
  echo "============================================="
  echo "  Установка TorrServer Docker"
  echo "============================================="
  echo "1. LAN — HTTP только из локальных IPv4-сетей, без Let's Encrypt"
  echo "2. PUBLIC — HTTPS через Caddy + Let's Encrypt, домен обязателен"
  local choice
  read -rp "Режим [1/2]: " choice
  case "$choice" in
    1) MODE="lan";;
    2) MODE="public";;
    *) warn "Неверный режим."; return;;
  esac

  while :; do
    if [[ "$MODE" == "lan" ]]; then
      while :; do
        read -rp "Приватный IPv4 адрес сервера в LAN (например 192.168.1.10): " BIND_IP
        if valid_private_ipv4 "$BIND_IP" && host_has_ipv4 "$BIND_IP"; then break; fi
        warn "Нужен приватный IPv4, реально назначенный интерфейсу сервера."
      done
    else
      BIND_IP=""
    fi
    read -rp "Порт TorrServer [${DEFAULT_PORT}]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    if [[ "$MODE" == "lan" ]]; then
      port_free "$PORT" && break || warn "Порт занят или неверен."
    else
      # In public mode the public endpoint is always 443; this value is only internal metadata.
      PORT="443"; break
    fi
  done

  if [[ "$MODE" == "public" ]]; then
    while :; do
      read -rp "Домен (например torr.example.com): " DOMAIN
      valid_domain "$DOMAIN" || { warn "Некорректный домен."; continue; }
      check_dns "$DOMAIN" && break
      read -rp "Повторить проверку? [Y/n]: " a
      [[ "${a:-Y}" =~ ^[Nn]$ ]] && return
    done
    while :; do
      read -rp "Email для Let's Encrypt: " EMAIL
      [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
      warn "Некорректный email."
    done
    port_free 80 || { warn "Порт 80 уже занят. Освободите его перед PUBLIC-установкой."; return; }
    port_free 443 || { warn "Порт 443 уже занят. Освободите его перед PUBLIC-установкой."; return; }
    public_preflight || return 1
  else
    DOMAIN=""; EMAIL=""
  fi

  install_packages
  mkdir -p "$APP_DIR" "$CONFIG_DIR"
  setup_auth
  save_config

  if [[ "$MODE" == "lan" ]]; then
    write_lan_compose
    firewall_lan
  else
    mkdir -p "$CERT_DIR"
    write_public_compose
    firewall_public
  fi

  start_stack
  if [[ "$MODE" == "lan" ]]; then
    ok "Установка завершена."
    ok "LAN: http://${BIND_IP}:${PORT}"
    ok "Docker привязан только к LAN IP: ${BIND_IP}:${PORT}"
  else
    if wait_for_letsencrypt 120; then
      ok "PUBLIC-установка завершена полностью."
      ok "HTTPS: https://${DOMAIN}"
    else
      warn "Контейнеры запущены, но PUBLIC-установка НЕ завершена: действующий сертификат Let's Encrypt не получен."
      warn "Исправьте внешний firewall/NAT/маршрутизацию и выполните: sudo torrserver check-le"
      return 1
    fi
  fi
}
status(){
  if [[ ! -f "$CONF" ]]; then echo "Не установлен"; return; fi
  load_config
  echo "Режим: $MODE"
  if [[ "$MODE" == "public" ]]; then
    echo "Домен: $DOMAIN"
    echo "URL: https://$DOMAIN"
  else
    echo "LAN IP: $BIND_IP"
    echo "URL: http://$BIND_IP:$PORT"
  fi
  echo "Порт: $PORT"
  (cd "$APP_DIR" && docker compose ps 2>/dev/null) || true
}
change_version(){
  [[ -f "$COMPOSE" ]] || { warn "Не установлен."; return; }
  local v old backup env_backup
  read -rp "Версия TorrServer (например MatriX.142.2 или latest): " v
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "Недопустимая версия."; return; }
  old="$(grep -E '^TORRSERVER_VERSION=' "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2- || true)"
  old="${old:-latest}"
  backup="${APP_DIR}/config.backup.$(date +%Y%m%d-%H%M%S)"
  env_backup="${APP_DIR}/.env.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_DIR" "$backup"
  [[ -f "${APP_DIR}/.env" ]] && cp -a "${APP_DIR}/.env" "$env_backup" || true
  printf 'TORRSERVER_VERSION=%s\n' "$v" >"${APP_DIR}/.env"
  if ! (cd "$APP_DIR" && docker compose pull torrserver && docker compose up -d torrserver); then
    warn "Обновление не удалось. Выполняется откат на $old."
    printf 'TORRSERVER_VERSION=%s\n' "$old" >"${APP_DIR}/.env"
    (cd "$APP_DIR" && docker compose up -d torrserver) || true
    return 1
  fi
  ok "Версия TorrServer установлена: $v"
  ok "Резервная копия конфигурации: $backup"
}
restart_stack(){ (cd "$APP_DIR" && docker compose restart); }
logs(){ (cd "$APP_DIR" && docker compose logs --tail=200 -f); }
manage_users(){
  [[ -f "$CONFIG_DIR/accs.db" ]] || { warn "Не установлен."; return; }
  while :; do
    echo "1. Список  2. Добавить  3. Сменить пароль  4. Удалить  0. Назад"
    read -rp "Выбор: " c
    case "$c" in
      1) jq -r 'keys[]' "$CONFIG_DIR/accs.db";;
      2)
        local u p p2
        read -rp "Логин: " u
        [[ "$u" =~ ^[A-Za-z0-9_.-]+$ ]] || { warn "Неверный логин."; continue; }
        jq -e --arg u "$u" 'has($u)' "$CONFIG_DIR/accs.db" >/dev/null && { warn "Пользователь уже есть."; continue; }
        read -rsp "Пароль: " p; echo; read -rsp "Повтор: " p2; echo
        [[ "$p" == "$p2" && ${#p} -ge 8 ]] || { warn "Пароль неверен."; continue; }
        jq --arg u "$u" --arg p "$p" '.+{($u):$p}' "$CONFIG_DIR/accs.db" >"${CONFIG_DIR}/accs.db.tmp" &&
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && chmod 600 "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      3)
        local u p p2
        read -rp "Логин: " u
        jq -e --arg u "$u" 'has($u)' "$CONFIG_DIR/accs.db" >/dev/null || { warn "Нет такого пользователя."; continue; }
        read -rsp "Новый пароль: " p; echo; read -rsp "Повтор: " p2; echo
        [[ "$p" == "$p2" && ${#p} -ge 8 ]] || { warn "Пароль неверен."; continue; }
        jq --arg u "$u" --arg p "$p" '.[$u]=$p' "$CONFIG_DIR/accs.db" >"${CONFIG_DIR}/accs.db.tmp" &&
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && chmod 600 "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      4)
        local u
        read -rp "Логин для удаления: " u
        [[ "$u" != "$PRIMARY_USER" ]] || { warn "Главного пользователя удалить нельзя."; continue; }
        jq -e --arg u "$u" 'has($u)' "$CONFIG_DIR/accs.db" >/dev/null || { warn "Нет такого пользователя."; continue; }
        jq --arg u "$u" 'del(.[$u])' "$CONFIG_DIR/accs.db" >"${CONFIG_DIR}/accs.db.tmp" &&
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && chmod 600 "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      0) return;;
      *) warn "Неверный выбор.";;
    esac
  done
}
switch_mode(){
  [[ -f "$CONF" ]] || { warn "Не установлен."; return; }
  load_config
  local old_mode="$MODE" old_port="$PORT" old_domain="$DOMAIN" old_email="$EMAIL" old_bind="$BIND_IP" a
  cp -a "$COMPOSE" "${COMPOSE}.mode-backup" 2>/dev/null || true
  cp -a "$CADDYFILE" "${CADDYFILE}.mode-backup" 2>/dev/null || true
  if [[ "$MODE" == "lan" ]]; then
    warn "Переключение LAN → PUBLIC потребует домен, DNS и Let's Encrypt."
    read -rp "Перейти в PUBLIC? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    while :; do read -rp "Домен: " DOMAIN; valid_domain "$DOMAIN" && check_dns "$DOMAIN" && break; done
    while :; do read -rp "Email: " EMAIL; [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break; done
    port_free 80 || { warn "Порт 80 занят."; return; }
    port_free 443 || { warn "Порт 443 занят."; return; }
    MODE="public"; PORT="443"; BIND_IP=""
    public_preflight || { MODE="$old_mode"; PORT="$old_port"; DOMAIN="$old_domain"; EMAIL="$old_email"; BIND_IP="$old_bind"; return 1; }
    write_public_compose
    if ! (cd "$APP_DIR" && docker compose down && docker compose pull && docker compose up -d); then
      warn "Не удалось включить PUBLIC. Восстанавливаю предыдущий режим."
      MODE="$old_mode"; PORT="$old_port"; DOMAIN="$old_domain"; EMAIL="$old_email"; BIND_IP="$old_bind"
      mv -f "${COMPOSE}.mode-backup" "$COMPOSE" 2>/dev/null || true
      mv -f "${CADDYFILE}.mode-backup" "$CADDYFILE" 2>/dev/null || true
      save_config
      (cd "$APP_DIR" && docker compose up -d) || true
      return 1
    fi
    remove_lan_firewall_rules "$old_port"
    firewall_public
    save_config
    if wait_for_letsencrypt 120; then
      ok "PUBLIC режим включен: https://${DOMAIN}"
    else
      warn "PUBLIC-режим запущен, но сертификат Let's Encrypt пока не получен. Режим оставлен активным для повторных попыток Caddy."
      return 1
    fi
  else
    warn "Переключение PUBLIC → LAN отключит внешний HTTPS и оставит TorrServer доступным только из LAN."
    read -rp "Перейти в LAN? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    MODE="lan"
    while :; do
      read -rp "Приватный IPv4 адрес сервера в LAN: " BIND_IP
      if valid_private_ipv4 "$BIND_IP" && host_has_ipv4 "$BIND_IP"; then break; fi
      warn "Нужен приватный IPv4, назначенный интерфейсу сервера."
    done
    while :; do read -rp "LAN-порт [8090]: " PORT; PORT="${PORT:-8090}"; port_free "$PORT" && break || warn "Порт занят или неверен."; done
    DOMAIN=""; EMAIL=""
    write_lan_compose
    if ! (cd "$APP_DIR" && docker compose down && docker compose pull torrserver && docker compose up -d); then
      warn "Не удалось включить LAN. Восстанавливаю предыдущий режим."
      MODE="$old_mode"; PORT="$old_port"; DOMAIN="$old_domain"; EMAIL="$old_email"; BIND_IP="$old_bind"
      mv -f "${COMPOSE}.mode-backup" "$COMPOSE" 2>/dev/null || true
      mv -f "${CADDYFILE}.mode-backup" "$CADDYFILE" 2>/dev/null || true
      save_config
      (cd "$APP_DIR" && docker compose up -d) || true
      return 1
    fi
    remove_public_firewall_rules
    firewall_lan
    save_config
    ok "LAN режим включен: http://${BIND_IP}:${PORT}"
  fi
  rm -f "${COMPOSE}.mode-backup" "${CADDYFILE}.mode-backup"
}
uninstall(){
  [[ -d "$APP_DIR" ]] || { warn "Не установлен."; return; }
  read -rp "Удалить TorrServer и его конфигурацию? [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]] || return
  load_config || true
  if command -v ufw >/dev/null 2>&1; then
    remove_public_firewall_rules
    remove_lan_firewall_rules "${PORT:-$DEFAULT_PORT}"
  fi
  (cd "$APP_DIR" && docker compose down -v 2>/dev/null || true)
  rm -rf "$APP_DIR" "$CERT_DIR"
  ok "Удалено."
}
check_letsencrypt(){
  [[ -f "$CONF" ]] || { warn "Не установлен."; return 1; }
  load_config
  if [[ "$MODE" != "public" ]]; then
    warn "Let's Encrypt используется только в PUBLIC режиме."
    return 1
  fi
  local failed=0 issuer="" dates=""
  info "Проверка Let's Encrypt для ${DOMAIN}"
  if check_dns "$DOMAIN"; then ok "DNS A-запись соответствует публичному IPv4 сервера."; else failed=1; fi
  if docker ps --format '{{.Names}}' | grep -qx 'torrserver-caddy'; then
    ok "Caddy запущен."
    docker exec torrserver-caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && ok "Caddyfile валиден." || { warn "Caddyfile не проходит caddy validate."; failed=1; }
  else
    warn "Контейнер Caddy не запущен."
    failed=1
  fi
  if timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout >/dev/null 2>&1; then
    issuer="$(timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
    dates="$(timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || true)"
    echo "$issuer"
    echo "$dates"
    if grep -qi "Let's Encrypt" <<<"$issuer"; then ok "Сертификат выдан Let's Encrypt."; else warn "TLS работает, но издатель не распознан как Let's Encrypt."; failed=1; fi
  else
    warn "Caddy локально не отдаёт сертификат для ${DOMAIN}; выпуск Let's Encrypt ещё не завершён."
    failed=1
  fi
  echo "Последние сообщения Caddy об ACME/TLS:"
  docker logs --tail 100 torrserver-caddy 2>&1 | grep -Ei 'certificate|acme|tls|issuer|renew' | tail -n 30 || true
  (( failed == 0 )) && ok "Проверка Let's Encrypt завершена успешно." || { warn "Обнаружены проблемы Let's Encrypt/TLS."; return 1; }
}
doctor(){
  local failed=0
  info "Диагностика TorrServer Docker Manager v${MANAGER_VERSION}"
  for cmd in bash curl docker jq ss ip openssl; do
    command -v "$cmd" >/dev/null 2>&1 && ok "$cmd: OK" || { warn "$cmd: не найден"; failed=1; }
  done
  docker compose version >/dev/null 2>&1 && ok "docker compose: OK" || { warn "docker compose: недоступен"; failed=1; }
  if [[ -f "$CONF" ]]; then
    load_config || { warn "manager.conf повреждён"; failed=1; }
    [[ -f "$COMPOSE" ]] && ok "docker-compose.yml: найден" || { warn "docker-compose.yml отсутствует"; failed=1; }
    (cd "$APP_DIR" && docker compose config >/dev/null 2>&1) && ok "Docker Compose config: валиден" || { warn "Docker Compose config: ошибка"; failed=1; }
    [[ -f "$CONFIG_DIR/accs.db" ]] && jq -e 'type=="object"' "$CONFIG_DIR/accs.db" >/dev/null 2>&1 && ok "accs.db: валиден" || { warn "accs.db отсутствует или повреждён"; failed=1; }
    if [[ "$MODE" == "public" ]]; then check_letsencrypt || failed=1; fi
  else
    info "TorrServer ещё не установлен; проверена только среда менеджера."
  fi
  (( failed == 0 )) && ok "Диагностика завершена без ошибок." || return 1
}
main(){
  require_root
  case "${1:-}" in
    update) change_version; return ;;
    restart) restart_stack; return ;;
    logs) logs; return ;;
    status) status; return ;;
    check-le|check-ssl|ssl) check_letsencrypt; return ;;
    check-update) check_manager_update; return $? ;;
    version) echo "v${MANAGER_VERSION}"; return ;;
    self-update|update-manager) self_update; return ;;
    doctor|check) doctor; return ;;
    menu|"") ;;
    *) echo "Использование: $0 {menu|status|update|restart|logs|check-le|check-update|self-update|doctor|version}"; return 1 ;;
  esac
  while :; do
    echo
    echo "=============================================="
    echo " TorrServer Docker Manager v${MANAGER_VERSION} — Chistovik92"
    echo "=============================================="
    status
    echo "----------------------------------------------"
    check_manager_update >/dev/null 2>&1 || true
    echo "1. Установить"
    echo "2. Обновить/понизить версию"
    echo "3. Пользователи"
    echo "4. Переключить LAN / PUBLIC"
    echo "5. Перезапустить"
    echo "6. Логи"
    echo "7. Удалить"
    echo "8. Проверить обновление менеджера"
    echo "9. Обновить сам менеджер с GitHub"
    echo "10. Диагностика проекта"
    echo "0. Выход"
    echo "=============================================="
    read -rp "Выбор: " c
    case "$c" in
      1) install_torr;;
      2) change_version;;
      3) manage_users;;
      4) switch_mode;;
      5) restart_stack;;
      6) logs;;
      7) uninstall;;
      8) check_manager_update || true;;
      9) self_update;;
      10) doctor || true;;
      0) exit 0;;
      *) warn "Неверный выбор.";;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
