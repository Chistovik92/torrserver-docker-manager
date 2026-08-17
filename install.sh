#!/usr/bin/env bash
set -euo pipefail
URL="${TORR_MANAGER_URL:-https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main/manager.sh}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp"
chmod 700 "$tmp"
exec sudo "$tmp"
