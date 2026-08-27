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

- 8 GB RAM hard cap per container
- 2 vCPU
- Host: Ryzen 9 3900, 128 GB → ~12 parallel sessions max

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
