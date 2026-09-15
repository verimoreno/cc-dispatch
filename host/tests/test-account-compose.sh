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
assert sys.argv[1:3]==['--setting-sources','user']
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
# Exercise the real auth subcommand: --version exits before parsing our flags.
mkdir -p "$TMP/diogo/config"
printf '{}' > "$TMP/diogo/config/settings.json"
docker run --rm --network none --entrypoint /usr/local/bin/claude \
  -v "$CC_ACCOUNT_WRAPPER:/usr/local/bin/claude:ro" \
  -v "$TMP/diogo/credentials:/run/cc-account:ro" \
  -v "$TMP/diogo/config:/home/pwuser/.claude" cc-session:latest auth status > "$TMP/status" 2>&1
python3 - "$TMP/status" <<'PYTEST'
import json, sys
text = open(sys.argv[1]).read()
assert 'dummy-container-token' not in text
status = json.loads(text)
assert status['authMethod'] == 'oauth_token' and not status.get('apiKeySource')
print('PASS: real Claude auth status uses the selected OAuth source')
PYTEST
# Saved settings must fail before the real CLI can use an API key/helper.
for settings in '{"env":{"ANTHROPIC_API_KEY":"dummy-api-override"}}' '{"apiKeyHelper":"dummy-api-override"}' '{invalid'; do
  printf '%s' "$settings" > "$TMP/diogo/config/settings.json"
  if docker run --rm --network none --entrypoint /usr/local/bin/claude \
    -v "$CC_ACCOUNT_WRAPPER:/usr/local/bin/claude:ro" \
    -v "$TMP/diogo/credentials:/run/cc-account:ro" \
    -v "$TMP/diogo/config:/home/pwuser/.claude" cc-session:latest auth status > "$TMP/rejected" 2>&1; then
    echo 'FAIL: unsafe settings accepted'; exit 1
  fi
  grep -q 'ERROR: selected account settings' "$TMP/rejected"
  if grep -qE 'dummy-container-token|dummy-api-override' "$TMP/rejected"; then
    echo 'FAIL: credential leaked'; exit 1
  fi
done
echo 'PASS: saved credentials/helpers and malformed settings fail closed without leaking values'
