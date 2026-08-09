#!/usr/bin/env bash
# exit-worktree.sh <uuid> — drive a LIVE Claude Code session OUT of its git worktree,
# back to the worktree's originalCwd (the repo root), via the ExitWorktree tool.
#
# WHY THIS EXISTS: a session inside a Claude Code git worktree can't be relocated by file
# surgery — Claude records the worktree state in the transcript (EnterWorktree events) and in
# ~/.claude.json, and on --resume REPLAYS it, re-entering the worktree and overriding any
# launch cwd. The only clean exit is calling ExitWorktree from INSIDE the live session. That
# means driving the live TUI, so it's kept as an explicit, opt-in step — isolated from the
# transfer path (`copy`). Success is verified STRUCTURALLY via /proc/<pid>/cwd, not by scraping
# the TUI, so the fragile part (injecting keys) is bounded by an authoritative check.
#
# After this succeeds, the session's cwd is the repo root; `copy`/`migrate` it from there.
set -uo pipefail

UUID="${1:-}"
[[ -n "$UUID" ]] || { echo "usage: exit-worktree.sh <uuid>" >&2; exit 2; }

# 1. Resolve the LIVE pid + the worktree's originalCwd (structural: state file + ~/.claude.json)
read -r PID WT_ORIG < <(python3 - "$UUID" <<'PYEOF'
import json, os, glob, sys
uuid = sys.argv[1]
pid = ""
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: d = json.load(open(f))
    except Exception: continue
    if d.get("sessionId") == uuid: pid = str(d.get("pid") or "")
orig = ""
try:
    c = json.load(open(os.path.expanduser("~/.claude.json")))
    for proj in (c.get("projects") or {}).values():
        aws = proj.get("activeWorktreeSession") if isinstance(proj, dict) else None
        if isinstance(aws, dict) and aws.get("sessionId") == uuid:
            orig = aws.get("originalCwd") or ""
except Exception: pass
print(pid, orig)
PYEOF
)
[[ -n "$PID" ]] || { echo "✗ no LIVE session for $UUID (~/.claude/sessions/<pid>.json). Resume it first, then retry." >&2; exit 1; }

CUR=$(readlink "/proc/$PID/cwd" 2>/dev/null || true)
if [[ "$CUR" != */.claude/worktrees/* && -z "$WT_ORIG" ]]; then
  echo "✓ session $UUID is not in a worktree (cwd=${CUR:-?}) — nothing to do"; exit 0
fi

# 2. Find the tmux pane running this pid (pid is a descendant of the pane's pane_pid)
PANE=$(python3 - "$PID" <<'PYEOF'
import subprocess, sys
pid = int(sys.argv[1])
def ppid(p):
    try:
        with open(f"/proc/{p}/stat") as fh:
            return int(fh.read().rsplit(") ", 1)[1].split()[1])
    except Exception:
        return 0
out = subprocess.run(["tmux","list-panes","-a","-F","#{pane_id} #{pane_pid}"],
                     capture_output=True, text=True).stdout
panes = {}
for line in out.split("\n"):
    if not line.strip(): continue
    pane, pp = line.split()
    panes[int(pp)] = pane
p = pid
for _ in range(64):
    if p in panes: print(panes[p]); break
    if p <= 1: break
    p = ppid(p)
PYEOF
)
[[ -n "$PANE" ]] || { echo "✗ couldn't find the tmux pane for pid $PID — is the session running under tmux?" >&2; exit 1; }

# 3. Idle-gate, then inject the ExitWorktree instruction (send text, then Enter)
if tmux capture-pane -p -J -t "$PANE" -S -4 2>/dev/null | grep -q 'esc to interrupt'; then
  echo "✗ session is busy (mid-generation) — retry when it's idle" >&2; exit 1
fi
MSG="Call the ExitWorktree tool now to leave the current git worktree and return to the repo root${WT_ORIG:+ ($WT_ORIG)}. This is an intentional relocation requested via claude-teleport. After it completes, run pwd and confirm the new working directory."
tmux send-keys -t "$PANE" "$MSG"; sleep 0.5; tmux send-keys -t "$PANE" Enter
echo "→ asked session $UUID (pane $PANE, pid $PID) to ExitWorktree; verifying via /proc…"

# 4. Wait until /proc cwd leaves the worktree (authoritative), or time out
for _ in $(seq 1 40); do
  sleep 3
  NEW=$(readlink "/proc/$PID/cwd" 2>/dev/null || true)
  if [[ -n "$NEW" && "$NEW" != */.claude/worktrees/* ]]; then
    echo "✓ exited worktree → $NEW"
    echo "  Now relocate it: claude-teleport copy $UUID <target> --target-cwd '$NEW' [--auto-spawn]"
    exit 0
  fi
done
echo "⚠ still in a worktree after ~2min — check the session manually (it may have asked for confirmation)." >&2
exit 1
