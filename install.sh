#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BASE_URL="${TORR_MANAGER_BASE_URL:-https://raw.githubusercontent.com/Chistovik92/torrserver-docker-manager/main}"
URL="${TORR_MANAGER_URL:-${BASE_URL}/manager.sh}"
APP_DIR="/opt/torr-docker"
TMP_MANAGER="$(mktemp)"
TMP_VERSION="$(mktemp)"
trap 'rm -f "$TMP_MANAGER" "$TMP_VERSION"' EXIT

curl -4fsSL --retry 3 --connect-timeout 10 --max-time 60 "$URL" -o "$TMP_MANAGER"
curl -4fsSL --retry 3 --connect-timeout 10 --max-time 30 "${BASE_URL}/VERSION" -o "$TMP_VERSION"

[[ -s "$TMP_MANAGER" ]] || { echo "Ошибка: manager.sh пустой" >&2; exit 1; }
bash -n "$TMP_MANAGER" || { echo "Ошибка: manager.sh не проходит bash -n" >&2; exit 1; }

remote_version="$(tr -d '[:space:]' <"$TMP_VERSION")"
[[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Ошибка: некорректный VERSION: $remote_version" >&2; exit 1; }
embedded_version="$(grep -E '^MANAGER_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$TMP_MANAGER" | head -n1 | cut -d'"' -f2 || true)"
[[ "$embedded_version" == "$remote_version" ]] || {
  echo "Ошибка: VERSION ($remote_version) не совпадает с MANAGER_VERSION (${embedded_version:-не найден})" >&2
  exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

install -d -m 755 "$APP_DIR"
install -m 755 "$TMP_MANAGER" "$APP_DIR/manager.sh"
install -m 644 "$TMP_VERSION" "$APP_DIR/VERSION"
ln -sf "$APP_DIR/manager.sh" /usr/local/bin/torrserver

echo "TorrServer Docker Manager v${remote_version} установлен."
exec "$APP_DIR/manager.sh"
