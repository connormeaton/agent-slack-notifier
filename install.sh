#!/bin/bash
# install.sh — install agent-slack-notifier into ~/.claude on this machine.
#
#   - copies notify-dispatcher.sh into ~/.claude/
#   - creates ~/.claude/notify.env from the example (only if missing), chmod 600
#   - merges Notification + Stop hooks into ~/.claude/settings.json (idempotent)
#
# Safe to re-run: it backs up settings.json and won't duplicate hooks or clobber
# an existing notify.env.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
DISPATCHER="$CLAUDE_DIR/notify-dispatcher.sh"
ENV_FILE="$CLAUDE_DIR/notify.env"

mkdir -p "$CLAUDE_DIR"

echo "==> Installing dispatcher → $DISPATCHER"
cp "$SRC_DIR/notify-dispatcher.sh" "$DISPATCHER"
chmod +x "$DISPATCHER"

if [ -f "$ENV_FILE" ]; then
  echo "==> Keeping existing $ENV_FILE (not overwritten)"
else
  echo "==> Creating $ENV_FILE from example (edit it to add your webhook!)"
  cp "$SRC_DIR/notify.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "==> Merging hooks into $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

CMD_MARK = "notify-dispatcher.sh"
hooks = cfg.setdefault("hooks", {})

def ensure(event):
    cmd = f'bash "$HOME/.claude/notify-dispatcher.sh" {event}'
    groups = hooks.setdefault(event, [])
    # remove any prior entry of ours so re-running stays clean
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", []) if CMD_MARK not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    groups.append({"hooks": [{"type": "command", "command": cmd}]})

ensure("Notification")
ensure("Stop")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("    hooks merged: Notification, Stop")
PY

if [ "${CLAUDE_NOTIFY_QUIET:-0}" != "1" ]; then
  echo
  echo "Done. Next steps:"
  echo "  • Easiest: run the guided wizard →  ./setup.sh"
  echo "  • Or edit $ENV_FILE — paste your Slack webhook URL into SLACK_WEBHOOK_URL."
  echo "  • Test:  echo '{\"message\":\"hi\",\"cwd\":\"$PWD\"}' | bash \"$DISPATCHER\" Notification"
  echo "  • New Claude Code sessions on this machine will then notify you."
fi
