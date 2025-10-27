#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Filter Updater
# - Reads config from YAML
# - Retrieves Miniflux URL + token from Bitwarden Secrets (bws)
# - Safe for cron: fixed PATH + SSL certs
# - Always sends an ntfy notification (success OR failure)
# - On failure, includes detailed error info
# ===============================================================

set -Eeuo pipefail   # -E: make ERR trap propagate into functions

# --- Environment for cron (DO NOT REMOVE) ---
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/usr/local/sbin:$PATH"
export SSL_CERT_DIR="/etc/ssl/certs"
export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"

# --- Configuration ---
CONFIG="$HOME/scripts/miniflux/config/filters.yaml"
LOG_FILE="$HOME/scripts/miniflux/logs/filter_feeds.log"
NTFY_TOPIC="https://ntfy.ts.autonate.dev/miniflux-filter"  # change if needed

MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# --- Runtime state for notifications ---
STATUS="success"                # or "error" (set by ERR trap)
ERROR_DETAILS=""                # appended by ERR trap
START_TS="$(date +%s)"
UPDATED_COUNT=0
UPDATED_FEEDS=()               # names of updated feeds

# --- Helpers ---
log() {
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

send_ntfy() {
  # send_ntfy "body" "Title text" "tag1,tag2"
  local body="${1:-}"
  local title="${2:-Miniflux Filter Sync}"
  local tags="${3:-}"

  # Build curl with optional headers
  local args=(-fsS -d "$body" -H "Title: $title")
  [ -n "$tags" ] && args+=(-H "Tags: $tags")

  if curl "${args[@]}" "$NTFY_TOPIC" >/dev/null 2>&1; then
    log "📨 ntfy notification sent"
  else
    log "⚠️ Failed to send ntfy notification to $NTFY_TOPIC"
  fi
}

# Trap any error and capture details (command + line + exit code)
err_trap() {
  local exit_code=$?
  local cmd="${BASH_COMMAND}"
  local line="${BASH_LINENO[0]}"
  STATUS="error"
  ERROR_DETAILS+=$'\n'"Exit code: ${exit_code}"
  ERROR_DETAILS+=$'\n'"Command  : ${cmd}"
  ERROR_DETAILS+=$'\n'"Line     : ${line}"
  # Let EXIT trap run to send the notification
}
trap err_trap ERR

# Always send a final notification (success or failure)
exit_trap() {
  local end_ts="$(date +%s)"
  local dur="$(( end_ts - START_TS ))s"

  if [ "$STATUS" = "success" ]; then
    if [ "${#UPDATED_FEEDS[@]}" -eq 0 ]; then
      # No updates — still notify (as requested, option D)
      send_ntfy "Filter sync completed in ${dur}. Updated 0 feed(s)." "Miniflux Filter Sync" "ok"
    else
      # Multi-line list
      local msg="Filter sync completed in ${dur}. Updated ${UPDATED_COUNT} feed(s):"
      for feed in "${UPDATED_FEEDS[@]}"; do
        msg+=$'\n'"• ${feed}"
      done
      send_ntfy "$msg" "Miniflux Filter Sync" "ok"
    fi
  else
    # Failure message with details
    # Keep it concise but informative
    local msg="Filter sync FAILED after ${dur}."
    msg+=$'\n'"See log: ${LOG_FILE}"
    [ -n "$ERROR_DETAILS" ] && msg+=$'\n'"Details:"$'\n'"${ERROR_DETAILS}"
    send_ntfy "$msg" "Miniflux Filter Sync ❌" "warning,rotating_light"
  fi
}
trap exit_trap EXIT

# ----------------- Main -----------------
log "🚀 Starting Miniflux Filter Sync..."

# Dependency check
REQUIRED_CMDS=("bws" "jq" "yq" "curl" "stat")
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_CMDS+=("$cmd")
  fi
done
if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
  log "❌ Missing dependencies: ${MISSING_CMDS[*]}"
  # Trigger failure path (trap/EXIT will notify)
  exit 1
fi

# Bitwarden access token
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  if [ -f /opt/secrets/.bws-env ]; then
    # shellcheck disable=SC1091
    source /opt/secrets/.bws-env
    log "🔑 Loaded Bitwarden token from /opt/secrets/.bws-env"
  else
    log "❌ BWS_ACCESS_TOKEN not found. Run 'source /opt/secrets/.bws-env' or 'bws login'."
    exit 1
  fi
fi

# Fetch secrets
MINIFLUX_URL="$(bws secret get "$MINIFLUX_URL_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"
MINIFLUX_TOKEN="$(bws secret get "$MINIFLUX_TOKEN_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"

if [ -z "$MINIFLUX_URL" ] || [ -z "$MINIFLUX_TOKEN" ]; then
  log "❌ Missing required secrets (MINIFLUX_URL or MINIFLUX_TOKEN)"
  exit 1
fi

# Normalise URL
MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

# Config check
if [ ! -f "$CONFIG" ]; then
  log "❌ Config not found: $CONFIG"
  exit 1
fi

log "📘 Using config: $CONFIG"
log "📏 Config size: $(stat -c%s "$CONFIG") bytes"

# Iterate feeds
while IFS= read -r entry; do
  FEED_ID=$(echo "$entry"   | jq -r '.key')
  FEED_NAME=$(echo "$entry" | jq -r '.value.name // "Unnamed Feed"')
  FEED_URL=$(echo "$entry"  | jq -r '.value.feed_url // "N/A"')
  BLOCK_RULES=$(echo "$entry" | jq -r '(.value.block_rules // []) | (if type=="array" then join("\n") else tostring end)')

  log "🔍 Checking feed $FEED_ID ($FEED_NAME, $FEED_URL)…"

  CURRENT_RULES=$(curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" \
                       "$MINIFLUX_URL/v1/feeds/$FEED_ID" \
                  | jq -r '.block_filter_entry_rules // ""')

  if [ "$BLOCK_RULES" = "$CURRENT_RULES" ]; then
    log "  → No changes, skipping."
    continue
  fi

  log "  → Updating block rules…"
  curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" -H "Content-Type: application/json" \
       -X PUT "$MINIFLUX_URL/v1/feeds/$FEED_ID" \
       -d "$(jq -n --arg b "$BLOCK_RULES" '{block_filter_entry_rules:$b}')"

  log "✅ Updated feed $FEED_ID ($FEED_NAME)"
  UPDATED_FEEDS+=("$FEED_NAME")
  UPDATED_COUNT=$((UPDATED_COUNT + 1))

  # Trim log to last 200 lines
  if [ "$(wc -l < "$LOG_FILE")" -gt 200 ]; then
    tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
done < <(yq eval -o=json --no-doc "$CONFIG" | jq -c '.feeds? // {} | to_entries[]')

log "🎉 Filter sync completed. Updated $UPDATED_COUNT feed(s)."
# EXIT trap will send the ntfy message (success/failure)
