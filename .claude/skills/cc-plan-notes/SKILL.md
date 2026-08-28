---
name: cc-plan-notes
description: Coordinate a multi-session plan through the shared /opt/cc-notes store on cc-host — create a plan (PLAN.md with roster + Assignments), spawn workers with the plan path in their prompt, poll their notes for STATUS/UNBLOCKS to sequence dependent spawns, and archive the plan when done. Use when Veri says "create a plan", "start a plan for <goal>", "check the plan", "what's the plan status", "who's blocked", "archive the plan", or when orchestrating several cc-host sessions that depend on each other.
license: Internal — Fractional / Veri
---

# cc-plan-notes — cross-session plan coordination over /opt/cc-notes

One shared store on cc-host for multi-agent plans: workers self-report progress,
orchestrators poll and **sequence** — a dependent session is spawned only when
the notes prove its prerequisite is done. Poll-based, no injection into running
sessions (injection stays a manual, Veri-only exception).

Host facts: SSH alias `cc-host`. Store at `/opt/cc-notes` (git repo, hourly cron
auto-commit, no remote). Mounted read-write at the same path inside every
cc-session container **spawned after 2026-08-27** — older containers cannot see
it, so only newly spawned sessions can be plan members. Workers learn the
protocol from the fleet CLAUDE.md (shared `cc-auth` volume); you give them the
concrete plan path in the spawn prompt (see [[cc-spawn-session]]).

## Layout & ownership (the contract)

```
/opt/cc-notes/<YYYY-MM-slug>/         one dir per plan — orchestrator creates it
    PLAN.md                           ONE writer: the orchestrator owning the plan
    notes/<session-name>.md           ONE writer: that session. Append-only.
/opt/cc-notes/archive/<plan>/         completed plans
```

Single-writer-per-file is what makes this lock-free. Never edit a worker's notes
file; workers never edit PLAN.md or each other's files.

## 1. Create a plan

Plan id: `YYYY-MM-<slug>` (e.g. `2026-08-billing-split`), slug short, `[a-z0-9-]`.

```bash
ssh cc-host 'mkdir -p /opt/cc-notes/PLAN_ID/notes'
ssh cc-host 'cat > /opt/cc-notes/PLAN_ID/PLAN.md' <<'EOF'
# <plan title>

GOAL: <one paragraph — what done looks like>
ORCHESTRATOR: <who owns this file — e.g. laptop session name / "Veri">
STATUS: active

## Roster
| session | repo/branch | task | depends on |
|---|---|---|---|
| <session-name or PLANNED> | <repo>/<branch> | <one line> | — |

## Assignments
| area / surface | owner |
|---|---|
| <e.g. db schema, auth module, repo X> | <session-name> |

## Log
- <ISO date> created
EOF
```

Roster rows for sessions not yet spawned get `PLANNED` until the spawn registers
a real session name. Every shared surface two sessions could both touch belongs
in Assignments **before** the second session spawns — that table is the
duplicate-work guard.

## 2. Spawn workers into the plan

Spawn via [[cc-spawn-session]] as usual, with two additions to the prompt:

- Name the plan dir explicitly, e.g.
  `You are part of plan /opt/cc-notes/PLAN_ID/ — follow the plan-notes protocol in your CLAUDE.md before starting.`
- State the task as usual.

Then register the session in the roster mechanically (replaces the matching
`PLANNED` row, or appends; never hand-sed markdown pipes):

```bash
ssh cc-host 'cc-plan register PLAN_ID --session SESSION_NAME --repo-branch repo/branch'
```

Add its Assignments rows by hand (still orchestrator-owned).

**Sequencing rule (hard):** if B depends on A, do NOT spawn B yet. B is spawned
in step 4, when A's notes say so.

## 3. Poll the plan

One SSH round-trip gives the whole machine-parsed picture — roster × notes ×
ledger × containers, with contradictions precomputed (`cc-plan` on the host):

```bash
ssh cc-host 'cc-plan json PLAN_ID'          # add --verify to also check UNBLOCKS evidence
```

The same data renders visually at the dispatch Plan Board: `http://cc-host:7822/plans.html`.
Raw-notes fallback (cc-plan unavailable):

```bash
ssh cc-host 'cd /opt/cc-notes/PLAN_ID && \
  for f in notes/*.md; do echo "== $f"; grep -h "^## \|^STATUS:\|^UNBLOCKS:" "$f" | tail -6; done'
```

- Latest `STATUS:` per file = that session's self-reported state. Cross-check
  against [[cc-supervise]] (pane/PR/CI truth) when it matters — notes are what
  the agent *believes*, cc-supervise is what *is*.
- `STATUS: blocked` → read the full entry (`ssh cc-host cat .../notes/<f>.md`),
  decide, and act via a *new* spawn or by telling Veri — not by injecting.
- A session that has been `working` with no new entry for hours isn't "fine",
  it's unobserved — check it with cc-supervise.
- `done-but-resident` in the contradictions = the work is finished (and ideally
  verified) but the container still occupies an admission slot. Reap it:
  `cc-stop <name>` then `cc-cleanup-worktree <repo> <branch>` — sessions are
  cattle, and the fleet budget only frees up when you actually reap.

For unattended watching, run this under `/loop` (e.g. `/loop 10m check plan
PLAN_ID and spawn any newly-unblocked sessions`).

## 4. Release dependencies

Protocol v1: an `UNBLOCKS:` claim is **typed evidence**, not prose. Workers write
exactly one of (single spaces, full 40-hex SHA):

```
UNBLOCKS: <artifact-name> pr repo=<owner/name> number=<N> head=<40-hex-sha>
UNBLOCKS: <artifact-name> commit repo=<owner/name> sha=<40-hex-sha> path=<repo-relative-path>
```

When a poll shows the awaited claim (or `STATUS: done`) from A:

1. **Verify mechanically**: `ssh cc-host 'cc-plan verify PLAN_ID'` — checks PR
   head SHA against GitHub (catches force-pushes) and commit+path against the
   local bare repo. `STATUS: done` with no well-formed claim is *done-unverified*
   and releases NOTHING; free text after `UNBLOCKS:` is a legacy claim, same rule.
2. Spawn B via [[cc-spawn-session]], its prompt naming the plan dir AND the
   verified artifact identity (repo + SHA), not just "A is done".
3. Log the release (artifact, SHA, verified time) in PLAN.md's `## Log`.

## 5. Close & archive

When the goal is met (or the plan is abandoned — say which):

```bash
ssh cc-host 'cd /opt/cc-notes && \
  sed -i "s/^STATUS: active/STATUS: closed <ISO-date>/" PLAN_ID/PLAN.md && \
  mv PLAN_ID archive/PLAN_ID && \
  git add -A && git -c user.name=cc-notes -c user.email=cc-notes@cc-host \
    commit -q -m "close: PLAN_ID"'
```

Sessions themselves are reaped separately via cc-cleanup-sessions — archiving
the plan does not tear anything down.

## Notes & guardrails

- **Poll, don't push.** This skill never injects into a running session's pane.
  If something must reach a running agent urgently, that's Veri's call, made
  manually.
- **Notes are claims, not facts.** Gate spawns on verified deliverables (step 4.1),
  not on `STATUS: done` alone.
- **Laptop orchestrators are plan members too** — a laptop session doing plan
  work writes its own `notes/<name>.md` over SSH (`ssh cc-host 'cat >> ...'`),
  same format, pick a stable name like `laptop-<topic>`.
- **Old containers can't join.** Anything spawned before the mount existed has
  no `/opt/cc-notes`. Don't hand plan paths to pre-existing sessions; respawn if
  membership matters (Veri decides — never stop a running session for this).
- **Quote everything** crossing SSH; plan ids stay `[a-z0-9-]` so the commands
  above stay quoting-safe.
- The store is a git repo with an hourly auto-commit cron on cc-host — history
  is the post-mortem trail; don't rewrite it.
