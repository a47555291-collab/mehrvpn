# MehrVPN

A self-hosted OpenVPN management panel for Debian/Ubuntu servers.

**Browser → Nginx/TLS → FastAPI → Unix-socket agent → OpenVPN/PKI**

Features include client provisioning, quota/expiry policy, accounting, revocation, encrypted backups, RBAC and a responsive web UI.

## One-command install

On a fresh supported VPS, run:

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/a47555291-collab/mehrvpn/main/install.sh)
```

The installer asks for the panel hostname/IP and owner username, then securely prompts for the owner password.

Unattended mode:

```bash
MEHRVPN_HOST=vpn.example.com MEHRVPN_PORT=8443 MEHRVPN_ADMIN=admin \
bash <(curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/a47555291-collab/mehrvpn/main/install.sh)
```

## Supported systems

- Ubuntu 22.04 / 24.04
- Debian 12 / 13
- Linux TUN device required

## Management

After installation:

```text
mehrvpn status
mehrvpn logs
mehrvpn restart
mehrvpn backup
mehrvpn update
mehrvpn uninstall
```

Updates preserve the panel database and OpenVPN PKI and create a timestamped server configuration backup.

## Security model

- Web panel runs as the unprivileged `mehrvpn` user.
- Privileged OpenVPN operations are isolated behind Unix sockets.
- Passwords use Argon2.
- Secure HTTP-only sessions use CSRF/origin checks and login rate limiting.
- Quota/expiry checks fail closed when the monitoring agent cannot enforce policy.
- Client names are strictly validated.
- systemd units use filesystem and capability restrictions.
- Nginx terminates TLS and the application emits security headers/CSP.
- The OpenVPN installer is obtained from the upstream Nyr project at install time.

## TLS

The initial panel certificate is self-signed so the installer can work without a domain or external certificate service. For an internet-facing production deployment, replace it with a certificate trusted by your clients and reload Nginx.

## Backups

`mehrvpn backup` creates an encrypted disaster-recovery archive using the panel's authenticated AES-GCM backup utility. Keep the backup password separately and test restoration on another VPS before relying on it.

## Development

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

## Production validation

A passing CI job does not prove a real VPS deployment. Before production use, validate a clean install, browser login, real OpenVPN client connection, routing/DNS, quota and expiry enforcement, reboot recovery, agent failure recovery, firewall rules and backup restoration.

## License

MIT — see `LICENSE`.
