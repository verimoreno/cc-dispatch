# Threat model — cc-host multi-agent fleet

*2026-08-27, written at the close of the hardening waves. One operator (Veri);
revisit before anyone else gets tailnet or host access.*

## System in one paragraph

Laptop orchestrator sessions drive, over SSH/Tailscale, a fleet of docker
containers on cc-host. Each container runs an **autonomous, bypass-permissions
coding agent** on a repo worktree, with outbound internet, working on code that
gets pushed to GitHub and deployed to client infrastructure. That sentence is
the threat model: semi-trusted automation with real credentials, driven by
prompts, running unattended.

## Assets, most valuable first

1. **Client repos + the GitHub identity** (SSH key, GITHUB_TOKEN) — code
   integrity, supply chain into client production.
2. **Deploy credentials** (Vercel/Railway/Supabase tokens) — direct prod access.
3. **The host itself** (veri is in the docker group = root-equivalent on cc-host).
4. **Fleet instructions** (cc-auth volume CLAUDE.md) — whoever writes these
   steers every agent.
5. **Coordination data** (/opt/cc-notes) — can contain client context; also an
   instruction-injection surface for agents that read it.
6. Model/API keys — a bill, not an intrusion.

## Threat actors, realistically

- **A confused or prompt-injected agent** (the main one): malicious text in a
  cloned repo, dependency, web page, or task description steers a
  bypass-permissions agent. Not hypothetical — it's the standard failure mode
  of autonomous agents.
- **A compromised dependency** running inside a session container (postinstall
  scripts etc.) with that container's env and mounts.
- **A device on the tailnet** other than Veri's (stolen tablet, compromised
  laptop): the dispatch UI will do what it's told.
- Not modeled: targeted external attackers, malicious insiders (n=1).

## Trust boundaries and what enforces them

| boundary | enforced by | holds against |
|---|---|---|
| container ↔ host | docker (no socket mounted, no privileged, uid 1000) | agent touching host beyond its mounts |
| container ↔ other repos | mount design (only own repo tree + shared stores) | cross-client code exposure |
| spawn correctness | cc-ledger (flock, fail-closed, budgets) | double-spawns, overcommit |
| control-plane integrity | git + deploy.sh --check (drift detection) | silent host edits |
| coordination truth | typed UNBLOCKS + cc-plan verify | agents releasing dependencies on false claims |
| task metadata | untrusted-fencing in injected prompts | instruction smuggling from the task system |

## Residual risks, ranked — the honest list

**R1 · The SSH key is an all-repo credential in every container (read-only
mount, but usable).** Any session can push to ANY repo the key reaches — the
scoped GITHUB_TOKEN work does not change this, because git push goes over SSH.
*Mitigation path:* per-repo deploy keys, or switch worktree remotes to
https+scoped-token at spawn (`CC_SCOPED_TOKEN=1` extended to rewrite the
remote). Until then: branch protection on important repos is the real control —
force-push and direct-to-main are provider-side blockable. **Do the branch
protection now; it's free.**

**R2 · The default GITHUB_TOKEN is a classic PAT, `repo`+`workflow`, all
repos.** Scoped 1h App tokens exist (`cc-github-token`, opt-in per spawn) but
the default stays broad until the App is created and the TTL/refresh question
is settled. *Runbook:* docs/scoped-github-tokens.md.

**R3 · Any session can poison the fleet's shared brain.** The cc-auth volume
(CLAUDE.md, skills, settings) is mounted read-write in every container: one
prompt-injected agent can append instructions that every future session obeys —
persistent, fleet-wide. *Mitigation:* deploy.sh --check now detects CLAUDE.md
drift (run it on cadence); real fix is mounting `:ro` per-session with a
separate writer path — worth doing when convenient.

**R4 · The dispatch UI's mutating routes trust the tailnet.** Spawn, prompt
injection, and image upload are open to any tailnet device; only /from-task
requires the bearer secret. Fine while every tailnet device is Veri's; not fine
the day one isn't. *Mitigation:* extend the bearer to all mutating routes, or
Tailscale ACLs pinning 7822 to Veri's devices.

**R5 · /opt/cc-notes is writable by every session.** Single-writer files are a
convention, not access control — one agent can overwrite another's notes or
PLAN.md, corrupting coordination (git history + off-host mirror = detection and
recovery, not prevention). Also: notes are agent-written text that other agents
read — treat as data, never as instructions (the fleet CLAUDE.md should keep
saying so).

**R6 · Secrets in /opt/cc-sessions/.env** are readable by anything running as
veri on the host and are visible in `docker inspect` of containers that got
them. Rotation runbook below. pids_limit/memswap caps bound runaway containers;
PSI-based rejection remains future work.

## Rotation / revocation runbook

- **GitHub PAT**: github.com → Settings → Developer settings → revoke; put the
  new one in `/opt/cc-sessions/.env`; running containers keep the old value
  until respawned — revocation is what actually kills it.
- **GitHub App key** (once configured): App settings → revoke key, generate new
  PEM → replace `/opt/cc-sessions/github-app.pem`. Tokens self-expire in 1h.
- **SSH key**: remove from GitHub → generate new pair in `~/.ssh` on cc-host →
  add public key to GitHub. Containers see the new key immediately (live mount).
- **Deploy tokens** (Vercel/Railway/Supabase): revoke in each provider's
  dashboard; update `.env`. Only sessions spawned with `CC_TOKENS=` ever had them.
- **A suspect tailnet device**: Tailscale admin → remove device. The dispatch
  UI and SSH both ride on tailnet membership.
- **A suspect session**: `cc-stop <name>` (container gone = env gone), then
  review its worktree diff and `git log` before anything merges.
