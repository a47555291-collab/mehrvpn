#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
REF="${MEHRVPN_REF:-main}"; ROOT=/opt/mehrvpn; ETC=/etc/mehrvpn; DB=/var/lib/mehrvpn; BACK=/var/backups/mehrvpn; ENV="$ETC/panel.env"; VPN=/etc/openvpn/server/server.conf; TMP=
log(){ echo "[MehrVPN] $*"; }; die(){ echo "[MehrVPN][ERROR] $*" >&2; exit 1; }; trap '[[ -z "${TMP:-}" ]] || rm -rf "$TMP"' EXIT
root(){ [[ $EUID -eq 0 ]] || die 'Run as root.'; }; cmd(){ command -v "$1" >/dev/null || die "Missing command: $1"; }
os_ok(){ source /etc/os-release; case "$ID:$VERSION_ID" in ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;; *) die 'Supported: Ubuntu 22.04/24.04, Debian 12/13.';; esac; [[ -e /dev/net/tun ]] || die 'TUN device is unavailable.'; }
source_tree(){ local h d; h="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; if [[ -f "$h/panel/app.py" ]]; then echo "$h"; return; fi; cmd curl; cmd tar; TMP=$(mktemp -d /tmp/mehrvpn.XXXXXX); curl -fsSL --proto '=https' --tlsv1.2 "https://github.com/a47555291-collab/mehrvpn/archive/refs/heads/$REF.tar.gz" -o "$TMP/r.tgz"; tar -xzf "$TMP/r.tgz" -C "$TMP"; d=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'mehrvpn-*' -print -quit); [[ -n "$d" ]] || die 'Invalid release archive.'; echo "$d"; }
install_pkgs(){ export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y python3 python3-venv python3-pip nginx openssl curl ca-certificates tar iproute2 openvpn; }
install_source(){ local s=$1; install -d -m755 "$ROOT"; cp -a "$s/panel" "$s/scripts" "$ROOT/"; install -m755 "$s/install.sh" "$ROOT/install.sh"; install -m644 "$s/requirements.txt" "$s/constraints.txt" "$ROOT/"; find "$ROOT/panel" -type d -exec chmod 755 {} +; find "$ROOT/panel" -type f -exec chmod 644 {} +; chmod 755 "$ROOT/install.sh" "$ROOT/scripts/"*.sh; }
ensure_user(){ getent passwd mehrvpn >/dev/null || useradd --system --home "$DB" --shell /usr/sbin/nologin mehrvpn; install -d -o mehrvpn -g mehrvpn -m700 "$DB"; install -d -m700 /var/lib/mehrvpn-agent "$ETC" "$ETC/tls" "$BACK"; }
openvpn_setup(){
 [[ -f "$VPN" ]] || { log 'OpenVPN server is not configured. Launching the official Nyr installer.'; install -d -m700 /root/mehrvpn-bootstrap; curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/Nyr/openvpn-install/master/openvpn-install.sh -o /root/mehrvpn-bootstrap/openvpn-install.sh; chmod700 /root/mehrvpn-bootstrap/openvpn-install.sh; bash /root/mehrvpn-bootstrap/openvpn-install.sh; }
 [[ -f "$VPN" && -x /etc/openvpn/server/easy-rsa/easyrsa && -f /etc/openvpn/server/client-common.txt ]] || die 'OpenVPN setup is incomplete.'; systemctl is-active --quiet openvpn-server@server.service || die 'OpenVPN service is not healthy.';
}
configure(){ local host=$1 port=$2 origin san; origin="https://$host:$port"; [[ $port ==443 ]] && origin="https://$host"; printf 'MEHRVPN_DB=%s\nMEHRVPN_PUBLIC_URL=%s\n' "$DB/panel.db" "$origin" > "$ENV"; chmod600 "$ENV"; [[ $host =~ ^[0-9]+(\.[0-9]+){3}$ ]] && san="IP:$host" || san="DNS:$host"; openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days365 -keyout "$ETC/tls/panel.key" -out "$ETC/tls/panel.crt" -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1; chmod600 "$ETC/tls/panel.key"; cat >/etc/nginx/conf.d/mehrvpn.conf <<EOF
server { listen $port ssl; server_name $host; ssl_certificate $ETC/tls/panel.crt; ssl_certificate_key $ETC/tls/panel.key; ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 16k; location / { proxy_pass http://127.0.0.1:8097; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$remote_addr; proxy_read_timeout 110s; access_log off; } }
EOF
 nginx -t; }
hooks(){ grep -q 'BEGIN MEHRVPN' "$VPN" || cat >>"$VPN" <<'EOF'

# BEGIN MEHRVPN
management /run/mehrvpn/management.sock unix
management-client-user root
script-security 2
client-connect /opt/mehrvpn/scripts/openvpn-hook.sh
client-disconnect /opt/mehrvpn/scripts/openvpn-hook.sh
# END MEHRVPN
EOF
 install -d -m755 /etc/systemd/system/openvpn-server@server.service.d; cat >/etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf <<'EOF'
[Unit]
BindsTo=mehrvpn-agent.service
After=mehrvpn-agent.service
[Service]
ReadWritePaths=/run/mehrvpn
EOF
 install -m644 "$ROOT/scripts/mehrvpn-agent.service" "$ROOT/scripts/mehrvpn-web.service" /etc/systemd/system/; }
wait_agent(){ for i in {1..30}; do [[ -S /run/mehrvpn/control.sock ]] && return; sleep1; done; die 'Agent socket did not appear.'; }
manager(){ cat >/usr/local/bin/mehrvpn <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-status}" in update|install) exec bash <(curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/a47555291-collab/mehrvpn/main/install.sh) "$1";; *) exec bash /opt/mehrvpn/install.sh "${1:-status}" "${@:2}";; esac
EOF
 chmod755 /usr/local/bin/mehrvpn; }
install(){ root; os_ok; [[ ! -f "$ENV" ]] || die 'Already installed; use mehrvpn update.'; local s host port admin; s=$(source_tree); install_pkgs; ensure_user; install_source "$s"; python3 -m venv "$ROOT/.venv"; "$ROOT/.venv/bin/pip" install --disable-pip-version-check -r "$ROOT/requirements.txt"; host="${MEHRVPN_HOST:-}"; port="${MEHRVPN_PORT:-8443}"; admin="${MEHRVPN_ADMIN:-admin}"; [[ -n $host ]] || read -rp 'Panel hostname or public IP: ' host; [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || die 'Invalid hostname.'; [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port>=1&&10#$port<=65535)) || die 'Invalid port.'; [[ $admin =~ ^[A-Za-z][A-Za-z0-9_-]{0,47}$ ]] || die 'Invalid admin username.'; openvpn_setup; cp -p "$VPN" "$BACK/server.conf.$(date +%Y%m%d-%H%M%S)"; hooks; configure "$host" "$port"; MEHRVPN_DB="$DB/panel.db" "$ROOT/.venv/bin/python" -m panel.cli owner --username "$admin"; chown -R mehrvpn:mehrvpn "$DB"; systemctl daemon-reload; systemctl enable --now mehrvpn-agent.service; wait_agent; systemctl restart openvpn-server@server.service; systemctl enable --now mehrvpn-web.service nginx; systemctl reload nginx; for i in {1..30}; do curl -fsS http://127.0.0.1:8097/api/health >/dev/null && break; sleep1; done; curl -fsS http://127.0.0.1:8097/api/health >/dev/null || die 'Panel health check failed.'; manager; log "Installed. Panel: https://$host:$port"; openssl x509 -in "$ETC/tls/panel.crt" -noout -fingerprint -sha256; }
update(){ root; [[ -f "$ENV" ]] || die 'Not installed.'; local s; s=$(source_tree); cp -p "$VPN" "$BACK/server.conf.$(date +%Y%m%d-%H%M%S)"; systemctl stop mehrvpn-web.service 2>/dev/null || true; cp -a "$s/panel/." "$ROOT/panel/"; cp -a "$s/scripts/." "$ROOT/scripts/"; install -m755 "$s/install.sh" "$ROOT/install.sh"; install -m644 "$s/requirements.txt" "$s/constraints.txt" "$ROOT/"; "$ROOT/.venv/bin/pip" install --disable-pip-version-check -r "$ROOT/requirements.txt"; chmod755 "$ROOT/install.sh" "$ROOT/scripts/"*.sh; systemctl daemon-reload; systemctl restart mehrvpn-agent.service mehrvpn-web.service openvpn-server@server.service; log 'Update completed.'; }
status(){ root; for s in openvpn-server@server.service mehrvpn-agent.service mehrvpn-web.service nginx; do printf '%-34s' "$s"; systemctl is-active --quiet "$s"&&echo active||echo inactive; done; curl -fsS http://127.0.0.1:8097/api/health 2>/dev/null||true; }
logs(){ root; journalctl -u mehrvpn-agent -u mehrvpn-web -u openvpn-server@server --no-pager -n 200; }
restart(){ root; systemctl restart mehrvpn-agent.service openvpn-server@server.service mehrvpn-web.service nginx.service; }
backup(){ root; bash "$ROOT/scripts/backup.sh"; }
uninstall(){ root; read -rp 'Type REMOVE to remove the panel (VPN/data preserved): ' x; [[ $x ==REMOVE ]]||return; systemctl disable --now mehrvpn-web.service mehrvpn-agent.service 2>/dev/null||true; rm -f /etc/systemd/system/mehrvpn-web.service /etc/systemd/system/mehrvpn-agent.service /etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf /etc/nginx/conf.d/mehrvpn.conf /usr/local/bin/mehrvpn; systemctl daemon-reload; systemctl reload nginx 2>/dev/null||true; rm -rf "$ROOT" "$ETC"; log 'Panel removed; OpenVPN and data preserved.'; }
case "${1:-install}" in install)install;;update)update;;status)status;;logs)logs;;restart)restart;;backup)backup;;uninstall)uninstall;;*) echo 'Usage: install.sh [install|update|status|logs|restart|backup|uninstall]'; exit 2;;esac
