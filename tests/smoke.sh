#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n manager.sh
bash -n install.sh
bash -n torrserver
source ./manager.sh

[[ "$MANAGER_VERSION" == "$(tr -d '[:space:]' < VERSION)" ]]
grep -q "Текущая версия менеджера: v${MANAGER_VERSION}" README.md

valid_port 1; valid_port 65535; ! valid_port 0; ! valid_port 65536; ! valid_port abc
valid_private_ipv4 10.0.0.1; valid_private_ipv4 172.16.0.1; valid_private_ipv4 172.31.255.254; valid_private_ipv4 192.168.1.10
! valid_private_ipv4 172.32.0.1; ! valid_private_ipv4 192.168.1.999; ! valid_private_ipv4 8.8.8.8
valid_domain example.com; valid_domain torr.example.com; ! valid_domain localhost; ! valid_domain bad_.example.com; ! valid_domain "-bad.example.com"
version_compare 1.4.0 1.5.0; ! version_compare 1.5.0 1.4.0; version_compare 1.5.0 1.5.0

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APP_DIR="$TMP"; CONF="$APP_DIR/manager.conf"; CONFIG_DIR="$APP_DIR/config"; COMPOSE="$APP_DIR/docker-compose.yml"; CADDYFILE="$APP_DIR/Caddyfile"; CERT_DIR="$APP_DIR/certs"
mkdir -p "$CONFIG_DIR"
host_has_ipv4(){ return 0; }

MODE=lan; PUBLIC_TLS=""; BIND_IP="192.168.1.10"; PORT="8090"
write_lan_compose
grep -q '192.168.1.10:8090:8090' "$COMPOSE"
! grep -q '0.0.0.0' "$COMPOSE"
grep -q 'restart: always' "$COMPOSE"
! grep -q 'unless-stopped' "$COMPOSE"

MODE=public; PUBLIC_TLS=letsencrypt; DOMAIN="torr.example.com"; EMAIL="admin@example.com"; PORT=443; PUBLIC_HOST=""
write_public_compose
grep -q '80:80' "$COMPOSE"; grep -q '443:443' "$COMPOSE"
grep -q 'issuer acme' "$CADDYFILE"; grep -q "test_dir ${LE_ACME_CA}" "$CADDYFILE"
caddyfile_is_current

MODE=public; PUBLIC_TLS=selfsigned; DOMAIN=""; EMAIL=""; PUBLIC_HOST="203.0.113.10"; PORT=443
generate_selfsigned_cert
write_public_compose
grep -q '443:443' "$COMPOSE"; ! grep -q '80:80' "$COMPOSE"
grep -q 'tls /certs/torr.crt /certs/torr.key' "$CADDYFILE"
openssl x509 -in "$CERT_DIR/torr.crt" -noout >/dev/null
caddyfile_is_current

MODE=public; PUBLIC_TLS=none; PUBLIC_HOST="203.0.113.10"; PORT=8090
write_public_compose
grep -q '0.0.0.0:8090:8090' "$COMPOSE"
[[ ! -f "$CADDYFILE" ]]
caddyfile_is_current

type public_preflight >/dev/null 2>&1
type wait_for_letsencrypt >/dev/null 2>&1
type repair_project >/dev/null 2>&1
type generate_selfsigned_cert >/dev/null 2>&1
type boot_stack >/dev/null 2>&1
type detect_lan_ip >/dev/null 2>&1
type ensure_lan_bind_ip >/dev/null 2>&1
type install_systemd_unit >/dev/null 2>&1
type remove_systemd_unit >/dev/null 2>&1
type systemd_available >/dev/null 2>&1

[[ "$UNIT_NAME" == "torrserver-docker.service" ]]
[[ "$UNIT_PATH" == "/etc/systemd/system/torrserver-docker.service" ]]
grep -q 'start|boot|autostart) boot_stack' manager.sh
grep -q 'ExecStart=/bin/bash ${APP_DIR}/manager.sh boot' manager.sh
grep -q 'Wants=network-online.target' manager.sh

# ensure_lan_bind_ip: адрес на месте — конфигурация не трогается
MODE=lan; PUBLIC_TLS=""; BIND_IP="192.168.1.10"; PORT="8090"; DOMAIN=""; EMAIL=""; PUBLIC_HOST=""; PRIMARY_USER="admin"
save_config
host_has_ipv4(){ [[ "$1" == "192.168.1.10" ]]; }
detect_lan_ip(){ printf '192.168.1.10
'; }
remove_lan_firewall_rules(){ :; }
ensure_lan_bind_ip 0
[[ "$BIND_IP" == "192.168.1.10" ]]
[[ "$BIND_IP_CHANGED" == "0" ]]

# ensure_lan_bind_ip: адрес сменился — конфигурация мигрирует, данные не трогаются
host_has_ipv4(){ return 1; }
detect_lan_ip(){ printf '192.168.1.55
'; }
ensure_lan_bind_ip 0
[[ "$BIND_IP" == "192.168.1.55" ]]
[[ "$BIND_IP_CHANGED" == "1" ]]
grep -q '^BIND_IP=192.168.1.55$' "$CONF"
grep -q '^PRIMARY_USER=admin$' "$CONF"

# ensure_lan_bind_ip: приватного адреса нет вообще — отказ без изменения конфигурации
detect_lan_ip(){ return 1; }
BIND_IP="192.168.1.55"
! ensure_lan_bind_ip 0
grep -q '^BIND_IP=192.168.1.55$' "$CONF"

echo "smoke: OK (manager v${MANAGER_VERSION})"
