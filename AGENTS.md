# claude-session-teleport — agent guide

Move a live Claude Code chat session — plus, optionally, the project it's about —
between machines. The chat arrives resumable, respawned in tmux with Remote
Control ON, a convention-named title (`<machine>/<dir>`), and a handoff briefing
typed in so the resumed agent knows it moved.

The skill is wired up for several coding agents from one source:

- **Claude Code / Cursor / Codex** — load the skill at [`skills/claude-session-teleport/SKILL.md`](skills/claude-session-teleport/SKILL.md)
  (auto-discovered via `.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/`).
- **Gemini** — reads this file (`gemini-extension.json` → `contextFileName: AGENTS.md`).
- Full, authoritative usage: [`skills/claude-session-teleport/SKILL.md`](skills/claude-session-teleport/SKILL.md).

CLI: `claude-teleport` with subcommands `preflight` (run FIRST, on the source),
`config-delta`, `copy` (the transfer itself, `--auto-spawn` to respawn), `rsync`
(project move, size-gated), `exit-worktree` (drive a live session out of a git worktree).

Key invariants for agents:

- Source-side checks happen BEFORE transfer — after `--auto-spawn` you're on the
  target and cannot inspect the source's working tree.
- A session inside a **git worktree** can't be relocated by copying the JSONL:
  `--resume` replays its `EnterWorktree` state and re-enters a `.claude/worktrees/…`
  path that won't exist at the destination. `copy` REFUSES such a session (override
  `--allow-worktree`); exit it first with `claude-teleport exit-worktree <uuid>`
  (drives the live session to `ExitWorktree`, back to the repo root), then copy.
- Never rsync above the size gate without showing the user the per-dir breakdown.
- Walk the post-spawn checklist in SKILL.md: remote-control URL in the report,
  briefing acknowledged, what moved / what didn't.

Requires `tmux`, `claude` (logged in) and `python3` on both ends.
