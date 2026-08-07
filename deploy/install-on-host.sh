#!/usr/bin/env bash
#
# Deploy cc-dispatch as an always-on systemd service on THIS machine.
# Run it ON cc-host (over SSH / Tailscale), as your NORMAL user — not with sudo,
# and not on your laptop or tablet. The script calls sudo itself for the steps
# that need it.
#
# It is idempotent — safe to re-run after a `git pull`:
#   - creates/updates the venv and installs deps
#   - writes .env ONLY if missing (never clobbers your secret), and backfills any
#     keys an older .env is missing
#   - (re)installs + enables the systemd unit and restarts the service
#
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
  echo "Run this as your normal user (e.g. veri), not as root/sudo — it calls sudo itself." >&2
  exit 1
fi

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
USER_NAME="$(id -un)"

echo "==> Python venv + dependencies"
[ -d .venv ] || python3 -m venv .venv
./.venv/bin/pip install -q --upgrade pip
./.venv/bin/pip install -q -r requirements.txt

echo "==> .env"
if [ -f .env ]; then
  echo "    .env already exists — leaving existing values untouched"
else
  SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  # umask 077 so the 256-bit secret is never world-readable, even briefly.
  ( umask 077; cat > .env <<EOF
# Empty = LOCAL mode: manage this host's own tmux / agent-deck directly.
# (Set to an SSH alias only if cc-dispatch runs somewhere OTHER than the host.)
CC_DISPATCH_HOST=
# 64-char hex, generated once. Regenerate with:
#   python3 -c "import secrets; print(secrets.token_hex(32))"
CC_DISPATCH_SECRET=$SECRET
# 'auto' = bind to this host's Tailscale IP, resolved fresh at each start so a
# changed Tailscale IP can't strand the service. Dashboard is then tailnet-only.
# Use 127.0.0.1 to keep it local-only.
CC_DISPATCH_BIND=auto
CC_DISPATCH_PORT=7822
EOF
  )
  echo "    wrote .env (bind=auto)"
fi

# Upgrade path: backfill keys this deploy needs even on an older .env.
grep -qE '^CC_DISPATCH_BIND=' .env || echo 'CC_DISPATCH_BIND=auto' >> .env
grep -qE '^CC_DISPATCH_PORT=' .env || echo 'CC_DISPATCH_PORT=7822' >> .env

PORT="$(grep -E '^CC_DISPATCH_PORT=' .env | head -n1 | cut -d= -f2-)"
PORT="${PORT:-7822}"

# Let the tailnet reach the dashboard port if ufw is the active firewall.
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> ufw: allow port $PORT on tailscale0"
  sudo ufw allow in on tailscale0 to any port "$PORT" proto tcp >/dev/null || true
fi

echo "==> systemd service"
sed "s|__DIR__|$DIR|g; s|__USER__|$USER_NAME|g" deploy/cc-dispatch.service \
  | sudo tee /etc/systemd/system/cc-dispatch.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable cc-dispatch
sudo systemctl restart cc-dispatch

sleep 2
echo "==> status"
sudo systemctl --no-pager -l status cc-dispatch | head -n 12 || true

IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
echo
echo "Done. Open the dashboard from any device on the tailnet:"
[ -n "$IP" ] && echo "    http://${IP}:${PORT}/"
echo "    http://cc-host-hel:${PORT}/     (MagicDNS name of this host, if enabled)"
