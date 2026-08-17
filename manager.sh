#!/usr/bin/env bash
# ==============================================================================
# TorrServer Docker Manager v1.5.0
# Author: Chistovik92
# Supports:
#   1) LAN mode: TorrServer exposed over HTTP to the local network, no Let's Encrypt.
#   2) Public mode: Let's Encrypt / self-signed TLS / plain HTTP.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/torr-docker"
MANAGER_VERSION="1.5.0"
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
  if [[ -f "$CONF" ]]; then
    info "Запуск автоматической миграции установленной конфигурации..."
    if "$APP_DIR/manager.sh" repair; then
      ok "Миграция конфигурации после self-update завершена."
    else
      warn "Менеджер обновлён, но repair требует внимания. Выполните: sudo torrserver repair"
    fi
  fi
}

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash manager.sh"; }
load_config(){
  [[ -f "$CONF" ]] || return 1
  # shellcheck disable=SC1090
  source "$CONF"
  MODE="${MODE:-lan}"; PORT="${PORT:-$DEFAULT_PORT}"; DOMAIN="${DOMAIN:-}"; EMAIL="${EMAIL:-}"; BIND_IP="${BIND_IP:-}"
  PUBLIC_TLS="${PUBLIC_TLS:-letsencrypt}"; PUBLIC_HOST="${PUBLIC_HOST:-${DOMAIN:-}}"
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
PUBLIC_TLS=${PUBLIC_TLS:-}
PUBLIC_HOST=${PUBLIC_HOST:-}
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
  apt-get install -y ca-certificates curl jq ufw openssl cron iproute2 tcpdump netcat-openbsd dnsutils
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin не найден."
}
ensure_repair_packages(){
  local missing=() cmd pkg
  for cmd in curl jq ss ip openssl tcpdump nc dig; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    case "$cmd" in
      ss|ip) pkg="iproute2";;
      tcpdump) pkg="tcpdump";;
      nc) pkg="netcat-openbsd";;
      dig) pkg="dnsutils";;
      *) pkg="$cmd";;
    esac
    missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    info "Установка недостающих диагностических пакетов: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${missing[@]}"
  fi
}

backup_runtime_config(){
  local stamp dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${APP_DIR}/backups/repair-${stamp}"
  mkdir -p "$dir"
  for f in "$CONF" "$COMPOSE" "$CADDYFILE" "${APP_DIR}/.env"; do
    [[ -f "$f" ]] && cp -a "$f" "$dir/"
  done
  [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "$dir/config"
  [[ -d "$CERT_DIR" ]] && cp -a "$CERT_DIR" "$dir/certs"
  echo "$dir"
}

caddyfile_is_current(){
  [[ "${MODE:-}" == "public" ]] || return 0
  case "${PUBLIC_TLS:-letsencrypt}" in
    none) [[ ! -f "$CADDYFILE" ]] || return 1 ;;
    letsencrypt)
      [[ -f "$CADDYFILE" ]] || return 1
      grep -qF "issuer acme" "$CADDYFILE" && grep -qF "dir ${LE_ACME_CA}" "$CADDYFILE" && grep -qF "test_dir ${LE_ACME_CA}" "$CADDYFILE"
      ;;
    selfsigned)
      [[ -f "$CADDYFILE" ]] && grep -qF 'tls /certs/torr.crt /certs/torr.key' "$CADDYFILE"
      ;;
    *) return 1 ;;
  esac
}

clear_caddy_staging_state(){
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'torrserver-caddy' || return 0
  docker exec torrserver-caddy sh -c 'rm -rf /data/caddy/acme/acme-staging-v02.api.letsencrypt.org-directory' >/dev/null 2>&1 || true
}

validate_generated_config(){
  (cd "$APP_DIR" && docker compose config >/dev/null) || die "Сгенерированный docker-compose.yml невалиден."
  if [[ "${MODE:-}" == "public" && "${PUBLIC_TLS:-letsencrypt}" != "none" ]]; then
    if [[ "${PUBLIC_TLS}" == "selfsigned" ]]; then
      docker run --rm -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" -v "$CERT_DIR:/certs:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null || die "Сгенерированный Caddyfile невалиден."
    else
      docker run --rm -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null || die "Сгенерированный Caddyfile невалиден."
    fi
  fi
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
  local p="${1:-${PORT:-0}}"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
  ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
  if valid_port "$p"; then ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 || true; fi
}
firewall_lan(){
  remove_public_firewall_rules
  command -v ufw >/dev/null 2>&1 || return 0
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow from 10.0.0.0/8 to any port "$PORT" proto tcp
  ufw allow from 172.16.0.0/12 to any port "$PORT" proto tcp
  ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp
  ufw --force enable
}
firewall_public(){
  command -v ufw >/dev/null 2>&1 || return 0
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH >/dev/null 2>&1 || true
  case "${PUBLIC_TLS:-letsencrypt}" in
    letsencrypt) ufw allow 80/tcp; ufw allow 443/tcp ;;
    selfsigned) ufw allow 443/tcp ;;
    none) ufw allow "${PORT}/tcp" ;;
  esac
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
  case "${PUBLIC_TLS:-letsencrypt}" in
    none)
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
      - "0.0.0.0:${PORT}:8090"
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}
EOF
      rm -f "$CADDYFILE"
      ;;
    letsencrypt|selfsigned)
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
      - "443:443"
EOF
      if [[ "$PUBLIC_TLS" == "letsencrypt" ]]; then
        cat >>"$COMPOSE" <<EOF
      - "80:80"
EOF
      fi
      cat >>"$COMPOSE" <<EOF
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
EOF
      if [[ "$PUBLIC_TLS" == "selfsigned" ]]; then
        cat >>"$COMPOSE" <<EOF
      - ${CERT_DIR}:/certs:ro
EOF
      fi
      cat >>"$COMPOSE" <<EOF
    networks: [internal]
    depends_on: [torrserver]

networks:
  internal:

volumes:
  caddy_data:
  caddy_config:
EOF
      if [[ "$PUBLIC_TLS" == "letsencrypt" ]]; then
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
      else
        cat >"$CADDYFILE" <<EOF
https://${PUBLIC_HOST} {
  tls /certs/torr.crt /certs/torr.key
  reverse_proxy torrserver:8090
}
EOF
      fi
      ;;
    *) die "Неизвестный PUBLIC_TLS: ${PUBLIC_TLS}" ;;
  esac
}
generate_selfsigned_cert(){
  local host="${PUBLIC_HOST:-}" san
  [[ -n "$host" ]] || die "Не задан PUBLIC_HOST для самоподписанного сертификата."
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  if valid_ipv4 "$host"; then san="IP:${host}"; else san="DNS:${host}"; fi
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 825 \
    -keyout "$CERT_DIR/torr.key" -out "$CERT_DIR/torr.crt" \
    -subj "/CN=${host}" -addext "subjectAltName=${san}" >/dev/null 2>&1 || die "Не удалось создать самоподписанный сертификат."
  chmod 600 "$CERT_DIR/torr.key"
  chmod 644 "$CERT_DIR/torr.crt"
}
public_preflight(){
  local failed=0 public_ip dnsips
  public_ip="$(get_public_ip)"
  [[ -n "$public_ip" ]] && ok "Публичный IPv4 сервера: $public_ip" || { warn "Не удалось определить публичный IPv4 сервера."; failed=1; }
  case "${PUBLIC_TLS:-letsencrypt}" in
    letsencrypt)
      info "PUBLIC preflight: Let's Encrypt для ${DOMAIN}"
      dnsips="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)"
      [[ -n "$dnsips" ]] && grep -qx "$public_ip" <<<"$dnsips" && ok "DNS A-запись домена указывает на этот сервер." || { warn "DNS A-запись не совпадает с публичным IPv4 сервера."; failed=1; }
      port_free 80 && ok "TCP/80 свободен локально." || { warn "TCP/80 занят локальным процессом."; failed=1; }
      port_free 443 && ok "TCP/443 свободен локально." || { warn "TCP/443 занят локальным процессом."; failed=1; }
      warn "Для Let's Encrypt входящие TCP/80 и TCP/443 должны быть доступны из Интернета."
      ;;
    selfsigned)
      info "PUBLIC preflight: самоподписанный TLS"
      port_free 443 && ok "TCP/443 свободен локально." || { warn "TCP/443 занят локальным процессом."; failed=1; }
      warn "Клиенты будут видеть предупреждение о недоверенном сертификате, пока вы явно не добавите его в доверенные."
      ;;
    none)
      info "PUBLIC preflight: HTTP без сертификата"
      port_free "$PORT" && ok "TCP/${PORT} свободен локально." || { warn "TCP/${PORT} занят локальным процессом."; failed=1; }
      warn "ВНИМАНИЕ: HTTP передаёт логин, пароль и трафик без TLS-шифрования. Используйте только если это осознанный выбор."
      ;;
    *) warn "Неизвестный тип PUBLIC_TLS: ${PUBLIC_TLS}"; failed=1 ;;
  esac
  (( failed == 0 )) || { warn "PUBLIC preflight не пройден."; return 1; }
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
  local top public_choice public_ip
  while :; do
    echo "============================================="
    echo "  Установка TorrServer Docker"
    echo "============================================="
    echo "1. Внутренняя сеть (LAN)"
    echo "2. Внешний доступ (PUBLIC)"
    echo "0. Назад"
    read -rp "Выбор: " top
    case "$top" in
      1) MODE="lan"; PUBLIC_TLS=""; break ;;
      2)
        MODE="public"; BIND_IP=""
        while :; do
          echo "---------------------------------------------"
          echo " Внешний доступ — выберите защиту"
          echo "1. Let's Encrypt (доверенный HTTPS, нужен домен)"
          echo "2. Самоподписанный сертификат (HTTPS)"
          echo "3. Без сертификата (HTTP)"
          echo "4. Назад к выбору LAN / PUBLIC"
          read -rp "Выбор: " public_choice
          case "$public_choice" in
            1) PUBLIC_TLS="letsencrypt"; break 2 ;;
            2) PUBLIC_TLS="selfsigned"; break 2 ;;
            3) PUBLIC_TLS="none"; break 2 ;;
            4) break ;;
            *) warn "Неверный выбор." ;;
          esac
        done
        [[ "$public_choice" == "4" ]] && continue
        ;;
      0) return ;;
      *) warn "Неверный выбор." ;;
    esac
  done

  if [[ "$MODE" == "lan" ]]; then
    while :; do
      read -rp "Приватный IPv4 адрес сервера в LAN (например 192.168.1.10): " BIND_IP
      valid_private_ipv4 "$BIND_IP" && host_has_ipv4 "$BIND_IP" && break
      warn "Нужен приватный IPv4, реально назначенный интерфейсу сервера."
    done
    while :; do read -rp "Порт TorrServer [${DEFAULT_PORT}]: " PORT; PORT="${PORT:-$DEFAULT_PORT}"; port_free "$PORT" && break || warn "Порт занят или неверен."; done
    DOMAIN=""; EMAIL=""; PUBLIC_HOST=""
  else
    public_ip="$(get_public_ip)"
    case "$PUBLIC_TLS" in
      letsencrypt)
        PORT="443"; PUBLIC_HOST=""
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
        ;;
      selfsigned)
        PORT="443"; EMAIL=""; DOMAIN=""
        read -rp "Имя для сертификата [${public_ip:-public-ip}]: " PUBLIC_HOST
        PUBLIC_HOST="${PUBLIC_HOST:-$public_ip}"
        if ! valid_ipv4 "$PUBLIC_HOST" && ! valid_domain "$PUBLIC_HOST"; then warn "Нужно корректное доменное имя или IPv4."; return 1; fi
        ;;
      none)
        DOMAIN=""; EMAIL=""; PUBLIC_HOST="${public_ip:-}"
        while :; do read -rp "Внешний HTTP-порт [${DEFAULT_PORT}]: " PORT; PORT="${PORT:-$DEFAULT_PORT}"; port_free "$PORT" && break || warn "Порт занят или неверен."; done
        ;;
    esac
    public_preflight || return 1
  fi

  install_packages
  mkdir -p "$APP_DIR" "$CONFIG_DIR"
  if [[ -f "$CONFIG_DIR/accs.db" && -n "${PRIMARY_USER:-}" ]]; then
    info "Существующая база пользователей сохранена."
    chmod 600 "$CONFIG_DIR/accs.db"
  else
    setup_auth
  fi
  if [[ "$MODE" == "public" && "$PUBLIC_TLS" == "selfsigned" ]]; then generate_selfsigned_cert; fi
  save_config
  if [[ "$MODE" == "lan" ]]; then write_lan_compose; firewall_lan; else write_public_compose; firewall_public; fi
  validate_generated_config
  start_stack

  if [[ "$MODE" == "lan" ]]; then
    ok "Установка завершена. LAN: http://${BIND_IP}:${PORT}"
  elif [[ "$PUBLIC_TLS" == "letsencrypt" ]]; then
    if wait_for_letsencrypt 180; then ok "PUBLIC HTTPS готов: https://${DOMAIN}"; else warn "PUBLIC запущен, но сертификат Let's Encrypt пока не получен."; return 1; fi
  elif [[ "$PUBLIC_TLS" == "selfsigned" ]]; then
    ok "PUBLIC HTTPS с самоподписанным сертификатом: https://${PUBLIC_HOST}"
    warn "Предупреждение браузера о недоверенном сертификате ожидаемо."
  else
    ok "PUBLIC HTTP без TLS: http://${PUBLIC_HOST:-$(get_public_ip)}:${PORT}"
    warn "Соединение не шифруется."
  fi
}
status(){
  if [[ ! -f "$CONF" ]]; then echo "Не установлен"; return; fi
  load_config
  echo "Режим: $MODE"
  if [[ "$MODE" == "public" ]]; then
    echo "PUBLIC TLS: ${PUBLIC_TLS:-letsencrypt}"
    case "${PUBLIC_TLS:-letsencrypt}" in
      letsencrypt) echo "Домен: $DOMAIN"; echo "URL: https://$DOMAIN"; echo "Порт: 443" ;;
      selfsigned) echo "Сертификат: самоподписанный"; echo "URL: https://${PUBLIC_HOST}"; echo "Порт: 443" ;;
      none) echo "Сертификат: отсутствует"; echo "URL: http://${PUBLIC_HOST:-$(get_public_ip)}:$PORT"; echo "Порт: $PORT" ;;
    esac
  else
    echo "LAN IP: $BIND_IP"
    echo "URL: http://$BIND_IP:$PORT"
    echo "Порт: $PORT"
  fi
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
  local backup old_mode="$MODE" old_port="$PORT"
  backup="$(backup_runtime_config)"
  warn "Смена режима будет выполнена через мастер установки параметров. Backup: $backup"
  (cd "$APP_DIR" && docker compose down) || true
  rm -f "$CONF"
  if install_torr; then
    if [[ "$old_mode" == "lan" ]]; then remove_lan_firewall_rules "$old_port"; else remove_public_firewall_rules "$old_port"; fi
    load_config || true
    if [[ "$MODE" == "lan" ]]; then firewall_lan; else firewall_public; fi
    ok "Режим успешно изменён."
    return 0
  fi
  warn "Смена режима не завершена. Восстанавливаю предыдущую конфигурацию из $backup"
  cp -a "$backup/manager.conf" "$CONF" 2>/dev/null || true
  cp -a "$backup/docker-compose.yml" "$COMPOSE" 2>/dev/null || true
  [[ -f "$backup/Caddyfile" ]] && cp -a "$backup/Caddyfile" "$CADDYFILE" || rm -f "$CADDYFILE"
  [[ -f "$backup/.env" ]] && cp -a "$backup/.env" "${APP_DIR}/.env" || true
  if [[ -d "$backup/config" ]]; then rm -rf "$CONFIG_DIR"; cp -a "$backup/config" "$CONFIG_DIR"; fi
  if [[ -d "$backup/certs" ]]; then rm -rf "$CERT_DIR"; cp -a "$backup/certs" "$CERT_DIR"; fi
  (cd "$APP_DIR" && docker compose up -d) || true
  return 1
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
repair_project(){
  require_root
  [[ -f "$CONF" ]] || { warn "TorrServer не установлен; repair применять не к чему."; return 1; }
  load_config || die "Не удалось прочитать manager.conf."
  ensure_repair_packages
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Сначала выполните обычную установку менеджера."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin недоступен."

  local backup
  backup="$(backup_runtime_config)"
  info "Резервная копия перед восстановлением: $backup"

  mkdir -p "$CONFIG_DIR"
  if [[ -f "$CONFIG_DIR/accs.db" ]]; then
    jq -e 'type=="object"' "$CONFIG_DIR/accs.db" >/dev/null 2>&1 || die "accs.db повреждён; автоматическое восстановление остановлено, backup: $backup"
    chmod 600 "$CONFIG_DIR/accs.db"
  fi
  chmod 600 "$CONF"

  if [[ "$MODE" == "lan" ]]; then
    valid_private_ipv4 "$BIND_IP" || die "В manager.conf указан некорректный LAN IP: $BIND_IP"
    host_has_ipv4 "$BIND_IP" || die "LAN IP $BIND_IP не назначен этому серверу."
    write_lan_compose
    firewall_lan
    validate_generated_config
    (cd "$APP_DIR" && docker compose up -d --remove-orphans)
    ok "LAN-конфигурация восстановлена: http://${BIND_IP}:${PORT}"
    return 0
  fi

  remove_lan_firewall_rules "$PORT"
  case "${PUBLIC_TLS:-letsencrypt}" in
    letsencrypt)
      valid_domain "$DOMAIN" || die "В manager.conf указан некорректный домен: $DOMAIN"
      [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "В manager.conf указан некорректный email."
      check_dns "$DOMAIN" || die "DNS домена не соответствует публичному IP сервера."
      firewall_public
      write_public_compose
      validate_generated_config
      (cd "$APP_DIR" && docker compose up -d --remove-orphans)
      clear_caddy_staging_state
      (cd "$APP_DIR" && docker compose restart caddy)
      if wait_for_letsencrypt 180; then ok "PUBLIC Let's Encrypt восстановлен: https://${DOMAIN}"; return 0; fi
      warn "Локальная конфигурация исправлена, но Let's Encrypt не завершил внешнюю проверку. Проверьте NAT/CGNAT/router/provider firewall."
      return 2
      ;;
    selfsigned)
      [[ -n "$PUBLIC_HOST" ]] || PUBLIC_HOST="$(get_public_ip)"
      if ! valid_ipv4 "$PUBLIC_HOST" && ! valid_domain "$PUBLIC_HOST"; then die "Некорректный PUBLIC_HOST: $PUBLIC_HOST"; fi
      if [[ ! -s "$CERT_DIR/torr.crt" || ! -s "$CERT_DIR/torr.key" ]] || ! openssl x509 -checkend 604800 -noout -in "$CERT_DIR/torr.crt" >/dev/null 2>&1; then
        generate_selfsigned_cert
      fi
      firewall_public
      write_public_compose
      validate_generated_config
      (cd "$APP_DIR" && docker compose up -d --remove-orphans)
      ok "PUBLIC self-signed восстановлен: https://${PUBLIC_HOST}"
      return 0
      ;;
    none)
      valid_port "$PORT" || die "Некорректный PUBLIC HTTP порт: $PORT"
      PUBLIC_HOST="${PUBLIC_HOST:-$(get_public_ip)}"
      firewall_public
      write_public_compose
      validate_generated_config
      (cd "$APP_DIR" && docker compose up -d --remove-orphans)
      ok "PUBLIC HTTP восстановлен: http://${PUBLIC_HOST}:${PORT}"
      return 0
      ;;
    *) die "Неизвестный PUBLIC_TLS: ${PUBLIC_TLS}" ;;
  esac
}

check_letsencrypt(){
  [[ -f "$CONF" ]] || { warn "Не установлен."; return 1; }
  load_config
  if [[ "$MODE" != "public" || "${PUBLIC_TLS:-letsencrypt}" != "letsencrypt" ]]; then
    warn "check-le применяется только к PUBLIC → Let's Encrypt. Текущий режим: ${MODE}/${PUBLIC_TLS:-none}."
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
  for cmd in bash curl docker jq ss ip openssl tcpdump nc dig; do
    command -v "$cmd" >/dev/null 2>&1 && ok "$cmd: OK" || { warn "$cmd: не найден"; failed=1; }
  done
  docker compose version >/dev/null 2>&1 && ok "docker compose: OK" || { warn "docker compose: недоступен"; failed=1; }
  if [[ -f "$CONF" ]]; then
    load_config || { warn "manager.conf повреждён"; failed=1; }
    [[ -f "$COMPOSE" ]] && ok "docker-compose.yml: найден" || { warn "docker-compose.yml отсутствует"; failed=1; }
    (cd "$APP_DIR" && docker compose config >/dev/null 2>&1) && ok "Docker Compose config: валиден" || { warn "Docker Compose config: ошибка"; failed=1; }
    [[ -f "$CONFIG_DIR/accs.db" ]] && jq -e 'type=="object"' "$CONFIG_DIR/accs.db" >/dev/null 2>&1 && ok "accs.db: валиден" || { warn "accs.db отсутствует или повреждён"; failed=1; }
    if [[ "$MODE" == "public" ]]; then
      case "${PUBLIC_TLS:-letsencrypt}" in
        letsencrypt)
          caddyfile_is_current && ok "Caddyfile: актуальный Let's Encrypt формат v1.5" || { warn "Caddyfile устарел; выполните: sudo torrserver repair"; failed=1; }
          check_letsencrypt || failed=1
          ;;
        selfsigned)
          caddyfile_is_current && ok "Caddyfile: актуальный self-signed формат v1.5" || { warn "Caddyfile устарел; выполните: sudo torrserver repair"; failed=1; }
          [[ -s "$CERT_DIR/torr.crt" && -s "$CERT_DIR/torr.key" ]] && openssl x509 -checkend 0 -noout -in "$CERT_DIR/torr.crt" >/dev/null 2>&1 && ok "Самоподписанный сертификат: валиден" || { warn "Самоподписанный сертификат отсутствует/истёк; выполните repair"; failed=1; }
          ;;
        none)
          [[ ! -f "$CADDYFILE" ]] && ok "PUBLIC HTTP: Caddy не используется" || { warn "Для HTTP без TLS найден лишний Caddyfile; выполните repair"; failed=1; }
          ;;
      esac
    fi
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
    repair|fix) repair_project; return ;;
    menu|"") ;;
    *) echo "Использование: $0 {menu|status|update|restart|logs|check-le|check-update|self-update|doctor|repair|version}"; return 1 ;;
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
    echo "11. Автовосстановление конфигурации (repair)"
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
      11) repair_project || true;;
      0) exit 0;;
      *) warn "Неверный выбор.";;
    esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
