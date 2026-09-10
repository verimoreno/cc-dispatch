# Claude Code — Autonomous Host Environment

This container runs on a Hetzner dedicated server, NOT Veri's laptop sandbox.

## Network access

**Full unrestricted outbound network access.** tiktoken downloads, pip-audit
CVE feeds, GitHub, npm, Anthropic API, Supabase, Vercel, Railway — all reachable.

If a tool fails with a network error, it's a real failure — not sandbox filtering.

## Pre-cached resources

Already in the image:
- tiktoken encodings: cl100k_base, p50k_base, r50k_base, o200k_base
- Playwright browsers: chromium, firefox, webkit
- pip-audit binary

## Pre-push hooks

Pre-push hooks run normally and SHOULD pass. If they fail:
1. Read the failure — it's a real bug, not network filtering
2. Fix it before pushing
3. Do NOT use `--no-verify` to bypass

## Session isolation

Each container = one git worktree at `/home/pwuser/work`.
- Bind-mounted from host's `~/Fractional/<repo>/wt-<branch>/`
- Changes visible on host immediately
- Host's `~/.ssh/id_ed25519` mounted read-only — git push works

## Authentication

Shared via Docker volumes and env vars:
- **Claude Code OAuth:** `cc-auth` volume → `~/.claude/`
- **Codex CLI auth:** `cc-codex` volume → `~/.codex/`
- **Gemini CLI auth:** `cc-gemini` volume → `~/.gemini/`
- **MCP config (Claude):** same `cc-auth` volume (configured ONCE during bootstrap)
- **MCP config (Codex):** `cc-codex` volume → `~/.codex/config.toml` + `.credentials.json`
  (the `wearefractional` MCP; log in once with `cc-codex-mcp-login`, policy from
  `host/fleet/codex-mcp.toml.tmpl`). Codex hides MCP tools behind **tool-search**:
  ask a session to list its tools and it says "none" — it has to search for them
  by name (`get_my_workload`, `list_tasks`, …). That is not a missing MCP.
  `codex mcp list` is the real check. The server exposes no MCP *resources*, so
  `list_mcp_resources` never shows it either.
- **Service tokens:** env vars (SUPABASE_ACCESS_TOKEN, VERCEL_TOKEN, RAILWAY_TOKEN, GITHUB_TOKEN, GH_TOKEN)
- **Optional API-key auth:** OPENAI_API_KEY, GEMINI_API_KEY env vars (alternative to interactive login)
- **Git SSH:** mounted from host

If service auth fails, rotate the token in /opt/cc-sessions/.env on the host.

## Available coding agents in this container

- `claude` — Claude Code (Anthropic), primary
- `codex` — Codex CLI (OpenAI)
- `gemini` — Gemini CLI (Google)

All three share the same worktree at /home/pwuser/work. You can switch between
them mid-session, or run different sessions on different agents via agent-deck.

## Resource limits

- RAM: a hard cap set at spawn — 3 GB default, 2/6/8 GB by task class. Check
  yours: `cat /sys/fs/cgroup/memory.max`.
- 2 vCPU · host is 62 GB → ~12 parallel sessions.
- **Hitting the cap**: a process killed with exit 137, or `oom_kill` > 0 in
  `/sys/fs/cgroup/memory.events`, means the *build/test* was OOM-killed at your
  ceiling — not a code bug. You cannot raise it from inside (no docker socket).
  Say so once — in your status / HANDOFF: "OOM at N GB, need M GB" — and stop
  retrying that command; the supervisor resizes you live with no restart.

## Playwright on this host

**Run headless by default** — the server has no display.
- Headless = same browser engine, no GUI rendering = faster + less RAM
- For test failures: Playwright generates `trace.zip`. Download to laptop, run
  `npx playwright show-trace trace.zip` for visual debugging
- Headful inside container: needs Xvfb, not configured by default

## Playwright Agents (Planner / Generator / Healer)

Per-project setup. Inside a session, in the worktree:
```bash
cc-init-playwright   # runs `npx playwright init-agents --loop=claude`
```
This generates `.claude/agents/playwright-{planner,generator,healer}.md` in the repo.
