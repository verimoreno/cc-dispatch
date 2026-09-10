# Deploying cc-dispatch on cc-host (tablet-friendly)

Goal: run the dispatch dashboard **on cc-host itself**, always-on, reachable
over Tailscale — so you can spawn/monitor sessions from a phone, tablet, or any
device on the tailnet with just a browser bookmark. No app to run client-side,
and it comes back on its own after a reboot.

## Why this layout

- **Runs on the host, in LOCAL mode** (`CC_DISPATCH_HOST=` empty in `.env`), so it
  drives the host's own `tmux` / `agent-deck` directly — no SSH loopback.
- **Bound to the host's Tailscale IP** (`CC_DISPATCH_BIND=auto`, resolved fresh at
  each start), so the dashboard is reachable only over the private tailnet, never
  the public internet. That tailnet boundary **is** the security model: **all** UI
  endpoints — including session **spawn** (`POST /api/sessions`) and prompt
  **injection** (`POST /api/sessions/{id}/prompt`), not just read-only browsing —
  are unauthenticated; only the Supabase `from-task` webhook is token-gated. So
  never bind this to `0.0.0.0` or a public interface.
- **systemd `Restart=always`, `StartLimitIntervalSec=0`, enabled at boot, with an
  `ExecStartPre` that waits for the Tailscale IP** — so a crash or reboot doesn't
  silently take dispatch offline, and it recovers on its own even through the
  window before tailscale is up.

> Note: `cc-host-hel` is the Tailscale/MagicDNS name of the same box the skills
> SSH to via the `cc-host` alias — one host, two names.

## One-time install (run ON cc-host, over SSH/Tailscale)

```bash
# clone if it isn't already on the host, otherwise just pull
git clone https://github.com/verimoreno/cc-dispatch.git ~/cc-dispatch 2>/dev/null || \
  git -C ~/cc-dispatch pull

cd ~/cc-dispatch
bash deploy/install-on-host.sh
```

The script sets up the venv, writes a locked-down `.env` (generating the secret
and auto-detecting the Tailscale IP via `tailscale ip -4`), installs the systemd
unit, and starts the service. It's idempotent — re-run it after any `git pull`.

## The public route (`dispatch.wearefractional.ai`)

The Supabase edge function `assign-to-veris-agent` runs in Supabase's cloud, not
on the tailnet, so it can only reach the bridge through nginx on this host's
**public** IP. That vhost lives at `deploy/nginx/cc-dispatch.conf` — copy it to
`/etc/nginx/sites-available/cc-dispatch` and reload.

**It proxies exactly one route**, `POST /api/sessions/from-task`, which is the
only route in `main.py` behind `secure_router` (the bearer check). Everything
else returns 404 publicly. That is deliberate: `POST /api/sessions` (spawn) and
`POST /api/sessions/{id}/prompt` (inject a prompt into a live agent session) are
on bare `@app` with **no** authentication, so publishing them with a blanket
`location /` would put unauthenticated remote code execution on the internet.

**The upstream is coupled to `CC_DISPATCH_BIND`.** `install-on-host.sh` sets
`auto`, which `run.sh` resolves to this host's Tailscale IP on port 7822 — *not*
`127.0.0.1:8000`. That coupling is how dispatch broke silently once already: the
bind moved to the tailnet, the vhost kept pointing at `127.0.0.1:8000`, nginx
answered 502, and every `veris_agent` run died as "Dispatch failed" from
2026-08-18 until 2026-09-02. Nothing alerted; the runs just stopped. Change one,
change the other.

`CC_DISPATCH_SECRET` must be identical here and in the Supabase project's
secrets. `install-on-host.sh` **generates a fresh secret** when `.env` has none,
so a reinstall silently rotates it out from under Supabase — which is exactly
what happened on 2026-08-09. After any reinstall, re-push it:

```bash
supabase secrets set CC_DISPATCH_SECRET="$(grep -m1 '^CC_DISPATCH_SECRET=' ~/cc-dispatch/.env | cut -d= -f2-)" \
  --project-ref rapfwpvqarrndzhgkaox
```

## Use it from the tablet

Open in the browser and bookmark:

```
http://cc-host-hel:7822/          # MagicDNS name (if enabled)
http://<tailscale-ip>:7822/       # e.g. http://100.100.213.79:7822/
```

- **+ New session** → pick repo + branch → Spawn.
- Tap a session → type a prompt → **Send** (Ctrl+Enter) to inject into it.

## Managing the service (on the host)

```bash
sudo systemctl status cc-dispatch      # is it up?
sudo systemctl restart cc-dispatch     # restart
journalctl -u cc-dispatch -n 50        # recent logs / why it died
```

## Updating

```bash
cd ~/cc-dispatch && git pull && bash deploy/install-on-host.sh
```
