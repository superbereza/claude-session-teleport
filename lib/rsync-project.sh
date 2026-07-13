#!/usr/bin/env bash
# rsync-project.sh — copy a project tree between machines.
#
# Usage:
#   rsync-project.sh <src> <dst> [--dry-run] [--delete] [--exclude-from <file>] [--yes]
#
# Size gate: transfers over $RSYNC_CONFIRM_THRESHOLD_MB (default 200 MB) ABORT
# with a per-dir breakdown unless --yes is passed. This forces the agent/user to
# consciously choose scope (often: git clone for tracked files + rsync only the
# gitignored dirs the task needs) instead of silently shipping gigabytes.
#
# <src> and <dst> are rsync-style paths:
#   /local/path/                  — local
#   alias:/remote/path/           — remote via SSH (uses ~/.ssh/config)
#
# Defaults:
#   - INCLUDES: .git/, .env*, dot-files, everything (sensible for handoff)
#   - EXCLUDES: build noise (node_modules, .venv, dist, etc.)
#   - No --delete (so target's extra files survive). Pass --delete explicitly.
#   - Shows a pre-flight summary (du -sh source, git status if applicable).

set -euo pipefail

# ── styled output ─────────────────────────────────────────
if [[ -t 1 ]]; then
  _c_red() { printf '\033[31m%s\033[0m' "$*"; }
  _c_grn() { printf '\033[32m%s\033[0m' "$*"; }
  _c_ylw() { printf '\033[33m%s\033[0m' "$*"; }
  _c_bld() { printf '\033[1m%s\033[0m' "$*"; }
else
  _c_red() { printf '%s' "$*"; }
  _c_grn() { printf '%s' "$*"; }
  _c_ylw() { printf '%s' "$*"; }
  _c_bld() { printf '%s' "$*"; }
fi
step()     { echo; _c_bld ">>> $*"; echo; }
ok()       { _c_grn "✓ $*"; echo; }
warn()     { _c_ylw "⚠ $*"; echo; }
die()      { _c_red "✗ $*" >&2; echo >&2; exit 1; }

# ── Args ──────────────────────────────────────────────────
DRY_RUN=0
DELETE=0
FORCE=0
EXTRA_EXCLUDE_FROM=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --delete)         DELETE=1; shift ;;
    --yes|-y)         FORCE=1; shift ;;
    --exclude-from)   EXTRA_EXCLUDE_FROM="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '/^# rsync-project/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                POSITIONAL+=("$1"); shift ;;
  esac
done

(( ${#POSITIONAL[@]} == 2 )) || die "Usage: rsync-project.sh <src> <dst> [--dry-run] [--delete] [--exclude-from <file>] [--yes]"

SRC="${POSITIONAL[0]}"
DST="${POSITIONAL[1]}"

# Strip trailing slash from sides for cleaner display; we re-add to source
# (rsync semantics: src/ means "contents of src" not "src dir itself").
SRC_DISPLAY="${SRC%/}"
DST_DISPLAY="${DST%/}"
[[ "$SRC" != */ ]] && SRC="${SRC}/"

# ── Default excludes — "build noise" only ────────────────
EXCLUDES=(
  --exclude '.DS_Store'
  --exclude '__pycache__'
  --exclude '*.pyc'
  --exclude '.pytest_cache'
  --exclude 'node_modules'
  --exclude '.venv'
  --exclude 'venv'
  --exclude 'dist'
  --exclude 'build'
  --exclude '.next'
  --exclude '.nuxt'
  --exclude 'target'    # Rust/Java build dir; if you have a top-level "target/" dir of source code, swap to a .handoff-ignore
  --exclude 'out'
  --exclude '.turbo'
  --exclude '.parcel-cache'
)

if [[ -n "$EXTRA_EXCLUDE_FROM" ]]; then
  [[ -f "$EXTRA_EXCLUDE_FROM" ]] || die "exclude-from file not found: $EXTRA_EXCLUDE_FROM"
  EXCLUDES+=(--exclude-from "$EXTRA_EXCLUDE_FROM")
fi

# Auto-detect .handoff-ignore in the source dir (works for local source only).
if [[ "$SRC" != *":"* ]]; then
  HANDOFF_IGNORE="${SRC%/}/.handoff-ignore"
  if [[ -f "$HANDOFF_IGNORE" ]]; then
    EXCLUDES+=(--exclude-from "$HANDOFF_IGNORE")
    ok "Using $HANDOFF_IGNORE for additional excludes"
  fi
fi

# ── Pre-flight summary ───────────────────────────────────
step "Pre-flight"
echo "  Source:  $SRC_DISPLAY"
echo "  Target:  $DST_DISPLAY"
(( DELETE )) && echo "  Mode:    --delete (target's extra files WILL be removed)"
(( DRY_RUN )) && echo "  Mode:    --dry-run (no files written)"

# Source size (best-effort, only for local source)
if [[ "$SRC" != *":"* ]] && [[ -d "$SRC" ]]; then
  local_size=$(du -sh "$SRC" 2>/dev/null | cut -f1 || echo "?")
  echo "  Size:    ~${local_size} (before excludes)"
  # ── Size gate: big transfers need an explicit, informed decision ──
  SIZE_MB=$(du -sm "$SRC" 2>/dev/null | cut -f1 || echo 0)
  THRESHOLD_MB="${RSYNC_CONFIRM_THRESHOLD_MB:-200}"
  if (( SIZE_MB > THRESHOLD_MB )) && (( !FORCE )) && (( !DRY_RUN )); then
    echo
    warn "Size gate: ${SIZE_MB} MB > ${THRESHOLD_MB} MB threshold. Per-dir breakdown:"
    du -sh "${SRC%/}"/*/ 2>/dev/null | sort -rh | head -10 | sed 's/^/    /'
    echo
    die "Large transfer blocked. Show the breakdown to the user and ask what to bring (often: git clone for tracked files + rsync only the needed gitignored dirs). Re-run with --yes once scope is confirmed."
  fi
  # Git state if applicable
  if (cd "$SRC" && git rev-parse --git-dir >/dev/null 2>&1); then
    dirty=$(cd "$SRC" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if (( dirty > 0 )); then
      warn "Source has $dirty uncommitted file(s) — will be transferred as-is."
    else
      ok "Source git tree is clean."
    fi
  fi
fi

# ── Run rsync ────────────────────────────────────────────
RSYNC_OPTS=(-a -P --human-readable)
(( DRY_RUN )) && RSYNC_OPTS+=(--dry-run)
(( DELETE )) && RSYNC_OPTS+=(--delete)

step "rsync"
echo "  rsync ${RSYNC_OPTS[*]} <excludes> $SRC_DISPLAY/ → $DST_DISPLAY"
echo
rsync "${RSYNC_OPTS[@]}" "${EXCLUDES[@]}" "$SRC" "$DST"

echo
if (( DRY_RUN )); then
  ok "Dry-run complete. Re-run without --dry-run to apply."
else
  ok "Transfer complete. Recreate any excluded artifacts on target if needed (e.g. npm install, pip install)."
fi
