# claude-session-teleport

Move a **live Claude Code chat session** — plus, optionally, the files it's about —
from one machine to another. Mac → server, server → Mac, server → server. The chat
arrives resumable (`claude --resume`), respawned in tmux, with **Remote Control ON**
and a **handoff briefing** typed in so the resumed agent knows it just moved.

Built after one too many "let me just re-explain everything to a fresh session on
the server" evenings.

## Why

A Claude Code conversation is a JSONL on disk — but naive copying breaks it: the
project path is encoded into the storage dir, the session UUID is global per
account (two machines with the same UUID fight over Remote Control), and bridge
state baked into the file clobbers the source's connection. Plus the chat is
usually *about* a project — with uncommitted work and gitignored `.env`s that a
`git clone` silently drops.

`claude-teleport` handles all of it: path rebasing, clone-vs-migrate semantics,
bridge stripping, project preflight, and a size gate so you don't ship 2 GB of
raw materials nobody asked for.

## Install

**Claude Code** (also its own marketplace):

```
/plugin marketplace add superbereza/claude-session-teleport
/plugin install claude-session-teleport@claude-session-teleport
```

The `claude-teleport` CLI is auto-added to PATH while the plugin is enabled. Other
agents read their own manifests (`.cursor-plugin/`, `.codex-plugin/`,
`gemini-extension.json`).

Also available in the [claude-session-suite](https://github.com/superbereza/claude-session-suite)
marketplace together with its siblings
[claude-remote-launcher](https://github.com/superbereza/claude-remote-launcher) (launch)
and [claude-session-keeper](https://github.com/superbereza/claude-session-keeper) (keep alive).

## Use

```bash
# 1. On the SOURCE: what would a git clone silently lose?
claude-teleport preflight ~/dev/myproject

# 2. What ~/.claude config (marketplaces/plugins/hooks) is the target missing?
claude-teleport config-delta my-server

# 3. Move the project (size-gated: >200 MB aborts with a per-dir breakdown)
claude-teleport rsync ~/dev/myproject my-server:~/dev/myproject

# 4. Move the chat and respawn it on the target
claude-teleport copy <session-uuid> my-server --auto-spawn
```

Step 4 prints the `claude.ai/code` URL — the session is immediately usable from
the phone/browser, titled `my-server/myproject` so it's distinguishable from its
still-living source.

## Clone vs migrate

| | `--clone` (default) | `--migrate` |
|---|---|---|
| UUID | new, rewritten throughout | preserved |
| Remote-control bridge state | stripped (fresh bridge) | kept |
| Source session | keeps working | should be retired |
| Use when | both machines stay active | deliberate one-way move |

## What --auto-spawn does

1. Verifies target prereqs (claude binary via known install paths, tmux, python3, login).
2. Pre-trusts the cwd, spawns detached tmux (`cc—<dir>`), resumes with the source's
   model + effort carried over.
3. Activates `/remote-control` (chat title `<machine>/<dir>`), prints the URL.
4. Types a **handoff briefing** into the session — source machine, clone/migrate,
   "source lives on: commit & push", MCP caveats, plus anything you pass via
   `--note` — and shows the pane tail so you can verify the agent acknowledged.

## Requirements

- Source & target: `claude` (logged in), `tmux`, `python3`, SSH access between them.
- The full agent playbook (decision tree, config migration, post-spawn checklist)
  lives in the skill: [`skills/claude-session-teleport/SKILL.md`](skills/claude-session-teleport/SKILL.md).
