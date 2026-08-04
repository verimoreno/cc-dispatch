#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
# main.py refuses to start without CC_DISPATCH_SECRET; the deployed service gets it
# from systemd, so .env is only present for local runs.
if [ -f "$DIR/.env" ]; then
  set -a
  . "$DIR/.env"
  set +a
fi
export CC_DISPATCH_HOST="${CC_DISPATCH_HOST:-cc-host}"
# kill whatever already holds the port, then take it over
fuser -k 7822/tcp 2>/dev/null && sleep 1 || true
exec "$DIR/.venv/bin/uvicorn" main:app --host 127.0.0.1 --port 7822 --app-dir "$DIR"
