# claude-notify

Get a phone notification when **Claude Code** needs your input or finishes a task —
so you can step away from the terminal. Works on any machine (remote server or
local) via Claude Code's hook system. Sends to **Slack** out of the box, with
optional **Twilio SMS**.

## How it works

Claude Code fires lifecycle [hooks](https://docs.claude.com/en/docs/claude-code/hooks).
Two are wired up:

| Event          | Fires when…                                              |
| -------------- | -------------------------------------------------------- |
| `Notification` | Claude is waiting on you for input / permission.         |
| `Stop`         | Claude finishes a turn.                                  |

Each event runs `notify-dispatcher.sh`, which reads the event payload and posts a
message to your configured channel(s). Secrets live in `~/.claude/notify.env`
(never committed); the hook wiring lives in `~/.claude/settings.json`.

## Install (on any machine)

```bash
git clone <your-remote> claude-notify
cd claude-notify
./install.sh
```

Then edit `~/.claude/notify.env` and paste your Slack webhook URL into
`SLACK_WEBHOOK_URL`. New Claude Code sessions on that machine will start notifying.

`install.sh` is idempotent and backs up `settings.json` before editing — safe to
re-run after `git pull` to pick up updates.

## Get a Slack webhook (free, ~2 min)

1. Create a free workspace at <https://slack.com/create> (or use any workspace
   where you can install apps).
2. Make a channel, e.g. `#claude-alerts`.
3. <https://api.slack.com/apps> → **Create New App** → **From scratch** → pick the
   workspace.
4. **Incoming Webhooks** → toggle **On** → **Add New Webhook to Workspace** →
   choose `#claude-alerts`.
5. Copy the `https://hooks.slack.com/services/...` URL into `notify.env`.
6. On your phone's Slack app, add the workspace and set that channel's
   notifications to **All messages**.

## Configure

All settings live in `~/.claude/notify.env`:

| Variable                 | Meaning                                             |
| ------------------------ | --------------------------------------------------- |
| `ENABLE_SLACK`           | `true`/`false` — Slack on/off                       |
| `SLACK_WEBHOOK_URL`      | your incoming-webhook URL                           |
| `NOTIFY_ON_NOTIFICATION` | alert when Claude needs input                       |
| `NOTIFY_ON_STOP`         | alert when Claude finishes a turn                   |
| `ENABLE_SMS` + `TWILIO_*`| optional Twilio SMS (off by default)                |

Toggling a channel off is just `ENABLE_SLACK="false"` — no need to touch hooks.

## Test

```bash
echo '{"message":"hello","cwd":"/tmp/myproject"}' \
  | bash ~/.claude/notify-dispatcher.sh Notification
tail ~/.claude/notify.log
```

## Uninstall

```bash
./uninstall.sh          # removes the hooks; leaves your env/script in place
```

Or just disable without uninstalling: set `ENABLE_SLACK="false"` in `notify.env`.

## Notes

- Secrets stay in `~/.claude/notify.env` (chmod 600) and are **gitignored**.
- The hook command uses `$HOME`, so the same `settings.json` is portable across
  machines and users.
- Requires `bash`, `curl`, and `python3` (used for safe JSON encoding).
