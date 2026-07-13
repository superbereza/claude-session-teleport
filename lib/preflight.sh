#!/usr/bin/env bash
# preflight.sh <project-dir> [<project-dir> ...]
#
# SOURCE-side safety check, run BEFORE a session handoff moves project files.
# Per project it reports git state + "important" gitignored files (anything that
# isn't known build/cache junk) and recommends how to transfer it:
#   clone  — clean, pushed, nothing important ignored → `git clone`/`git pull` on target
#   rsync  — dirty / unpushed / important gitignored files → rsync to keep them
#
# WHY THIS EXISTS: these checks are only possible on the SOURCE, before transfer.
# After the handoff the resumed agent is on the TARGET and can't see the source's
# working tree — skipping this is how uncommitted work, .env files and local DBs
# get silently left behind.
#
# Informational: always exits 0. The caller shows the report; the user decides
# per project (the skill recommends, the human confirms).

set -uo pipefail
[ $# -ge 1 ] || { echo "usage: preflight.sh <project-dir> [<project-dir> ...]" >&2; exit 2; }

# Known-junk gitignore patterns — rebuildable or machine-local, safe to NOT carry.
# Anything ignored that does NOT match this is surfaced for a human decision.
JUNK='(^|/)(\.venv|venv|\.tox|node_modules|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.cache|\.DS_Store|\.idea|\.vscode|dist|build|out|target|\.next|\.nuxt|\.svelte-kit|coverage|\.coverage|htmlcov|.*\.egg-info|.*\.pyc|.*\.pyo|.*\.class|uv\.lock|\.gradle|\.terraform)(/|$)'

for dir in "$@"; do
  printf '\n=== %s ===\n' "$dir"
  if [ ! -d "$dir/.git" ]; then
    echo "  ⚠ not a git repo → rsync if you want it on the target (can't git clone)"
    continue
  fi
  (
    cd "$dir" || exit 0

    dirty=$(git status --porcelain 2>/dev/null)
    important=$(git ls-files --others --ignored --exclude-standard 2>/dev/null | grep -vE "$JUNK" || true)
    ahead=0; upnote=""
    if up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
      ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    else
      up="(none)"; upnote="no upstream branch — nothing to pull from on the target"
    fi

    [ -n "$dirty" ]     && { echo "  UNCOMMITTED:"; echo "$dirty" | sed 's/^/      /'; }
    [ "$ahead" -gt 0 ]  && echo "  UNPUSHED: $ahead commit(s) ahead of $up"
    [ -n "$upnote" ]    && echo "  NOTE: $upnote"
    [ -n "$important" ] && { echo "  GITIGNORED (a git clone would NOT carry these):"; echo "$important" | sed 's/^/      /'; }

    if [ -n "$dirty" ] || [ -n "$important" ] || [ -n "$upnote" ]; then
      echo "  → RECOMMEND: rsync — has local state a git clone would miss"
    elif [ "$ahead" -gt 0 ]; then
      echo "  → RECOMMEND: push first, then clone/pull on target (or rsync the unpushed work)"
    else
      echo "  → RECOMMEND: clone — clean & pushed; git clone/pull on the target is enough"
    fi
  )
done

cat <<'NOTE'

Run this on the SOURCE, before transfer. After --auto-spawn the resumed agent is
on the TARGET and can no longer inspect the source's working tree.
NOTE
