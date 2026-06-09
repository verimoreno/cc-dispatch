#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
export CC_DISPATCH_HOST="${CC_DISPATCH_HOST:-cc-host}"
exec "$DIR/.venv/bin/uvicorn" main:app --host 127.0.0.1 --port 7822 --app-dir "$DIR"
