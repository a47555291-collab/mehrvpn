# MehrVPN

A self-hosted OpenVPN management panel for Debian/Ubuntu servers.

MehrVPN is designed around a small privilege boundary:

**Browser → Nginx/TLS → FastAPI panel → Unix-socket privileged agent → OpenVPN/PKI**

It provides client provisioning, expiry/quota policy, accounting, revocation, backups, RBAC and an operator-friendly web UI.

## Quick install

On a fresh supported server:

```bash
bash <(curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/a47555291-collab/mehrvpn/main/install.sh)
```

The installer is interactive by default. It asks for the panel hostname/IP and creates the owner password securely without storing the plaintext password.

For unattended installation:

```bash
MEHRVPN_HOST=vpn.example.com MEHRVPN_PORT=8443 MEHRVPN_ADMIN=admin \
  bash <(curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/a47555291-collab/mehrvpn/main/install.sh)
```

> **Important:** the default certificate is self-signed. For a public production deployment, replace it with a certificate trusted by your clients before treating the panel as a finished internet-facing service.

## Supported operating systems

- Ubuntu 22.04
- Ubuntu 24.04
- Debian 12
- Debian 13

A Linux server with `/dev/net/tun` is required.

## Management

After installation, `/usr/local/bin/mehrvpn` can be installed as a convenience wrapper, or the repository installer can be invoked directly:

```text
mehrvpn status
mehrvpn logs
mehrvpn restart
mehrvpn backup
mehrvpn update
mehrvpn uninstall
```

Updates preserve the application database and OpenVPN PKI. The installer creates a timestamped OpenVPN configuration backup before an update.

## Architecture and security

- FastAPI application runs as the unprivileged `mehrvpn` user.
- OpenVPN policy operations are isolated behind a local Unix socket.
- Passwords use Argon2 hashing.
- Session cookies are secure/HTTP-only with CSRF and origin checks.
- Client names are strictly validated.
- Quota and expiry enforcement is fail-closed.
- Accounting is designed to be replay-safe.
- OpenVPN configuration changes are constrained to the supported upstream layout.
- The bundled upstream OpenVPN installer is verified against the SHA-256 value in `vendor/source.json` before use.
- systemd units apply filesystem and capability restrictions.
- Security headers and a restrictive CSP are emitted by the application.

## Backups

The panel includes encrypted backup primitives and an operator backup script. Always test restoration on a separate server before relying on backups for disaster recovery.

## Development

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

The browser/UI tests require Node.js:

```bash
npm ci
node tests/test_ui.cjs
```

## Production validation

Passing tests is not the same as proving a clean VPS deployment. Before a production rollout, validate at minimum:

1. Fresh install on a clean supported VPS.
2. Browser login over HTTPS.
3. Client creation and download.
4. Real OpenVPN connection from a separate client.
5. Routing and DNS behavior.
6. Quota enforcement with real traffic.
7. Expiry/suspension behavior.
8. Reboot recovery of all services.
9. Agent/OpenVPN failure recovery.
10. Backup and restore.
11. Firewall/cloud-security-group rules.
12. Mobile and desktop browsers.

See `docs/VALIDATION.md` and `docs/ACCEPTANCE.md`.

## License

See `LICENSE`.
