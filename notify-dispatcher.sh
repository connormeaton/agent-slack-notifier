#!/bin/bash
# notify-dispatcher.sh — send Claude Code lifecycle events to Slack / ntfy / SMS.
#
# Invoked by hooks in ~/.claude/settings.json, e.g.:
#   bash "$HOME/.claude/notify-dispatcher.sh" Notification
# Claude Code pipes a JSON event object on stdin; we use it to enrich the message.
#
# Config & log (override with env vars):
#   CLAUDE_NOTIFY_ENV   default: $HOME/.claude/notify.env
#   CLAUDE_NOTIFY_LOG   default: $HOME/.claude/notify.log
#
# Stop "what finished" summary:
#   SUMMARY_MODE="snippet" (default) — Claude's last message, free + instant
#   SUMMARY_MODE="llm"               — a 1-line Haiku summary, run in the BACKGROUND
#                                      (needs ANTHROPIC_API_KEY in notify.env;
#                                       falls back to the snippet if missing/failing)

set -uo pipefail

ENV_FILE="${CLAUDE_NOTIFY_ENV:-$HOME/.claude/notify.env}"
LOG_FILE="${CLAUDE_NOTIFY_LOG:-$HOME/.claude/notify.log}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

API_BASE="${ANTHROPIC_API_BASE:-https://api.anthropic.com}"
SUMMARY_MODEL="${SUMMARY_MODEL:-claude-haiku-4-5}"
EVENT_TYPE="${1:-${NI_EVENT:-Unknown}}"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT_TYPE" "$1" >> "$LOG_FILE" 2>/dev/null; }

# --- send TEXT ($1) to every enabled channel ---
send_all() {
  local TEXT="$1" sent=0 CODE PAYLOAD BODY esc
  if [ "${ENABLE_SLACK:-false}" = "true" ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
      PAYLOAD="$(TEXT="$TEXT" python3 -c 'import os,json;print(json.dumps({"text":os.environ["TEXT"]}))')"
    else
      esc="${TEXT//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"; PAYLOAD="{\"text\":\"$esc\"}"
    fi
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-type: application/json' \
      --data "$PAYLOAD" "$SLACK_WEBHOOK_URL")"
    if [ "$CODE" = "200" ]; then log "slack ok"; sent=1; else log "slack FAILED (http $CODE)"; fi
  fi
  if [ "${ENABLE_NTFY:-false}" = "true" ] && [ -n "${NTFY_TOPIC:-}" ]; then
    local server="${NTFY_SERVER:-https://ntfy.sh}" title tags prio
    case "$EVENT_TYPE" in
      Notification) title="Claude needs you"; tags="bell"; prio="high" ;;
      Stop)         title="Claude finished";  tags="white_check_mark"; prio="default" ;;
      *)            title="Claude Code";       tags="information_source"; prio="default" ;;
    esac
    BODY="$(printf '%s' "$TEXT" | sed -e 's/[*_>]//g' -e 's/:[a-z_]*://g')"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
      ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} -d "$BODY" "$server/$NTFY_TOPIC")"
    if [[ "$CODE" =~ ^2 ]]; then log "ntfy ok"; sent=1; else log "ntfy FAILED (http $CODE)"; fi
  fi
  if [ "${ENABLE_SMS:-false}" = "true" ] && [ -n "${TWILIO_ACCOUNT_SID:-}" ]; then
    BODY="$(printf '%s' "$TEXT" | sed -e 's/[*_>]//g' -e 's/:[a-z_]*://g')"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/Messages.json" \
      --data-urlencode "Body=$BODY" --data-urlencode "From=$TWILIO_FROM_NUMBER" \
      --data-urlencode "To=$TO_PHONE_NUMBER" -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN")"
    if [[ "$CODE" =~ ^2 ]]; then log "sms ok"; sent=1; else log "sms FAILED (http $CODE)"; fi
  fi
  [ "$sent" = "0" ] && log "no channel enabled — nothing sent"
}

# --- llm_summarize SNIPPET ($1) -> prints a 1-line summary, or nothing on failure ---
llm_summarize() {
  command -v python3 >/dev/null 2>&1 || return 0
  SNIPPET="$1" MODEL="$SUMMARY_MODEL" KEY="${ANTHROPIC_API_KEY:-}" BASE="$API_BASE" python3 - <<'PY'
import os, json, urllib.request
key = os.environ.get("KEY", "")
snip = os.environ.get("SNIPPET", "")[:6000]
if not key or not snip:
    raise SystemExit(0)
SYS = ("You convert an AI coding assistant's end-of-turn message into a single status line "
       "for a phone notification. Rules: output EXACTLY one line, max 12 words, past tense, "
       "start with a verb (e.g. 'Launched', 'Fixed', 'Added'). Plain text only - no markdown, "
       "headings, bullets, emoji, quotes, code, or trailing newline. Describe what was "
       "accomplished, not what the text says. Output only the line.")
body = json.dumps({
    "model": os.environ["MODEL"],
    "max_tokens": 40,
    "system": SYS,
    "messages": [{"role": "user", "content": "<assistant_message>\n" + snip + "\n</assistant_message>"}],
}).encode()
req = urllib.request.Request(os.environ["BASE"] + "/v1/messages", data=body, headers={
    "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    txt = "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text").strip()
    # Defensive: take first non-empty line, strip stray markdown/quote chars.
    line = next((l for l in txt.splitlines() if l.strip()), "")
    line = line.lstrip("#-*> ").strip().strip('"')
    print(" ".join(line.split()))
except Exception:
    pass
PY
}

# ---------------------------------------------------------------------------
# Internal background entrypoint: summarize (llm) + send, then exit.
# ---------------------------------------------------------------------------
if [ "${DISPATCH_INTERNAL:-0}" = "1" ]; then
  summary="${NI_SNIPPET:-}"
  if [ "${SUMMARY_MODE:-snippet}" = "llm" ] && [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -n "$summary" ]; then
    s="$(llm_summarize "$summary")"
    if [ -n "$s" ]; then summary="$s"; log "llm summary ok"; else log "llm summary failed → snippet"; fi
  fi
  TEXT="${NI_TEXT:-}"
  [ -n "$summary" ] && TEXT="$TEXT"$'\n'"> $summary"
  send_all "$TEXT"
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal hook entrypoint
# ---------------------------------------------------------------------------
STDIN_JSON="$(cat 2>/dev/null || true)"

case "$EVENT_TYPE" in
  Notification) [ "${NOTIFY_ON_NOTIFICATION:-true}" = "true" ] || { log "skipped (toggle off)"; exit 0; } ;;
  Stop)         [ "${NOTIFY_ON_STOP:-true}" = "true" ]         || { log "skipped (toggle off)"; exit 0; } ;;
esac

# Extract project / message / last-assistant snippet from the payload.
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
summary = ""
tp = data.get("transcript_path") or ""
if tp:
    try:
        last = ""
        with open(os.path.expanduser(tp)) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "assistant":
                    continue
                c = (d.get("message") or {}).get("content")
                if isinstance(c, list):
                    t = " ".join(b.get("text", "") for b in c
                                 if isinstance(b, dict) and b.get("type") == "text").strip()
                    if t:
                        last = t
        summary = " ".join(last.split())
        if len(summary) > 400:
            summary = summary[:400].rstrip() + "…"
    except Exception:
        summary = ""
print(project)
print(msg)
print(summary)
PY

PROJECT=""; HOOK_MSG=""; SNIPPET=""
if command -v python3 >/dev/null 2>&1; then
  mapfile -t _PY < <(STDIN_JSON="$STDIN_JSON" python3 -c "$PYHELPER")
  PROJECT="${_PY[0]:-}"; HOOK_MSG="${_PY[1]:-}"; SNIPPET="${_PY[2]:-}"
fi

case "$EVENT_TYPE" in
  Notification) TEXT=":bell: Claude Code needs your attention" ;;
  Stop)         TEXT=":white_check_mark: Claude Code finished its turn" ;;
  *)            TEXT=":information_source: Claude Code: $EVENT_TYPE event" ;;
esac
[ -n "$PROJECT" ] && TEXT="$TEXT  ·  *$PROJECT*"
[ "$EVENT_TYPE" = "Notification" ] && [ -n "$HOOK_MSG" ] && TEXT="$TEXT"$'\n'"> $HOOK_MSG"

# Stop: optionally append a "what finished" summary.
if [ "$EVENT_TYPE" = "Stop" ] && [ "${STOP_SUMMARY:-true}" = "true" ] && [ -n "$SNIPPET" ]; then
  if [ "${SUMMARY_MODE:-snippet}" = "llm" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    # Background the LLM call + send so the hook returns instantly (no latency).
    if command -v setsid >/dev/null 2>&1; then
      DISPATCH_INTERNAL=1 NI_EVENT="$EVENT_TYPE" NI_TEXT="$TEXT" NI_SNIPPET="$SNIPPET" \
        setsid bash "$0" >/dev/null 2>&1 </dev/null &
    else
      DISPATCH_INTERNAL=1 NI_EVENT="$EVENT_TYPE" NI_TEXT="$TEXT" NI_SNIPPET="$SNIPPET" \
        nohup bash "$0" >/dev/null 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
    log "stop summary queued (llm, background)"
    exit 0
  fi
  TEXT="$TEXT"$'\n'"> $SNIPPET"
fi

send_all "$TEXT"
exit 0
