#!/usr/bin/env bash
# Render real Compose and exercise the wrapper in a disposable dummy-only container.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  echo 'SKIP: account compose checks require Docker Compose'; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SESSION_NAME=account-check REPO_DIR="$TMP/repo" WORKTREE_PATH="$TMP/repo/work"
export CC_ACCOUNT=diogo CC_ACCOUNT_DIR="$TMP/diogo" CC_ACCOUNT_WRAPPER="$HERE/sessions/claude-account"
# Never read host .env during tests.
printf '' > "$TMP/env"
docker compose --env-file "$TMP/env" -f "$HERE/sessions/docker-compose.yml" config --format json > "$TMP/default.json"
docker compose --env-file "$TMP/env" -f "$HERE/sessions/docker-compose.yml" -f "$HERE/sessions/account.yml" config --format json > "$TMP/account.json"
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
d=json.loads((p/'default.json').read_text())['services']['cc-session']
s=json.loads((p/'account.json').read_text())['services']['cc-session']
assert any(v['source']=='cc-auth' for v in d['volumes'])
assert any(v['source']=='/opt/cc-data/claude.json' for v in d['volumes'])
assert 'CC_ACCOUNT' not in d['environment']
assert s['labels']['com.fractional.cc-account']=='diogo'
assert not any(v['source'] in ('cc-auth','cc-codex','cc-gemini','cc-config','cc-opencode','/opt/cc-data/claude.json') for v in s['volumes'])
assert [v for v in s['volumes'] if v['target']=='/run/cc-account'][0]['read_only']
assert all(v['source'] != str(p) for v in s['volumes'])
assert 'CLAUDE_CODE_OAUTH_TOKEN' not in s['environment']
assert s['environment']['PATH'].startswith('/usr/local/bin:')
print('PASS: default and explicit compose, selected-only mounts, alias metadata, no Docker token env')
PY
if ! docker image inspect cc-session:latest >/dev/null 2>&1; then
  echo 'SKIP: wrapper container check needs existing cc-session:latest image'; exit 0
fi
mkdir -p "$TMP/diogo/credentials"
printf 'dummy-container-token\n' > "$TMP/diogo/credentials/token"
chmod 755 "$TMP" "$TMP/diogo" "$TMP/diogo/credentials"
chmod 644 "$TMP/diogo/credentials/token" # dummy fixture readable by image uid
cat > "$TMP/fake-claude" <<'PY'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert os.environ['CLAUDE_CODE_OAUTH_TOKEN']=='dummy-container-token'
assert not any(k.startswith('ANTHROPIC_') for k in os.environ)
assert 'CLAUDE_CODE_USE_VERTEX' not in os.environ
assert sys.argv[-2:]==['--setting-sources','user']
assert Path('/run/cc-account/token').read_text().strip()=='dummy-container-token'
assert not Path('/run/cc-account/../other/token').exists()
print('PASS: container startup reads selected token and clears inherited auth')
PY
chmod 755 "$TMP/fake-claude"
docker run --rm --network none --entrypoint /usr/local/bin/claude \
  -e ANTHROPIC_API_KEY=dummy-api-override -e CLAUDE_CODE_USE_VERTEX=1 \
  -v "$CC_ACCOUNT_WRAPPER:/usr/local/bin/claude:ro" \
  -v "$TMP/fake-claude:/home/pwuser/.npm-global/bin/claude:ro" \
  -v "$TMP/diogo/credentials:/run/cc-account:ro" cc-session:latest > "$TMP/output"
if grep -qE 'dummy-container-token|dummy-api-override' "$TMP/output"; then
  echo 'FAIL: credential leaked'; exit 1
fi
cat "$TMP/output"
# Real installed CLI accepts the wrapper's flags; no network/auth request.
docker run --rm --network none --entrypoint /usr/local/bin/claude \
  -v "$CC_ACCOUNT_WRAPPER:/usr/local/bin/claude:ro" \
  -v "$TMP/diogo/credentials:/run/cc-account:ro" cc-session:latest --version > "$TMP/version"
if grep -q 'dummy-container-token' "$TMP/version"; then echo 'FAIL: credential leaked'; exit 1; fi
printf 'PASS: real Claude CLI accepts startup wrapper flags\n'
# scripts-only deploy must return before any fleet-config renderer/writer.
(
  source "$HERE/deploy.sh"
  SCRIPTS_ONLY=1
  RELEASES="$TMP/releases"; CURRENT="$RELEASES/current"
  SESSIONS="$TMP/sessions"; BIN_DIR="$TMP/bin"; SPAWN_LOCK="$TMP/spawn.lock"
  mkdir -p "$RELEASES/next/bin" "$RELEASES/next/sessions/tokens.d" "$SESSIONS" "$BIN_DIR"
  SESSION_FILES=()
  render_claude(){ echo 'FAIL: scripts-only reached shared config' >&2; exit 1; }
  switch_to "$RELEASES/next"
  test "$(readlink "$CURRENT")" = "$RELEASES/next"
)
echo 'PASS: scripts-only deployment skips shared configuration'
