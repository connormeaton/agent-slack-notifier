#!/bin/bash
# approve-gate.sh — PreToolUse hook that gates a tool call through Slack approval.
#
# Wired via settings.json as a PreToolUse hook (see install-approvals.sh). When
# "armed" (ENABLE_APPROVALS=true), it posts the pending command to Slack and waits
# for you to react ✅ (allow) or ❌ (deny), then returns that decision to Claude.
#
# Design choices:
#   • DISARMED (default): instant passthrough — emits nothing, normal permission
#     flow applies. Your everyday workflow is untouched until you opt in.
#   • FAIL CLOSED on no-answer: if nobody reacts before APPROVAL_TIMEOUT, it
#     returns "deny" (Claude Code's own hook timeout fails OPEN, so we deny first).
#   • FAIL SOFT on misconfig/Slack error while armed: returns "ask" so a present
#     user just gets the normal local prompt instead of being hard-blocked.
#
# Requires a Slack *bot token* (xoxb-...) with scopes chat:write + reactions:read,
# the bot invited to the channel, and the channel ID. See README.

set -uo pipefail

ENV_FILE="${CLAUDE_NOTIFY_ENV:-$HOME/.claude/notify.env}"
LOG_FILE="${CLAUDE_NOTIFY_LOG:-$HOME/.claude/notify.log}"
API="${SLACK_API_BASE:-https://slack.com/api}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
API="${SLACK_API_BASE:-https://slack.com/api}"   # allow env file to override

log() { printf '%s [approve] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null; }

emit() { # $1=allow|deny|ask  $2=reason   → print decision JSON and exit 0
  DEC="$1" RSN="$2" python3 -c 'import os,json;print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":os.environ["DEC"],"permissionDecisionReason":os.environ["RSN"]}}))'
  exit 0
}

INPUT="$(cat 2>/dev/null || true)"

# 1) Disarmed → passthrough (no output = no objection = normal flow). Fail OPEN.
if [ "${ENABLE_APPROVALS:-false}" != "true" ]; then
  exit 0
fi

# Self-test hook for validating decision wiring without Slack.
if [ -n "${APPROVAL_SELFTEST:-}" ]; then
  emit "$APPROVAL_SELFTEST" "selftest"
fi

# 2) Armed but not configured → fall back to local prompt instead of blocking.
if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL_ID:-}" ]; then
  log "armed but SLACK_BOT_TOKEN/SLACK_CHANNEL_ID missing → ask"
  emit "ask" "approval gate not configured (need bot token + channel); using local prompt"
fi

APPROVAL_TIMEOUT="${APPROVAL_TIMEOUT:-300}"     # seconds to wait for a human
APPROVAL_POLL="${APPROVAL_POLL:-4}"             # seconds between reaction polls
APPROVE_EMOJI="${APPROVE_EMOJI:-white_check_mark}"
DENY_EMOJI="${DENY_EMOJI:-x}"

# Parse tool name + a one-line human summary + project from the PreToolUse JSON.
mapfile -t P < <(INPUT="$INPUT" python3 -c '
import os,json
try: d=json.loads(os.environ["INPUT"])
except Exception: d={}
tool=d.get("tool_name","?")
ti=d.get("tool_input",{}) or {}
if tool=="Bash": s=ti.get("command","")
elif tool in ("Edit","Write","NotebookEdit"): s=ti.get("file_path","")
else: s=json.dumps(ti)
s=" ".join(str(s).split())[:400]
cwd=d.get("cwd","") or ""
proj=os.path.basename(cwd.rstrip("/")) if cwd else ""
print(tool); print(s); print(proj)
')
TOOL="${P[0]:-?}"; SUMMARY="${P[1]:-}"; PROJECT="${P[2]:-}"

TITLE=":warning: Approve *${TOOL}*"
[ -n "$PROJECT" ] && TITLE="$TITLE in *${PROJECT}*"
TEXT="$TITLE ?
\`\`\`${SUMMARY}\`\`\`
React :${APPROVE_EMOJI}: to allow · :${DENY_EMOJI}: to deny · times out in ${APPROVAL_TIMEOUT}s → denied."

# 3) Post the approval request (chat.postMessage returns the message ts we poll).
PAYLOAD="$(CH="$SLACK_CHANNEL_ID" TXT="$TEXT" python3 -c 'import os,json;print(json.dumps({"channel":os.environ["CH"],"text":os.environ["TXT"]}))')"
RESP="$(curl -s -X POST "$API/chat.postMessage" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H 'Content-type: application/json; charset=utf-8' \
  --data "$PAYLOAD")"
read -r OK TS < <(RESP="$RESP" python3 -c 'import os,json;d=json.loads(os.environ["RESP"] or "{}");print(d.get("ok"),d.get("ts",""))' 2>/dev/null)
if [ "$OK" != "True" ] || [ -z "$TS" ]; then
  ERR="$(RESP="$RESP" python3 -c 'import os,json;print(json.loads(os.environ["RESP"] or "{}").get("error","?"))' 2>/dev/null)"
  log "chat.postMessage failed ($ERR) → ask"
  emit "ask" "could not reach Slack ($ERR); using local prompt"
fi
log "posted approval request ts=$TS tool=$TOOL"

# 4) Poll reactions until a decision or our (fail-closed) deadline.
DEADLINE=$(( $(date +%s) + APPROVAL_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep "$APPROVAL_POLL"
  RR="$(curl -s "$API/reactions.get?channel=$SLACK_CHANNEL_ID&timestamp=$TS" \
        -H "Authorization: Bearer $SLACK_BOT_TOKEN")"
  DECISION="$(RR="$RR" AP="$APPROVE_EMOJI" DN="$DENY_EMOJI" ALLOW_USERS="${APPROVER_USER_IDS:-}" python3 -c '
import os,json
rr=json.loads(os.environ["RR"] or "{}")
if not rr.get("ok"): raise SystemExit(0)
reacts=(rr.get("message",{}) or {}).get("reactions",[]) or []
allow_users=set(u for u in os.environ.get("ALLOW_USERS","").replace(","," ").split() if u)
def ok(r):
    if not allow_users: return True
    return bool(set(r.get("users",[])) & allow_users)
ap,dn=os.environ["AP"],os.environ["DN"]
names={r["name"]:r for r in reacts}
if dn in names and ok(names[dn]): print("deny")
elif ap in names and ok(names[ap]): print("allow")
' 2>/dev/null)"
  case "$DECISION" in
    allow) log "approved (reaction) tool=$TOOL"; emit "allow" "approved via Slack reaction" ;;
    deny)  log "denied (reaction) tool=$TOOL";   emit "deny"  "denied via Slack reaction" ;;
  esac
done

log "timed out after ${APPROVAL_TIMEOUT}s → deny (fail closed) tool=$TOOL"
emit "deny" "no Slack approval within ${APPROVAL_TIMEOUT}s (denied for safety)"
