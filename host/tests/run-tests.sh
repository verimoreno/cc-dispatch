#!/usr/bin/env bash
# Run the host control-plane test suite. Parser tests run anywhere with python3;
# ledger tests need docker (run on cc-host). From the laptop:
#   ssh cc-host '/opt/cc-releases/repo/host/tests/run-tests.sh'
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
echo "==== cc-plan parser fixtures"
python3 "$HERE/test-plan-parser.py" || rc=1
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "==== cc-ledger integration"
  bash "$HERE/test-ledger.sh" || rc=1
else
  echo "==== cc-ledger integration SKIPPED (no docker here — run on cc-host)"
fi
exit $rc
