---
name: cc-plan-design
description: Design a parallelization-perfect multi-agent plan FROM INSIDE the client repo — gate whether parallelism pays, decompose the goal into work units, build the file-level conflict matrix, define typed artifact contracts for every dependency edge, size the waves against fleet capacity, and emit PLAN.md + per-session briefs ready for the fleet. Use when Veri says "design a plan", "plan this for the fleet", "split this into parallel agents", "parallelize this feature/PRD", or "make a plan for X" while working in a project repo. Hands execution to cc-plan-notes (run the plan) and cc-spawn-session (spawn the sessions); this skill only THINKS.
license: Internal — Fractional / Veri
---

# cc-plan-design — decompose work into a plan agents can't collide on

The thinking half of fleet orchestration. [[cc-plan-notes]] runs plans;
**this skill designs them** — and it runs in the *client repo session*, because
good decomposition comes from reading the actual code, not guessing at it.
Output: a PLAN.md draft + one self-contained brief per session, then handoff.

## 0. The gate — most work should NOT be parallelized

Parallelize only when **both** hold:

- **Size**: serial execution would take more than ~a day of agent work.
- **Separability**: the work splits along surfaces that don't share files
  (verified in step 2, not assumed).

Otherwise say so and spawn ONE session ([[cc-spawn-session]]) — a plan with one
worker is overhead with no payoff. Integration cost is real: N parallel agents
buy speed only if the merge at the end is trivial because they never touched
the same thing.

## 1. Decompose the goal into candidate work units

From the goal/PRD, list units as *verb + surface* ("build the schema
migration", "add the export endpoint", "rewrite the upload UI"). For each unit
note what it **produces** (files, endpoints, schemas) and what it **consumes**
(things another unit produces). Consumes-edges are dependency candidates;
everything else is parallelism candidates.

## 2. The conflict matrix — the core move

For every unit, find the files/dirs it will *create or modify*. **Grep the
repo, don't guess** — imports, call sites, config, tests, migrations:

```
unit               | files it touches
-------------------|--------------------------------------
schema-migration   | db/schema.sql, migrations/*, models/user.py
export-endpoint    | api/export.py, api/routes.py, tests/test_export.py
upload-ui          | web/upload/*, api/routes.py   ← COLLISION
```

Rule: **two units that share ANY file never run in the same wave.** Resolve
each collision by (in order of preference):

1. **Re-slice** — move the shared file's change into one unit (e.g. one unit
   owns `api/routes.py` entirely; the other exposes its route from its own
   module the owner registers).
2. **Sequence** — add a dependency edge; the second unit's brief starts from
   the first's merged artifact.
3. **Merge the units** — if they're that entangled, they're one session's job.

The finished matrix becomes the plan's **Assignments** table verbatim: every
shared-ish surface has exactly one owner, and every brief says what its
session must NOT touch.

## 3. Contract-first dependency edges

Every edge gets a **typed artifact contract, written before anyone spawns** —
the same grammar the workers will use to claim it (protocol v1):

```
edge: schema-migration → export-endpoint
contract: UNBLOCKS: db-schema commit repo=<owner/repo> sha=<TBD> path=db/schema.sql
meaning: export work starts only from a verified schema at a pinned SHA
```

At release time the orchestrator fills `<TBD>` with the *verified* SHA
(`cc-plan verify`) and puts it in the downstream brief. A dependency without a
nameable artifact is a smell: either invent the artifact (a stub, a schema
file, an interface) or admit the units aren't really separable.

## 4. Waves, capacity, integration

- **Wave = a set of pairwise-disjoint units** (per the matrix). Prefer a wide
  wave 1 of foundations; later waves consume contracts.
- **Wave width ≤ 4–5.** The fleet budget (12 resident / 48G, shared with every
  other plan and Veri's other work) and your own review bandwidth both cap out
  around there. Check before designing wider: `ssh cc-host 'cc-ledger list; docker ps -q | wc -l'`.
- **One branch per session, always** (git can't co-checkout a branch twice).
  Name them `<plan-slug>/<unit>`; keep `len(repo)+1+len(branch)` ≤ 63.
- **Memory class per unit**: browser/e2e/build-heavy → note `CC_MEM_LIMIT=6g`
  in its brief line; default 4g otherwise.
- **Declare the integration strategy in PLAN.md**: client repos = PR + CI per
  session, orchestrator merges after `cc-plan verify` + green checks; the
  snake-demo push-to-main shortcut is for demos only. State who merges, in
  what order, and what the final integration check is.

## 5. Outputs

**(a) PLAN.md draft** — [[cc-plan-notes]] format: GOAL, ORCHESTRATOR, STATUS,
Roster (wave-1 sessions named, later waves as `PLANNED` rows with their
`depends on`), Assignments (from the matrix), plus a `## Contracts` section
listing every edge's typed artifact line (the cc-plan parser ignores extra
sections; humans and briefs read it).

**(b) One brief per session** — save as local files (`briefs/<session>.md`),
fed later to `cc-launch --prompt-file`. Template:

```
You are part of plan /opt/cc-notes/<plan-id>/ — follow the plan-notes protocol
in your CLAUDE.md (read PLAN.md first; notes entries start with the ## timestamp
heading as the FIRST line; typed UNBLOCKS only).

TASK: <what to build, concretely — outcomes, not vibes>
YOUR SURFACES: <files/dirs it owns, from Assignments>
DO NOT TOUCH: <other sessions' surfaces that border yours>
STARTS FROM: <verified artifact identity, for dependent waves — repo+sha+path>
DELIVER: branch <branch>, PR against <target>, and your final note:
STATUS: done + UNBLOCKS: <artifact> commit repo=<o/r> sha=<sha> path=<path>
```

## 6. Grill the plan before spawning anything

Walk this checklist — or run /grill-me on the draft for a real interrogation:

- Any two same-wave sessions sharing a file? (re-check the matrix against the
  final roster — the #1 failure mode)
- Does every edge have a typed contract with a real, checkable artifact?
- Is every brief self-contained — could a cold agent execute it without asking?
- Does wave 1 failing partially leave a salvageable plan (independent units
  fail independently), or does everything cascade?
- Is the whole thing still worth more than one good serial session?

## 7. Handoff — design ends here

Execute via [[cc-plan-notes]]: create the plan dir + PLAN.md on cc-host, then
per wave-1 session: `cc-spawn --detach` → `cc-launch --agent ccd --prompt-file`
→ `cc-plan register` ([[cc-spawn-session]] has the exact commands). Watch with
cc-supervise; release later waves only on `cc-plan verify`.
