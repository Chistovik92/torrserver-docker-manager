#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${TORR_MANAGER_BASE_URL:-https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main}"
URL="${TORR_MANAGER_URL:-${BASE_URL}/manager.sh}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp"
chmod 700 "$tmp"
sudo install -d -m 755 /opt/torr-docker
sudo install -m 755 "$tmp" /opt/torr-docker/manager.sh
curl -fsSL --max-time 15 "${BASE_URL}/VERSION" -o /tmp/torrserver-manager-version
if [[ -s /tmp/torrserver-manager-version ]]; then sudo install -m 644 /tmp/torrserver-manager-version /opt/torr-docker/VERSION; fi
sudo ln -sf /opt/torr-docker/manager.sh /usr/local/bin/torrserver
rm -f /tmp/torrserver-manager-version
exec sudo /opt/torr-docker/manager.sh
