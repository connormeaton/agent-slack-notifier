#!/bin/bash
# install-approvals.sh — wire the Slack approval gate as a PreToolUse hook.
#
# This is OPT-IN and separate from ./install.sh because it intercepts tool calls.
# It only *engages* when armed (./away.sh on); disarmed, it's an instant passthrough.
#
# Which tools to gate (default: Bash). Override:
#   APPROVAL_MATCHER="Bash|Edit|Write" ./install-approvals.sh
#
# Claude's hook timeout is set to 600s (the max); approve-gate.sh enforces its own
# shorter APPROVAL_TIMEOUT and denies first, so we never hit Claude's fail-open.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
GATE="$CLAUDE_DIR/approve-gate.sh"
MATCHER="${APPROVAL_MATCHER:-Bash}"

mkdir -p "$CLAUDE_DIR"
echo "==> Installing approval gate → $GATE"
cp "$SRC_DIR/approve-gate.sh" "$GATE"
chmod +x "$GATE"

echo "==> Wiring PreToolUse hook (matcher: $MATCHER) into $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$SETTINGS" "$MATCHER" <<'PY'
import json, sys
path, matcher = sys.argv[1], sys.argv[2]
with open(path) as f: cfg = json.load(f)
MARK = "approve-gate.sh"
cmd = 'bash "$HOME/.claude/approve-gate.sh"'
groups = cfg.setdefault("hooks", {}).setdefault("PreToolUse", [])
# strip any prior gate command, drop groups left empty (preserves others' hooks)
for g in groups:
    g["hooks"] = [h for h in g.get("hooks", []) if MARK not in h.get("command", "")]
groups[:] = [g for g in groups if g.get("hooks")]
groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd, "timeout": 600}]})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
print(f"    PreToolUse approval gate wired for: {matcher}")
PY

echo
echo "Approval gate installed (currently DISARMED — safe)."
echo "Next:"
echo "  1. In notify.env set SLACK_BOT_TOKEN (xoxb-…) and SLACK_CHANNEL_ID."
echo "     (Bot needs scopes chat:write + reactions:read, and must be in the channel.)"
echo "  2. Arm it when stepping away:   ./away.sh on     (disarm: ./away.sh off)"
echo "  3. Remove the gate entirely:    ./uninstall.sh"
