#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Filter Updater
# ---------------------------------------------------------------
# Updates feed filter rules using Miniflux API.
# Designed to run under run-all.sh with shared logging and BW env.
# ===============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/home/nathan/scripts/logs"
LOG_FILE="$LOG_DIR/sync_filters.log"
CONFIG="/home/nathan/scripts/miniflux/config/filters.yaml"
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"
MAX_LOG_SIZE=$((5 * 1024 * 1024)) # 5MB

mkdir -p "$LOG_DIR"

# --- Logging helper ---
log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

# --- Log trimming helper (5MB cap) ---
trim_log() {
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "🧹 Log trimmed to last 500 lines (exceeded 5 MB)"
  fi
}

# --- Dependency check ---
REQUIRED_CMDS=("bws" "jq" "yq" "curl" "stat")
for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "❌ Missing dependency: $cmd"
    exit 1
  }
done

# --- Verify Bitwarden session ---
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  echo "❌ Bitwarden session not detected. Please run via run-all.sh or source /opt/secrets/.bws-env first."
  exit 1
fi

# --- Fetch secrets from Bitwarden ---
MINIFLUX_URL="$(bws secret get "$MINIFLUX_URL_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"
MINIFLUX_TOKEN="$(bws secret get "$MINIFLUX_TOKEN_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"

if [ -z "$MINIFLUX_URL" ] || [ -z "$MINIFLUX_TOKEN" ]; then
  log "❌ Error: Missing required secrets (MINIFLUX_URL or MINIFLUX_TOKEN)"
  exit 1
fi

# --- Normalise URL ---
MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

# --- Sanity check ---
[ -f "$CONFIG" ] || { log "❌ Config not found: $CONFIG"; exit 1; }

log "🔐 Using Bitwarden secrets for configuration"
log "📘 Reading config: $CONFIG"
log "📏 Config size: $(stat -c%s "$CONFIG") bytes"

UPDATED_COUNT=0

# --- Process each feed ---
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

  log "  ✅ Updated feed $FEED_ID ($FEED_NAME)"
  UPDATED_COUNT=$((UPDATED_COUNT + 1))
  trim_log
done < <(yq eval -o=json --no-doc "$CONFIG" | jq -c '.feeds? // {} | to_entries[]')

log "✅ Filter sync completed. Updated $UPDATED_COUNT feed(s)."
trim_log
