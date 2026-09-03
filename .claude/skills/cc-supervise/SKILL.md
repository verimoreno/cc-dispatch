---
name: cc-supervise
description: Supervise the cc-spawn sessions on cc-host as a fleet — classify each session's real state (working / waiting-for-input / PR-green / PR-red / stuck) by reading its tmux pane, git worktree, and GitHub PR/CI, then report a status table with a recommended action per session. NOTIFY-ONLY by default: it reads and reports, it injects NOTHING. Use when Veri says "supervise the sessions", "how are the runs doing", "check on the fleet", "babysit the runs", "which sessions need me", or runs this under /loop for unattended watching.
---

# cc-supervise — read the fleet, report what needs a human

The orchestrator (this Claude Code session) can already **list** sessions and
**inject** prompts through cc-dispatch, but cc-dispatch is write-mostly and can't
tell you what a session *produced*. This skill closes that gap by reading the
real signal directly: the tmux pane (what the agent is saying), the git worktree
(what it did), and the GitHub PR + CI (whether the work landed).

**Autonomy: NOTIFY-ONLY (v1).** This skill NEVER injects a prompt, never pushes,
never touches a container. It classifies and reports. Acting on those reports is
Veri's call. (See "Graduating to auto-fix" at the bottom for v2.)

Run it once for a snapshot, or under `/loop 5m cc-supervise` for unattended watching.

## Readback path

- **Session state + pane + local git** → SSH to `cc-host` (richest read, zero new
  surface on the fragile bridge). Note the host home is `/home/veri`, not `/home/veridiano`.
- **PR + CI** → `gh` run locally against the remote repo. Branches are pushed to
  GitHub, so `gh -R <owner/repo> pr checks <branch>` works from here without SSH.

## Procedure

### 1. Enumerate the fleet
```bash
ssh cc-host 'agent-deck ls --json'
```
Each entry gives: `id`, `title`, `path` (the worktree, e.g.
`/home/veri/Fractional/<repo>/wt-<branch>`), `status` (`idle` | `running`),
`tmux_session` (e.g. `agentdeck_<name>_<hash>`).

If Veri named a specific set of sessions/branches (the ones just dispatched),
filter to those. Otherwise supervise all of them.

### 2. Per session, gather three reads (do them in parallel across sessions)

**a. Pane — what is it doing right now**
```bash
ssh cc-host 'tmux capture-pane -p -t <tmux_session> | tail -25'
```
Read the tail to classify the terminal state:
- Bottom shows a Claude Code REPL prompt with a **question awaiting an answer**
  (e.g. an AskUserQuestion modal, a `/grill-me` question, "Do you want to…") →
  **waiting-for-input**.
- Active tool output / "esc to interrupt" / streaming → **working**.
- Idle REPL footer (`? for shortcuts`, `shift+tab to cycle`) with no question and
  no recent activity → **idle** (candidate for stuck; corroborate with git below).

**b. Worktree — what it has done**
```bash
ssh cc-host 'cd <path> && git rev-parse --abbrev-ref HEAD && git log --oneline -5 && git status --porcelain=v1 | head'
```
- Commits since the base branch → it produced work.
- Only uncommitted changes → work in progress, nothing pushed.
- Clean tree, no commits ahead → produced nothing yet.

**c. PR + CI — whether it landed (run locally)**
Derive `<owner/repo>` from the worktree remote if you don't already hold it:
```bash
ssh cc-host 'cd <path> && git remote get-url origin'   # -> owner/repo
```
Then, locally:
```bash
gh -R <owner/repo> pr list --head <branch> --json number,url,state,statusCheckRollup
```
- No PR → **no-pr-yet**.
- PR open, checks pending → **ci-pending**.
- PR open, all checks passed → **pr-green**.
- PR open, a check failed → **pr-red** (capture the failing check name + summary
  via `gh -R <owner/repo> pr checks <branch>`).

### 3. Classify each session into ONE state

Priority order (first match wins):
| State | Meaning | Recommended action (for Veri to take) |
|---|---|---|
| `pr-red` | PR open, CI failing | Inject fix-prompt with the failing check output; or investigate |
| `waiting-for-input` | Agent asked a question, nobody's answering | Answer it (mechanical → could be automated later) |
| `stuck` | Idle pane + no commits + no PR after a while | Attach and unblock, or respawn |
| `ci-pending` | PR open, checks running | Wait — no action |
| `working` | Actively producing | Wait — no action |
| `no-pr-yet` | Committing but no PR opened | Wait, or nudge to open a PR |
| `pr-green` | PR open, CI passing | Review + merge; then capture a post-mortem (see below) |

### 4. Report — one table, most-urgent first

Print a single table sorted so `pr-red` / `waiting-for-input` / `stuck` are at the
top (those are the only rows that need Veri). Columns:

`session · repo/branch · state · commits · PR# · CI · recommended action`

Then a one-line summary: `N sessions · X need you (pr-red/waiting/stuck) · Y healthy · Z done`.

**Inject nothing.** End by naming the specific sessions that need a human and why.
If run under `/loop`, only speak up when the "need you" count is > 0 or changed
since last tick — silent ticks when everything's healthy.

## Plan-aware pass (v2, 2026-08-27)

After the per-session table, check the multi-session plans:

```bash
ssh cc-host 'cc-plan list'                       # active plans in /opt/cc-notes
ssh cc-host 'cc-plan json <plan> --verify'       # per plan: roster × notes × ledger × evidence
```

Report each plan's `contradictions` array verbatim — the projection already
computes the joins, so do NOT re-derive them from pane text. The kinds:
`working-but-no-container` (agent believes it's working, container is gone),
`stale-notes` (working but silent >2h), `blocked-untyped` (blocked with no typed
WAITS — only a human can release it), `waits-refuted` (its wait matches a claim
that failed verification), `done-unverified` (STATUS done with no
typed UNBLOCKS evidence — the dependency must NOT be released), and
`evidence-failed` (claim's SHA no longer matches — force-push or stale claim).
`parser_errors` mean a worker broke protocol v1 — report as "unknown", never
infer green. Cross-check against `cc-reconcile` when ledger states look off.
The same data is visual at `http://cc-host:7822/plans.html` (Plan Board).

## Notes & guardrails

- **Green CI is the only real success signal.** A repo with no CI can't be
  supervised this way — every session there will read `no-pr-yet`/`working`
  forever with nothing to converge on. Flag repos that lack checks; they need CI
  before the loop means anything.
- **Don't confuse `agent-deck status:idle` with done.** `idle` is a tmux-activity
  flag, not an outcome. Always corroborate with git + PR before calling a session
  stuck. A session can be `idle` because it's waiting for input (needs you) or
  because it finished and opened a green PR (needs review) — opposite actions.
- **Never call a session stuck on the first tick.** "Idle + no progress" only
  means stuck if it persists across ticks. On a one-shot run, report it as
  `idle — recheck` rather than `stuck`.
- Reuses the SSH-to-`cc-host` + `agent-deck ls --json` conventions from
  [[cc-cleanup-sessions]]. Session→worktree→tmux mapping per `cc-docker-host-setup`.

## Graduating to auto-fix (v2 — do NOT enable without Veri's explicit say-so)

Once Veri has watched notify-only classify correctly across several real runs, the
single behavioral change to make it act unattended:

- On `pr-red` **and** attempts-for-this-branch < CAP (start CAP=3): inject a
  fix-prompt into that session via cc-dispatch
  `POST /api/sessions/{id}/prompt` — *"CI failed on your PR: {failing check
  summary}. Fix it and push to the same branch."* — and increment an
  attempts counter the supervisor holds in its own context.
- On `pr-green`: inject once — *"Before finishing, write docs/solutions/<slug>.md:
  what was underspecified, what broke, what would make this one-shot. Include it in
  the PR."* This is the compounding outer loop — memory lands in the client repo
  for the next session to read at task start.
- Everything else (`waiting-for-input`, `stuck`, CAP reached) still escalates to
  Veri. Autonomy is bounded to the one safe, verifiable action: fixing red CI
  toward green, capped.
