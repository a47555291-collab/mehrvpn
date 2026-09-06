#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
dest="${1:-/var/backups/mehrvpn}"; install -d -m700 "$dest"; stage=$(mktemp -d /var/backups/mehrvpn/stage.XXXXXX); trap 'rm -rf "$stage"; systemctl start mehrvpn-agent.service openvpn-server@server.service mehrvpn-web.service 2>/dev/null || true' EXIT
systemctl stop mehrvpn-web.service openvpn-server@server.service mehrvpn-agent.service
tar -C / -czf "$stage/backup.tar.gz" etc/openvpn/server etc/mehrvpn var/lib/mehrvpn var/lib/mehrvpn-agent etc/nginx/conf.d/mehrvpn.conf etc/systemd/system/openvpn-server@server.service.d/mehrvpn.conf
/opt/mehrvpn/.venv/bin/python -m panel.backup_crypto encrypt "$stage/backup.tar.gz" "$dest/mehrvpn-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.enc"
echo "Encrypted backup saved in $dest"
