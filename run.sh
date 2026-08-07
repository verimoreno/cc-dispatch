#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
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
# unless a deploy sets CC_DISPATCH_BIND (e.g. the host's Tailscale IP).
BIND="${CC_DISPATCH_BIND:-127.0.0.1}"
PORT="${CC_DISPATCH_PORT:-7822}"
# kill whatever already holds the port, then take it over
fuser -k "${PORT}/tcp" 2>/dev/null && sleep 1 || true
exec "$DIR/.venv/bin/uvicorn" main:app --host "$BIND" --port "$PORT" --app-dir "$DIR"
