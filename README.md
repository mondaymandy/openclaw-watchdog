# OpenClaw Watchdog

Independent process monitor for OpenClaw gateway. Runs outside OpenClaw so it can detect and recover from gateway failures.

## What It Monitors

Every 30 seconds (configurable):

1. **Gateway process** — Is the process running? If not, auto-restart via `launchctl kickstart` and alert.
2. **Health endpoint** — Is the gateway responding to HTTP? Alerts after 3 consecutive failures (process alive but unhealthy).
3. **Battery status** (macOS) — Is the Mac unplugged? Alerts after 5 minutes on battery.

## Why

OpenClaw can't monitor itself if it's down. This watchdog runs as a separate launchd job — completely independent. If the gateway crashes, gets stuck, or the Mac loses power, you get an alert and (where possible) auto-recovery.

## Setup

### 1. Configure the script

Edit `openclaw-watchdog.sh` and set:

```bash
GATEWAY_LABEL="ai.openclaw.gateway"  # Your launchd label
GATEWAY_PORT=18789                    # Your gateway port
WA_ALERT_TARGET=""                    # Phone/group JID for WhatsApp alerts
CHECK_INTERVAL=30                     # Seconds between checks
UNPLUG_ALERT_AFTER=300                # Seconds on battery before alerting
ALERT_COOLDOWN=300                    # Min seconds between repeated alerts
```

### 2. Install the launchd plist

Copy `ai.openclaw.watchdog.plist` to `~/Library/LaunchAgents/`:

```bash
cp ai.openclaw.watchdog.plist ~/Library/LaunchAgents/
```

Update the script path inside the plist if needed.

### 3. Load it

```bash
launchctl load ~/Library/LaunchAgents/ai.openclaw.watchdog.plist
```

### 4. Verify

```bash
# Check it's running
launchctl list | grep watchdog

# Check logs
tail -f ~/.openclaw/watchdog/watchdog.log
```

## Alert Delivery

Alerts try two paths:
1. `openclaw message send` CLI (works if gateway is alive but session is stuck)
2. Direct HTTP to gateway API (works if process is up but CLI is broken)

**Limitation:** If the gateway is fully dead, WhatsApp alerts won't work either (they route through the same process). For true independence, add an external webhook (Slack, email, etc.) to the `send_alert` function.

## State Management

The watchdog tracks state in `~/.openclaw/watchdog/state.json`:
- Last alert timestamps (per check type) — prevents spam
- Battery switch timestamp — tracks how long on battery
- Consecutive health failures — only alerts after 3

## Files

- `openclaw-watchdog.sh` — Main watchdog script
- `ai.openclaw.watchdog.plist` — macOS launchd config
- `state.json` — Runtime state (auto-created)
- `watchdog.log` — Log file

## License

MIT
