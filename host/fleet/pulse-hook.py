#!/usr/bin/env python3
"""cc-pulse — fleet heartbeat, written by Claude Code hooks, read by cc-plan.

One line per tool call / notification / turn-end into
/opt/cc-notes/.pulse/<hostname>.jsonl. Hooks run OUTSIDE the model's context, so
this is the mid-run progress feed that costs a lane nothing — the reason we do
NOT ask lanes to write a note per step (context is what runs out first).

Deployed into the shared cc-auth volume as /home/pwuser/.claude/cc-pulse by
host/deploy.sh; wired up by host/fleet/settings.hooks.json.

Contract: ALWAYS exit 0, ALWAYS print nothing. A hook that fails feeds its
stderr straight back into the agent's context — the exact cost this exists to
avoid. Every failure here is silent by design.
"""
import json, os, sys, time

PULSE = "/opt/cc-notes/.pulse"
MAX = 200               # chars of target text kept per line
ROTATE_BYTES = 1 << 20  # keep TAIL_LINES once a lane's file passes this
TAIL_LINES = 300
FIELDS = ("file_path", "command", "pattern", "path", "url", "description", "prompt")


def target(inp):
    for k in FIELDS:
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip().replace("\n", " ")[:MAX]
    return ""


def main():
    d = json.load(sys.stdin)
    ev = d.get("hook_event_name") or "?"
    rec = {"ts": int(time.time()), "ev": ev, "tool": d.get("tool_name") or "", "t": ""}
    if ev == "Notification":
        rec["t"] = str(d.get("message") or "")[:MAX]
    else:
        rec["t"] = target(d.get("tool_input") or {})
    os.makedirs(PULSE, exist_ok=True)
    path = os.path.join(PULSE, os.uname().nodename + ".jsonl")
    # ponytail: racy truncate (two hooks could rotate at once, losing a line or
    # two). A lost pulse line costs nothing; an unbounded file on a shared mount
    # costs a 3am page. Per-lane lock if that ever stops being true.
    try:
        if os.path.getsize(path) > ROTATE_BYTES:
            with open(path) as f:
                tail = f.readlines()[-TAIL_LINES:]
            with open(path, "w") as f:
                f.writelines(tail)
    except OSError:
        pass
    # one short line, O_APPEND: atomic enough without a lock
    with open(path, "a") as f:
        f.write(json.dumps(rec) + "\n")


try:
    main()
except Exception:
    pass
sys.exit(0)
