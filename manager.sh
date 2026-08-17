#!/usr/bin/env bash
# ==============================================================================
# TorrServer Docker Manager v1.0
# Author: Chistovik92
# Supports:
#   1) LAN mode: TorrServer exposed over HTTP to the local network, no Let's Encrypt.
#   2) Public mode: Caddy reverse proxy + Let's Encrypt certificate, domain required.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/opt/torr-docker"
CONF="${APP_DIR}/manager.conf"
CONFIG_DIR="${APP_DIR}/config"
COMPOSE="${APP_DIR}/docker-compose.yml"
CADDYFILE="${APP_DIR}/Caddyfile"
CERT_DIR="/opt/certs/torr"
IMAGE="ghcr.io/yourok/torrserver"
DEFAULT_PORT="8090"

die(){ echo -e "\e[31mОшибка: $*\e[0m" >&2; return 1; }
info(){ echo -e "\e[36m$*\e[0m"; }
ok(){ echo -e "\e[32m$*\e[0m"; }
warn(){ echo -e "\e[33m$*\e[0m"; }

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
  valid_port "$1" || return 1
  ! ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q .
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
  apt-get install -y ca-certificates curl jq ufw openssl cron
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
firewall_lan(){
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
  [[ "$BIND_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]] || die "Для LAN режима BIND_IP должен быть приватным IPv4-адресом."
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
  auto_https on
}
${DOMAIN} {
  reverse_proxy torrserver:8090
}
EOF
}
start_stack(){
  cd "$APP_DIR"
  docker compose pull
  docker compose up -d
  docker compose ps
}
install_torr(){
  [[ ! -d "$APP_DIR" ]] || { warn "Установка уже существует. Используйте управление."; return; }
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
        [[ "$BIND_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]] && break
        warn "Нужен адрес из 10.0.0.0/8, 172.16.0.0/12 или 192.168.0.0/16."
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
  ok "Установка завершена."
  if [[ "$MODE" == "lan" ]]; then
    local ip
    ip="$(hostname -I | awk '{print $1}')"
    ok "LAN: http://${ip}:${PORT}"
    warn "LAN-режим не открывает порт в Интернет через UFW; Docker всё равно публикует порт на 0.0.0.0."
    warn "Если сервер доступен из Интернета, дополнительно закройте порт на внешнем firewall/security-group."
  else
    ok "HTTPS: https://${DOMAIN}"
    warn "Caddy сам получает и продлевает сертификат Let's Encrypt. Порт 80 должен быть доступен с Интернета."
  fi
}
status(){
  if [[ ! -f "$CONF" ]]; then echo "Не установлен"; return; fi
  load_config
  echo "Режим: $MODE"
  [[ "$MODE" == "public" ]] && echo "Домен: $DOMAIN"
  echo "Порт: $PORT"
  (cd "$APP_DIR" && docker compose ps 2>/dev/null) || true
}
change_version(){
  [[ -f "$COMPOSE" ]] || { warn "Не установлен."; return; }
  local v
  read -rp "Версия TorrServer (например MatriX.142.2 или latest): " v
  [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "Недопустимая версия."; return; }
  cp -a "$CONFIG_DIR" "${APP_DIR}/config.backup.$(date +%Y%m%d-%H%M%S)"
  sed -i "s/^TORRSERVER_VERSION=.*/TORRSERVER_VERSION=${v}/" "${APP_DIR}/.env" 2>/dev/null || true
  echo "TORRSERVER_VERSION=${v}" >"${APP_DIR}/.env"
  (cd "$APP_DIR" && docker compose pull torrserver && docker compose up -d torrserver)
  ok "Версия обновлена: $v"
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
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      3)
        local u p p2
        read -rp "Логин: " u
        jq -e --arg u "$u" 'has($u)' "$CONFIG_DIR/accs.db" >/dev/null || { warn "Нет такого пользователя."; continue; }
        read -rsp "Новый пароль: " p; echo; read -rsp "Повтор: " p2; echo
        [[ "$p" == "$p2" && ${#p} -ge 8 ]] || { warn "Пароль неверен."; continue; }
        jq --arg u "$u" --arg p "$p" '.[$u]=$p' "$CONFIG_DIR/accs.db" >"${CONFIG_DIR}/accs.db.tmp" &&
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      4)
        local u
        read -rp "Логин для удаления: " u
        [[ "$u" != "$PRIMARY_USER" ]] || { warn "Главного пользователя удалить нельзя."; continue; }
        jq -e --arg u "$u" 'has($u)' "$CONFIG_DIR/accs.db" >/dev/null || { warn "Нет такого пользователя."; continue; }
        jq --arg u "$u" 'del(.[$u])' "$CONFIG_DIR/accs.db" >"${CONFIG_DIR}/accs.db.tmp" &&
          mv "${CONFIG_DIR}/accs.db.tmp" "$CONFIG_DIR/accs.db" && docker restart torrserver >/dev/null
        ;;
      0) return;;
      *) warn "Неверный выбор.";;
    esac
  done
}
switch_mode(){
  [[ -f "$CONF" ]] || { warn "Не установлен."; return; }
  load_config
  if [[ "$MODE" == "lan" ]]; then
    warn "Переключение LAN → PUBLIC потребует домен, DNS и Let's Encrypt."
    read -rp "Перейти в PUBLIC? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    while :; do read -rp "Домен: " DOMAIN; valid_domain "$DOMAIN" && check_dns "$DOMAIN" && break; done
    while :; do read -rp "Email: " EMAIL; [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break; done
    MODE="public"; PORT="443"; save_config
    write_public_compose; firewall_public; (cd "$APP_DIR" && docker compose up -d)
    ok "PUBLIC режим включен: https://${DOMAIN}"
  else
    warn "Переключение PUBLIC → LAN отключит внешний HTTPS и оставит TorrServer доступным только из LAN через UFW."
    read -rp "Перейти в LAN? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || return
    MODE="lan"
    while :; do
      read -rp "Приватный IPv4 адрес сервера в LAN: " BIND_IP
      [[ "$BIND_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]] && break
      warn "Нужен приватный IPv4-адрес."
    done
    while :; do read -rp "LAN-порт [8090]: " PORT; PORT="${PORT:-8090}"; port_free "$PORT" && break; done
    DOMAIN=""; EMAIL=""; save_config
    write_lan_compose; firewall_lan; (cd "$APP_DIR" && docker compose down && docker compose up -d)
    ok "LAN режим включен."
  fi
}
uninstall(){
  [[ -d "$APP_DIR" ]] || { warn "Не установлен."; return; }
  read -rp "Удалить TorrServer и его конфигурацию? [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]] || return
  load_config || true
  if command -v ufw >/dev/null 2>&1; then
    [[ "${MODE:-lan}" == "public" ]] && { ufw delete allow 80/tcp >/dev/null 2>&1 || true; ufw delete allow 443/tcp >/dev/null 2>&1 || true; }
  fi
  (cd "$APP_DIR" && docker compose down -v 2>/dev/null || true)
  rm -rf "$APP_DIR" "$CERT_DIR"
  ok "Удалено."
}
main(){
  require_root
  while :; do
    echo
    echo "=============================================="
    echo " TorrServer Docker Manager v1.0 — Chistovik92"
    echo "=============================================="
    status
    echo "----------------------------------------------"
    echo "1. Установить"
    echo "2. Обновить/понизить версию"
    echo "3. Пользователи"
    echo "4. Переключить LAN / PUBLIC"
    echo "5. Перезапустить"
    echo "6. Логи"
    echo "7. Удалить"
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
      0) exit 0;;
      *) warn "Неверный выбор.";;
    esac
  done
}
main "$@"
