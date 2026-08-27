#!/usr/bin/env bash
# host/deploy.sh — deploy the cc-host control plane from this git checkout.
#
# Runs ON cc-host, from a checkout of cc-dispatch (e.g. /opt/cc-releases/repo).
#   deploy.sh            deploy HEAD: validate -> stage release -> switch -> smoke
#   deploy.sh --check    drift report (repo vs live), exit 1 on drift
#   deploy.sh --rollback switch back to the previous release (+ smoke)
#   deploy.sh --list     list releases and what is currently live
#
# Managed surfaces:
#   host/bin/*                 -> /usr/local/bin/* (symlinks through releases/current)
#   host/sessions/*            -> /opt/cc-sessions/{docker-compose.yml,Dockerfile,
#                                 CC-CONTAINER.md,tokens.d} (symlinks through current)
#   host/fleet/CLAUDE.md.tmpl  -> managed region of CLAUDE.md in the cc-auth volume
#   host/crontab.snippet       -> managed block of veri's crontab
# NOT managed (see README.md): /opt/cc-sessions/.env, ~/.ssh, docker volumes,
#   agent-deck config, /opt/cc-notes, /opt/cc-data.
set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SHA=$(git -C "$HOST_DIR" rev-parse --short HEAD 2>/dev/null || echo unversioned)
RELEASES=/opt/cc-releases
CURRENT="$RELEASES/current"
BIN_DIR=/usr/local/bin
SESSIONS=/opt/cc-sessions
SPAWN_LOCK=/opt/cc-data/spawn.lock
AUTH_VOL=cc-sessions_cc-auth
MARK_S='<!-- cc-managed:start (host/fleet/CLAUDE.md.tmpl — edit in git, deploy via host/deploy.sh) -->'
MARK_E='<!-- cc-managed:end -->'
CRON_S='# cc-managed:start (host/crontab.snippet — edit in git, deploy via host/deploy.sh)'
CRON_E='# cc-managed:end'
SESSION_FILES=(docker-compose.yml Dockerfile CC-CONTAINER.md)

die(){ echo "ERROR: $*" >&2; exit 1; }
note(){ echo "→ $*"; }

# ln that falls back to sudo -n (some targets/dirs are root-owned)
xln(){ ln -sfn "$1" "$2" 2>/dev/null || sudo -n ln -sfn "$1" "$2" || die "cannot link $2"; }

live_claude(){ docker run --rm -v "$AUTH_VOL":/v cc-session:latest sh -c 'cat /v/CLAUDE.md' 2>/dev/null; }

# strip a marker-delimited region (fixed-string match) from stdin
strip_region(){ awk -v s="$1" -v e="$2" 'index($0,s){f=1} !f{print} index($0,e){f=0}'; }

render_claude(){  # desired full CLAUDE.md on stdout
  { live_claude \
      | strip_region "$MARK_S" "$MARK_E" \
      | strip_region '<!-- plan-notes-directive' 'plan-notes-directive -->' \
      | strip_region '<!-- graphify-fleet-directive' 'graphify-fleet-directive -->'
    echo "$MARK_S"
    cat "$HOST_DIR/fleet/CLAUDE.md.tmpl"
    echo "$MARK_E"
  } | cat -s
}

render_cron(){  # desired full crontab on stdout
  { crontab -l 2>/dev/null \
      | strip_region "$CRON_S" "$CRON_E" \
      | grep -vxF -f "$HOST_DIR/crontab.snippet" || true
    echo "$CRON_S"
    cat "$HOST_DIR/crontab.snippet"
    echo "$CRON_E"
  } | sed '/./,$!d'
}

check(){
  local drift=0 f b
  for f in "$HOST_DIR"/bin/*; do
    b=$(basename "$f")
    if [[ ! -e "$BIN_DIR/$b" ]]; then echo "DRIFT: $BIN_DIR/$b missing"; drift=1
    elif ! diff -q "$f" "$BIN_DIR/$b" >/dev/null 2>&1; then echo "DRIFT: $BIN_DIR/$b differs"; drift=1; fi
  done
  for b in "$BIN_DIR"/cc-*; do
    [[ -e "$HOST_DIR/bin/$(basename "$b")" ]] || echo "UNMANAGED: $b"
  done
  for f in "${SESSION_FILES[@]}"; do
    diff -q "$HOST_DIR/sessions/$f" "$SESSIONS/$f" >/dev/null 2>&1 || { echo "DRIFT: $SESSIONS/$f"; drift=1; }
  done
  for f in "$HOST_DIR"/sessions/tokens.d/*.yml; do
    b=$(basename "$f")
    diff -q "$f" "$SESSIONS/tokens.d/$b" >/dev/null 2>&1 || { echo "DRIFT: $SESSIONS/tokens.d/$b"; drift=1; }
  done
  diff <(live_claude) <(render_claude) >/dev/null 2>&1 || { echo "DRIFT: fleet CLAUDE.md managed region"; drift=1; }
  diff <(crontab -l 2>/dev/null) <(render_cron) >/dev/null 2>&1 || { echo "DRIFT: crontab managed block"; drift=1; }
  if [[ $drift -eq 0 ]]; then echo "OK: no drift ($REPO_SHA)"; fi
  return $drift
}

validate(){
  local f
  for f in "$HOST_DIR"/bin/*; do
    case "$(head -1 "$f")" in
      *bash*)    bash -n "$f" || die "syntax: $f" ;;
      *python3*) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || die "syntax: $f" ;;
      *)         die "unknown interpreter in $f" ;;
    esac
  done
  local cfg
  cfg=$(SESSION_NAME=validate REPO_DIR=/tmp WORKTREE_PATH=/tmp \
        docker compose -f "$HOST_DIR/sessions/docker-compose.yml" config 2>/dev/null) \
    || die "docker compose config failed"
  grep -q 'com.fractional.cc-fleet' <<<"$cfg" || die "rendered compose lacks fleet label"
  grep -q 'mem_limit: "4294967296"' <<<"$cfg" || die "rendered compose default mem_limit is not 4g"
  if grep -qE 'VERCEL|RAILWAY|SUPABASE' <<<"$cfg"; then die "deploy tokens leaked into default compose"; fi
  [[ -n "$(live_claude)" ]] || die "cannot read fleet CLAUDE.md (docker/volume problem)"
  note "validation ok"
}

switch_to(){  # $1 = release dir; symlink switch under the spawn lock, then live-state deploy
  local rel="$1"
  exec 9>"$SPAWN_LOCK"; flock -w 60 9 || die "spawn lock timeout"
  ln -sfn "$rel" "$RELEASES/.next" && mv -T "$RELEASES/.next" "$CURRENT"
  local f b
  for f in "$rel"/bin/*; do b=$(basename "$f"); xln "$CURRENT/bin/$b" "$BIN_DIR/$b"; done
  for f in "${SESSION_FILES[@]}"; do
    [[ -e "$SESSIONS/$f" && ! -L "$SESSIONS/$f" ]] && mv "$SESSIONS/$f" "$SESSIONS/$f.pre-release"
    xln "$CURRENT/sessions/$f" "$SESSIONS/$f"
  done
  if [[ -d "$SESSIONS/tokens.d" && ! -L "$SESSIONS/tokens.d" ]]; then mv "$SESSIONS/tokens.d" "$SESSIONS/tokens.d.pre-release"; fi
  xln "$CURRENT/sessions/tokens.d" "$SESSIONS/tokens.d"
  flock -u 9
  render_claude | docker run --rm -i -v "$AUTH_VOL":/v cc-session:latest sh -c 'cat > /v/CLAUDE.md'
  render_cron | crontab -
}

smoke(){
  if cc-spawn >/dev/null 2>&1; then die "smoke: cc-spawn with no args should fail with usage"; fi
  local out=""
  if out=$(CC_ADMIT_GB=1 cc-spawn smoke-nonexistent-repo smoke-branch 2>&1); then
    die "smoke: admission should have refused (CC_ADMIT_GB=1)"
  fi
  grep -q "exceeds" <<<"$out" || die "smoke: admission refusal missing budget message: $out"
  ( cd "$SESSIONS" && SESSION_NAME=smoke REPO_DIR=/tmp WORKTREE_PATH=/tmp docker compose config -q ) \
    || die "smoke: live compose config failed"
  note "smoke ok"
}

deploy(){
  [[ -d "$RELEASES" ]] || sudo -n install -d -o "$(id -un)" -g "$(id -gn)" "$RELEASES" || die "cannot create $RELEASES"
  validate
  local rel="$RELEASES/$(date +%Y%m%d-%H%M%S)-$REPO_SHA"
  mkdir -p "$rel"
  cp -r "$HOST_DIR/bin" "$HOST_DIR/sessions" "$rel/"
  chmod +x "$rel"/bin/*
  local prev=""; [[ -L "$CURRENT" ]] && prev=$(readlink -f "$CURRENT")
  switch_to "$rel"
  { echo "sha: $REPO_SHA"; echo "date: $(date -u +%FT%TZ)"; echo "by: $(id -un)@$(hostname)"; echo "prev: ${prev:-none}"; } > "$rel/DEPLOYED"
  if ! smoke; then
    if [[ -n "$prev" ]]; then note "smoke FAILED — rolling back to $prev"; switch_to "$prev"; fi
    die "deploy failed smoke; rolled back"
  fi
  note "deployed $rel"
}

rollback(){
  [[ -L "$CURRENT" ]] || die "no current release"
  local prev
  prev=$(sed -n 's/^prev: //p' "$CURRENT/DEPLOYED" 2>/dev/null)
  [[ -n "$prev" && -d "$prev" && "$prev" != "none" ]] || die "no previous release recorded"
  switch_to "$prev"
  smoke
  note "rolled back to $prev"
}

case "${1:-deploy}" in
  --check)    check ;;
  --rollback) rollback ;;
  --list)     ls -1t "$RELEASES" 2>/dev/null | grep -v '^repo$' || true; echo "current -> $(readlink -f "$CURRENT" 2>/dev/null || echo none)"; cat "$CURRENT/DEPLOYED" 2>/dev/null || true ;;
  deploy|--deploy) deploy ;;
  *) die "usage: deploy.sh [--check|--rollback|--list|deploy]" ;;
esac
