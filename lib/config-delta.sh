#!/usr/bin/env bash
# config-delta.sh <target-alias>
#
# Compares THIS machine's (SOURCE) ~/.claude config against a TARGET's (over SSH)
# and prints what a session handoff may need to set up on the target: plugin
# marketplaces, enabled plugins, hooks, MCP servers. Flags Mac-only plugins that
# usually shouldn't go to a Linux server. If nothing differs, says so explicitly
# (the target may already be set up from a previous handoff).
#
# Read-only: never writes to either machine. The skill turns this report into a
# "which of these to migrate?" question for the user.

set -uo pipefail
[ $# -ge 1 ] || { echo "usage: config-delta.sh <target-alias>" >&2; exit 2; }
TARGET="$1"

SRC=$(cat "$HOME/.claude/settings.json" 2>/dev/null || echo '{}')
TGT=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" 'cat ~/.claude/settings.json 2>/dev/null || echo "{}"') \
  || { echo "✗ couldn't read target config over ssh ($TARGET)"; exit 1; }

SRC="$SRC" TGT="$TGT" python3 <<'PY'
import json, os
src = json.loads(os.environ.get("SRC") or "{}")
tgt = json.loads(os.environ.get("TGT") or "{}")

# Plugins tied to the source Mac — usually SKIP on a Linux server.
MAC_ONLY = {"things", "ai-yolo-modes", "use-withcorp-on-access-failure"}

def keys(d, *path):
    cur = d
    for p in path:
        cur = (cur or {}).get(p, {})
    return set(cur.keys()) if isinstance(cur, dict) else set()

base = lambda n: n.split("@", 1)[0]   # "things@mkt" -> "things"
changed = False

add_mkt = keys(src, "extraKnownMarketplaces") - keys(tgt, "extraKnownMarketplaces")
if add_mkt:
    changed = True
    print("MARKETPLACES to add on target (copy the entry verbatim; private repos need `gh auth login`):")
    for m in sorted(add_mkt): print(f"  + {m}")

add_pl = keys(src, "enabledPlugins") - keys(tgt, "enabledPlugins")
if add_pl:
    changed = True
    print("PLUGINS on source but not target (install: `claude plugin install <name>@<marketplace>`):")
    for p in sorted(add_pl):
        tag = "   ⚠ Mac-only — likely SKIP" if base(p) in MAC_ONLY else ""
        print(f"  + {p}{tag}")

if keys(src, "hooks"):
    changed = True
    print("HOOKS defined on source (review before copying — often call platform-specific binaries):")
    for h in sorted(keys(src, "hooks")): print(f"  ~ {h}")

if keys(src, "mcpServers"):
    changed = True
    print("MCP servers on source (usually DON'T transfer — OAuth / local-process creds won't move):")
    for s in sorted(keys(src, "mcpServers")): print(f"  ~ {s}")

if not changed:
    print("✓ target already mirrors source — nothing to migrate.")
PY
