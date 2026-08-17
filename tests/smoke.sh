#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n manager.sh
bash -n install.sh
bash -n torrserver

# shellcheck disable=SC1091
source ./manager.sh

[[ "$MANAGER_VERSION" == "$(tr -d '[:space:]' < VERSION)" ]]
grep -q "Текущая версия менеджера: v${MANAGER_VERSION}" README.md

valid_port 1
valid_port 65535
! valid_port 0
! valid_port 65536
! valid_port abc

valid_private_ipv4 10.0.0.1
valid_private_ipv4 172.16.0.1
valid_private_ipv4 172.31.255.254
valid_private_ipv4 192.168.1.10
! valid_private_ipv4 172.32.0.1
! valid_private_ipv4 192.168.1.999
! valid_private_ipv4 8.8.8.8

valid_domain example.com
valid_domain torr.example.com
! valid_domain localhost
! valid_domain bad_.example.com
! valid_domain "-bad.example.com"

version_compare 1.2.0 1.3.0
! version_compare 1.3.0 1.2.0
version_compare 1.3.0 1.3.0
version_compare 1.9.9 1.10.0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP_DIR="$TMP"
CONF="$APP_DIR/manager.conf"
CONFIG_DIR="$APP_DIR/config"
COMPOSE="$APP_DIR/docker-compose.yml"
CADDYFILE="$APP_DIR/Caddyfile"
mkdir -p "$CONFIG_DIR"
host_has_ipv4(){ return 0; }

BIND_IP="192.168.1.10"
PORT="8090"
write_lan_compose
grep -q '192.168.1.10:8090:8090' "$COMPOSE"
! grep -q '0.0.0.0' "$COMPOSE"

DOMAIN="torr.example.com"
EMAIL="admin@example.com"
write_public_compose
grep -q '80:80' "$COMPOSE"
grep -q '443:443' "$COMPOSE"
grep -q 'acme-v02.api.letsencrypt.org/directory' "$CADDYFILE"
grep -q 'reverse_proxy torrserver:8090' "$CADDYFILE"

echo "smoke: OK (manager v${MANAGER_VERSION})"
