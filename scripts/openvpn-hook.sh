#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
exec /opt/mehrvpn/.venv/bin/python -m panel.hook
