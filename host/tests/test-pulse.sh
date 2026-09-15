#!/usr/bin/env bash
# Fixtures for host/sessions/cc-pulse — the hook every lane runs on every tool
# call. Runs the REAL script as a subprocess against a temp PULSE dir, because
# the things that can hurt (blocking, speaking, losing a record to a concurrent
# rotation) only show up across processes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HOOK="$TMP/cc-pulse"
sed "s|^PULSE = .*|PULSE = \"$TMP/pulse\"|" "$HERE/../sessions/cc-pulse" > "$HOOK"; chmod +x "$HOOK"
FILE="$TMP/pulse/$(hostname).jsonl"
rc=0
ok(){ echo "  ok: $1"; }
no(){ echo "  FAIL: $1"; rc=1; }

ev(){ printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

echo "== silence and exit code"
out=$(ev one | "$HOOK" 2>&1); [[ $? -eq 0 && -z "$out" ]] && ok "normal input: exit 0, no output" || no "normal input spoke or failed"
out=$(echo 'not json' | "$HOOK" 2>&1); [[ $? -eq 0 && -z "$out" ]] && ok "malformed input silent" || no "malformed input spoke"
out=$(printf '' | "$HOOK" 2>&1); [[ $? -eq 0 && -z "$out" ]] && ok "empty input silent" || no "empty input spoke"

echo "== a non-regular file is left alone (open() on a FIFO would hang the lane)"
mv "$FILE" "$TMP/saved"; mkfifo "$FILE"
timeout 5 bash -c "$(printf 'echo %q | %q' "$(ev fifo)" "$HOOK")" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "FIFO: returned without blocking" || no "FIFO: blocked or failed"
rm -f "$FILE"; mv "$TMP/saved" "$FILE"

echo "== a record is never appended while another process is rotating"
python3 - "$FILE" <<'EOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    for _ in range(12000): f.write(json.dumps({"ts": int(time.time()), "ev": "PostToolUse", "t": "x"*80}) + "\n")
EOF
# hold the lock the way rotate() does, then try to append from a second process
python3 - "$FILE" "$HOOK" <<'EOF'
import fcntl, json, subprocess, sys
path, hook = sys.argv[1], sys.argv[2]
with open(path, "a+b") as held:
    fcntl.flock(held, fcntl.LOCK_EX)            # stand in for a rotation in flight
    r = subprocess.run([hook], input=b'{"hook_event_name":"Stop"}', capture_output=True)
    before = open(path, "rb").read()
    # the rotation the holder was about to do
    held.seek(-65536, 2); tail = held.read(65536).split(b"\n", 1)[-1]
    held.seek(0); held.truncate(); held.write(tail)
assert r.returncode == 0 and not r.stdout and not r.stderr, "hook spoke or failed under contention"
assert b'"Stop"' not in before, "hook appended while the file was locked — a rotation would erase it"
EOF
[[ $? -eq 0 ]] && ok "contended append dropped, not written into a rotating file" || no "contended append written"

echo "== rotation keeps the file bounded and every line parseable"
python3 - "$FILE" <<'EOF'
import json, sys, time
with open(sys.argv[1], "w") as f:
    for _ in range(12000): f.write(json.dumps({"ts": int(time.time()), "ev": "PostToolUse", "t": "x"*80}) + "\n")
EOF
ev after-rotate | "$HOOK"
python3 - "$FILE" <<'EOF'
import json, os, sys
p = sys.argv[1]; lines = open(p).read().splitlines()
assert os.path.getsize(p) < (1 << 20), "still over the rotation threshold"
for l in lines: json.loads(l)
assert json.loads(lines[-1])["t"] == "after-rotate", "the new record did not survive the trim"
EOF
[[ $? -eq 0 ]] && ok "rotated, all lines parse, newest record kept" || no "rotation lost or corrupted records"

exit $rc
