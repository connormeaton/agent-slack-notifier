#!/bin/bash
# setup.sh — guided onboarding for claude-notify.
# Walks you through picking channels, entering credentials, installing the hooks,
# and sending a live test — then helps if you don't hear it.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
ENV_FILE="$CLAUDE_DIR/notify.env"
DISPATCHER="$CLAUDE_DIR/notify-dispatcher.sh"

# ---------- pretty output ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  B=$(tput bold); D=$(tput dim); R=$(tput sgr0)
  GRN=$(tput setaf 2); YEL=$(tput setaf 3); CYN=$(tput setaf 6); RED=$(tput setaf 1)
else
  B=""; D=""; R=""; GRN=""; YEL=""; CYN=""; RED=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s%s%s\n' "$B$CYN" "$*" "$R"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$R" "$*"; }
err()  { printf '%s✗%s %s\n' "$RED" "$R" "$*"; }

# Read prompts from the terminal even if stdin is piped.
TTY=/dev/tty; [ -r "$TTY" ] || TTY=/dev/stdin
ask()     { local p="$1" d="${2:-}" a; if [ -n "$d" ]; then printf '%s %s[%s]%s ' "$p" "$D" "$d" "$R" >&2; else printf '%s ' "$p" >&2; fi; read -r a < "$TTY" || true; printf '%s' "${a:-$d}"; }
confirm() { local p="$1" a; printf '%s %s[y/N]%s ' "$p" "$D" "$R" >&2; read -r a < "$TTY" || true; [[ "${a:-}" =~ ^[Yy] ]]; }

if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
  err "setup.sh needs an interactive terminal. Run it directly:  ./setup.sh"
  exit 1
fi

clear 2>/dev/null || true
say "${B}${CYN}┌──────────────────────────────────────────────┐${R}"
say "${B}${CYN}│         claude-notify · guided setup          │${R}"
say "${B}${CYN}└──────────────────────────────────────────────┘${R}"
say "${D}Get a phone/desktop alert when Claude Code needs you${R}"
say "${D}or finishes a task, so you can step away.${R}"

# ---------- 1. prerequisites ----------
head "1) Checking prerequisites"
missing=0
for t in bash curl python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t found"; else err "$t missing"; missing=1; fi
done
if [ "$missing" = "1" ]; then
  err "Install the missing tool(s) and re-run. (Linux: apt/yum; macOS: they're built in or via brew.)"
  exit 1
fi

# ---------- 2. choose channels ----------
head "2) Where should alerts go?"
say "  ${B}1)${R} Slack   ${D}— free, posts to a channel (you'll need a webhook URL)${R}"
say "  ${B}2)${R} ntfy    ${D}— free push app with a reliable alarm sound (great on phones)${R}"
say "  ${B}3)${R} Both${R}"
choice="$(ask "Choose 1, 2, or 3:" "1")"

ENABLE_SLACK=false; SLACK_WEBHOOK_URL=""
ENABLE_NTFY=false;  NTFY_TOPIC=""; NTFY_SERVER="https://ntfy.sh"; NTFY_TOKEN=""
[[ "$choice" =~ [13] ]] && ENABLE_SLACK=true
[[ "$choice" =~ [23] ]] && ENABLE_NTFY=true

# ---------- 3. Slack ----------
if [ "$ENABLE_SLACK" = "true" ]; then
  head "3) Slack setup"
  say "${D}How to get a webhook (≈2 min):${R}"
  say "  1. Create/pick a workspace at ${CYN}https://slack.com/create${R} (free)."
  say "  2. Make a channel, e.g. ${B}#claude-alerts${R}."
  say "  3. ${CYN}https://api.slack.com/apps${R} → Create New App → From scratch."
  say "  4. Incoming Webhooks → On → Add New Webhook to Workspace → pick the channel."
  say "  5. Copy the ${B}https://hooks.slack.com/services/...${R} URL."
  while :; do
    SLACK_WEBHOOK_URL="$(ask "Paste your Slack webhook URL:")"
    if [[ "$SLACK_WEBHOOK_URL" == https://hooks.slack.com/services/* ]]; then break; fi
    warn "That doesn't look like a Slack webhook URL. Try again (or Ctrl-C to abort)."
  done
fi

# ---------- 4. ntfy ----------
if [ "$ENABLE_NTFY" = "true" ]; then
  head "4) ntfy setup"
  def_topic="claude-alerts-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c6)"
  [ -n "$def_topic" ] || def_topic="claude-alerts-mytopic"
  say "${D}A topic is like a private channel name — anyone who knows it can read it,${R}"
  say "${D}so keep the suggested random one unless you have a reason to change it.${R}"
  NTFY_TOPIC="$(ask "Topic name:" "$def_topic")"
  NTFY_SERVER="$(ask "ntfy server:" "https://ntfy.sh")"
  say ""
  say "  On your ${B}phone${R}: install the ${B}ntfy${R} app (App Store / Play Store),"
  say "  tap ${B}+${R} → Subscribe → enter topic ${B}$NTFY_TOPIC${R}"
  if [ "$NTFY_SERVER" != "https://ntfy.sh" ]; then say "  and server ${B}$NTFY_SERVER${R}"; fi
  say "  ${D}(Or just open ${NTFY_SERVER}/${NTFY_TOPIC} in a browser tab.)${R}"
  confirm "Subscribed on your device?" >/dev/null || true
fi

# ---------- 5. events ----------
head "5) When should it alert you?"
say "  ${B}1)${R} Only when Claude needs input ${D}(quiet, high-signal)${R}"
say "  ${B}2)${R} Needs input ${B}and${R} task finished ${D}(more alerts)${R}"
ev="$(ask "Choose 1 or 2:" "2")"
NOTIFY_ON_NOTIFICATION=true
if [ "$ev" = "1" ]; then NOTIFY_ON_STOP=false; else NOTIFY_ON_STOP=true; fi

# ---------- 6. write env ----------
head "6) Writing config"
mkdir -p "$CLAUDE_DIR"
if [ -f "$ENV_FILE" ] && ! confirm "$ENV_FILE exists — overwrite it?"; then
  warn "Keeping existing $ENV_FILE. Edit it by hand if needed."
else
  umask 077
  cat > "$ENV_FILE" <<EOF
# notify.env — generated by setup.sh. Holds secrets; keep private (chmod 600).
NOTIFY_ON_NOTIFICATION="$NOTIFY_ON_NOTIFICATION"
NOTIFY_ON_STOP="$NOTIFY_ON_STOP"

ENABLE_SLACK="$ENABLE_SLACK"
SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL"

ENABLE_NTFY="$ENABLE_NTFY"
NTFY_TOPIC="$NTFY_TOPIC"
NTFY_SERVER="$NTFY_SERVER"
NTFY_TOKEN="$NTFY_TOKEN"

ENABLE_SMS="false"
TWILIO_ACCOUNT_SID=""
TWILIO_AUTH_TOKEN=""
TWILIO_FROM_NUMBER=""
TO_PHONE_NUMBER=""
EOF
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE (chmod 600)"
fi

# ---------- 7. install hooks ----------
head "7) Installing dispatcher + hooks"
CLAUDE_NOTIFY_QUIET=1 bash "$SRC_DIR/install.sh"
ok "Dispatcher installed and hooks wired into settings.json"

# ---------- 8. live test ----------
head "8) Sending a test"
say "${D}Tip: switch away from the target Slack channel first — Slack mutes the${R}"
say "${D}channel you're actively viewing.${R}"
confirm "Send a test notification now?" && {
  echo "{\"message\":\"claude-notify setup test — you're all set!\",\"cwd\":\"$PWD\"}" \
    | bash "$DISPATCHER" Notification
  sleep 1
  tail -n 3 "$CLAUDE_DIR/notify.log" 2>/dev/null | sed "s/^/${D}log: /; s/$/${R}/"
  if ! confirm "Did you SEE and HEAR it?"; then
    head "No sound? The usual culprit on macOS (we've seen this!):"
    say "  • ${B}Sound effects channel is separate from media volume.${R}"
    say "    System Settings → Sound → ${B}Sound Effects${R}:"
    say "      – ${B}Alert volume${R} up"
    say "      – ${B}Play sound effects through${R} → your real speakers/headphones"
    say "      – ${B}Play user interface sound effects${R} → on"
    say "  • Turn off ${B}Do Not Disturb / Focus${R}."
    say "  • Slack → Preferences → Notifications → notification sound ≠ ${B}None${R};"
    say "    and ${B}Notify me about → All new messages${R} (per workspace)."
    say "  • Not seeing it at all? Make sure you weren't viewing that channel."
    say "  ${D}Re-test anytime:  echo '{\"message\":\"hi\"}' | bash $DISPATCHER Notification${R}"
  else
    ok "It works!"
  fi
}

# ---------- done ----------
head "Done 🎉"
say "New Claude Code sessions on this machine will now notify you."
say ""
say "${B}Manage it:${R}"
say "  • Mute fast:      set ${B}ENABLE_SLACK=\"false\"${R} (or ENABLE_NTFY) in $ENV_FILE"
say "  • Quiet 'done':   set ${B}NOTIFY_ON_STOP=\"false\"${R}"
say "  • Status check:   ${B}./status.sh${R}"
say "  • Remove hooks:   ${B}./uninstall.sh${R}"
say "  • Re-run wizard:  ${B}./setup.sh${R}"
