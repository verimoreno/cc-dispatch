#!/usr/bin/env bash
# Fixtures for host/sessions/cc-pulse — the hook every lane runs on every tool
# call. Runs the REAL script as a subprocess against a temp PULSE dir, because
# the things that can hurt (speaking, hanging, losing a record to a concurrent
# rotation) only show up across processes.
#
# Every subprocess here is wrapped in `timeout`: an earlier version of this file
# HUNG when given a hook with a blocking flock, which is a test that cannot fail.
# Output is captured to files and checked for zero SIZE, not compared to "" —
# command substitution strips trailing newlines, so a hook printing one blank
# line passed the old check.
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

# run the hook on stdin; assert exit 0 and not one byte on stdout or stderr
silent(){
  local label="$1" input="$2"
  printf '%s' "$input" | timeout 10 "$HOOK" >"$TMP/out" 2>"$TMP/err"
  local code=$?
  [[ $code -eq 0 ]] || { no "$label: exit $code"; return 1; }
  [[ ! -s "$TMP/out" && ! -s "$TMP/err" ]] || { no "$label: wrote $(wc -c <"$TMP/out")B stdout, $(wc -c <"$TMP/err")B stderr"; return 1; }
  ok "$label"
}

fill(){   # $1 = how many records, each ~100B, tagged so rotation loss is visible
  python3 - "$FILE" "$1" <<'EOF'
import json, sys, time
n = int(sys.argv[2])
with open(sys.argv[1], "w") as f:
    for i in range(n):
        f.write(json.dumps({"ts": int(time.time()), "ev": "PostToolUse", "tool": "Bash", "t": f"seq-{i}-" + "x"*80}) + "\n")
EOF
}

echo "== silence and exit code"
silent "normal input" "$(ev one)"
silent "malformed input" 'not json'
silent "empty input" ''

echo "== a non-regular file is left alone (open() on a FIFO would hang the lane)"
mv "$FILE" "$TMP/saved"; mkfifo "$FILE"
silent "FIFO: returns without blocking" "$(ev fifo)"
rm -f "$FILE"; mv "$TMP/saved" "$FILE"

echo "== a record is never appended while another process is rotating"
fill 12000
timeout 20 python3 - "$FILE" "$HOOK" <<'EOF'
import fcntl, subprocess, sys, time
path, hook = sys.argv[1], sys.argv[2]
with open(path, "a+b") as held:
    fcntl.flock(held, fcntl.LOCK_EX)            # stand in for a rotation in flight
    t0 = time.monotonic()
    r = subprocess.run([hook], input=b'{"hook_event_name":"Stop"}', capture_output=True, timeout=10)
    elapsed = time.monotonic() - t0
    during = open(path, "rb").read()
assert r.returncode == 0 and not r.stdout and not r.stderr, "hook spoke or failed under contention"
assert b'"Stop"' not in during, "hook appended while the file was locked — a rotation would erase it"
# ...and it must GIVE UP quickly, not sit on a blocking lock until its own alarm:
# a 5s worker per matching tool call piles up in a long lane
assert elapsed < 2, f"hook waited {elapsed:.1f}s for a held lock — it should give up in ms"
EOF
case $? in
  0) ok "contended append dropped, not written into a rotating file" ;;
  124) no "contention test TIMED OUT — the hook blocks on the lock instead of giving up" ;;
  *) no "contention check failed — see the assertion above" ;;
esac

echo "== once the lock is free, a writer really does append (drop is not the only path)"
fill 3                     # small: below the rotation threshold, so the count is just +1
before=$(wc -l < "$FILE")
silent "uncontended append" "$(ev lock-free)"
[[ $(wc -l < "$FILE") -eq $((before + 1)) ]] && ok "record landed" || no "record did not land once the lock was free"

echo "== rotation keeps the file bounded AND keeps the recent history"
fill 12000
ev after-rotate | timeout 10 "$HOOK"
timeout 20 python3 - "$FILE" <<'EOF'
import json, os, sys
p = sys.argv[1]; lines = open(p).read().splitlines()
assert os.path.getsize(p) < (1 << 20), "still over the rotation threshold"
recs = [json.loads(l) for l in lines]                      # every line must parse
assert recs[-1]["t"] == "after-rotate", "the newest record did not survive the trim"
kept = [r["t"] for r in recs if r["t"].startswith("seq-")]
assert len(kept) > 100, f"rotation discarded the history it is supposed to keep ({len(kept)} left)"
seq = [int(t.split("-")[1]) for t in kept]
assert seq == sorted(seq) and len(seq) == len(set(seq)), "retained records are out of order or duplicated"
assert seq[-1] == 11999, "the trim kept the oldest records instead of the newest"
EOF
[[ $? -eq 0 ]] && ok "rotated, bounded, history intact and in order" || no "rotation lost, reordered or corrupted records"

exit $rc
