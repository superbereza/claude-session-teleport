#!/usr/bin/env bash
# session-copy.sh — copy a Claude Code session (JSONL + memory) to another machine
# with the path rebased correctly (so `claude --resume <uuid>` works on the target).
#
# Usage:
#   session-copy.sh <uuid> <target-alias> [--target-cwd <path>] [--auto-spawn]
#                                          [--source-cwd <path>] [--dry-run]
#
# Defaults:
#   --source-cwd:  inferred from where the JSONL is found on this machine
#   --target-cwd:  source-cwd rebased to the target's home layout
#                  (/Users/<name>/X → /home/<name>/X if target is Linux,
#                   or kept as-is if both are Mac, etc. — best-effort)
#   --auto-spawn:  after copying, spawn a detached tmux session on the target and
#                  run `claude --resume <uuid>` in it (self-contained — no
#                  claude-remote/plugin dependency). Activates /remote-control
#                  by DEFAULT and prints the URL — a handed-off session on a
#                  headless server is useless from phone/browser without it.
#                  Opt out with --no-remote-control. Chat title defaults to the
#                  "<machine>/<dir-under-dev>" convention (shared with the
#                  claude-remote skill), e.g. "my-server/myproject".
#                  After spawn, a handoff briefing is typed into the session so
#                  the resumed agent knows it was moved (see --note; disable
#                  with --no-briefing). Requires on the target: claude (logged
#                  in), tmux, python3 — verified before spawn.
#   --model:       model for the resumed chat. Default = the last real model in
#                  the source JSONL (the model this dialog is currently on).
#   --effort:      effort level for the resumed chat (low|medium|high|xhigh|max).
#                  Default = $CLAUDE_EFFORT of the session running this skill
#                  (effort is not stored per-dialog in the JSONL, so the live
#                  session's effort is the best available signal).
#
# Special target:
#   "localhost"  — treat as a same-machine copy (no SSH). Useful for
#                  source-machine → source-machine moves (different cwds).

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
UUID=""
TARGET=""
SOURCE_CWD=""
TARGET_CWD=""
AUTO_SPAWN=0
DRY_RUN=0
MODE="clone"             # clone (default) | migrate
NEW_UUID=""              # populated for clone mode
REMOTE_CONTROL="on"      # on (default — always activate on auto-spawn) | off
NAME=""                  # base name for tmux session (default: dir under ~/dev)
REMOTE_NAME=""           # chat title (default: "<target>/<dir>" per naming convention)
BRIEFING=1               # type a handoff briefing into the resumed session
NOTE=""                  # extra transfer-specific text appended to the briefing
MODEL=""                 # model for resumed session; default = last model in source JSONL
EFFORT=""                # effort level; default = live $CLAUDE_EFFORT of this session

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-cwd)         TARGET_CWD="${2:-}"; shift 2 ;;
    --source-cwd)         SOURCE_CWD="${2:-}"; shift 2 ;;
    --auto-spawn)         AUTO_SPAWN=1; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --clone)              MODE="clone"; shift ;;
    --migrate)            MODE="migrate"; shift ;;
    --with-remote-control) REMOTE_CONTROL="on"; shift ;;
    --no-remote-control)   REMOTE_CONTROL="off"; shift ;;
    --no-briefing)         BRIEFING=0; shift ;;
    --note)                NOTE="${2:-}"; shift 2 ;;
    --name)                NAME="${2:-}"; shift 2 ;;
    --remote-name)         REMOTE_NAME="${2:-}"; shift 2 ;;
    --model)               MODEL="${2:-}"; shift 2 ;;
    --effort)              EFFORT="${2:-}"; shift 2 ;;
    -h|--help)            sed -n '/^# session-copy/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                   die "Unknown flag: $1" ;;
    *)
      if [[ -z "$UUID" ]]; then UUID="$1"
      elif [[ -z "$TARGET" ]]; then TARGET="$1"
      else die "Unexpected positional arg: $1"
      fi
      shift ;;
  esac
done

[[ -n "$UUID" && -n "$TARGET" ]] || die "Usage: session-copy.sh <uuid> <target-alias> [--name <name>] [--target-cwd <path>] [--clone|--migrate] [--auto-spawn] [--no-remote-control] [--remote-name <title>] [--note <text>] [--no-briefing]"

# ── Find the session JSONL ───────────────────────────────
step "Locating session $UUID"

JSONL=$(find "$HOME/.claude/projects" -maxdepth 2 -type f -name "${UUID}.jsonl" 2>/dev/null | head -1)
[[ -n "$JSONL" ]] || die "Session JSONL not found in ~/.claude/projects/*/${UUID}.jsonl"

SOURCE_DIR=$(dirname "$JSONL")          # ~/.claude/projects/-Users-X-dev
ENCODED=$(basename "$SOURCE_DIR")       # -Users-X-dev

# Claude's dir-name encoding is LOSSY: every non-alphanumeric char becomes "-",
# so "ai-auth-lib" and "ai/auth/lib" produce the SAME dir name. Decoding the dir
# name back to a path is therefore guesswork (this bit us: a decoded cwd of
# .../ai/auth/lib made tmux fall back to $HOME → trust prompt → stuck TUI).
# The authoritative cwd is recorded INSIDE the JSONL on every entry — read it.
# Caveats handled below: (a) entries' cwd CHANGES when the session's shell cd's
# around, (b) a previously-migrated JSONL still carries the old machine's cwd in
# its early entries. Self-consistency check: the right cwd is the one whose
# encoding equals the dir name the JSONL actually lives in — prefer the LAST
# such value; fall back to the last cwd seen at all.
cwd_from_jsonl() {
  python3 - "$1" "$2" <<'PYEOF'
import json, re, sys
path, want_enc = sys.argv[1], sys.argv[2]
enc = lambda s: re.sub(r"[^A-Za-z0-9]", "-", s)
last, last_matching = "", ""
for line in open(path):
    try: d = json.loads(line)
    except Exception: continue
    c = d.get("cwd")
    if not c: continue
    last = c
    if enc(c) == want_enc: last_matching = c
print(last_matching or last)
PYEOF
}

DETECTED_CWD=$(cwd_from_jsonl "$JSONL" "$ENCODED")
[[ -z "$SOURCE_CWD" ]] && SOURCE_CWD="$DETECTED_CWD"
[[ -z "$SOURCE_CWD" ]] && die "could not determine the source cwd (no 'cwd' field in the JSONL) — pass --source-cwd explicitly"

echo "  JSONL:       $JSONL"
echo "  Source cwd:  $SOURCE_CWD"
echo "  Encoded:     $ENCODED"

# ── Detect model + effort to carry over to the resumed chat ──
# Model: the model this dialog is currently on = the last real assistant-message
#        model in the source JSONL (skipping '<synthetic>'). Override via --model.
# Effort: NOT recorded per-dialog in the JSONL. The best available signal is the
#        LIVE effort of the session running this skill — Claude Code exports it to
#        tool subprocesses as $CLAUDE_EFFORT. (Main use case: "migrate myself" — the
#        skill runs inside the very chat being moved, so $CLAUDE_EFFORT is exactly
#        that chat's effort.) Override via --effort.
detect_model() {
  python3 - "$1" <<'PYEOF'
import json, sys
last = ""
for line in open(sys.argv[1]):
    try: d = json.loads(line)
    except Exception: continue
    m = d.get("message")
    if isinstance(m, dict) and d.get("type") == "assistant":
        mod = m.get("model")
        if mod and mod != "<synthetic>":
            last = mod
print(last)
PYEOF
}
[[ -z "$MODEL"  ]] && MODEL=$(detect_model "$JSONL")
[[ -z "$EFFORT" ]] && EFFORT="${CLAUDE_EFFORT:-}"
echo "  Model:       ${MODEL:-<account default>}"
echo "  Effort:      ${EFFORT:-<account default>}"

# ── Decide target cwd ────────────────────────────────────
if [[ -z "$TARGET_CWD" ]]; then
  if [[ "$SOURCE_CWD" =~ ^/Users/([^/]+)(.*)$ ]]; then
    TARGET_CWD="/home/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  else
    TARGET_CWD="$SOURCE_CWD"
  fi
fi

# Resolve symlinks in the target cwd — claude encodes the RESOLVED path of its
# cwd, so an unresolved one breaks --resume lookup (classic: macOS /tmp is a
# symlink to /private/tmp — the copied JSONL lands in -tmp-... while claude
# looks in -private-tmp-...). If the dir doesn't exist yet, keep as given.
if [[ "$TARGET" == "localhost" ]]; then
  RESOLVED_CWD=$(cd "$TARGET_CWD" 2>/dev/null && pwd -P || true)
else
  RESOLVED_CWD=$(ssh "$TARGET" "cd '$TARGET_CWD' 2>/dev/null && pwd -P" 2>/dev/null || true)
fi
if [[ -n "$RESOLVED_CWD" && "$RESOLVED_CWD" != "$TARGET_CWD" ]]; then
  warn "target cwd is behind a symlink — using the resolved path: $RESOLVED_CWD"
  TARGET_CWD="$RESOLVED_CWD"
fi

# Encode target cwd into the dir-name claude expects. Claude's real scheme:
# EVERY non-alphanumeric char → "-" (no escaping; verified empirically:
# /Users/x/dev/ai-auth-lib → -Users-x-dev-ai-auth-lib). Lossy by design —
# that's fine for encoding; never try to reverse it (see cwd_from_jsonl).
encode_cwd() {
  local cwd="$1"
  python3 - "$cwd" <<'PYEOF'
import re, sys
print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))
PYEOF
}

TARGET_ENCODED=$(encode_cwd "$TARGET_CWD")

# ── Compute effective UUID (NEW for clone, SAME for migrate) ─────
EFFECTIVE_UUID="$UUID"
if [[ "$MODE" == "clone" ]]; then
  NEW_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  EFFECTIVE_UUID="$NEW_UUID"
fi

step "Plan"
echo "  Mode:            $MODE"
[[ "$MODE" == "clone" ]] && echo "  Source UUID:     $UUID  →  NEW UUID: $NEW_UUID"
[[ "$MODE" == "migrate" ]] && echo "  UUID (preserved): $UUID"
echo "  Target machine:  $TARGET"
echo "  Target cwd:      $TARGET_CWD"
# NB: display with literal "~" — the dir lives on the TARGET, whose home we
# don't know here (substituting the SOURCE's $HOME printed Frankenstein paths
# like /Users/<me>/.claude/... "(on target)" for a Linux target).
echo "  Target dir:      ~/.claude/projects/${TARGET_ENCODED}  (on target)"
echo "  Auto-spawn:      $([[ $AUTO_SPAWN == 1 ]] && echo 'yes — self-contained tmux + claude --resume' || echo 'no — just print resume cmd')"
(( DRY_RUN )) && echo "  Mode:            --dry-run"
if [[ "$MODE" == "migrate" ]]; then
  warn "MIGRATE: source and target will share the same UUID."
  warn "  Claude's per-account session registry treats UUID as global."
  warn "  Activating /remote-control on target may disconnect the source."
fi
if [[ "$MODE" == "clone" ]]; then
  ok "CLONE: target gets a fresh UUID + stripped bridge state — source unaffected."
fi

# ── Confirm ──────────────────────────────────────────────
if (( !DRY_RUN )) && [[ -t 0 ]]; then
  read -rp "Proceed? [y/N] " yn
  [[ "$yn" =~ ^[Yy] ]] || die "Aborted"
fi

# ── Prepare the JSONL to ship ────────────────────────────
# For clone: rewrite sessionId throughout + strip bridge-session entries.
# For migrate: ship as-is.
STAGED_JSONL=""
TMP_TO_CLEAN=""
if [[ "$MODE" == "clone" ]]; then
  step "Rewriting sessionId + stripping bridge state for clone"
  STAGED_JSONL=$(mktemp -t handoff-jsonl)
  TMP_TO_CLEAN="$STAGED_JSONL"
  python3 - "$JSONL" "$UUID" "$NEW_UUID" > "$STAGED_JSONL" <<'PYEOF'
import json, sys
src, old_uuid, new_uuid = sys.argv[1], sys.argv[2], sys.argv[3]
kept = 0
dropped_bridge = 0
with open(src) as f:
    for line in f:
        # Try parse to filter & clean
        try:
            d = json.loads(line)
            if d.get("type") == "bridge-session":
                dropped_bridge += 1
                continue
            if d.get("type") == "system" and d.get("subtype") == "bridge_status":
                dropped_bridge += 1
                continue
            if "bridgeSessionId" in d:
                del d["bridgeSessionId"]
            out = json.dumps(d, ensure_ascii=False) + "\n"
        except json.JSONDecodeError:
            out = line if line.endswith("\n") else line + "\n"
        # Plain string replace catches sessionId AND any other UUID references
        out = out.replace(old_uuid, new_uuid)
        sys.stdout.write(out)
        kept += 1
sys.stderr.write(f"  kept {kept} lines, dropped {dropped_bridge} bridge entries\n")
PYEOF
  ok "Rewritten: $(wc -l < "$STAGED_JSONL" | tr -d ' ') lines"
else
  STAGED_JSONL="$JSONL"
fi

# ── Copy JSONL + memory ──────────────────────────────────
step "Copying session files"

# Files to ship: the (possibly-rewritten) JSONL + the memory dir if present.
# In clone mode the JSONL must be renamed to use the NEW UUID on target.
[[ -d "$SOURCE_DIR/memory" ]] && HAVE_MEMORY=1 || HAVE_MEMORY=0

# Target JSONL filename always uses the EFFECTIVE UUID (NEW for clone, same for migrate).
TARGET_JSONL_NAME="${EFFECTIVE_UUID}.jsonl"

if [[ "$TARGET" == "localhost" ]]; then
  # Same-machine copy (different cwd)
  LOCAL_TARGET="$HOME/.claude/projects/${TARGET_ENCODED}"
  if (( DRY_RUN )); then
    echo "  [dry-run] mkdir -p $LOCAL_TARGET"
    echo "  [dry-run] cp $STAGED_JSONL → $LOCAL_TARGET/$TARGET_JSONL_NAME"
    (( HAVE_MEMORY )) && echo "  [dry-run] cp -r $SOURCE_DIR/memory → $LOCAL_TARGET/"
  else
    mkdir -p "$LOCAL_TARGET"
    cp "$STAGED_JSONL" "$LOCAL_TARGET/$TARGET_JSONL_NAME"
    echo "  copied: $TARGET_JSONL_NAME"
    if (( HAVE_MEMORY )); then
      cp -r "$SOURCE_DIR/memory" "$LOCAL_TARGET/"
      echo "  copied: memory"
    fi
  fi
else
  # SSH target — ensure remote dir, then rsync
  REMOTE_MKDIR="mkdir -p \"\$HOME/.claude/projects/${TARGET_ENCODED}\""
  RSYNC_OPTS=(-a -P)
  (( DRY_RUN )) && RSYNC_OPTS+=(--dry-run)

  if (( !DRY_RUN )); then
    ssh "$TARGET" "$REMOTE_MKDIR" || die "Failed to create remote dir"
  else
    echo "  [dry-run] ssh $TARGET '$REMOTE_MKDIR'"
  fi

  if (( DRY_RUN )); then
    echo "  [dry-run] rsync $STAGED_JSONL → ${TARGET}:~/.claude/projects/${TARGET_ENCODED}/${TARGET_JSONL_NAME}"
    (( HAVE_MEMORY )) && echo "  [dry-run] rsync $SOURCE_DIR/memory → ${TARGET}:~/.claude/projects/${TARGET_ENCODED}/"
  else
    rsync "${RSYNC_OPTS[@]}" "$STAGED_JSONL" \
      "${TARGET}:~/.claude/projects/${TARGET_ENCODED}/${TARGET_JSONL_NAME}"
    echo "  copied: $TARGET_JSONL_NAME"
    if (( HAVE_MEMORY )); then
      rsync "${RSYNC_OPTS[@]}" "$SOURCE_DIR/memory" \
        "${TARGET}:~/.claude/projects/${TARGET_ENCODED}/"
      echo "  copied: memory"
    fi
  fi
fi

# Cleanup staged temp file
[[ -n "$TMP_TO_CLEAN" ]] && rm -f "$TMP_TO_CLEAN"

(( DRY_RUN )) && { ok "Dry-run complete."; exit 0; }
ok "Session files copied"

# ── Auto-spawn: self-contained (no claude-remote dependency) ─────
# Spawns a detached tmux session with `claude --resume <uuid>` directly.
# Does NOT depend on the claude-remote skill or any plugin wrapper.
# Only requires: claude binary on target + tmux + python3 (for pre-trust).

# Find claude on target — multiple known install locations.
find_claude() {
  local where="$1"
  if [[ "$where" == "localhost" ]]; then
    command -v claude 2>/dev/null \
      || ls "$HOME"/.npm-global/bin/claude 2>/dev/null \
      || ls "$HOME"/.local/bin/claude 2>/dev/null \
      || ls /usr/local/bin/claude 2>/dev/null \
      || true
  else
    ssh "$where" '
      command -v claude 2>/dev/null \
        || ls "$HOME"/.npm-global/bin/claude 2>/dev/null \
        || ls "$HOME"/.local/bin/claude 2>/dev/null \
        || ls /usr/local/bin/claude 2>/dev/null \
        || true
    '
  fi | head -1
}

# Pre-trust the cwd in ~/.claude.json + pre-accept bypass-permissions in settings.json.
# So `claude --dangerously-skip-permissions --resume` doesn't pause on dialogs.
preflight_claude() {
  local where="$1" cwd="$2"
  local script
  script=$(cat <<PY
import json, os
# 1. settings.json: bypass-permissions pre-accept
sp = os.path.expanduser('~/.claude/settings.json')
os.makedirs(os.path.dirname(sp), exist_ok=True)
try:
    with open(sp) as f: sd = json.load(f)
except Exception:
    sd = {}
sd['bypassPermissionsModeAccepted'] = True
with open(sp, 'w') as f: json.dump(sd, f, indent=2)

# 2. ~/.claude.json: trust the target cwd
cp = os.path.expanduser('~/.claude.json')
try:
    with open(cp) as f: cfg = json.load(f)
except Exception:
    cfg = {'projects': {}}
projs = cfg.setdefault('projects', {})
entry = projs.setdefault('$cwd', {})
entry['hasTrustDialogAccepted'] = True
for k, v in {
    'allowedTools': [], 'mcpContextUris': [], 'mcpServers': {},
    'enabledMcpjsonServers': [], 'disabledMcpjsonServers': [],
    'projectOnboardingSeenCount': 0,
    'hasClaudeMdExternalIncludesApproved': False,
    'hasClaudeMdExternalIncludesWarningShown': False,
    'exampleFiles': [],
}.items():
    entry.setdefault(k, v)
with open(cp, 'w') as f: json.dump(cfg, f, indent=2)
PY
)
  if [[ "$where" == "localhost" ]]; then
    python3 -c "$script"
  else
    ssh "$where" "python3 -c \"$(printf '%s' "$script" | sed 's/"/\\"/g')\""
  fi
}

# Spawn detached tmux session with claude --resume.
spawn_resumed() {
  local where="$1" cwd="$2" uuid="$3" tmux_name="$4" extra="${5:-}"

  # SSH reachability FIRST — otherwise every later check lies ("claude missing"
  # when the truth is "can't reach the target at all", e.g. a poisoned DNS alias
  # resolving to a fake 198.18.x.x, tailscale down, wrong port...).
  if [[ "$where" != "localhost" ]]; then
    local ssh_err
    if ! ssh_err=$(ssh -o ConnectTimeout=12 -o BatchMode=yes "$where" 'echo REACHABLE' 2>&1) \
       || ! grep -q REACHABLE <<<"$ssh_err"; then
      die "cannot ssh to '$where' — real error: ${ssh_err:-<empty>}. Fix connectivity first (right alias/IP? tailscale up? check-mode approval pending?), then retry."
    fi
  fi

  local claude_path
  claude_path=$(find_claude "$where")
  [[ -z "$claude_path" ]] && die "claude binary not found on $where (looked in PATH, ~/.npm-global/bin, ~/.local/bin, /usr/local/bin). Install Claude Code on the target first (see the claude-code-setup skill)."

  # Target prerequisites beyond the binary. tmux + python3 are hard requirements
  # (the spawn and pre-trust need them). A logged-in claude is required to
  # actually resume — checked via ~/.claude/.credentials.json, but only WARNED:
  # on macOS the creds may live in the Keychain, so the file can be legitimately
  # absent. On a Linux server its absence almost always means "not logged in".
  local prereq_script='
    miss=""
    command -v tmux    >/dev/null 2>&1 || miss="$miss tmux"
    command -v python3 >/dev/null 2>&1 || miss="$miss python3"
    echo "MISSING:$miss"
    [ -f "$HOME/.claude/.credentials.json" ] && echo "LOGIN:ok" || echo "LOGIN:absent"
  '
  local prereq miss
  if [[ "$where" == "localhost" ]]; then prereq=$(bash -c "$prereq_script"); else prereq=$(ssh "$where" "$prereq_script"); fi
  miss=$(printf '%s\n' "$prereq" | sed -n 's/^MISSING://p')
  [[ -n "${miss// /}" ]] && die "target '$where' is missing for --auto-spawn:$miss — install them on the target, then retry."
  if printf '%s\n' "$prereq" | grep -q '^LOGIN:absent'; then
    warn "no ~/.claude/.credentials.json on '$where' — if claude isn't logged in there, the resumed session won't start. (macOS: creds may be in the Keychain — ignore. Linux server: run \`claude\` there once to log in.)"
  fi

  preflight_claude "$where" "$cwd"

  local spawn_cmd="tmux new-session -d -s '$tmux_name' -c '$cwd' && tmux send-keys -t '$tmux_name' '$claude_path --dangerously-skip-permissions --resume $uuid$extra' Enter"

  if [[ "$where" == "localhost" ]]; then
    bash -c "$spawn_cmd"
  else
    ssh "$where" "$spawn_cmd"
  fi
}

# Remote-control is ON by default (a handed-off session on a headless server is
# useless from the user's phone/browser without it). --no-remote-control opts out.

# Naming defaults — convention shared with the claude-remote skill:
#   tmux session:  cc—<dir-under-dev>          (e.g. cc—myproject)
#   chat title:    <machine>/<dir-under-dev>   (e.g. my-server/myproject)
# The machine prefix is what distinguishes the handed-off chat from its
# still-living source in the claude.ai session list.
#   --name <X>            → tmux session "cc—<X>"
#   --remote-name <Y>     → overrides chat title (keep the machine prefix!)
CWD_BASE=$(basename "$TARGET_CWD")
TITLE_HOST="$TARGET"
[[ "$TARGET" == "localhost" ]] && TITLE_HOST=$(hostname -s 2>/dev/null || echo localhost)
[[ -z "$NAME" ]] && NAME="$CWD_BASE"
[[ -z "$REMOTE_NAME" ]] && REMOTE_NAME="${TITLE_HOST}/${CWD_BASE}"
if [[ "$REMOTE_NAME" != */* ]]; then
  warn "chat title '$REMOTE_NAME' has no '<machine>/' prefix — without it the handed-off chat is indistinguishable from its source in the claude.ai list (convention: ${TITLE_HOST}/${CWD_BASE})"
fi

# Build the extra `claude` args (model/effort) once — note each fragment starts
# with a leading space so it appends cleanly after the resume UUID.
EXTRA_ARGS=""
[[ -n "$MODEL"  ]] && EXTRA_ARGS+=" --model $MODEL"
[[ -n "$EFFORT" ]] && EXTRA_ARGS+=" --effort $EFFORT"

# Activate /remote-control inside a spawned tmux pane.
# Self-contained: poll for TUI ready, send /remote-control, auto-confirm prompt,
# poll for URL. ~30 lines, no external dependency.
activate_remote_control() {
  local where="$1" tmux_name="$2" rc_name="$3"
  local URL_TIMEOUT=30 POLL_INT=0.5

  local capture_cmd send_cmd
  if [[ "$where" == "localhost" ]]; then
    capture_cmd() { tmux capture-pane -p -J -t "$1" -S -200 2>/dev/null || true; }
    send_cmd() { tmux send-keys -t "$1" "$2" "$3"; }
  else
    capture_cmd() { ssh "$where" "tmux capture-pane -p -J -t '$1' -S -200" 2>/dev/null || true; }
    send_cmd() { ssh "$where" "tmux send-keys -t '$1' '$2' '$3'"; }
  fi

  # Wait for "bypass permissions on" — TUI is ready
  local ready=0
  for _ in $(seq 1 80); do
    if capture_cmd "$tmux_name" | grep -q 'bypass permissions on'; then
      ready=1; break
    fi
    sleep 0.5
  done
  if (( !ready )); then
    warn "claude TUI didn't become ready in 40s — pane tail follows (so you don't have to capture it by hand):"
    capture_cmd "$tmux_name" | tail -25 | sed 's/^/  │ /'
    return 1
  fi

  # Send /remote-control <name>
  send_cmd "$tmux_name" "/remote-control $rc_name" Enter

  # Poll for URL OR for the "Enable Remote Control" prompt
  local url="" confirmed=0
  local iters
  iters=$(awk -v t="$URL_TIMEOUT" -v s="$POLL_INT" 'BEGIN{print int(t/s)}')
  for _ in $(seq 1 "$iters"); do
    local pane
    pane=$(capture_cmd "$tmux_name")
    # Auto-confirm one-time "Enable Remote Control" prompt (default option)
    if (( !confirmed )) && printf '%s' "$pane" | grep -q 'Enable Remote Control'; then
      send_cmd "$tmux_name" Enter ""
      confirmed=1
      sleep 0.5
      continue
    fi
    url=$(printf '%s' "$pane" | grep -oE 'https://claude\.ai/code[/?][A-Za-z0-9._~:/?#@!$&+=%-]+' | tail -1 || true)
    [[ -n "$url" ]] && break
    sleep "$POLL_INT"
  done

  if [[ -n "$url" ]]; then
    echo "URL:    $url"
    return 0
  else
    warn "remote-control URL didn't appear within ${URL_TIMEOUT}s — pane tail follows (so you don't have to capture it by hand):"
    capture_cmd "$tmux_name" | tail -25 | sed 's/^/  │ /'
    return 1
  fi
}

# Watch the freshly spawned pane and auto-confirm startup prompts. Belt & braces:
# pre-trust SHOULD prevent the "trust this folder" dialog, but a cwd mismatch or
# a new claude version can still surface it — and it blocks the TUI forever
# (this is exactly how a past handoff got stuck: wrong cwd → trust prompt →
# remote-control timeout). Returns once the TUI looks ready or after ~30s.
auto_confirm_startup() {
  local where="$1" tmux_name="$2"
  local pane
  for _ in $(seq 1 30); do
    if [[ "$where" == "localhost" ]]; then
      pane=$(tmux capture-pane -p -t "$tmux_name" 2>/dev/null || true)
    else
      pane=$(ssh "$where" "tmux capture-pane -p -t '$tmux_name'" 2>/dev/null || true)
    fi
    if printf '%s' "$pane" | grep -qiE 'trust this folder|do you trust'; then
      warn "trust-folder prompt appeared (pre-trust should have prevented it) — auto-confirming"
      if [[ "$where" == "localhost" ]]; then tmux send-keys -t "$tmux_name" Enter
      else ssh "$where" "tmux send-keys -t '$tmux_name' Enter"; fi
      sleep 1; continue
    fi
    printf '%s' "$pane" | grep -q 'bypass permissions on' && return 0
    sleep 1
  done
  warn "TUI not confirmed ready after 30s — current pane tail (informational):"
  printf '%s\n' "$pane" | tail -20 | sed 's/^/  │ /'
  return 0   # informational watcher — never fail the handoff
}

# Read the tail of the spawned pane (shared helper for briefing ack etc.)
pane_tail() {
  local where="$1" tmux_name="$2" lines="${3:-15}"
  if [[ "$where" == "localhost" ]]; then
    tmux capture-pane -p -J -t "$tmux_name" -S -200 2>/dev/null | tail -"$lines" || true
  else
    ssh "$where" "tmux capture-pane -p -J -t '$tmux_name' -S -200" 2>/dev/null | tail -"$lines" || true
  fi
}

# Type the handoff briefing into the resumed session (-l = literal, no key parsing).
send_briefing() {
  local where="$1" tmux_name="$2" text="$3"
  local q
  q=$(printf '%q' "$text")
  if [[ "$where" == "localhost" ]]; then
    tmux send-keys -t "$tmux_name" -l "$text"
    sleep 1
    tmux send-keys -t "$tmux_name" Enter
  else
    ssh "$where" "tmux send-keys -t '$tmux_name' -l $q && sleep 1 && tmux send-keys -t '$tmux_name' Enter"
  fi
}

if (( AUTO_SPAWN )); then
  TMUX_NAME="cc—${NAME}"
  # Exact-name collision guard ("=name" = exact match; bare -t matches prefixes)
  if { [[ "$TARGET" == "localhost" ]] && tmux has-session -t "=$TMUX_NAME" 2>/dev/null; } \
     || { [[ "$TARGET" != "localhost" ]] && ssh "$TARGET" "tmux has-session -t '=$TMUX_NAME'" 2>/dev/null; }; then
    warn "tmux session '$TMUX_NAME' already exists on target — suffixing with the session uuid"
    TMUX_NAME="cc—${NAME}-${EFFECTIVE_UUID:0:8}"
  fi
  step "Spawning detached tmux session on target ($TMUX_NAME)"
  spawn_resumed "$TARGET" "$TARGET_CWD" "$EFFECTIVE_UUID" "$TMUX_NAME" "$EXTRA_ARGS"
  auto_confirm_startup "$TARGET" "$TMUX_NAME"
  ok "spawned: $TMUX_NAME"

  if [[ "$REMOTE_CONTROL" == "on" ]]; then
    step "Activating /remote-control on target (chat title: $REMOTE_NAME)"
    activate_remote_control "$TARGET" "$TMUX_NAME" "$REMOTE_NAME" || true
  fi

  if (( BRIEFING )); then
    step "Sending handoff briefing into the resumed session"
    [[ "$MODE" == "clone" ]] && VERB="cloned" || VERB="migrated"
    SRC_HOST=$(hostname -s 2>/dev/null || hostname)
    BRIEF="[handoff] Automated notice from the source machine (${SRC_HOST}). This session was ${VERB} to ${TITLE_HOST} — you are now running there, cwd: ${TARGET_CWD}."
    if [[ "$MODE" == "clone" ]]; then
      BRIEF+=" The original session on the source machine keeps living and may continue in parallel — commit and push your changes so the two do not diverge."
    else
      BRIEF+=" This was a migrate: the source session is retired, you are the primary continuation."
    fi
    BRIEF+=" Source-machine-specific MCP servers (Gmail/Drive/Calendar etc.) do not work here."
    [[ -n "$NOTE" ]] && BRIEF+=" Transfer notes: ${NOTE}."
    BRIEF+=" Acknowledge briefly, sanity-check the project folder, then wait for the user."
    send_briefing "$TARGET" "$TMUX_NAME" "$BRIEF"
    # Give the resumed agent a moment to acknowledge, then show the pane tail
    # so the operator SEES the briefing landed (not just trusts it did).
    sleep 25
    echo "  Pane tail after briefing (verify the agent acknowledged):"
    pane_tail "$TARGET" "$TMUX_NAME" 12 | sed 's/^/  │ /'
  fi

  echo
  echo "ATTACH locally:"
  if [[ "$TARGET" == "localhost" ]]; then
    echo "  tmux attach -t '$TMUX_NAME'"
  else
    echo "  ssh $TARGET 'tmux attach -t \"$TMUX_NAME\"'"
  fi
  if [[ "$REMOTE_CONTROL" != "on" ]]; then
    echo
    echo "FOR remote-control URL (mobile/browser access):"
    echo "  attach to the tmux session and type: /remote-control [name]"
  fi
else
  echo
  echo "Resume on target ($MODE):"
  if [[ "$TARGET" == "localhost" ]]; then
    echo "  cd $TARGET_CWD && claude --resume $EFFECTIVE_UUID$EXTRA_ARGS"
  else
    echo "  ssh $TARGET 'cd $TARGET_CWD && claude --resume $EFFECTIVE_UUID$EXTRA_ARGS'"
    echo "Or with --auto-spawn flag: spawns a detached tmux session for you."
  fi
fi
