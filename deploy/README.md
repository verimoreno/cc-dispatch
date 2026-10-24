# Deploying cc-dispatch on cc-host (tablet-friendly)

Goal: run the dispatch dashboard **on cc-host itself**, always-on, reachable
over Tailscale — so you can spawn/monitor sessions from a phone, tablet, or any
device on the tailnet with just a browser bookmark. No app to run client-side,
and it comes back on its own after a reboot.

## Why this layout

- **Runs on the host, in LOCAL mode** (`CC_DISPATCH_HOST=` empty in `.env`), so it
  drives the host's own `tmux` / `agent-deck` directly — no SSH loopback.
- **Bound to the host's Tailscale IP** (`CC_DISPATCH_BIND=auto`, resolved fresh at
  each start), so the app itself listens only on the private tailnet. **All** UI
  endpoints — including session **spawn** (`POST /api/sessions`) and prompt
  **injection** (`POST /api/sessions/{id}/prompt`), not just read-only browsing —
  are unauthenticated in the app; only the Supabase `from-task` webhook is
  token-gated. The public route below adds a login in nginx, in front of the app.
  So never bind this to `0.0.0.0` or a public interface.
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

The repo and branch pickers in **+ New session** need the GitHub CLI on the host:
`sudo apt install gh`. `run.sh` hands it `GITHUB_TOKEN` from `/opt/cc-sessions/.env`,
so no `gh auth login` is needed. Without `gh` the pickers stay empty (the
endpoint 500s) and you have to type `owner/repo` by hand.

## The public route (`dispatch.wearefractional.ai`)

The Supabase edge function `assign-to-veris-agent` runs in Supabase's cloud, not
on the tailnet, so it can only reach the bridge through nginx on this host's
**public** IP. That vhost lives at `deploy/nginx/cc-dispatch.conf` — copy it to
`/etc/nginx/sites-available/cc-dispatch` and reload.

**One route is published without a login**, `POST /api/sessions/from-task`,
which is the only route in `main.py` behind `secure_router` (the bearer check).

**Everything else — the dashboard — sits behind nginx `auth_basic`** (since
2026-10-01, so it works from a phone without Tailscale). `POST /api/sessions`
(spawn) and `POST /api/sessions/{id}/prompt` (inject a prompt into a live agent
session) are on bare `@app` with **no** authentication of their own, so that
`auth_basic` is the only thing between the internet and remote code execution.
nginx has no lockout: keep the password long and machine-generated.

The user is `veri`; the password hash lives in `/etc/nginx/cc-dispatch.htpasswd`
(root:www-data, 640). Set or rotate it from the laptop — takes effect
immediately, no reload:

```bash
printf 'veri:%s\n' "$(openssl passwd -6)" | \
  ssh cc-host 'sudo install -m 640 -o root -g www-data /dev/stdin /etc/nginx/cc-dispatch.htpasswd'
```

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

## Multi-host (hel + lm-server)

The dashboard on hel also drives a second fleet host, **lm-server** (a
mirror of hel bootstrapped from this repo — same `cc-*` in `/usr/local/bin`,
same `/opt/cc-notes` and `/opt/cc-data`). Pick the host in the top bar; the
pick is saved in the browser and every API call carries it as `?host=`.
`GET /api/hosts` reports reachability so an offline host is greyed out.

Registry in `.env`:

```
CC_DISPATCH_HOSTS=hel=local,lm-server=lm-server    # name=ssh alias; local = this box
```

The first entry is the default, so callers that never pass `?host=` (the
Supabase `from-task` webhook, old bookmarks) keep landing on hel. An `.env`
with only `CC_DISPATCH_HOST` still boots: empty → `hel=local`.

A remote host is only ever reached **from the dashboard process, over its ssh
alias** — the browser never talks to it, and nothing about auth changes.
Plans are per host: a plan lives in one host's `/opt/cc-notes`, and the Plan
Board labels each plan with its host.

**Prerequisite, done by hand (not by the installer):**

```bash
# 1. alias in hel's ~/.ssh/config (done 2026-10-24) + lm-server's host key in known_hosts
cat >> ~/.ssh/config <<'EOF'
Host lm-server
    HostName 100.75.141.60
    User veri
EOF
ssh-keyscan 100.75.141.60 >> ~/.ssh/known_hosts
# 2. verify — must print the hostname with no prompt
ssh -o BatchMode=yes lm-server hostname
```

**lm-server runs Tailscale SSH** (`RunSSH: true`), which answers port 22 on the
tailnet instead of OpenSSH and ignores `~/.ssh/authorized_keys` — hel's key is
there but unused. Access is decided by the tailnet ACL, and the default SSH
rule is `check`, which asks for a browser login and re-asks every 12 h, so an
unattended ssh from the dashboard fails with "Tailscale SSH requires an
additional check". Fix in the Tailscale admin console → Access controls, an
`accept` rule for hel → lm-server placed in the `ssh` section (accept beats
check when both match):

```json
{"action": "accept", "src": ["cc-host-hel"], "dst": ["lm-server"], "users": ["veri"]}
```

Until step 2 passes, `lm-server` shows as offline in the selector and its routes
return errors; hel is unaffected.

## Use it from the tablet

Open in the browser and bookmark:

```
https://dispatch.wearefractional.ai/   # anywhere, behind the login
http://cc-host-hel:7822/          # tailnet only; type http:// — it has no TLS
http://<tailscale-ip>:7822/       # e.g. http://100.100.213.79:7822/
```

- **Host** selector in the top bar → hel or lm-server (greyed out when unreachable).
- **+ New session** → pick repo + branch → Spawn (on the selected host).
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
