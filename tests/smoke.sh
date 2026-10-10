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

# backup_runtime_config: пропускает отсутствующие файлы и возвращает 0
MODE=lan; PUBLIC_TLS=""; BIND_IP="192.168.1.10"; PORT="8090"
CERT_DIR="$TMP/no-such-certs"
rm -f "$CADDYFILE" "$APP_DIR/.env"
b="$(backup_runtime_config)"
[[ -d "$b" ]]
[[ -f "$b/manager.conf" ]]
[[ -d "$b/config" ]]
[[ ! -e "$b/certs" ]]

# die завершает действие, а не возвращает управление (иначе "cmd || true" проглатывает ошибку)
out="$( (die "тест"; echo CONTINUED) 2>&1 || true )"
! grep -q CONTINUED <<<"$out"

# detect_lan_ip разбирает "src" из ip route (раньше sed печатал пустую строку)
(
  ip(){
    if [[ "$3" == route ]]; then echo "1.1.1.1 via 192.168.7.1 dev eth0 src 192.168.7.20 uid 0"; fi
  }
  unset -f detect_lan_ip; source ./manager.sh
  [[ "$(detect_lan_ip)" == "192.168.7.20" ]]
)

# switch_mode: отмена мастера установки возвращает прежнюю конфигурацию и код ошибки
MODE=lan; PUBLIC_TLS=""; BIND_IP="192.168.1.10"; PORT="8090"; DOMAIN=""; EMAIL=""; PUBLIC_HOST=""; PRIMARY_USER="admin"
host_has_ipv4(){ return 0; }
save_config; write_lan_compose
docker(){ :; }
rc=0; switch_mode <<<"0" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]]
[[ -f "$CONF" ]] && grep -q '^BIND_IP=192.168.1.10$' "$CONF"
[[ -f "$COMPOSE" ]]
unset -f docker

# Бэкап настроек: архив создаётся, перечисляется и проходит проверку путей
echo '{"admin":"password1"}' >"$CONFIG_DIR/accs.db"
docker(){ echo false; }
backup_create >/dev/null
[[ -f "$BACKUP_LAST" ]]
[[ "$(stat -c %a "$BACKUP_LAST")" == "600" ]]
tar -tzf "$BACKUP_LAST" | grep -q 'config/accs.db'
tar -tzf "$BACKUP_LAST" | grep -qx 'manager.conf'
backup_list >/dev/null
backup_entries_are_safe "$BACKUP_LAST"
unset -f docker

# Восстановление отвергает архив с посторонними путями
mkdir "$TMP/evil" && echo x >"$TMP/evil/passwd" && tar -C "$TMP" -czf "$TMP/evil.tar.gz" evil/passwd
! backup_entries_are_safe "$TMP/evil.tar.gz"
! backup_restore "$TMP/evil.tar.gz" >/dev/null 2>&1

# Восстановление возвращает настройки из архива
cp "$CONFIG_DIR/accs.db" "$TMP/accs.saved"
echo '{"admin":"changed-pass"}' >"$CONFIG_DIR/accs.db"
docker(){ echo false; }
boot_stack(){ :; }
backup_restore "$BACKUP_LAST" <<<"y" >/dev/null
grep -q 'password1' "$CONFIG_DIR/accs.db"
unset -f docker

# Список торрентов: экспорт нормализует ответ API, импорт пропускает уже существующие
container_running(){ return 0; }
RESP='[{"hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","title":"Film One","poster":"p","category":"movie","data":"{}"},{"hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"Two"}]'
CALLS="$TMP/calls"; : >"$CALLS"
ts_api(){ if [[ "$2" == *'"list"'* ]]; then echo "$RESP"; else echo "$2" >>"$CALLS"; fi; }
torrents_export "$TMP/t.json" >/dev/null
[[ "$(jq length "$TMP/t.json")" == "2" ]]
[[ "$(jq -r '.[0].hash' "$TMP/t.json")" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
jq -e '.[0].magnet | startswith("magnet:?xt=urn:btih:aaaa") and endswith("dn=Film%20One")' "$TMP/t.json" >/dev/null
RESP='[{"hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","title":"Film One"}]'
torrents_import "$TMP/t.json" >/dev/null
[[ "$(wc -l <"$CALLS")" == "1" ]]
grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$CALLS"
grep -q '"save_to_db":true' "$CALLS"

# sanitize_input: пробелы, CR и escape-последовательности bracketed paste не должны ломать ввод версии
[[ "$(sanitize_input "  latest ")" == "latest" ]]
[[ "$(sanitize_input "$(printf '\033[200~MatriX.142.2\033[201~\r')")" == "MatriX.142.2" ]]

# Обновление TorrServer: последняя версия берётся из релизов YouROK/TorrServer
curl(){ echo '{"tag_name":"MatriX.146"}'; }
[[ "$(get_latest_torrserver_version)" == "MatriX.146" ]]
curl(){ echo '{"tag_name":"bad tag!"}'; }
[[ -z "$(get_latest_torrserver_version)" ]]
curl(){ echo '{"tag_name":"MatriX.146"}'; }
docker(){ :; }
printf 'TORRSERVER_VERSION=MatriX.145\n' >"$APP_DIR/.env"
change_version <<<"" >/dev/null 2>&1                  # Enter = последний релиз
grep -qx 'TORRSERVER_VERSION=MatriX.146' "$APP_DIR/.env"
change_version release >/dev/null 2>&1                # уже последняя — ничего не меняет
grep -qx 'TORRSERVER_VERSION=MatriX.146' "$APP_DIR/.env"
change_version MatriX.145.2 >/dev/null 2>&1           # явная версия, в т.ч. понижение
grep -qx 'TORRSERVER_VERSION=MatriX.145.2' "$APP_DIR/.env"
unset -f curl docker

echo "smoke: OK (manager v${MANAGER_VERSION})"
