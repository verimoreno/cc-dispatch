#!/usr/bin/env bash
# render_codex fixtures — the awk that drops codex's own [mcp_servers.wearefractional]
# table is the one thing here that can write a broken config.toml into the shared
# cc-codex volume and take down every codex session. Runs anywhere (no docker).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../deploy.sh"
set +e   # deploy.sh sets -e on source; grep -c 0 must not abort the run
rc=0

check(){ # name, expected-grep-count, pattern, input
  local name="$1" want="$2" pat="$3" got
  got=$(render_codex | grep -cF "$pat")
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else
    echo "FAIL $name: expected $want × '$pat', got $got"; rc=1; fi
}

# 1. a live file carrying codex's own bare table: exactly one table survives
live_codex(){ printf '%s\n' \
  '[projects."/home/pwuser/work"]' 'trust_level = "trusted"' '' \
  '[mcp_servers.wearefractional]' 'url = "https://mcp.wearefractional.ai/api/mcp"'; }
check "bare table deduped"  1 '[mcp_servers.wearefractional]'
check "trust_level kept"    1 'trust_level = "trusted"'
check "policy applied"      1 'default_tools_approval_mode = "approve"'

# 2. codex's table in the MIDDLE — only its own lines go, the next table stays
live_codex(){ printf '%s\n' \
  '[mcp_servers.wearefractional]' 'url = "x"' '' \
  '[tui.model_availability_nux]' '"gpt-5.6-sol" = 4'; }
check "middle table deduped" 1 '[mcp_servers.wearefractional]'
check "following table kept" 1 '[tui.model_availability_nux]'
check "stale url dropped"    0 'url = "x"'

# 3. idempotent: rendering our own output again changes nothing
live_codex(){ printf '%s\n' '[projects."/tmp"]' 'trust_level = "trusted"'; }
first=$(render_codex)
live_codex(){ printf '%s\n' "$first"; }
if [[ "$(render_codex)" == "$first" ]]; then echo "ok   idempotent"
else echo "FAIL idempotent: second render differs"; rc=1; fi

# 4. the rendered TOML actually parses, and says what we meant
render_codex | python3 -c '
import sys,tomllib
d=tomllib.loads(sys.stdin.read())
s=d["mcp_servers"]["wearefractional"]
assert s["default_tools_approval_mode"]=="approve", s
assert "delete_task" in s["disabled_tools"], s
assert s["url"].startswith("https://"), s
print("ok   parses as TOML")' || { echo "FAIL toml"; rc=1; }

# 5. the known ceiling: strip_table only understands a [table] header. If codex
# ever writes the inline form, the render duplicates the key — deploy.sh
# validate() parses before writing, and this proves it has something to catch.
live_codex(){ printf '%s\n' 'mcp_servers.wearefractional = { url = "x" }'; }
if render_codex | python3 -c 'import sys,tomllib; tomllib.loads(sys.stdin.read())' 2>/dev/null
then echo "FAIL inline-table ceiling: expected unparseable output, got valid TOML"; rc=1
else echo "ok   inline-table ceiling caught by the TOML parse"; fi

# 6. regression: piping a render straight into a writer on the SAME file truncates
# it before the render has read it — that wiped the codex trust levels once.
if grep -qE 'render_(claude|codex) *\| *docker run' "$HERE/../deploy.sh"; then
  echo "FAIL render piped straight into its own file's writer — render to a var first"; rc=1
else echo "ok   no render piped into its own writer"; fi

exit $rc
