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

## CC_TOKENS=gcp

Opt-in token class for sessions that work on the foraudits staging stack (GCP
Identity Platform + Cloud SQL). `CC_TOKENS=gcp cc-spawn <repo> <branch>` makes
cc-spawn add `tokens.d/gcp.yml` to the compose invocation; nothing else changes,
and a session spawned without it sees none of these variables.

### What it grants

| variable | what it is |
|---|---|
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | the `foraudits-web@` service-account key, as JSON content |
| `GOOGLE_APPLICATION_CREDENTIALS` | `/home/pwuser/.gcp/sa.json` — where the entrypoint writes that content, 0600, owned by pwuser |
| `GCP_PROJECT`, `GOOGLE_CLOUD_PROJECT` | `foraudits-staging` |
| `GIP_API_KEY` | Identity Platform web API key — the login plane |
| `CLOUD_SQL_INSTANCE` | `<project>:<region>:<instance>` connection name |
| `DATABASE_URL_SESSION` | password plane, `127.0.0.1:5433` (proxy) |
| `DATABASE_URL_TX_POOLER` | IAM plane, `127.0.0.1:5432` (proxy, `--auto-iam-authn`) |
| `SEED_TENANT_DB_USER`, `SEED_TENANT_DB_TOKEN` | tenant seeding |

> **State as of 2026-09-02:** the class is **live and proven end to end**. Key
> `c0fdd0b97216` passes the mint gate, and a throwaway `CC_TOKENS=gcp` session
> reached an authenticated `/app` as `auditor@agri.local` over HTTPS with nothing
> hand-copied into it. The predecessor key `e36d3ae2a40c` was revoked and had been
> hand-copied into three lane containers — see Rotation.

**Content, not a mount.** The key is passed as a string and materialized to a file
by the overlay's `entrypoint` (`tokens.d/gcp.yml`), because the google libraries
read a file while a `.env` can only carry a string. The rejected alternative was a
read-only bind-mount of a host key directory: a mount lives in the compose project
and is one copy-paste from every session, whereas this path only ever runs for a
session that asked for the token class. The entrypoint override clears the image
`CMD`, so it ends with an explicit `exec /bin/bash`.

**`GIP_ADMIN_ACCESS_TOKEN` is not granted**, and the app agrees: in
`apps/web/lib/auth-providers/gip.ts` it is an *override*, not the primary path —
absent it, `adminToken()` falls back to the app's own credential helper. A ~1h
OAuth token in a static `.env` would ship a secret that expires before it is read.

**But do not assume a session can mint an admin token from the class key.** That
same file records a measurement from 2026-09-01: the Identity Toolkit *admin*
surface (`:signUp`, `:delete`, `:update`) needs `serviceusage.services.use` on the
named project, and `foraudits-web@` holds only
`roles/cloudsql.{client,instanceUser}` — so a token minted from the class key gets
403 there, reported misleadingly as if the API key were wrong. Until that SA is
granted `roles/serviceusage.serviceUsageConsumer`:

- **Sign-in and ordinary GCP calls** — fine on the class key.
- **Persona seeding / invitation-accept** — needs the override, set to a token from
  a principal that actually holds the role (`gcloud auth print-access-token` run by
  a human with owner). `gcloud` is deliberately not in the image, so that value is
  injected from outside per run, never stored.

### Where the values live, and why not in git

`/opt/cc-sessions/.env`, mode 0600, owned by veri. That file is **deliberately
unmanaged** — `deploy.sh` never reads, writes, or restores it (see its header), so
it survives every release and rollback. Key *names* are documented in
`sessions/env.template`; values are never committed, never quoted in a commit
message, and never pasted into a doc. `deploy.sh` validate asserts that none of
these names appear in the rendered *default* compose, so the class cannot silently
become the default.

`GOOGLE_APPLICATION_CREDENTIALS_JSON` must be a **single line wrapped in single
quotes** (`jq -c . sa.json`). Double quotes do not work and fail loudly — the JSON's
own `"` terminates the value early, and compose refuses the whole file:

    failed to read .env: line 1: unexpected character '"' in variable name ...

Single-quoted values are taken literally, so the `\n` escapes inside `private_key`
reach the container as escapes and `jq`/`JSON.parse` rebuild the real newlines.
Verified both ways against `docker compose config` on 2026-09-02.

### Rotation — the mint gate comes first

A revoked key is invisible until something exercises it. On 2026-09-02 key
`e36d3ae2a40c` was found dead in three containers at once, having been hand-copied
between them. **Never store a key that has not minted a token in front of you.**

1. O1 (the GCP owner, per `docs/plans/gcp-finish/PLAN.md`) mints a new key for
   `foraudits-web@foraudits-staging.iam.gserviceaccount.com` in the console.
   Minting is not the fleet operator's job and no IAM binding gets widened to
   work around a dead key.
2. Gate it — `HTTP 200` proceeds, `HTTP 400 invalid_grant` stops:

       node -e '
       const c=require("crypto"),fs=require("fs");
       const d=JSON.parse(fs.readFileSync(process.argv[1]));
       const b=o=>Buffer.from(JSON.stringify(o)).toString("base64url");
       const now=Math.floor(Date.now()/1000);
       const h=b({alg:"RS256",typ:"JWT",kid:d.private_key_id});
       const p=b({iss:d.client_email,scope:"https://www.googleapis.com/auth/cloud-platform",
                  aud:"https://oauth2.googleapis.com/token",iat:now,exp:now+3600});
       const s=c.sign("RSA-SHA256",Buffer.from(h+"."+p),d.private_key).toString("base64url");
       fetch("https://oauth2.googleapis.com/token",{method:"POST",
         headers:{"content-type":"application/x-www-form-urlencoded"},
         body:new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",
                                   assertion:h+"."+p+"."+s})})
         .then(async r=>console.log("HTTP",r.status,(await r.text()).slice(0,180)));
       ' /path/to/new-sa.json

3. Back up, then rewrite the one line, keeping 0600:

       cp -a /opt/cc-sessions/.env /opt/cc-sessions/.env.bak-$(date +%Y%m%d-%H%M%S)
       # edit GOOGLE_APPLICATION_CREDENTIALS_JSON='<jq -c . output>'
       chmod 600 /opt/cc-sessions/.env

4. Re-run the gate **inside a freshly spawned session**, against the file the
   entrypoint materialized, before trusting the fleet.
5. Old key: delete it in the console, and `rm ~/.gcp/sa.json` in any container
   still holding a hand-placed copy.

### Verifying a session — a login, not an env dump

A green `printenv` proves interpolation, not access. The acceptance test is a
completed login. This walk was run end to end on 2026-09-02 and passed; the
non-obvious steps are the ones that cost time.

    CC_TOKENS=gcp CC_MEM_LIMIT=6g cc-spawn --detach foraudits <throwaway-branch>

1. **Key arrives without anyone copying it.** `stat` it: `mode=600
   owner=pwuser:pwuser`, and `jq -r .private_key_id` should be the key you gated.
2. **Re-run the mint gate inside the container** before trusting anything. HTTP 200.
3. **Check out `feat/rebuild`, not `main`.** The GIP provider does not exist on
   `main` — its login route is still Supabase, and `GIP_API_KEY` is read nowhere in
   `apps/web`. Acceptance on `main` proves nothing about this class.
4. **Install needs a user-level npm token.** `pnpm` refuses to expand env vars in the
   project `.npmrc`, so `@wearefractional/ui` 401s from GitHub Packages. Fix, once
   per session: `pnpm config set "//npm.pkg.github.com/:_authToken" "$GITHUB_TOKEN"`.
5. **Use spare ports.** Host networking means 5432/5433 and 8443 may already be held
   by another session. Run your own proxy on e.g. 5442 and repoint
   `DATABASE_URL_TX_POOLER` at it for the run; serve the app on a free port.
6. **Serve over HTTPS.** `next dev --experimental-https --hostname agri.localtest.me
   --port <free>` — it fetches mkcert and mints a cert. The GIP cookie is
   `secure:true`, so a plain-http origin never keeps a session.
7. **The proof:** `POST /api/auth/login` with `auditor@agri.local` returns
   `{"ok":true,"redirect":"/app"}` and sets `fa_session` + `fa_refresh` (`Secure`,
   `HttpOnly`). Then `GET /app` **with** the cookie is 200 and **without** it
   redirects to `/login?next=%2Fapp`. Both halves matter — the control proves the
   session is doing the work.

Then tear the session down (`cc-stop`, `cc-cleanup-worktree`, `cc-ledger
set-by-session <name> done`). `cc-cleanup-worktree` refuses while Next's generated
`next-env.d.ts`/`.gitignore` edits are uncommitted; discard them first.

**`DATABASE_URL_SESSION` is empty on purpose.** The password plane (`postgres`
superuser) was rejected with `password authentication failed` on 2026-09-02, tested
both as a URI and with discrete parameters, so it was blanked in `.env` with the
reason left in-file. A wrong credential fails late and reads like a proxy fault; an
absent one fails early and says so. Refill it only with a rotated password — and it
needs rotating on its own track regardless, since it is a plaintext password in a
DSN on a port every container on the box can reach.

**You may not need a listener at all.** Lane u0 shipped its work using the Cloud SQL
connector directly — `DB_IAM_AUTH=1` plus `CLOUD_SQL_INSTANCE`, no proxy, no local
port (D-017). The connector is gated on that explicit flag, which this token class
does *not* set (`packages/db/src/cloud-sql.ts` is emphatic that the mode is never
inferred), so a session wanting that path exports it itself. Where it works it is
strictly better than a shared listener: nothing to squat a port, nothing to inherit
from another lane, nothing to die when that lane is reaped. What still needs a
listener: `psql` at a human prompt, and `infra/scripts/agri_demo_shared.ts`, which
builds its tenant client from discrete host/port fields and never spreads the
connector options.

Two things a fresh session does **not** get, by design:

- **`cloud-sql-proxy` is not in the image.** Fetch it in-session when you need
  psql-level access (`curl -fsSL -o ~/.local/bin/cloud-sql-proxy
  https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.1/cloud-sql-proxy.linux.amd64
  && chmod +x ~/.local/bin/cloud-sql-proxy`). Tools are fetchable; credentials are not.
- Sessions run `network_mode: host`, so `127.0.0.1:5432` / `:5433` are a **host-wide
  singleton**. Whichever session starts the proxy owns the port, and every other
  session silently borrows it — and loses the database when that session is reaped.
  Use a spare port (`--port 5442`) when you only need to prove your own credentials.
  A host-level proxy service is the standing fix; it is not yet built.

### If a spawn breaks after a deploy

`deploy.sh --check` first — it diffs `bin/` and `sessions/` against the live
symlinks and reports hand-edits as DRIFT. Then `deploy.sh --rollback`, which
switches `current` back to the release named in `DEPLOYED: prev` and re-runs the
smoke test. The `.env` is untouched by both, so a rollback reverts the *plumbing*
(gcp.yml, the cc-spawn allowlist) and leaves the values in place; a session spawned
against the rolled-back release simply refuses `CC_TOKENS=gcp` again.
