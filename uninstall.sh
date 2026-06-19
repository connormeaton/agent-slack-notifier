#!/bin/bash
# uninstall.sh — remove claude-notify hooks from ~/.claude/settings.json.
# Leaves notify-dispatcher.sh and notify.env in place (delete them by hand if you want).

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

[ -f "$SETTINGS" ] || { echo "No $SETTINGS — nothing to do."; exit 0; }
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
CMD_MARK = "notify-dispatcher.sh"
hooks = cfg.get("hooks", {})
for event in ("Notification", "Stop"):
    groups = hooks.get(event, [])
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if CMD_MARK not in h.get("command", "")]
    hooks[event] = [g for g in groups if g.get("hooks")]
    if not hooks[event]:
        del hooks[event]
if "hooks" in cfg and not cfg["hooks"]:
    del cfg["hooks"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("Removed claude-notify hooks.")
PY

echo "Done. (Disable instead of uninstall by setting ENABLE_SLACK=false in ~/.claude/notify.env.)"
