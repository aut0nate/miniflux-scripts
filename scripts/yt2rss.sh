#!/bin/bash
# ============================================================
# Add YouTube Channel to Miniflux via RSS Feed
# Retrieves Miniflux URL and API token securely from Bitwarden
# ============================================================

set -uo pipefail

# --- Configuration ---
CATEGORY_ID=21
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --- Optional Verbose Mode ---
VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
  VERBOSE=true
  shift
fi

log() { echo "$*"; }
debug() { $VERBOSE && echo "[DEBUG] $*"; }

# --- Pre-Run Requirements Check ---
REQUIRED_CMDS=("bws" "jq" "curl" "grep")
MISSING_CMDS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_CMDS+=("$cmd")
  fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
  echo "❌ Missing required dependencies: ${MISSING_CMDS[*]}"
  echo "Please install them before running this script."
  echo
  echo "📦 Example (Ubuntu/Debian): sudo apt install jq curl grep"
  echo "📦 Bitwarden Secrets CLI (Linux): https://bitwarden.com/help/secrets-manager-cli/#download-and-install"
  exit 1
fi

# --- Load Bitwarden Access Token ---
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  if [ -f /opt/secrets/.bws-env ]; then
    source /opt/secrets/.bws-env
  else
    echo "❌ BWS_ACCESS_TOKEN not found. Please run 'source /opt/secrets/.bws-env' or 'bws login'."
    exit 1
  fi
fi

# --- Fetch secrets from Bitwarden ---
MINIFLUX_URL="$(bws secret get "$MINIFLUX_URL_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"
MINIFLUX_TOKEN="$(bws secret get "$MINIFLUX_TOKEN_ID" 2>/dev/null | jq -r '.value' | tr -d '\r\n' | xargs)"

if [ -z "$MINIFLUX_URL" ] || [ -z "$MINIFLUX_TOKEN" ]; then
  log "❌ Error: Failed to retrieve Miniflux secrets from Bitwarden."
  exit 1
fi

# Normalise URL
MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"
API_ENDPOINT="$MINIFLUX_URL/v1/feeds"

debug "MINIFLUX_URL=$MINIFLUX_URL"
debug "API_ENDPOINT=$API_ENDPOINT"
debug "TOKEN length=${#MINIFLUX_TOKEN}"

# --- Validate argument ---
if [ -z "${1:-}" ]; then
  echo "Usage: $0 [--verbose] <YouTube_Channel_URL>"
  exit 1
fi
URL="$1"

# --- Extract Channel ID ---
if echo "$URL" | grep -q "/channel/"; then
  CHANNEL_ID=$(echo "$URL" | grep -oP '(?<=/channel/)[A-Za-z0-9_-]+')
else
  HANDLE=$(echo "$URL" | grep -o '@[^/?]*')
  if [ -z "$HANDLE" ]; then
    log "❌ Error: could not extract handle from URL."
    exit 1
  fi
  HTML=$(curl -sL "https://www.youtube.com/$HANDLE/about")
  CHANNEL_ID=$(echo "$HTML" | grep -oP '(?<=channelId\":\")[^"]+' | head -n 1)
fi

# --- Validate channel ID pattern ---
if ! [[ "$CHANNEL_ID" =~ ^UC ]]; then
  log "❌ Invalid or unresolvable YouTube channel. Please check the URL."
  exit 1
fi

RSS_URL="https://www.youtube.com/feeds/videos.xml?channel_id=$CHANNEL_ID"
TITLE=$(curl -s "$RSS_URL" | grep -oPm1 "(?<=<title>)[^<]+")
TITLE=${TITLE:-"Unknown Channel"}

log "🔗 Resolved RSS Feed: $RSS_URL"
log "📺 Channel Title: $TITLE"

# --- Step 1: Skip if feed already exists ---
debug "Checking if feed already exists..."
if curl -s -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds" \
  | jq -e --arg url "$RSS_URL" '.[] | select(.feed_url==$url)' >/dev/null; then
  log "ℹ️ Feed already exists in Miniflux. Skipping creation."
  exit 0
fi

# --- Create Feed in Miniflux ---
debug "Creating feed..."
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" -X POST "$API_ENDPOINT" \
  -H "X-Auth-Token: $MINIFLUX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"feed_url\": \"$RSS_URL\", \"category_id\": $CATEGORY_ID}")

HTTP_STATUS=$(echo "$RESPONSE" | grep -oP '(?<=HTTP_STATUS:)\d+')
BODY=$(echo "$RESPONSE" | sed -E 's/HTTP_STATUS:[0-9]+//g')

debug "HTTP status: $HTTP_STATUS"
debug "Response body: $BODY"

if [ "$HTTP_STATUS" -eq 201 ]; then
  FEED_ID=$(echo "$BODY" | jq -r '.feed_id // empty')
  log "✅ Successfully added \"$TITLE\" (Feed ID: $FEED_ID) to Miniflux (Category: $CATEGORY_ID)"
elif [ "$HTTP_STATUS" -eq 400 ] && echo "$BODY" | grep -q "already exists"; then
  log "ℹ️ Feed already exists in Miniflux."
else
  log "❌ Failed to add channel to Miniflux. Response: $BODY"
  exit 1
fi

