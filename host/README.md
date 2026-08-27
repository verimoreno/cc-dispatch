# host/ — the cc-host control plane, versioned

Everything that runs the session fleet on cc-host, managed from git. Before this
directory existed these files were hand-edited on the host with no history
(the pre-hardening state is snapshotted at
`cc-host:/opt/cc-data/snapshot-2026-08-27-pre-hardening/`).

## Layout

    bin/                  the cc-* lifecycle scripts installed to /usr/local/bin
    sessions/             docker-compose.yml, Dockerfile, CC-CONTAINER.md,
                          tokens.d/ (opt-in deploy-token overrides), env.template
    fleet/CLAUDE.md.tmpl  managed region of the fleet-wide CLAUDE.md (cc-auth volume)
    crontab.snippet       managed block of veri's crontab on the host
    deploy.sh             deploy / --check / --rollback / --list (see header)

## Deploying

On cc-host, from the deploy checkout:

    cd /opt/cc-releases/repo && git pull --ff-only && host/deploy.sh

From the laptop: `ssh cc-host 'cd /opt/cc-releases/repo && git pull --ff-only && host/deploy.sh'`

Deploys stage a release under `/opt/cc-releases/<ts>-<sha>/`, validate
(`bash -n`, rendered compose assertions), switch symlinks atomically under the
spawn lock, then smoke-test; a failed smoke auto-rolls back. `--check` is the
drift detector — run it when something on the host behaves unexpectedly.

## Deliberately NOT managed (bootstrap by hand on a fresh host)

- `/opt/cc-sessions/.env` — secrets; keys listed in `sessions/env.template`
- `~/.ssh`, `~/.gitconfig` — host identity
- docker named volumes (`cc-sessions_cc-*`) — login/auth state; created by first run
- agent-deck install + `~/.agent-deck/config.toml`
- `/opt/cc-notes` (plan store; mirrored to github.com/verimoreno/cc-notes) and `/opt/cc-data`
- docker engine, tmux, agent-deck binaries
