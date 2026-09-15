# Owner-selected Claude Code accounts

`CC_ACCOUNT=diogo cc-spawn --detach Internal-App test/diogo-account`
uses Diogo's privately provisioned setup-token. Omitting `CC_ACCOUNT` keeps the
existing shared login behavior. The alias is an operator-selected label; token
ownership must be checked by Diogo, not inferred from its spelling.

## Diogo's runbook

1. On his own machine, logged into **his** Claude subscription, Diogo runs
   `claude setup-token`. This is the [Claude Code setup-token flow](https://code.claude.com/docs/en/authentication).
   He keeps the result private; no chat, task notes, shell arguments, or env dumps.
2. Once this release is installed, he runs:

   ```sh
   ssh -t cc-host 'cc-account provision diogo'
   ```

   Paste the token at the hidden prompt. This command uses the existing host
   operator UID (1000), matching the container; it refuses non-terminal input.
   Host SSH access is required. It never prints the token.
3. Spawn the isolated session:

   ```sh
   ssh cc-host 'CC_ACCOUNT=diogo cc-spawn --detach Internal-App test/diogo-account'
   ```

4. Confirm the selection and local authentication source, without dumping env or
   full Docker inspection output:

   ```sh
   ssh cc-host 'docker inspect --format '\''{{index .Config.Labels "com.fractional.cc-account"}}'\'' internal-app-test-diogo-account'
   ssh cc-host 'docker exec internal-app-test-diogo-account claude auth status'
   ```

   The label must be `diogo`; auth status must identify OAuth/subscription auth,
   not an API key. A label alone is not proof of token ownership or validity.
   Diogo should also verify his account in Claude's `/status` when available.
5. Run the single harmless pilot prompt with tools disabled:

   ```sh
   ssh cc-host 'docker exec internal-app-test-diogo-account claude -p --tools "" "Reply exactly ACCOUNT_PILOT_OK. Do not edit files or take external actions."'
   ```

   Record only the alias, authentication source, success/failure and marker.
   This makes one Claude request; it permits no repo edits or tool actions.
   Afterward, normal interactive use follows the existing lifecycle:

   ```sh
   ssh cc-host 'CC_ACCOUNT=diogo cc-launch internal-app-test-diogo-account --agent ccd'
   ```

6. Expired token: run `claude setup-token` privately again, then repeat step 2.
   Exit and restart **Claude in Diogo's session** to read the replacement token.
   No container or other session restart is required. A running Claude process
   retains its old environment until it exits. Never run shared `/login` as a fix.

## Operator preparation and deployment

Run `host/tests/run-tests.sh` on cc-host from the reviewed checkout first.
Deploy this change with `host/deploy.sh --scripts-only`: this uses the existing
release/symlink/smoke lifecycle but skips writes to shared Claude/Codex config and
crontab. It needs no image rebuild and restarts no existing containers. Use a
clean checkout containing the reviewed commit; do not deploy unrelated changes.
The normal deploy command still manages fleet configuration as before.

If credentials are not provisioned, stop at implementation/testing and give
Diogo the provisioning command above. Do not run the live pilot with another
account. Provisioning can also run directly from a reviewed checkout before
installation. The prepared pilot checkout uses:

```sh
ssh -t cc-host '/opt/cc-releases/diogo-account-pilot/host/bin/cc-account provision diogo'
```

This checkout is staged only; its lifecycle scripts are not live until deployed.

## Storage and behavior

- `/opt/cc-data/accounts/<alias>/credentials/token`: host-owned 0600 file under
  0700 directories, outside git. Only this account's credential directory is
  mounted read-only; atomic token replacement remains visible inside containers.
- `<alias>/config` and `<alias>/claude.json`: isolated, writable Claude state.
  No shared `cc-auth`, `.claude.json`, Codex, Gemini, OpenCode or `.config` auth
  volume is mounted. Existing fleet Git SSH identity and build caches remain.
- The startup wrapper reads the token immediately before executing Claude. Docker
  config, tmux commands and process arguments contain no setup-token. It clears
  inherited Anthropic credentials/endpoints, alternate-provider flags and OAuth
  credentials before setting `CLAUDE_CODE_OAUTH_TOKEN`. It ignores project/local
  **settings** to prevent their `env`/API helpers overriding subscription auth;
  repository instructions still apply. User settings start with only fleet hooks.
- Provisioning seeds the managed fleet instructions, the four versioned fleet
  skills, and the five credential-free MCP definitions inspected on cc-host.
  It does not copy shared histories, OAuth metadata, plugin state, personal skills
  or MCP login tokens. MCPs needing login require the owner's own authorization.
  Token replacement preserves the account's configuration. Fleet seed updates
  require deliberate updates to isolated account config.
- `com.fractional.cc-account` labels expose aliases on containers. The host-only
  `/opt/cc-data/session-accounts/<session>` record keeps selection fixed even after
  container deletion; default sessions have an empty alias. A failed first spawn
  may leave this selection reserved. Use a new session name to select another
  account. `cc-spawn` rejects mismatches, including omission for an explicit
  session. `cc-launch` with no account uses the already selected container; an
  explicit different alias is refused before any keystrokes.
- This is owner-controlled CLI use. There is no credential UI, routing, pooling,
  account rotation, or subscription proxy.

## Verification performed (2026-09-15)

Read-only inspection found shared credentials/history/plugins/skills in `cc-auth`
and OAuth account metadata alongside MCP definitions in `/opt/cc-data/claude.json`.
No Diogo account was provisioned. Tests used dummy credentials only: name and
permission validation, missing/empty tokens, private provisioning and replacement,
fixed selection including legacy/stopped containers, default/explicit Compose,
credential precedence, secret-free output, and a disposable container wrapper
startup with networking disabled. Existing host parser, render, pulse and ledger
checks passed; the board smoke was skipped because its prerequisites were absent.
The local ledger run was refused by the laptop's memory floor; the host ledger
run passed all 18 checks.

**The live Diogo authentication/prompt pilot has not been run.** No shared auth was
changed and no existing session was restarted.
