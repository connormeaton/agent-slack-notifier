#!/bin/bash
# status.sh — show current agent-slack-notifier configuration and health.

set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
ENV_FILE="$CLAUDE_DIR/notify.env"
DISPATCHER="$CLAUDE_DIR/notify-dispatcher.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
LOG_FILE="$CLAUDE_DIR/notify.log"

if [ -t 1 ]; then B=$(tput bold 2>/dev/null||true); R=$(tput sgr0 2>/dev/null||true); G=$(tput setaf 2 2>/dev/null||true); Y=$(tput setaf 3 2>/dev/null||true); else B=""; R=""; G=""; Y=""; fi
yn() { [ "$1" = "true" ] && printf '%son%s'  "$G" "$R" || printf '%soff%s' "$Y" "$R"; }

echo "${B}agent-slack-notifier status${R}"

# dispatcher
[ -x "$DISPATCHER" ] && echo "  dispatcher : installed ($DISPATCHER)" || echo "  dispatcher : ${Y}NOT installed${R} — run ./install.sh"

# hooks
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS" <<'PY'
import json,sys
try: cfg=json.load(open(sys.argv[1]))
except Exception: cfg={}
h=cfg.get("hooks",{})
for ev in ("Notification","Stop"):
    on=any("notify-dispatcher.sh" in x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
    print(f"  hook {ev:<12}: {'wired' if on else 'not wired'}")
gate=any("approve-gate.sh" in x.get("command","") for g in h.get("PreToolUse",[]) for x in g.get("hooks",[]))
print(f"  approval gate : {'wired' if gate else 'not wired'}")
PY
else
  echo "  hooks      : (settings.json or python3 unavailable)"
fi

# config
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "  events     : needs-input=$(yn "${NOTIFY_ON_NOTIFICATION:-true}")  finished=$(yn "${NOTIFY_ON_STOP:-true}")"
  echo "  Slack      : $(yn "${ENABLE_SLACK:-false}") $( [ -n "${SLACK_WEBHOOK_URL:-}" ] && echo "(webhook set)" || echo "(no webhook)" )"
  echo "  ntfy       : $(yn "${ENABLE_NTFY:-false}") $( [ -n "${NTFY_TOPIC:-}" ] && echo "(topic: $NTFY_TOPIC)" || echo "(no topic)" )"
  echo "  SMS        : $(yn "${ENABLE_SMS:-false}")"
  echo "  approvals  : $(yn "${ENABLE_APPROVALS:-false}") $( [ "${ENABLE_APPROVALS:-false}" = "true" ] && echo "(ARMED)" || echo "(disarmed)" )$( [ -n "${SLACK_BOT_TOKEN:-}" ] && echo " bot-token set" )"
else
  echo "  config     : ${Y}$ENV_FILE missing${R} — run ./setup.sh"
fi

# recent log
if [ -f "$LOG_FILE" ]; then
  echo "${B}recent activity:${R}"
  tail -n 5 "$LOG_FILE" | sed 's/^/  /'
fi
