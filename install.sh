#!/usr/bin/env bash
# MehrVPN official installer/manager.
set -Eeuo pipefail
umask 077

MEHRVPN_REF="${MEHRVPN_REF:-main}"
INSTALL_DIR="${MEHRVPN_INSTALL_DIR:-/opt/mehrvpn}"
ETC_DIR="/etc/mehrvpn"
STATE_DIR="/var/lib/mehrvpn"
BACKUP_DIR="/var/backups/mehrvpn"
ENV_FILE="${ETC_DIR}/panel.env"
VPN_CONFIG="/etc/openvpn/server/server.conf"
PANEL_PORT_DEFAULT=8443
TMP_ROOT=""

log(){ printf '\n[MehrVPN] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "${TMP_ROOT:-}" ]] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
trap 'die "Operation failed at line $LINENO. Review: journalctl -u mehrvpn-agent -u mehrvpn-web --no-pager -n 100"' ERR

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

source_tree(){
  local here dir
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  if [[ -f "$here/panel/app.py" && -f "$here/vendor/openvpn-install.sh" ]]; then
    printf '%s\n' "$here"; return
  fi
  require_cmd curl; require_cmd tar
  TMP_ROOT="$(mktemp -d /tmp/mehrvpn.XXXXXX)"
  log "Downloading MehrVPN ${MEHRVPN_REF} from GitHub..."
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "https://github.com/a47555291-collab/mehrvpn/archive/refs/heads/${MEHRVPN_REF}.tar.gz" \
    -o "$TMP_ROOT/release.tar.gz"
  tar -xzf "$TMP_ROOT/release.tar.gz" -C "$TMP_ROOT"
  dir="$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'mehrvpn-*' -print -quit)"
  [[ -n "$dir" ]] || die "Downloaded source archive is invalid."
  printf '%s\n' "$dir"
}

check_os(){
  source /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) die "Supported systems: Ubuntu 22.04/24.04 and Debian 12/13." ;;
  esac
  [[ -e /dev/net/tun ]] || die "TUN device is unavailable. Enable /dev/net/tun first."
  require_cmd systemctl
}

install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-venv python3-pip nginx openssl curl ca-certificates tar
}

validate_host(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || die "Invalid panel hostname/IP."; }
validate_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || die "Invalid TCP port."; }

install_source(){
  local src="$1"
  install -d -m 755 "$INSTALL_DIR"
  cp -a "$src/panel" "$src/vendor" "$src/scripts" "$INSTALL_DIR/"
  install -m 644 "$src/requirements.txt" "$INSTALL_DIR/requirements.txt"
  install -m 644 "$src/constraints.txt" "$INSTALL_DIR/constraints.txt"
  [[ -f "$src/pyproject.toml" ]] && install -m 644 "$src/pyproject.toml" "$INSTALL_DIR/pyproject.toml"
  find "$INSTALL_DIR/panel" "$INSTALL_DIR/vendor" -type d -exec chmod 755 {} +
  find "$INSTALL_DIR/panel" "$INSTALL_DIR/vendor" -type f -exec chmod 644 {} +
  chmod 755 "$INSTALL_DIR/scripts/"*.sh
}

verify_vendor(){
  python3 - "$1" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
s=json.loads((p/'vendor/source.json').read_text())
got=hashlib.sha256((p/'vendor/openvpn-install.sh').read_bytes()).hexdigest()
if got != s['sha256']:
    raise SystemExit('Upstream OpenVPN installer checksum mismatch')
PY
}

ensure_user(){
  getent passwd mehrvpn >/dev/null || useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin mehrvpn
  install -d -o mehrvpn -g mehrvpn -m 700 "$STATE_DIR"
  install -d -m 700 /var/lib/mehrvpn-agent "$ETC_DIR" "$ETC_DIR/tls" "$BACKUP_DIR"
}

backup_config(){
  [[ -f "$VPN_CONFIG" ]] && cp -p "$VPN_CONFIG" "$BACKUP_DIR/server.conf.$(date +%Y%m%d-%H%M%S)"
}

create_admin(){
  local user="$1"
  cd "$INSTALL_DIR"
  log "Creating the owner account. The password is hashed into the database."
  MEHRVPN_DB="$STATE_DIR/panel.db" "$INSTALL_DIR/.venv/bin/python" -m panel.cli owner --username "$user"
}

configure_panel(){
  local host="$1" port="$2" origin san
  origin="https://${host}:${port}"
  [[ "$port" == "443" ]] && origin="https://${host}"
  printf 'MEHRVPN_DB=%s\nMEHRVPN_PUBLIC_URL=%s\n' "$STATE_DIR/panel.db" "$origin" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
    -keyout "$ETC_DIR/tls/panel.key" -out "$ETC_DIR/tls/panel.crt" \
    -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1
  chmod 600 "$ETC_DIR/tls/panel.key"; chmod 644 "$ETC_DIR/tls/panel.crt"
  cat > /etc/nginx/conf.d/mehrvpn.conf <<NGINX
server {
    listen ${port} ssl;
    server_name ${host};
    ssl_certificate ${ETC_DIR}/tls/panel.crt;
    ssl_certificate_key ${ETC_DIR}/tls/panel.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MehrVPN:10m;
    client_max_body_size 16k;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location / {
        proxy_pass http://127.0.0.1:8097;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_read_timeout 110s;
        access_log off;
    }
}
NGINX
  nginx -t
}

configure_openvpn(){
  [[ -f "$VPN_CONFIG" ]] || {
    log "OpenVPN is not installed. Starting the bundled upstream installer."
    install -d -m 700 /root/mehrvpn-bootstrap
    install -m 700 "$1/vendor/openvpn-install.sh" /root/mehrvpn-bootstrap/openvpn-install.sh
    bash /root/mehrvpn-bootstrap/openvpn-install.sh
  }
  [[ -f "$VPN_CONFIG" && -x /etc/openvpn/server/easy-rsa/easyrsa && -f /etc/openvpn/server/client-common.txt ]] || die "OpenVPN installation is incomplete."
  systemctl is-active --quiet openvpn-server@server.service || die "OpenVPN service is not healthy."
  python3 - <<'PY'
import pathlib,re
vpn=pathlib.Path('/etc/openvpn/server'); config=(vpn/'server.conf').read_text()
for key,expected in [('user','nobody'),('group','nogroup')]:
    m=re.search(r'^'+key+r'\s+(\S+)',config,re.M)
    if not m or m.group(1)!=expected: raise SystemExit('Unsupported OpenVPN user/group configuration.')
for line in (vpn/'easy-rsa/pki/index.txt').read_text().splitlines():
    f=line.split('\t')
    if len(f)<6 or f[0]!='V' or '/CN=' not in f[-1]: continue
    name=f[-1].split('/CN=')[-1]
    if name.lower() not in {'server','ca'} and not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]{0,47}',name):
        raise SystemExit('Existing client name is unsupported: '+name)
PY
}

configure_hooks(){
  grep -q 'BEGIN MEHRVPN' "$VPN_CONFIG" || cat >> "$VPN_CONFIG" <<'CONF'

# BEGIN MEHRVPN: policy and accounting integration
management /run/mehrvpn/management.sock unix
management-client-user root
script-security 2
client-connect /opt/mehrvpn/scripts/openvpn-hook.sh
client-disconnect /opt/mehrvpn/scripts/openvpn-hook.sh
# END MEHRVPN
CONF
  install -d -m 755 /etc/systemd/system/openvpn-server@server.service.d
  cat > /etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf <<'UNIT'
[Unit]
BindsTo=mehrvpn-agent.service
After=mehrvpn-agent.service
[Service]
ReadWritePaths=/run/mehrvpn
UNIT
  install -m 644 "$INSTALL_DIR/scripts/mehrvpn-agent.service" /etc/systemd/system/
  install -m 644 "$INSTALL_DIR/scripts/mehrvpn-web.service" /etc/systemd/system/
}

wait_socket(){ for _ in {1..30}; do [[ -S /run/mehrvpn/control.sock ]] && return 0; sleep 1; done; return 1; }

install_wrapper(){
  cat > /usr/local/bin/mehrvpn <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec bash /opt/mehrvpn/install.sh "${1:-status}"
EOF
  chmod 755 /usr/local/bin/mehrvpn
}

start_services(){
  systemctl daemon-reload
  systemctl enable --now mehrvpn-agent.service
  wait_socket || die "MehrVPN Agent socket did not appear."
  systemctl restart openvpn-server@server.service
  systemctl enable --now mehrvpn-web.service
  systemctl enable --now nginx
  systemctl reload nginx
  for _ in {1..30}; do curl -fsS http://127.0.0.1:8097/api/health >/dev/null && return 0; sleep 1; done
  die "Panel health check failed."
}

firewall(){
  local port="$1"
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "${port}/tcp" comment MehrVPN >/dev/null || true; fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
    firewall-cmd --add-port="${port}/tcp" >/dev/null || true
  fi
}

do_install(){
  require_root; check_os
  [[ ! -f "$ENV_FILE" ]] || die "MehrVPN is already installed. Use: mehrvpn update"
  local src host port admin
  src="$(source_tree)"; verify_vendor "$src"; install_packages; ensure_user; install_source "$src"
  python3 -m venv "$INSTALL_DIR/.venv"
  "$INSTALL_DIR/.venv/bin/pip" install --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"
  host="${MEHRVPN_HOST:-}"; port="${MEHRVPN_PORT:-$PANEL_PORT_DEFAULT}"; admin="${MEHRVPN_ADMIN:-admin}"
  [[ -n "$host" ]] || read -r -p "Panel hostname or public IP: " host
  validate_host "$host"; validate_port "$port"
  [[ "$port" == "443" ]] || ! ss -ltnH "sport = :$port" | grep -q . || die "Panel port $port is already in use."
  [[ "$admin" =~ ^[A-Za-z][A-Za-z0-9_-]{0,47}$ && "$admin" != server && "$admin" != ca ]] || die "Invalid admin username."
  configure_openvpn "$src"; backup_config; configure_hooks; configure_panel "$host" "$port"
  create_admin "$admin"; chown -R mehrvpn:mehrvpn "$STATE_DIR"
  start_services; install_wrapper; firewall "$port"
  log "Installation completed."
  echo "Panel: https://${host}:${port}"; echo "Admin: $admin"
  echo "TLS: self-signed certificate; replace it with a trusted certificate for public production."
  echo "Manage: mehrvpn status | mehrvpn logs | mehrvpn restart | mehrvpn backup | mehrvpn update"
  openssl x509 -in "$ETC_DIR/tls/panel.crt" -noout -fingerprint -sha256
}

do_update(){
  require_root; [[ -f "$ENV_FILE" ]] || die "MehrVPN is not installed."
  local src; src="$(source_tree)"; verify_vendor "$src"; backup_config
  systemctl stop mehrvpn-web.service 2>/dev/null || true
  cp -a "$src/panel/." "$INSTALL_DIR/panel/"; cp -a "$src/scripts/." "$INSTALL_DIR/scripts/"
  install -m 644 "$src/requirements.txt" "$INSTALL_DIR/requirements.txt"; install -m 644 "$src/constraints.txt" "$INSTALL_DIR/constraints.txt"
  "$INSTALL_DIR/.venv/bin/pip" install --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"
  chmod 755 "$INSTALL_DIR/scripts/"*.sh; systemctl daemon-reload
  systemctl start mehrvpn-web.service; systemctl restart mehrvpn-agent.service; systemctl restart openvpn-server@server.service
  systemctl is-active --quiet mehrvpn-web.service || die "Web service failed after update."
  log "Update completed."
}

do_status(){
  require_root
  for s in openvpn-server@server.service mehrvpn-agent.service mehrvpn-web.service nginx; do
    printf '%-34s' "$s"; systemctl is-active --quiet "$s" && echo active || echo inactive
  done
  curl -fsS http://127.0.0.1:8097/api/health 2>/dev/null || true
}
do_logs(){ require_root; journalctl -u mehrvpn-agent -u mehrvpn-web -u openvpn-server@server --no-pager -n "${MEHRVPN_LOG_LINES:-200}"; }
do_restart(){ require_root; systemctl restart mehrvpn-agent.service openvpn-server@server.service mehrvpn-web.service nginx.service; }
do_backup(){ require_root; [[ -x "$INSTALL_DIR/scripts/backup.sh" ]] || die "Backup script is missing."; bash "$INSTALL_DIR/scripts/backup.sh"; }
do_uninstall(){
  require_root; read -r -p "Type REMOVE to uninstall MehrVPN (VPN configuration/data are preserved): " confirm
  [[ "$confirm" == REMOVE ]] || { echo "Cancelled."; return; }
  systemctl disable --now mehrvpn-web.service mehrvpn-agent.service 2>/dev/null || true
  rm -f /etc/systemd/system/mehrvpn-web.service /etc/systemd/system/mehrvpn-agent.service /usr/local/bin/mehrvpn
  rm -f /etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf /etc/nginx/conf.d/mehrvpn.conf
  systemctl daemon-reload; systemctl reload nginx 2>/dev/null || true
  rm -rf "$INSTALL_DIR" "$ETC_DIR"
  log "MehrVPN panel removed. OpenVPN and /var/lib/mehrvpn data were preserved."
}

usage(){ cat <<'EOF'
MehrVPN — OpenVPN management panel

Usage:
  bash install.sh                 Install
  bash install.sh install         Install
  bash install.sh update          Update from GitHub/local source
  bash install.sh status          Show service health
  bash install.sh logs            Show recent logs
  bash install.sh restart         Restart services
  bash install.sh backup          Run backup
  bash install.sh uninstall       Remove panel, preserve VPN/data

Unattended install:
  MEHRVPN_HOST=vpn.example.com MEHRVPN_PORT=8443 MEHRVPN_ADMIN=admin bash install.sh
EOF
}

case "${1:-install}" in
  install) do_install ;; update) do_update ;; status) do_status ;; logs) do_logs ;;
  restart) do_restart ;; backup) do_backup ;; uninstall) do_uninstall ;;
  -h|--help|help) usage ;; *) usage; exit 2 ;;
esac
