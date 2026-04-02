#!/bin/bash
# OpenClaw Gateway Watchdog
# Independent process that monitors gateway health outside of OpenClaw itself.
# Runs as a separate launchd job — if the gateway is down, this still works.
#
# Checks:
# 1. Gateway process alive (pgrep + launchctl kickstart)
# 2. Gateway health endpoint responding (curl localhost)
# 3. Mac charger connected (pmset, macOS only)
#
# Alerts via direct WhatsApp API call (NOT through OpenClaw).

# === CONFIGURATION (adapt per instance) ===
GATEWAY_LABEL="ai.openclaw.gateway"
GATEWAY_PORT=18789
HEALTH_URL="http://127.0.0.1:${GATEWAY_PORT}/health"
CHECK_INTERVAL=30          # seconds between checks
UNPLUG_ALERT_AFTER=300     # seconds on battery before alerting (5 min)
ALERT_COOLDOWN=300         # seconds between repeated alerts (5 min)
LOG_FILE="$HOME/.openclaw/watchdog/watchdog.log"
STATE_FILE="$HOME/.openclaw/watchdog/state.json"

# WhatsApp alert config — direct to WA gateway, bypasses OpenClaw
WA_GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}"
WA_ALERT_TARGET=""  # Set to phone number or group JID for alerts
# NOTE: If gateway is fully down, WA alerts won't work either since they
# go through the same process. For true independence, use an external
# webhook (Slack, email, etc). This covers the "process alive but unhealthy" case.

# === FUNCTIONS ===

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

read_state() {
  local key="$1"
  local default="$2"
  if [ -f "$STATE_FILE" ]; then
    local val
    val=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('$key','$default'))" 2>/dev/null)
    echo "${val:-$default}"
  else
    echo "$default"
  fi
}

write_state() {
  local key="$1"
  local val="$2"
  if [ -f "$STATE_FILE" ]; then
    python3 -c "
import json
with open('$STATE_FILE','r') as f: d=json.load(f)
d['$key']='$val'
with open('$STATE_FILE','w') as f: json.dump(d,f)
" 2>/dev/null
  else
    echo "{\"$key\":\"$val\"}" > "$STATE_FILE"
  fi
}

seconds_since() {
  local ts="$1"
  if [ -z "$ts" ] || [ "$ts" = "0" ]; then
    echo "999999"
    return
  fi
  local now
  now=$(date +%s)
  echo $(( now - ts ))
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  
  # Try OpenClaw CLI first (works if gateway is alive but session is stuck)
  if command -v openclaw &>/dev/null && [ -n "$WA_ALERT_TARGET" ]; then
    openclaw message send --channel whatsapp --target "$WA_ALERT_TARGET" --message "$msg" 2>/dev/null && return 0
  fi
  
  # Fallback: direct HTTP to gateway (works if gateway process is up)
  if [ -n "$WA_ALERT_TARGET" ]; then
    curl -s -X POST "${WA_GATEWAY_URL}/api/message" \
      -H "Content-Type: application/json" \
      -d "{\"channel\":\"whatsapp\",\"to\":\"${WA_ALERT_TARGET}\",\"message\":\"${msg}\"}" 2>/dev/null && return 0
  fi
  
  log "ALERT DELIVERY FAILED — no working alert channel"
  return 1
}

check_gateway_process() {
  if pgrep -f "openclaw.*gateway" > /dev/null 2>&1; then
    return 0  # alive
  else
    return 1  # dead
  fi
}

check_gateway_health() {
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HEALTH_URL" 2>/dev/null)
  if [ "$http_code" = "200" ]; then
    return 0  # healthy
  else
    return 1  # unhealthy
  fi
}

check_power() {
  # macOS only — skip on Linux
  if ! command -v pmset &>/dev/null; then
    return 0
  fi
  
  local power_source
  power_source=$(pmset -g ps | head -1)
  
  if echo "$power_source" | grep -q "AC Power"; then
    # On charger — reset battery timer
    write_state "battery_since" "0"
    return 0
  else
    # On battery
    local battery_since
    battery_since=$(read_state "battery_since" "0")
    local now
    now=$(date +%s)
    
    if [ "$battery_since" = "0" ]; then
      write_state "battery_since" "$now"
      log "Switched to battery power"
      return 0  # Just switched, don't alert yet
    fi
    
    local on_battery_secs
    on_battery_secs=$(seconds_since "$battery_since")
    
    if [ "$on_battery_secs" -ge "$UNPLUG_ALERT_AFTER" ]; then
      local battery_pct
      battery_pct=$(pmset -g ps | grep -o '[0-9]*%' | head -1)
      return 1  # Been on battery too long
    fi
    
    return 0  # On battery but within grace period
  fi
}

# === MAIN LOOP ===

log "Watchdog started (PID $$)"

# Initialize state file
if [ ! -f "$STATE_FILE" ]; then
  echo '{"last_process_alert":"0","last_health_alert":"0","last_power_alert":"0","battery_since":"0","consecutive_health_fails":"0"}' > "$STATE_FILE"
fi

while true; do
  # --- Check 1: Gateway process ---
  if ! check_gateway_process; then
    _last_alert=$(read_state "last_process_alert" "0")
    _since_alert=$(seconds_since "$_last_alert")
    
    if [ "$_since_alert" -ge "$ALERT_COOLDOWN" ]; then
      log "Gateway process NOT running — attempting restart"
      launchctl kickstart -k "gui/$(id -u)/${GATEWAY_LABEL}" 2>/dev/null
      sleep 5
      
      if check_gateway_process; then
        send_alert "🔄 OpenClaw gateway was down — auto-restarted successfully"
        log "Gateway restarted successfully"
      else
        send_alert "🚨 OpenClaw gateway is DOWN and failed to restart! Manual intervention needed."
        log "Gateway restart FAILED"
      fi
      
      write_state "last_process_alert" "$(date +%s)"
    fi
  else
    # --- Check 2: Gateway health (only if process is alive) ---
    if ! check_gateway_health; then
      _fails=$(read_state "consecutive_health_fails" "0")
      _fails=$((_fails + 1))
      write_state "consecutive_health_fails" "$_fails"
      
      if [ "$_fails" -ge 3 ]; then
        _last_alert=$(read_state "last_health_alert" "0")
        _since_alert=$(seconds_since "$_last_alert")
        
        if [ "$_since_alert" -ge "$ALERT_COOLDOWN" ]; then
          send_alert "⚠️ OpenClaw gateway process alive but health check failing ($_fails consecutive failures)"
          write_state "last_health_alert" "$(date +%s)"
        fi
      fi
    else
      write_state "consecutive_health_fails" "0"
    fi
  fi
  
  # --- Check 3: Power (macOS) ---
  if ! check_power; then
    _last_alert=$(read_state "last_power_alert" "0")
    _since_alert=$(seconds_since "$_last_alert")
    
    if [ "$_since_alert" -ge "$ALERT_COOLDOWN" ]; then
      _battery_pct=$(pmset -g ps | grep -o '[0-9]*%' | head -1)
      send_alert "🔋 Mac on battery for 5+ minutes (${_battery_pct}). Plug in to avoid gateway shutdown."
      write_state "last_power_alert" "$(date +%s)"
    fi
  fi
  
  sleep "$CHECK_INTERVAL"
done
