#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="https://github.com/a47555291-collab/mehrvpn"
REF="${MEHRVPN_REF:-main}"
ROOT="/opt/mehrvpn"
ETC="/etc/mehrvpn"
DATA="/var/lib/mehrvpn"
AGENT_DATA="/var/lib/mehrvpn-agent"
BACKUP="/var/backups/mehrvpn"
ENV_FILE="$ETC/panel.env"
VPN_CONF="/etc/openvpn/server/server.conf"
TMP=""
SOURCE_DIR=""

log(){ printf '\n[MehrVPN] %s\n' "$*"; }
die(){ printf '\n[MehrVPN][ERROR] %s\n' "$*" >&2; exit 1; }
trap '[[ -z "${TMP:-}" ]] || rm -rf "$TMP"' EXIT
trap 'die "Installer stopped at line $LINENO. Check: journalctl -u mehrvpn-agent -u mehrvpn-web --no-pager -n 100"' ERR

root_check(){ [[ $EUID -eq 0 ]] || die "Run as root."; }
os_check(){
  source /etc/os-release
  case "$ID:$VERSION_ID" in ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;; *) die "Supported: Ubuntu 22.04/24.04 and Debian 12/13.";; esac
  [[ -e /dev/net/tun ]] || die "/dev/net/tun is unavailable.";
}

need_pkgs(){
  local p; local -a missing=()
  for p in python3 python3-venv python3-pip nginx openssl curl ca-certificates tar iproute2 openvpn; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if ((${#missing[@]}==0)); then log "All required OS packages are already installed; skipping apt update."; return; fi
  log "Installing: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update
  apt-get install -y "${missing[@]}"
}

source_tree(){
  local here dir
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
  if [[ -f "$here/panel/app.py" && -f "$here/requirements.txt" ]]; then
    SOURCE_DIR="$here"
    return 0
  fi
  TMP="$(mktemp -d /tmp/mehrvpn.XXXXXX)"
  log "Downloading MehrVPN source..."
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$REPO/archive/refs/heads/$REF.tar.gz" -o "$TMP/mehrvpn.tar.gz"
  tar -xzf "$TMP/mehrvpn.tar.gz" -C "$TMP"
  dir="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'mehrvpn-*' -print -quit)"
  [[ -n "$dir" ]] || die "Invalid MehrVPN archive."
  SOURCE_DIR="$dir"
}

install_source(){
  local s="$SOURCE_DIR"
  [[ -d "$s/panel" && -d "$s/scripts" ]] || die "MehrVPN source archive is incomplete: $s"
  install -d -m 755 "$ROOT"
  cp -a "$s/panel" "$s/scripts" "$ROOT/"
  install -m 755 "$s/install.sh" "$ROOT/install.sh"
  install -m 644 "$s/requirements.txt" "$s/constraints.txt" "$ROOT/"
  chmod 755 "$ROOT/install.sh" "$ROOT/scripts/"*.sh "$ROOT/scripts/mehrvpn" 2>/dev/null || true
}

ensure_dirs(){
  getent passwd mehrvpn >/dev/null || useradd --system --home "$DATA" --shell /usr/sbin/nologin mehrvpn
  install -d -o mehrvpn -g mehrvpn -m 700 "$DATA"
  install -d -m 700 "$AGENT_DATA" "$ETC" "$ETC/tls" "$BACKUP"
}

openvpn_setup(){
  if [[ ! -f "$VPN_CONF" ]]; then
    log "OpenVPN server is not configured. Starting the official Nyr installer."
    install -d -m 700 /root/mehrvpn-bootstrap
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      "https://raw.githubusercontent.com/Nyr/openvpn-install/master/openvpn-install.sh" \
      -o /root/mehrvpn-bootstrap/openvpn-install.sh
    chmod 700 /root/mehrvpn-bootstrap/openvpn-install.sh
    bash /root/mehrvpn-bootstrap/openvpn-install.sh
  fi
  [[ -f "$VPN_CONF" ]] || die "OpenVPN server configuration was not created."
  [[ -x /etc/openvpn/server/easy-rsa/easyrsa ]] || die "Easy-RSA was not installed."
  [[ -f /etc/openvpn/server/client-common.txt ]] || die "OpenVPN client template is missing."
  systemctl is-active --quiet openvpn-server@server.service || die "OpenVPN service is not active."
}

configure_panel(){
  local host="$1" port="$2" origin san
  origin="https://${host}:${port}"; [[ "$port" == 443 ]] && origin="https://${host}"
  printf 'MEHRVPN_DB=%s\nMEHRVPN_PUBLIC_URL=%s\n' "$DATA/panel.db" "$origin" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
    -keyout "$ETC/tls/panel.key" -out "$ETC/tls/panel.crt" \
    -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1
  chmod 600 "$ETC/tls/panel.key"
  cat > /etc/nginx/conf.d/mehrvpn.conf <<NGINX
server {
    listen ${port} ssl;
    server_name ${host};
    ssl_certificate ${ETC}/tls/panel.crt;
    ssl_certificate_key ${ETC}/tls/panel.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16k;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
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

configure_openvpn_integration(){
  grep -q 'BEGIN MEHRVPN' "$VPN_CONF" || cat >> "$VPN_CONF" <<'CONF'

# BEGIN MEHRVPN
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
  install -m 644 "$ROOT/scripts/mehrvpn-agent.service" /etc/systemd/system/mehrvpn-agent.service
  install -m 644 "$ROOT/scripts/mehrvpn-web.service" /etc/systemd/system/mehrvpn-web.service
}

create_owner(){
  local admin="$1"
  MEHRVPN_DB="$DATA/panel.db" "$ROOT/.venv/bin/python" -m panel.cli owner --username "$admin"
}

wait_agent(){ for _ in {1..30}; do [[ -S /run/mehrvpn/control.sock ]] && return 0; sleep 1; done; die "MehrVPN agent socket did not appear."; }

install_all(){
  root_check; os_check
  [[ ! -f "$ENV_FILE" ]] || die "MehrVPN is already installed. Use: mehrvpn update"
  local host port admin
  source_tree
  need_pkgs
  ensure_dirs
  install_source
  python3 -m venv "$ROOT/.venv"
  "$ROOT/.venv/bin/pip" install --disable-pip-version-check -r "$ROOT/requirements.txt"
  host="${MEHRVPN_HOST:-}"; port="${MEHRVPN_PORT:-8443}"; admin="${MEHRVPN_ADMIN:-admin}"
  [[ -n "$host" ]] || read -r -p "Panel hostname or public IP: " host
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || die "Invalid hostname/IP."
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port>=1&&10#$port<=65535)) || die "Invalid panel port."
  [[ "$admin" =~ ^[A-Za-z][A-Za-z0-9_-]{0,47}$ ]] || die "Invalid admin username."
  openvpn_setup
  cp -p "$VPN_CONF" "$BACKUP/server.conf.$(date +%Y%m%d-%H%M%S)"
  configure_openvpn_integration
  configure_panel "$host" "$port"
  create_owner "$admin"
  chown -R mehrvpn:mehrvpn "$DATA"
  install -m 755 "$ROOT/scripts/mehrvpn" /usr/local/bin/mehrvpn 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --now mehrvpn-agent.service
  wait_agent
  systemctl restart openvpn-server@server.service
  systemctl enable --now mehrvpn-web.service nginx
  systemctl reload nginx
  for _ in {1..30}; do curl -fsS http://127.0.0.1:8097/api/health >/dev/null && break; sleep 1; done
  curl -fsS http://127.0.0.1:8097/api/health >/dev/null || die "Panel health check failed."
  log "MehrVPN installed successfully."
  echo "Panel: https://${host}:${port}"
  echo "Username: ${admin}"
  echo "Certificate: self-signed (replace with a trusted certificate for production)."
}

update_all(){
  root_check; [[ -f "$ENV_FILE" ]] || die "MehrVPN is not installed."
  source_tree
  systemctl stop mehrvpn-web.service 2>/dev/null || true
  cp -a "$SOURCE_DIR/panel/." "$ROOT/panel/"
  cp -a "$SOURCE_DIR/scripts/." "$ROOT/scripts/"
  install -m 755 "$SOURCE_DIR/install.sh" "$ROOT/install.sh"
  install -m 644 "$SOURCE_DIR/requirements.txt" "$SOURCE_DIR/constraints.txt" "$ROOT/"
  "$ROOT/.venv/bin/pip" install --disable-pip-version-check -r "$ROOT/requirements.txt"
  chmod 755 "$ROOT/install.sh" "$ROOT/scripts/"*.sh "$ROOT/scripts/mehrvpn" 2>/dev/null || true
  systemctl daemon-reload
  systemctl restart mehrvpn-agent.service mehrvpn-web.service openvpn-server@server.service
  log "Update completed."
}

status_all(){ root_check; for s in openvpn-server@server.service mehrvpn-agent.service mehrvpn-web.service nginx; do printf '%-36s' "$s"; systemctl is-active --quiet "$s" && echo active || echo inactive; done; curl -fsS http://127.0.0.1:8097/api/health 2>/dev/null || true; }
logs_all(){ root_check; journalctl -u mehrvpn-agent -u mehrvpn-web -u openvpn-server@server --no-pager -n 200; }
restart_all(){ root_check; systemctl restart mehrvpn-agent.service openvpn-server@server.service mehrvpn-web.service nginx.service; }
backup_all(){ root_check; bash "$ROOT/scripts/backup.sh"; }
uninstall_all(){ root_check; read -r -p 'Type REMOVE to remove the panel (VPN/data preserved): ' x; [[ "$x" == REMOVE ]] || return; systemctl disable --now mehrvpn-web.service mehrvpn-agent.service 2>/dev/null || true; rm -f /etc/systemd/system/mehrvpn-web.service /etc/systemd/system/mehrvpn-agent.service /etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf /etc/nginx/conf.d/mehrvpn.conf /usr/local/bin/mehrvpn; systemctl daemon-reload; systemctl reload nginx 2>/dev/null || true; rm -rf "$ROOT" "$ETC"; log 'Panel removed; OpenVPN and /var/lib/mehrvpn data preserved.'; }

case "${1:-install}" in
  install) install_all;; update) update_all;; status) status_all;; logs) logs_all;; restart) restart_all;; backup) backup_all;; uninstall) uninstall_all;;
  -h|--help|help) echo 'Usage: install.sh [install|update|status|logs|restart|backup|uninstall]';;
  *) echo 'Usage: install.sh [install|update|status|logs|restart|backup|uninstall]'; exit 2;;
esac
