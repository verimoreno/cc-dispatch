# Scoped GitHub tokens — one-time App setup

`cc-github-token <owner/repo>` mints a **single-repo, ~1-hour** GitHub App
installation token; `CC_SCOPED_TOKEN=1 cc-spawn …` puts it in that session's
`GITHUB_TOKEN`/`GH_TOKEN` instead of the all-repo PAT. Until the App below
exists, plain spawns are unaffected — but a spawn that explicitly asks for
`CC_SCOPED_TOKEN=1` **refuses to start** rather than silently falling back to
the broad PAT (you asked for least privilege; a quiet downgrade would betray
that). Configure the App first, then use the flag.

## One-time setup (~5 min, needs the browser)

1. github.com → Settings → Developer settings → **GitHub Apps → New GitHub App**
   - Name: `cc-fleet-tokens` (anything). Homepage: the repo URL. **Webhook: off.**
   - Repository permissions: **Contents: Read & write · Pull requests: Read &
     write · Workflows: Read & write**. Nothing else.
2. After creating: **Generate a private key** → downloads a `.pem`.
3. **Install App** → your account/org → select the repos sessions work on
   (add more any time).
4. On cc-host:
   ```bash
   scp app-key.pem cc-host:/opt/cc-sessions/github-app.pem
   ssh cc-host 'chmod 600 /opt/cc-sessions/github-app.pem
     printf "GITHUB_APP_ID=<the App ID from its settings page>\nGITHUB_APP_KEY=/opt/cc-sessions/github-app.pem\n" > /opt/cc-sessions/github-app.env'
   ssh cc-host 'cc-github-token verimoreno/cc-dispatch'   # should print a ghs_… token
   ```

## Limits, honestly

- **~1 h TTL, no refresh**: a session doing `gh` calls hours in will hit an
  expired token. Use `CC_SCOPED_TOKEN=1` for short, well-scoped tasks; leave
  long sessions on the default until a refresh mechanism exists.
- **git push is unaffected** either way — it rides the mounted SSH key, which
  remains an all-repo credential (threat-model R1). Scoped tokens narrow the
  API surface (`gh`, PR creation), not the push surface.
- Flipping the default to scoped = decision for later, after TTL experience.
