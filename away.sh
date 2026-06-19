#!/bin/bash
# away.sh — arm/disarm Slack command approvals (flips ENABLE_APPROVALS in notify.env).
#   ./away.sh on     # arm: tool calls now require Slack ✅/❌ approval
#   ./away.sh off    # disarm: instant passthrough (normal workflow)
#   ./away.sh        # show current state

set -uo pipefail
ENV_FILE="${CLAUDE_NOTIFY_ENV:-$HOME/.claude/notify.env}"
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE — run ./setup.sh first."; exit 1; }

cur="$(grep -E '^ENABLE_APPROVALS=' "$ENV_FILE" | tail -1 | cut -d'"' -f2)"
case "${1:-status}" in
  on|arm)    new="true" ;;
  off|disarm) new="false" ;;
  status|"") echo "approvals: ${cur:-false}"; exit 0 ;;
  *) echo "usage: ./away.sh [on|off]"; exit 1 ;;
esac

if grep -qE '^ENABLE_APPROVALS=' "$ENV_FILE"; then
  sed -i.bak "s/^ENABLE_APPROVALS=.*/ENABLE_APPROVALS=\"$new\"/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
  printf '\nENABLE_APPROVALS="%s"\n' "$new" >> "$ENV_FILE"
fi
echo "approvals: ${cur:-false} → $new"
[ "$new" = "true" ] && echo "Armed. New tool calls will wait for Slack approval (existing sessions keep their old hooks until restarted)."
[ "$new" = "false" ] && echo "Disarmed. Back to normal passthrough."
