#!/usr/bin/env bash
set -euo pipefail
URL="${TORR_MANAGER_URL:-https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/manager.sh}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp"
chmod 700 "$tmp"
sudo install -d -m 755 /opt/torr-docker
sudo install -m 755 "$tmp" /opt/torr-docker/manager.sh
sudo ln -sf /opt/torr-docker/manager.sh /usr/local/bin/torrserver
exec sudo /opt/torr-docker/manager.sh
