---
name: claude-session-teleport
description: Use when the user wants to continue a Claude Code chat session on a different machine — "continue this chat on the server", "перенеси сессию на сервер", "продолжим на маке", "teleport this session", "session handoff". Optionally also transfers the project(s) the chat is about. The claude-teleport CLI (preflight / config-delta / copy / rsync) does the work — run preflight first (on the source) so uncommitted/gitignored files aren't silently left behind, then copy the chat and (optionally) the projects.
---

# claude-session-teleport

Move a live Claude Code chat session — plus, optionally, the files it's
about — from one machine to another. Bidirectional: Mac → server,
server → Mac, server → server.

Everything is driven by one CLI, **`claude-teleport`** (on PATH while the
plugin is enabled):

| Subcommand | Purpose |
|---|---|
| `claude-teleport preflight <dir>…` | **Run first, on the source.** Per project: git state + important gitignored files → recommends `clone` vs `rsync`. Stops silent data loss. |
| `claude-teleport config-delta <target>` | Compares this machine's `~/.claude` config vs the target's (over SSH) → what marketplaces/plugins/hooks/MCP may need setting up. |
| `claude-teleport copy <uuid> <target>` | Copy the JSONL + memory dir with path rebasing. `--auto-spawn` respawns the chat in tmux on the target (remote-control ON by default, handoff briefing typed in). |
| `claude-teleport rsync <src> <dst>` | Move a project directory with sane excludes but **including `.git/` and `.env*`**; size gate blocks silent multi-GB transfers. |

## Which machine am I on? (read this first)

A handoff has a **direction**, and being aware of *which side you're on* is
load-bearing — after a clone there is no felt "I moved", the conversation just
continues, so you will not notice the boundary unless you check.

- **Source-side inspections happen on the source, BEFORE transfer** — uncommitted
  work, important gitignored files (`.env`, local DBs), secrets, `git status`.
  This is what `claude-teleport preflight` automates (decision-tree step 3). Do it first.
- After `--auto-spawn`, the resumed agent is **on the target** with the copied
  history. It **cannot see the source's working tree** — "let me just re-check the
  source" is impossible from there. Skip the pre-transfer check and any
  un-pushed / gitignored data is silently gone.
- **Reverse reachability:** if both machines share a network (e.g. Tailscale), the
  target *can* `ssh <source-alias>` back — handy for a forgotten file, but **not a
  substitute** for the pre-transfer check (don't assume it exists).
- To know where you are right now: `uname -s` + `hostname`. Don't assume.

## What it does

A chat session = JSONL conversation file + (optionally) per-session
memory. Both live under `~/.claude/projects/<cwd-encoded>/`. To resume
the chat elsewhere you copy these to the target's matching path. If the
chat references files in a project, you also need those files there.

This skill orchestrates two primitives:

| Tool | Purpose |
|---|---|
| `preflight` | **Run first, on the source.** Per project: git state + important gitignored files → recommends `clone` vs `rsync`. Stops silent data loss. |
| `config-delta` | Compares this machine's `~/.claude` config vs the target's (over SSH) → what marketplaces/plugins/hooks/MCP may need setting up (flags Mac-only). |
| `copy` | Copy the JSONL + memory dir with path rebasing (Mac `/Users/X` ↔ Linux `/home/X`). `--auto-spawn` verifies target prereqs (claude+login+tmux+python3) before spawning. |
| `rsync` | Move a project directory between machines with sane excludes (`node_modules`, `.venv`, build artifacts) but **including `.git/` and `.env*`**. |

For projects that are clean in git and have nothing critical gitignored,
you can skip rsync entirely and just `ssh <target> 'cd <path> && git pull'`
(or `gh repo clone` if missing). The skill describes when each choice
makes sense — but doesn't ship a wrapper script for it (a one-liner SSH
is enough).

## Pre-flight: analyze the chat's configuration

**BEFORE the file/chat transfer**, inspect what the source machine has
that the target may need. Read these on source, compare with target,
ask the user which to also migrate:

| Source location | What it is | Migrate to target if… |
|---|---|---|
| `~/.claude/settings.json → extraKnownMarketplaces` | Plugin marketplaces (private repos need gh auth) | Always (cheap; required for plugins below) |
| `~/.claude/settings.json → enabledPlugins` | Plugins the user uses | Yes — but **filter Mac-only ones** (e.g. anything that drives Mac-only apps). Ask if uncertain. |
| `~/.claude/skills/*` (NOT under `plugins/cache/`) | User-local skills | Per-skill, ask. Some are platform-tied. |
| `~/.claude/settings.json → hooks` | Pre/post tool-call hooks | Yes if portable. Hooks often call platform-specific binaries (e.g. `say` on Mac) — adjust before migrating. |
| `~/.claude/settings.json → mcpServers` (global) and `~/.claude.json → mcpServers` (per-project) | MCP server configs (Gmail, Drive, Calendar, custom) | Mostly NO. MCP servers that authenticate against user-machine credentials (Gmail OAuth, Drive) don't transfer. Custom local-process MCPs need their binaries on target. Always ask. |
| `~/.claude/settings.json → cleanupPeriodDays`, `bypassPermissionsModeAccepted`, theme, etc. | General settings | Usually mirror — safe defaults. |

### Steps for the agent

Run the delta — it does the source/target read + diff for you (don't hand-jq it):

```bash
claude-teleport config-delta <target-alias>
```

It prints what's on the source but not the target — marketplaces to add, plugins
to install (Mac-only ones flagged `⚠ likely SKIP`), and any hooks/MCP to review.
If the target already matches (e.g. set up by a previous handoff) it says
`✓ target already mirrors source — nothing to migrate`. Show the user the output
and ask which of the deltas to apply (default: marketplaces + portable plugins;
skip Mac-only, hooks, and MCP unless asked).

### Applying the chosen config on target

- **Marketplaces**: copy the source's `~/.claude/settings.json → extraKnownMarketplaces` entry **verbatim** to the target — preserve its `autoUpdate` value as-is (the handoff mirrors the source, it doesn't impose a policy). Requires `gh auth login` on target for private repos. (Note: `"autoUpdate": true` is what makes Claude refresh a marketplace and its installed plugins on session start — but only set it on the target if the source had it.)
- **Plugins**: `ssh <alias> 'claude plugin install <name>@<marketplace>'` — works non-interactively. Loop over the chosen list. (Don't just write to `enabledPlugins`: that alone doesn't install in current Claude Code; explicit `claude plugin install` does.)
- **Hooks**: copy the JSON snippet, but warn about platform-specific binaries.
- **MCPs**: usually skipped. If user insists, copy `mcpServers` entry but flag credentials need re-auth.

## Pre-flight: project needs (when the chat is tied to a dev project)

If the chat being moved is **about a dev project that's also moving**, files are
not the whole story — the project may depend on accesses and machine state that
`claude-teleport preflight` can't see in the tree. Before transfer, **scan for markers on the
source, then ask the user 3–4 targeted questions** instead of discovering the
gaps after landing.

What to scan (cheap, on the source):

| Marker | What it implies on the target |
|---|---|
| private git remotes (`git remote -v`, submodules) | `gh auth login` / SSH deploy key needed to pull & push |
| `~/.ssh/config` Host entries the project uses (deploy, db-tunnels) | keys + config entries must be provisioned (keys do NOT auto-transfer) |
| env vars consumed by code but absent from `.env*` (`process.env.X` / `os.environ[...]` / `getenv` vs keys in `.env*`) | they live in the shell profile or CI — find where, ask how to provide |
| tokens/keys exported in shell profile mentioning the project (`grep -iE 'TOKEN|SECRET|API_KEY' ~/.zshrc ~/.zshenv ~/.profile`) | copy the *variable name list* to the user; never auto-copy values |
| `docker-compose.yml`, `Procfile`, references to `localhost:5432/6379/...` | running services (Postgres/Redis/...) must exist on the target |
| `.nvmrc` / `.python-version` / `engines` / `rust-toolchain` / README "prerequisites" | runtime versions + system tools (`brew`/`apt`) to install |
| certs, custom `/etc/hosts` entries, forwarded ports mentioned in configs | manual provisioning, surface explicitly |

Then ask the user, concretely: *"To keep working on `<project>` on `<target>`, the
chat will likely need: gh auth for `<remote>`, `DATABASE_URL` (currently from your
zshrc), a running Postgres, node 20. Which of these should I set up / which does
the continued work actually need?"* — scoped to what the **chat's ongoing task**
touches, not the project's full dev setup.

Default stance: **never auto-copy out-of-tree secrets** (Keychain, `~/.secrets/`,
shell-profile values, SSH keys). List what's needed by name; the user provisions
or explicitly hands over each one.

## Two transfer modes — `--clone` (default) vs `--migrate`

Critical: in Claude's account-wide session registry, **UUID is global per account**, not per machine. If two machines have JSONLs with the same UUID and both activate `/remote-control`, they fight — UI shows only one, archives the other.

Bridge state (`bridge-session` entries, `bridgeSessionId` fields) is also baked into the JSONL — when copied as-is, a resumed claude tries to reuse the original machine's bridge and clobbers it.

`claude-teleport copy` handles both with explicit modes:

### `--clone` (default — safe)

- Generates a **NEW UUID**
- Rewrites every occurrence in the JSONL (sessionId field + any other reference)
- **Strips `bridge-session` lines + `bridgeSessionId` fields** so the target gets a fresh remote-control bridge
- Source side keeps working untouched
- Two independent branches diverging from the moment of copy

Use when: you want a copy to experiment with, or to have both machines available, or you're not sure.

### `--migrate`

- Same UUID as source
- No JSONL rewrite, no bridge strip
- Both machines see the same JSONL ID → Claude treats them as **one session**, the most recent activation wins
- When the target activates `/remote-control`, source typically gets archived in the UI
- Useful when you've decided to fully move and never come back to the source

Use when: deliberate one-way move. **Plan to stop using the source.**

## Decision tree (transfer step)

1. **Find the chat's UUID.**
   - Current session: `ls -t ~/.claude/projects/<cwd-encoded>/*.jsonl | head -1`
     where `cwd-encoded` = absolute path with `/` replaced by `-`, prefixed
     with `-`. E.g. `/Users/<you>/dev` → `-Users-<you>-dev`.
   - If unclear, ask the user.

2. **What's the scope of the chat?**
   - Single project (the chat's cwd is one repo) → handle that one.
   - Broad cwd like `~/dev` covering many repos → **ask the user which
     projects to transfer**. Don't blindly rsync the whole `~/dev` — it's
     usually huge and most repos are irrelevant to the chat.

3. **Run `claude-teleport preflight` on the picked projects — REQUIRED, don't eyeball it.**

   ```bash
   claude-teleport preflight <project-dir> [<project-dir> ...]
   ```

   For each project it reports uncommitted work, unpushed commits, and important
   gitignored files (anything that isn't known build/cache junk), then recommends:
   - **`clone`** — clean & pushed, nothing important ignored → `ssh <target> "cd <path> && git pull"`, or `gh repo clone` if missing.
   - **`rsync`** — dirty / unpushed / has important gitignored files (`.env`, local DBs, …) → `claude-teleport rsync` (preserves `.git/`, `.env*`, dot-files; skips build noise).

   Show the recommendation to the user and let them confirm per project. This is
   the step that prevents silent data loss — and it **only works from the source**
   (see "Which machine am I on?"). Skipping it = the failure mode that motivated it.

   **Size gate (MANDATORY before any rsync):** run `du -sh` on the project AND
   per top-level dir. If the total exceeds ~200 MB, do NOT start rsync — show
   the user the per-dir breakdown and ask what to bring. Typical resolution:
   git clone/pull for tracked files + rsync ONLY the gitignored dirs the
   continued task actually needs; heavy media/raw-source dirs (recordings,
   PDFs, datasets) usually stay behind — the chat's md-notes layer often
   already covers them. Never let preflight's "recommend: rsync" mean "rsync
   everything". `claude-teleport rsync` enforces this: above the threshold
   (`RSYNC_CONFIRM_THRESHOLD_MB`, default 200) it aborts with the breakdown
   until re-run with `--yes` after the user confirmed scope.

4. **Always: copy the chat itself.**
   ```bash
   claude-teleport copy <uuid> <target-alias>
   ```
   Add `--target-cwd <path>` if the target uses a different home layout.
   Default rebases `/Users/<name>/...` → `/home/<name>/...` automatically.

   > **`--target-cwd` also *relocates* the session** — it lands under whatever cwd you
   > pass, not just a rebased home. So it's the "move this chat to a different directory"
   > knob, and it works with a real target host **or `localhost`** (pure local file-ops —
   > moving a session between directories on the *same* machine). This works because a
   > session is just its `<uuid>.jsonl` transcript plus a cwd, and `claude --resume` looks
   > for that jsonl in the **current cwd's** project dir — so placing the jsonl under a new
   > cwd's project dir and resuming from there continues the same chat elsewhere.

5. **(Optional) Auto-spawn the resumed session in tmux:**
   With `--auto-spawn`, the skill opens a detached `tmux` session on the
   target and runs `claude --dangerously-skip-permissions --resume <uuid>`
   inside. **Self-contained** — no external skills/wrappers required.

   **Target prereqs are verified before the spawn** (no need to check by hand —
   and don't trust a bare `ssh host command -v claude`, the non-login PATH lies):
   - `claude` — found via known install locations (`~/.npm-global/bin`,
     `~/.local/bin`, `/usr/local/bin`, PATH); aborts with a clear message if absent.
   - `tmux`, `python3` — hard requirement, aborts if missing.
   - **logged-in claude** (`~/.claude/.credentials.json`) — warns if absent (on a
     Linux server that means "not logged in → resume won't start"; on macOS creds
     may be in the Keychain, so the warning is advisory).

   **`/remote-control` is ON by default for every auto-spawn** — a handed-off
   session on a headless server is useless from the user's phone/browser
   without it. The script activates it and prints the URL; **ALWAYS include
   this URL in your final report to the user.** Pass `--no-remote-control`
   only if the user explicitly says the session stays terminal-only. If URL
   activation fails, the script dumps the pane tail; as a fallback the
   `claude-remote` plugin's `refresh <session>` re-issues `/remote-control`
   in the same pane (same mechanism, battle-tested).

   **Session/chat title convention** (shared with the `claude-remote` skill):
   `<machine>/<dir-under-~/dev>` — e.g. `my-server/myproject`. The script
   defaults to this (tmux: `cc—<dir>`, chat title: `<target>/<dir>`); only
   override via `--remote-name` if the user asks, and keep the machine
   prefix — without it the handed-off chat is indistinguishable from its
   still-living source in the claude.ai session list.

   **A handoff briefing is typed into the resumed session automatically**:
   the resumed agent learns it was moved (source machine, clone vs migrate,
   target cwd, "source lives on — commit & push", MCP caveat). Add
   transfer-specific facts via `--note "course/materials stayed on the Mac"`
   — anything the size gate decided to leave behind belongs in the note.
   The script then shows the pane tail so you can VERIFY the agent
   acknowledged; if the pane shows no acknowledgement, investigate before
   reporting success. Disable with `--no-briefing` only if the user asks.

   Self-contained: waits for TUI readiness, sends `/remote-control`,
   auto-confirms the "Enable Remote Control" prompt, polls for the URL.
   No external skill/binary dependency.

   **Model + effort carry over to the resumed chat:**
   - **Model** is auto-detected from the source JSONL (the last real
     `message.model` = the model this dialog is currently on) and passed as
     `--model` on spawn. Override with `--model <alias|id>`.
   - **Effort** is *not* stored per-dialog in the JSONL, so it defaults to the
     **live** effort of the session running this skill (`$CLAUDE_EFFORT`, which
     Claude Code exports to tool subprocesses). For the "migrate myself" use
     case this is exactly the right value — the skill runs inside the chat being
     moved. Passed as `--effort`. Override with `--effort low|medium|high|xhigh|max`.
   - Both are echoed in the **Plan** block before copying, so you can confirm.

## Post-spawn checklist (walk it EVERY handoff, in order)

1. [ ] **Size gate**: per-dir `du` shown, user chose transfer scope BEFORE any
       rsync started (never silently ship gigabytes).
2. [ ] **Remote-control**: active, URL captured, title follows the
       `<machine>/<dir>` convention — URL and title included in the report.
3. [ ] **Briefing**: handoff briefing landed in the target tmux and the pane
       tail shows the resumed agent *acknowledged* it (not just an empty
       prompt). Anything left behind (skipped dirs) was passed via `--note`.
4. [ ] **Report to the user**: what moved / what didn't / how to attach
       (ssh+tmux command AND the claude.ai URL).

Skipping any item = the handoff is not done.

## Cheat-sheet examples

### Single-project chat, repo clean

```bash
ssh my-server "cd ~/dev/myproject 2>/dev/null && git pull || gh repo clone <you>/myproject ~/dev/myproject"
claude-teleport copy <uuid> my-server --auto-spawn
```

### Single project, dirty / has .env

```bash
claude-teleport rsync ~/dev/myproject my-server:~/dev/myproject
claude-teleport copy <uuid> my-server --auto-spawn
```

### Chat that touches several repos

```bash
# Ask the user which projects to bring. Then per-project:
claude-teleport rsync ~/dev/other-lib my-server:~/dev/other-lib
ssh my-server "cd ~/dev/myproject && git pull"      # clean repo: git pull
claude-teleport copy <uuid> my-server --auto-spawn
```

### Reverse direction (server → Mac)

```bash
claude-teleport rsync my-server:~/dev/myproject ~/dev/myproject
claude-teleport copy <uuid> localhost --target-cwd ~/dev  # localhost mode: just file ops
```

(`localhost` source/target = file copy, no SSH.)

## What this skill explicitly does NOT do

- **Move secrets safely**. Secrets in `.env` files come along with rsync
  if they're in the project tree, BUT the skill doesn't sync system-level
  secrets (Keychain, `~/.secrets/`, SSH agents). Mention this to the user
  before transfer if secrets are likely needed.
- **Recreate runtime artifacts**. `node_modules`, `.venv`, etc. are
  excluded. After landing, user needs `npm install` / `pip install -r` /
  whatever on target.
- **Bidirectional sync over time**. The skill is for **one-shot moves**.
  For ongoing sync between Mac and server, use git (commit + push + pull)
  as the source of truth.
- **Sync MCP server configs**. The target has its own `.mcp.json` /
  `~/.claude/mcp.json` — Gmail/Drive/Calendar from Mac won't work on a
  Linux server. Mention this if the chat used them.
- **Sync skills/plugins**. The target's set of installed plugins matters.
  Check the target's plugin marketplaces separately.

## Running `claude-teleport copy` as an agent (no crutches needed)

- **Run it in the FOREGROUND with a generous timeout** (≥5 min). With
  `--auto-spawn` it legitimately takes 1–2.5 min (TUI-ready wait + remote-control
  URL wait). Do **not** `run_in_background` + poll the output file + chain
  sleeps — that's how a past run ended up fighting the harness ("Blocked:
  sleep 45 followed by tail…") for no benefit.
- **Normally you don't touch tmux on the target.** The script confirms the
  trust-folder prompt, confirms "Enable Remote Control", polls for the URL, and
  **on any wait failure dumps the pane tail** into its own output — the reason
  is in front of you.
- It is non-interactive-safe: the `Proceed?` confirmation only appears on a TTY.

### Emergency manual control (when the script's dump isn't enough)

The spawned session is plain tmux named `cc—<name>`. Prefix every command with
`ssh <target>` when the target isn't localhost:

```bash
tmux ls                                              # find the session
tmux capture-pane -p -J -t 'cc—<name>' -S -200       # read the screen (last 200 lines)
tmux send-keys -t 'cc—<name>' 'some text' Enter      # type + Enter
tmux send-keys -t 'cc—<name>' Enter                  # just Enter (confirm a prompt)
tmux send-keys -t 'cc—<name>' Escape                 # dismiss a dialog
tmux display-message -p -t 'cc—<name>' '#{pane_current_path}'   # pane cwd
tmux kill-session -t 'cc—<name>'                     # tear down for a respawn
```

Typical rescues: confirm a stuck prompt (`Enter`), check the pane cwd, or
kill + respawn with corrected args. If a rescue was needed, that's also a
signal the script missed a case — worth fixing there too.

## Network gotchas seen in the wild

- **`Connection closed by 198.18.x.x port 22` — and the x.x CHANGES between
  attempts**: a fake-IP VPN/proxy on the source (Shadowrocket, clash, sing-box…)
  is intercepting DNS and answering with addresses from its private
  `198.18.0.0/15` pool. The target is fine. Don't debug the server — switch to
  an ssh alias pinned to a **literal IP** (public IP or the tailscale `100.x`),
  or have the user pause the proxy. Spending time on keys/sshd here is wasted.
- **PATH lies over non-interactive ssh**: `ssh host 'command -v claude'` failing
  does NOT mean claude is missing — non-login shells skip `~/.zshrc`/`~/.profile`.
  Check known install paths (the prereq guard in `claude-teleport copy` does this).

## Warnings to surface to the user

Before running, summarize:
- Source/target paths
- Approx size to transfer (run `du -sh` for rsync paths)
- Uncommitted git state per project (just informational)
- Which secrets / .env files are being transferred
- Project needs beyond files (accesses, services, runtimes) — see "Pre-flight: project needs"
- That MCP/plugins may differ on target

## Where it lives

- Plugin: installed via any marketplace that carries `claude-session-teleport`;
  the `claude-teleport` CLI is on PATH while the plugin is enabled.
- GitHub: https://github.com/superbereza/claude-session-teleport
