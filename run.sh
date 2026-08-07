#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
# Under systemd the service runs with a minimal PATH that omits ~/.local/bin and
# ~/bin, where agent-deck / cc-spawn typically live. Prepend the host-local tool
# dirs so local-mode spawns don't silently fail to find them.
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
# main.py refuses to start without CC_DISPATCH_SECRET; the deployed service reads
# it from .env (see deploy/). .env is optional for one-off local runs.
if [ -f "$DIR/.env" ]; then
  set -a
  . "$DIR/.env"
  set +a
fi
# Single-dash default: fill in only when UNSET, so an explicit empty value in
# .env (CC_DISPATCH_HOST=) is respected and selects LOCAL mode. `:-` would
# clobber that empty value and force remote/SSH mode on the host itself.
export CC_DISPATCH_HOST="${CC_DISPATCH_HOST-cc-host}"
# Bind address + port for the web UI. Default to localhost so nothing is exposed
# unless a deploy sets CC_DISPATCH_BIND. The value `auto` resolves to this host's
# Tailscale IP at *runtime* (not frozen at install time), so a changed Tailscale
# IP — or an install that ran before tailscale was up — can't strand the service.
BIND="${CC_DISPATCH_BIND:-127.0.0.1}"
PORT="${CC_DISPATCH_PORT:-7822}"
if [ "$BIND" = "auto" ]; then
  BIND="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [ -z "$BIND" ]; then
    echo "CC_DISPATCH_BIND=auto but no Tailscale IP is assigned yet — exiting so systemd retries" >&2
    exit 1
  fi
fi
# kill whatever already holds the port, then take it over
fuser -k "${PORT}/tcp" 2>/dev/null && sleep 1 || true
exec "$DIR/.venv/bin/uvicorn" main:app --host "$BIND" --port "$PORT" --app-dir "$DIR"
