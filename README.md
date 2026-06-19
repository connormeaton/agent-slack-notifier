# agent-slack-notifier

Get a phone/desktop alert when **Claude Code** needs your input or finishes a
task — so you can step away from the terminal. Works on any machine (remote
server or local) via Claude Code's hook system.

**Channels:** Slack (free), ntfy.sh (free push app with a reliable sound), and
optional Twilio SMS.

## Quick start

```bash
git clone git@github.com:connormeaton/agent-slack-notifier.git
cd agent-slack-notifier
./setup.sh          # guided wizard: pick channels, paste creds, test
```

That's it. The wizard checks prerequisites, walks you through Slack and/or ntfy,
writes your config, wires up the hooks, and sends a live test. New Claude Code
sessions on that machine then notify you automatically.

Prefer to do it by hand or automate it? See [Manual install](#manual-install).

## How it works

Claude Code fires lifecycle [hooks](https://docs.claude.com/en/docs/claude-code/hooks).
There is **no daemon** — nothing runs in the background. Two events are wired up,
and each just runs `notify-dispatcher.sh` once when it fires:

| Event          | Fires when…                                       |
| -------------- | ------------------------------------------------- |
| `Notification` | Claude is waiting on you for input / permission.  |
| `Stop`         | Claude finishes a turn.                            |

Secrets live in `~/.claude/notify.env` (chmod 600, never committed). The hook
wiring lives in `~/.claude/settings.json`.

## Commands

| Command          | What it does                                                  |
| ---------------- | ------------------------------------------------------------- |
| `./setup.sh`     | Guided onboarding wizard (recommended).                       |
| `./install.sh`   | Non-interactive install — copies dispatcher, merges hooks.    |
| `./status.sh`    | Show current config, whether hooks are wired, recent log.     |
| `./install-approvals.sh` | Wire the optional Slack approval gate (PreToolUse).    |
| `./away.sh on\|off` | Arm/disarm Slack command approvals.                        |
| `./uninstall.sh` | Remove all hooks (leaves your env/scripts).                   |

All are idempotent and back up `settings.json` before editing. Re-run after a
`git pull` to pick up updates.

## Channels

### Slack (free)
1. Create/pick a workspace at <https://slack.com/create>.
2. Make a channel, e.g. `#claude-alerts`.
3. <https://api.slack.com/apps> → **Create New App** → **From scratch** → pick the
   workspace.
4. **Incoming Webhooks** → **On** → **Add New Webhook to Workspace** → choose the
   channel → copy the `https://hooks.slack.com/services/...` URL.

The wizard asks for that URL. On your phone's Slack app, set the channel's
notifications to **All messages** (by default Slack only sounds for DMs/mentions).

### ntfy (free, best for guaranteed sound)
1. Install the **ntfy** app (App Store / Play Store), or open <https://ntfy.sh>.
2. Subscribe to a secret topic (the wizard generates one like
   `claude-alerts-7f3a9k` — treat it like a password).
3. The wizard enables it and tests it. Self-hosted ntfy and auth tokens are
   supported via `NTFY_SERVER` / `NTFY_TOKEN`.

### Twilio SMS (optional, paid)
Set `ENABLE_SMS="true"` and the `TWILIO_*` values in `~/.claude/notify.env`.

## Configuration

Everything lives in `~/.claude/notify.env`:

| Variable                 | Meaning                                       |
| ------------------------ | --------------------------------------------- |
| `NOTIFY_ON_NOTIFICATION` | alert when Claude needs input                 |
| `NOTIFY_ON_STOP`         | alert when Claude finishes a turn             |
| `ENABLE_SLACK` / `SLACK_WEBHOOK_URL` | Slack on/off + webhook            |
| `ENABLE_NTFY` / `NTFY_TOPIC` / `NTFY_SERVER` / `NTFY_TOKEN` | ntfy   |
| `ENABLE_SMS` / `TWILIO_*`| Twilio SMS                                    |

**Turn it off without uninstalling:** set the channel's `ENABLE_*` to `"false"`.
Takes effect on the next event (no restart needed). Silence just the "finished"
pings with `NOTIFY_ON_STOP="false"`.

## Troubleshooting: "I see it but don't hear it" (macOS)

This bit us during development, so here's the fix. macOS plays notification
sounds on the **sound-effects channel, which is separate from media volume** —
so music can be loud while notifications are silent. Check:

- **System Settings → Sound → Sound Effects**
  - **Alert volume** turned up
  - **Play sound effects through** → your real speakers/headphones (often
    silently points at a monitor with no speakers)
  - **Play user interface sound effects** → on
- Turn off **Do Not Disturb / Focus**.
- Slack: notification sound ≠ **None**, and **Notify me about → All new
  messages** (this is **per workspace** — easy to miss if you have two accounts).
- Slack mutes the channel you're **actively viewing** — test with another channel
  focused.

If it's still flaky, use **ntfy** — it's built to make a reliable sound.

## Approve commands from Slack (optional, two-way)

Beyond *notifications*, you can **approve or deny tool calls from Slack** while
you're away. It uses Claude Code's `PreToolUse` hook: when Claude wants to run a
matched tool, the hook posts the command to Slack and waits for you to react
✅ (allow) or ❌ (deny), then returns that decision to Claude.

**Properties:**
- **Opt-in & disarmed by default** — installing the gate does nothing until you
  arm it. Disarmed = instant passthrough, your normal workflow is untouched.
- **Fail closed** — no reaction before `APPROVAL_TIMEOUT` → the command is
  **denied** (Claude Code's own hook timeout fails *open*, so we deny first).
- **Fail soft on misconfig** — if armed but the bot token is missing/Slack is
  unreachable, it falls back to the normal local permission prompt (`ask`), so a
  present user is never hard-blocked.

### Requires a Slack bot token (not the webhook)
Reading your reaction needs the Slack Web API, so the one-way Incoming Webhook
isn't enough. In your Slack app at <https://api.slack.com/apps>:
1. **OAuth & Permissions → Bot Token Scopes** → add `chat:write` and
   `reactions:read`.
2. **Install App** to the workspace → copy the **Bot User OAuth Token** (`xoxb-…`).
3. Invite the bot to your channel: `/invite @YourBot`.
4. Get the **channel ID** (right-click the channel → View channel details → ID at
   the bottom, like `C0123456789`).

### Enable it
```bash
./install-approvals.sh                       # wire the PreToolUse gate (default: Bash)
APPROVAL_MATCHER="Bash|Edit|Write" ./install-approvals.sh   # or gate more tools
```
Then set in `~/.claude/notify.env`:
```bash
SLACK_BOT_TOKEN="xoxb-…"
SLACK_CHANNEL_ID="C0123456789"
# optional: APPROVER_USER_IDS="U0123 U0456"   # only these users' reactions count
```
Arm when you step away, disarm when back:
```bash
./away.sh on        # tool calls now require Slack approval
./away.sh off       # back to normal
./away.sh           # show current state
```

> ⚠️ Anyone who can react in that channel can approve commands. Use a **private
> channel**, set `APPROVER_USER_IDS` to restrict who counts, and gate only the
> tools you care about (`APPROVAL_MATCHER`) to avoid approval fatigue.

## Notes

- Secrets stay in `~/.claude/notify.env` (chmod 600) and are **gitignored**.
- Hook commands use `$HOME`, so `settings.json` is portable across machines/users.
- Requires `bash`, `curl`, and `python3`.

## Manual install

```bash
./install.sh                                  # dispatcher + hooks
cp notify.env.example ~/.claude/notify.env    # if not already present
chmod 600 ~/.claude/notify.env
# edit ~/.claude/notify.env with your webhook/topic
echo '{"message":"hi","cwd":"'"$PWD"'"}' | bash ~/.claude/notify-dispatcher.sh Notification
```

## License

MIT — see [LICENSE](LICENSE).
