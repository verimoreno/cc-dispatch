# Who owns the fleet's database plane

*Written 2026-09-02, after the `CC_TOKENS=gcp` work (PRs #9–#11). Records the
reasoning behind a decision that was **deferred**, not taken — so that whoever
revisits it does not start from zero. Companion to [`threat-model.md`](threat-model.md)
and the `CC_TOKENS=gcp` runbook in [`../host/README.md`](../host/README.md).*

## The situation that prompted it

Two `cloud-sql-proxy` listeners sat on `127.0.0.1:5432` and `:5433`, started by hand
inside one session's container. Because every session runs `network_mode: host`, they
served the whole box, and other lanes silently depended on them. The lane that owned
them drifted from `d3-acceptance` to `u0-conformance-ledger` within hours without
anyone noticing — including this author, who reported the wrong container until a
`/proc/<pid>/cgroup` trace corrected it.

They were also dead. Every connection since startup failed `invalid_grant` on a
revoked service-account key, while the listeners stayed up: TCP accepted, then reset.
A dead tunnel that answers on the port reads as a network flake, not a credential
problem, which is how it survived.

## Facts worth not re-deriving

- **Reachability is fleet-wide and confirmed, not theoretical.** From an unrelated
  client's session with no GCP grant, both ports opened and `psql` is in the image.
- **`:5432` is passwordless by construction.** It runs `--auto-iam-authn`, so the
  proxy supplies the credential and the client presents only a username. On that port,
  loopback reachability *is* the authorization.
- **`:5433` carries a plaintext superuser password** in `DATABASE_URL_SESSION`. A
  session could squat the port with a fake Postgres listener and harvest it.
- **Containers share the network namespace but not the mount namespace.** This is the
  hinge of the whole analysis.
- **No container holds `CAP_NET_ADMIN`** (docker default bounding set), so a session
  cannot rewrite host firewall rules.
- **`~/.config` is a shared volume across every session**; `~/.gcp` is per-container.
  Any fix routed through `gcloud` ADC lands in all sessions at once, including other
  clients'.
- **Ports are not the only singleton.** `infra/scripts/local_test_db.sh` binds
  `127.0.0.1:55432`; two lanes running the sanctioned local rig collide today.

## The options

**A — restart the proxy inside a lane container.** The status quo, and a regression:
it puts a live SA key on the writable filesystem of a container the token class never
granted, and it propagates by copy to the next lane. A proxy-hosting lane is a
legitimate `cc-teardown-idle` target, so the fleet's database disappears with no
signal when that lane finishes.

**B — a host systemd unit.** Containers mount `${HOME}/.ssh` and `${HOME}/.gitconfig`,
*not* `${HOME}`, so a key at a host path is invisible to every session. `Restart=always`
survives reap, reboot and deploy. Underrated benefit: it wins the port race at boot,
which is what makes squatting impossible. Versioned in `host/` and shipped by
`deploy.sh` like the rest of the control plane.

**C — no shared listener; each session binds its own spare port.** Correct blast
radius, wrong ergonomics: no port allocator exists, so concurrent sessions collide,
and the `.env` DSNs are hardcoded to 5432/5433 — the class would ship values that are
wrong by default. Keep it as the documented per-session escape hatch it already is.

**D — the connector; a listener only for humans.** `packages/db/src/cloud-sql.ts`
wires `@google-cloud/cloud-sql-connector` into postgres.js, mTLS to `:3307` with an
ephemeral cert, gated on an explicit `DB_IAM_AUTH=1`. **Lane u0 shipped its work this
way** — no proxy, no local port. Where it applies it is strictly better than a shared
listener: nothing squats a port, nothing is inherited, nothing dies on reap.

## Recommendation, if this is picked up again

**B scoped down by D, with the listener on a unix socket rather than TCP.**

The socket is the part that matters and the part most likely to be dropped for
expedience. Because containers share the network namespace but not the mount
namespace, a socket in a host directory bind-mounted only by `tokens.d/gcp.yml` is
reachable *only* by sessions that opted into the token class. That restores exactly
the property the class is supposed to have and that TCP cannot give it.

**A host unit on TCP is a reliability improvement, not a security one.** It changes who
owns the listener, not who can reach it. If the socket work is dropped, ship it as a
reliability fix and attach no security claim to it.

Honest caveats on the socket: the DSN shape changes (`?host=/var/run/cloudsql`), which
touches both `.env` values; `db-target.ts::isLoopbackHost` will not recognise a socket
host, so the TD-195 disposability guard still fails closed but with misleading error
text; and with `--auto-iam-authn` the mount is the entire boundary, with nothing behind
it.

## Mitigations that do not work

- **Firewall rules** — plain iptables/nft cannot discriminate: same namespace, same
  `127.0.0.1` source, same uid 1000. Cgroup matching (`nft socket cgroupv2`) *can*,
  since each container is its own `docker-<id>.scope` and cannot remove the rule
  without `CAP_NET_ADMIN` — but the cgroup path changes every spawn, so `cc-spawn` and
  `cc-stop` would maintain root-owned rules per session, failing open or leaking on a
  missed removal. Feasible, fragile, strictly worse than the socket.
- **"Rely on DB auth instead of reachability"** — backwards for `:5432`. With
  `--auto-iam-authn` there is no DB auth left to rely on.
- **IAM scoping** — real but coarse. Do it regardless: it shrinks the prize rather than
  restoring opt-in.

## Is `network_mode: host` the root cause?

Yes for the sharing; no for the credential sprawl, which was hand-copying.

**Nothing documents why it is there.** The comment above it justifies `ipc: host`
(Chromium crashes under parallel load); the network line carries no rationale at all,
and `host/README.md` documents only its consequence. Somebody who knows should write
it down — you cannot cost a removal you cannot justify.

Moving to per-session network namespaces is a multi-day change across `cc-spawn`,
compose and nginx: dev servers need a port allocator and reverse-proxy wiring to stay
reachable. **The expensive unknown is Tailscale** — sessions inherit the host's tailnet
identity for free today and lose it under bridge networking unless proxied or run
per-container. Check that before promising a migration.

## The strongest argument against the recommendation

B makes the wrong thing permanent. Today's exposure is intermittent and
self-announcing — every proxy dies with its lane and the fleet notices loudly. B
converts that into a standing, boot-persistent, unattended service holding a live SA
key that outlives every session, deploy and rollback, in the same "nobody diffs it"
plane as the `.env`. And once `systemctl status` is green, the pressure to finish D
evaporates: the listener becomes load-bearing, the DSNs stay pointed at loopback, and
the connector path — already written, already tested, already how u0 shipped — stays
behind `DB_IAM_AUTH=0` indefinitely.

The purist end state is **D + C**: no shared plane at all, each session proving its own
credential, humans running their own proxy on their own port. If B is taken, put an
expiry on it here and in `host/README.md`: it exists to serve `psql`, and the app and
test paths are to move off it.

## Why nothing was done

The orphaned listeners are children of u0's container PID 1 and die with it on the
normal reap — no intervention needed. u0 then shipped without them via the connector,
which removed the urgency entirely: the fleet demonstrated it does not need a shared
DB plane for the work it was actually doing. What still needs a listener is `psql` at a
human prompt and `infra/scripts/agri_demo_shared.ts`, which builds its tenant client
from discrete host/port fields and never spreads the connector options.
