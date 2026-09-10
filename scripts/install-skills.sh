#!/usr/bin/env bash
# scripts/install-skills.sh — make ~/.claude/skills/cc-* AND ~/.codex/skills/cc-*
# symlinks to this repo, so the repo is the single source of truth for the fleet
# skills (no drifting copies).
#
# Codex reads its own skills dir. It was linked by hand in Aug and then never
# updated, so it silently missed every skill added afterwards (cc-plan-design,
# cc-plan-notes) — local codex could spawn and supervise but knew nothing about
# the plan protocol. Both agents are managed here now; re-run after adding a skill.
set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.claude/skills" && pwd)"
for DEST in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
mkdir -p "$DEST"
echo "== $DEST"

for src in "$REPO_SKILLS"/cc-*/; do
  name=$(basename "$src")
  dst="$DEST/$name"
  if [[ -L "$dst" && "$(readlink -f "$dst")" == "$(readlink -f "$REPO_SKILLS/$name")" ]]; then
    echo "ok:        $name"
  elif [[ -e "$dst" && ! -L "$dst" ]]; then
    if diff -rq "$dst" "$REPO_SKILLS/$name" >/dev/null 2>&1; then
      rm -rf "$dst"; ln -sn "$REPO_SKILLS/$name" "$dst"; echo "converted: $name (copy was identical)"
    else
      echo "DRIFT:     $name — $dst differs from repo; reconcile manually, then re-run" >&2
    fi
  else
    ln -sfn "$REPO_SKILLS/$name" "$dst"; echo "linked:    $name"
  fi
done

for d in "$DEST"/cc-*; do
  [[ -e "$d" ]] || continue   # no matches -> the literal glob
  [[ -e "$REPO_SKILLS/$(basename "$d")" ]] || echo "UNMANAGED: $d (exists user-level only)"
done
done
