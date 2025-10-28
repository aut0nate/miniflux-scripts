#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Finder
# ---------------------------------------------------------------
# Performs fuzzy search across all Miniflux feeds by title.
# Designed to run standalone or under run-all.sh.
# ===============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/home/nathan/scripts/logs"
LOG_FILE="$LOG_DIR/find_feeds.log"
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"
MAX_LOG_SIZE=$((5 * 1024 * 1024)) # 5 MB

mkdir -p "$LOG_DIR"

# --- Logging helpers ---
log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="[$ts] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

trim_log() {
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "🧹 Log trimmed to last 500 lines (exceeded 5 MB)"
  fi
}

# --- Validate input ---
if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <search_term>"
  exit 1
fi
SEARCH_TERM="$1"

# --- Dependency check ---
REQUIRED_CMDS=("bws" "jq" "curl")
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

# --- Fetch secrets ---
MINIFLUX_URL="$(bws secret get "$MINIFLUX_URL_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"
MINIFLUX_TOKEN="$(bws secret get "$MINIFLUX_TOKEN_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"

if [ -z "$MINIFLUX_URL" ] || [ -z "$MINIFLUX_TOKEN" ]; then
  log "❌ Missing required secrets (MINIFLUX_URL or MINIFLUX_TOKEN)"
  exit 1
fi

# --- Normalise URL ---
MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

log "🔍 Searching feeds for: '$SEARCH_TERM'"

# --- Query and fuzzy-match feeds ---
response=$(curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds")

matches=$(echo "$response" | jq --arg term "$SEARCH_TERM" \
  '.[] | select(.title | test($term; "i")) | {id, title, feed_url}')

if [ -z "$matches" ]; then
  log "❌ No feeds found matching '$SEARCH_TERM'"
  trim_log
  exit 0
fi

echo "$matches" | jq -r '"id: \(.id)\ntitle: \(.title)\nfeed_url: \(.feed_url)\n---"' | tee -a "$LOG_FILE"

count=$(echo "$matches" | jq -r 'length' 2>/dev/null || true)
log "✅ Found matching feeds for '$SEARCH_TERM'"
trim_log
