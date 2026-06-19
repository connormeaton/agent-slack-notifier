#!/bin/bash
# notify-dispatcher.sh — send Claude Code lifecycle events to Slack (and optionally Twilio SMS).
#
# Invoked by hooks in ~/.claude/settings.json, e.g.:
#   bash "$HOME/.claude/notify-dispatcher.sh" Notification
# Claude Code pipes a JSON event object on stdin; we use it to enrich the message.
#
# Config & log locations (override with env vars if you like):
#   CLAUDE_NOTIFY_ENV   default: $HOME/.claude/notify.env
#   CLAUDE_NOTIFY_LOG   default: $HOME/.claude/notify.log
#
# Manual test:
#   echo '{"message":"hello","cwd":"/tmp"}' | bash notify-dispatcher.sh Notification

set -uo pipefail

ENV_FILE="${CLAUDE_NOTIFY_ENV:-$HOME/.claude/notify.env}"
LOG_FILE="${CLAUDE_NOTIFY_LOG:-$HOME/.claude/notify.log}"

EVENT_TYPE="${1:-Unknown}"

# Load config
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Read the hook payload from stdin (may be empty when run manually)
STDIN_JSON="$(cat 2>/dev/null || true)"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT_TYPE" "$1" >> "$LOG_FILE" 2>/dev/null; }

# Respect per-event toggles
case "$EVENT_TYPE" in
  Notification) [ "${NOTIFY_ON_NOTIFICATION:-true}" = "true" ] || { log "skipped (toggle off)"; exit 0; } ;;
  Stop)         [ "${NOTIFY_ON_STOP:-true}" = "true" ]         || { log "skipped (toggle off)"; exit 0; } ;;
esac

# Extract cwd / message from the stdin JSON via python (graceful if absent/invalid).
read -r -d '' PYHELPER <<'PY'
import sys, json, os
raw = os.environ.get("STDIN_JSON", "")
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
cwd = data.get("cwd") or ""
project = os.path.basename(cwd.rstrip("/")) if cwd else ""
msg = (data.get("message") or "").strip()
print(project)
print(msg)
PY

PROJECT=""
HOOK_MSG=""
if command -v python3 >/dev/null 2>&1; then
  mapfile -t _PY < <(STDIN_JSON="$STDIN_JSON" python3 -c "$PYHELPER")
  PROJECT="${_PY[0]:-}"
  HOOK_MSG="${_PY[1]:-}"
fi

case "$EVENT_TYPE" in
  Notification) TEXT=":bell: Claude Code needs your attention" ;;
  Stop)         TEXT=":white_check_mark: Claude Code finished its turn" ;;
  *)            TEXT=":information_source: Claude Code: $EVENT_TYPE event" ;;
esac
[ -n "$PROJECT" ]  && TEXT="$TEXT  ·  *$PROJECT*"
[ -n "$HOOK_MSG" ] && TEXT="$TEXT"$'\n'"> $HOOK_MSG"

sent_any=0

# --- Dispatch: Slack ---
if [ "${ENABLE_SLACK:-false}" = "true" ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PAYLOAD="$(TEXT="$TEXT" python3 -c 'import os,json;print(json.dumps({"text":os.environ["TEXT"]}))')"
  else
    # Minimal fallback: escape backslashes, quotes, newlines.
    esc="${TEXT//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
    PAYLOAD="{\"text\":\"$esc\"}"
  fi
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-type: application/json' \
    --data "$PAYLOAD" "$SLACK_WEBHOOK_URL")"
  if [ "$HTTP_CODE" = "200" ]; then log "slack ok"; sent_any=1; else log "slack FAILED (http $HTTP_CODE)"; fi
fi

# --- Dispatch: ntfy (push app, reliable sound) ---
if [ "${ENABLE_NTFY:-false}" = "true" ] && [ -n "${NTFY_TOPIC:-}" ]; then
  NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
  case "$EVENT_TYPE" in
    Notification) NTFY_TITLE="Claude needs you"; NTFY_TAGS="bell";       NTFY_PRIO="high" ;;
    Stop)         NTFY_TITLE="Claude finished";  NTFY_TAGS="white_check_mark"; NTFY_PRIO="default" ;;
    *)            NTFY_TITLE="Claude Code";       NTFY_TAGS="information_source"; NTFY_PRIO="default" ;;
  esac
  # ntfy body is plain text; strip Slack markup
  NTFY_BODY="$(printf '%s' "$TEXT" | sed -e 's/[*_>]//g' -e 's/:[a-z_]*://g')"
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Title: $NTFY_TITLE" -H "Tags: $NTFY_TAGS" -H "Priority: $NTFY_PRIO" \
    ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
    -d "$NTFY_BODY" "$NTFY_SERVER/$NTFY_TOPIC")"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then log "ntfy ok"; sent_any=1; else log "ntfy FAILED (http $HTTP_CODE)"; fi
fi

# --- Dispatch: Twilio SMS ---
if [ "${ENABLE_SMS:-false}" = "true" ] && [ -n "${TWILIO_ACCOUNT_SID:-}" ]; then
  SMS_TEXT="$(printf '%s' "$TEXT" | sed -e 's/[*_>]//g' -e 's/:[a-z_]*://g')"
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/Messages.json" \
    --data-urlencode "Body=$SMS_TEXT" \
    --data-urlencode "From=$TWILIO_FROM_NUMBER" \
    --data-urlencode "To=$TO_PHONE_NUMBER" \
    -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN")"
  if [[ "$HTTP_CODE" =~ ^2 ]]; then log "sms ok"; sent_any=1; else log "sms FAILED (http $HTTP_CODE)"; fi
fi

[ "$sent_any" = "0" ] && log "no channel enabled — nothing sent"
exit 0
