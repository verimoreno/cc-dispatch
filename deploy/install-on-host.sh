#!/usr/bin/env bash
#
# Deploy cc-dispatch as an always-on systemd service on THIS machine.
# Run it ON cc-host (over SSH / Tailscale), NOT on your laptop or tablet.
#
# It is idempotent — safe to re-run after a `git pull`:
#   - creates/updates the venv and installs deps
#   - writes .env ONLY if missing (never clobbers your secret)
#   - (re)installs + enables the systemd unit and restarts the service
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
USER_NAME="$(id -un)"

echo "==> Python venv + dependencies"
[ -d .venv ] || python3 -m venv .venv
./.venv/bin/pip install -q --upgrade pip
./.venv/bin/pip install -q -r requirements.txt

echo "==> .env"
if [ -f .env ]; then
  echo "    .env already exists — leaving it untouched"
else
  SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  BIND="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  BIND="${BIND:-127.0.0.1}"
  cat > .env <<EOF
# Empty = LOCAL mode: manage this host's own tmux / agent-deck directly.
# (Set to an SSH alias only if cc-dispatch runs somewhere OTHER than the host.)
CC_DISPATCH_HOST=
# 64-char hex, generated once. Regenerate with:
#   python3 -c "import secrets; print(secrets.token_hex(32))"
CC_DISPATCH_SECRET=$SECRET
# Bind to the Tailscale IP so the dashboard is reachable ONLY over the tailnet.
CC_DISPATCH_BIND=$BIND
CC_DISPATCH_PORT=7822
EOF
  chmod 600 .env
  echo "    wrote .env  (bind=$BIND)"
fi

PORT="$(grep -E '^CC_DISPATCH_PORT=' .env | cut -d= -f2)"
BIND="$(grep -E '^CC_DISPATCH_BIND=' .env | cut -d= -f2)"

# Let the tailnet reach the dashboard port if ufw is the active firewall.
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> ufw: allow port $PORT on tailscale0"
  sudo ufw allow in on tailscale0 to any port "$PORT" proto tcp >/dev/null || true
fi

echo "==> systemd service"
sed "s|__DIR__|$DIR|g; s|__USER__|$USER_NAME|g" deploy/cc-dispatch.service \
  | sudo tee /etc/systemd/system/cc-dispatch.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable cc-dispatch >/dev/null 2>&1 || sudo systemctl enable cc-dispatch
sudo systemctl restart cc-dispatch

sleep 1
echo "==> status"
sudo systemctl --no-pager -l status cc-dispatch | head -n 12 || true

echo
echo "Done. Open the dashboard from any device on the tailnet:"
echo "    http://${BIND}:${PORT}/"
echo "    http://cc-host-hel:${PORT}/     (if MagicDNS is on)"
