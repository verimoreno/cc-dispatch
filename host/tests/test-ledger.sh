#!/usr/bin/env bash
# Integration tests for cc-ledger admission + reservation semantics.
# Runs against an ISOLATED temp ledger (CC_LEDGER_DIR/CC_SPAWN_LOCK overrides) —
# never touches /opt/cc-data. Needs docker (for the resident-fleet probe) — i.e.
# run it on cc-host: /opt/cc-releases/repo/host/tests/test-ledger.sh
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CC_LEDGER_DIR="$TMP/ledger" CC_SPAWN_LOCK="$TMP/lock"
L="python3 $BIN/cc-ledger"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }
check_fails(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi }

echo "== admission refusals (fail-closed inputs)"
check_fails "budget 1G refuses" "CC_ADMIT_GB=1 $L admit --session s --repo o/r --ref b --mem 4"
check_fails "mem 99 refused"    "$L admit --session s --repo o/r --ref b --mem 99"
check_fails "repo without owner refused" "CC_ADMIT_GB=99 $L admit --session s --repo bare --ref b --mem 4"

echo "== reservation + duplicate"
A=$(CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session s1 --repo o/r --ref b1 --mem 4) && ok "first admit ($A)"
check_fails "same-key duplicate refused" "CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session s1b --repo o/r --ref b1 --mem 4"
check "different ref admitted" "CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session s2 --repo o/r --ref b2 --mem 4"

echo "== concurrency: 5 parallel same-key admits -> exactly 1 winner"
WINS=0
for i in 1 2 3 4 5; do
  (CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session rc --repo o/r --ref race --mem 4 >/dev/null 2>&1 && echo W) &
done > "$TMP/wins"; wait
WINS=$(grep -c W "$TMP/wins" || true)
[[ "$WINS" == 1 ]] && ok "1/5 winners" || bad "expected 1 winner, got $WINS"

echo "== start limit"
check_fails "4th concurrent start refused (max 3)" \
  "CC_ADMIT_GB=99 CC_MAX_STARTS=3 $L admit --session s4 --repo o/r --ref b4 --mem 4"

echo "== transitions"
check "requested->starting" "$L set $A starting --container deadbeef"
check "starting->running"   "$L set $A running --tmux tm1"
check_fails "running->starting (backwards) refused" "$L set $A starting"
check "set-by-session stopping" "$L set-by-session s1 stopping"
check "stopping->done" "$L set-by-session s1 done"
check_fails "terminal is immutable" "$L set $A running"
check "key reusable after terminal" "CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session s1c --repo o/r --ref b1 --mem 4"

echo "== stale supersede (dead owner, old, no container)"
B=$(CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session st --repo o/r --ref stale --mem 4)
F=$(ls "$CC_LEDGER_DIR"/*.json | xargs grep -l "\"$B\"")
python3 - "$F" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
rec["current"]["pid"] = 999999999
rec["current"]["epoch"] -= 3600
json.dump(rec, open(sys.argv[1], "w"))
EOF
check "stale reservation superseded by new admit" \
  "CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session st2 --repo o/r --ref stale --mem 4"

echo "== zombie reservations expire fleet-wide (crash leftovers must not eat start slots)"
export CC_LEDGER_DIR="$TMP/ledger-zombie"   # isolated: earlier sections' live records must not gate this
Z1=$(CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session z1 --repo o/r --ref zomb1 --mem 4)
Z2=$(CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session z2 --repo o/r --ref zomb2 --mem 4)
for Z in "$Z1" "$Z2"; do
  F=$(ls "$CC_LEDGER_DIR"/*.json | xargs grep -l "\"$Z\"")
  python3 - "$F" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
rec["current"]["boot_id"] = "dead-boot"
rec["current"]["epoch"] -= 7200
json.dump(rec, open(sys.argv[1], "w"))
EOF
done
check "admit succeeds despite 2 zombies at max_starts=2" \
  "CC_ADMIT_GB=99 CC_MAX_STARTS=2 $L admit --session fresh --repo o/r --ref fresh1 --mem 4"

echo "== corrupt record fails closed"
echo '{broken json' > "$CC_LEDGER_DIR/deadbeefdeadbeefdeadbeef.json"
check_fails "admit with corrupt ledger file refuses" \
  "CC_ADMIT_GB=99 CC_MAX_STARTS=9 $L admit --session cz --repo o/r --ref cz --mem 4"

echo
echo "ledger tests: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
