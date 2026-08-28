# Kicking off a fleet plan — the prompt

Open a Claude Code session **in the client repo** (never in cc-dispatch — this
repo is the control plane's source, not its cockpit) and paste one of these.
The skills are global on the laptop, so any repo session has them.

## From an existing plan / PRD

```
Use the cc-plan-design skill to convert an existing plan into a fleet-parallel plan.

INPUT: the plan at <path-to-plan.md — or paste it below>.

Work strictly through the skill: run the parallelize-or-not gate honestly (tell me
if this should just be one session); decompose into work units; build the file-level
conflict matrix by actually grepping THIS repo — no guessed file lists; define a typed
UNBLOCKS artifact contract for every dependency edge before anything spawns; size the
waves (≤4–5 wide, note CC_MEM_LIMIT=6g units and each unit's VERIFY class:
browser|api|cli|lib); write the PLAN.md draft and one brief per session under briefs/.

Then STOP: show me the plan, the conflict matrix, and your grill-checklist answers.
Do not create the plan on cc-host or spawn anything until I approve.
```

## From scratch (just a goal)

Same prompt, replacing the INPUT line with:

```
GOAL: <what you want built, a paragraph — outcomes, not implementation>
```

## After you approve

The same session becomes the plan's orchestrator and executes the handoff
(cc-plan-notes): creates `/opt/cc-notes/<plan>/` + PLAN.md, then per wave-1
session `cc-spawn --detach` → `cc-launch --prompt-file` → `cc-plan register`.
Watch on the Plan Board (`http://100.100.213.79:7822/plans.html` — the GRAPH
toggle shows the dependency DAG) or with cc-supervise (`/loop 10m` for
unattended). Later waves release only on `cc-plan verify` — and **merges are
yours**: workers end at PR + evidence, never merge.

Change requests to a worker:
`ssh cc-host 'cc-launch <session> --agent ccd --prompt "<feedback>"'`
Reap when merged: `cc-stop <session>` + `cc-cleanup-worktree <repo> <branch>`,
then archive the plan (cc-plan-notes step 5).
