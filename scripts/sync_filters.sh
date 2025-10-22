#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Filter Updater
# Retrieves Miniflux URL and API token securely from Bitwarden
# ===============================================================

set -uo pipefail

# --- Configuration ---
CONFIG="$HOME/scripts/miniflux/config/filters.yaml"
LOG_FILE="$HOME/scripts/miniflux/logs/filter_feeds.log"
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --- Logging Helpers ---
log() { echo "$*"; }

# --- Dependency Check ---
REQUIRED_CMDS=("bws" "jq" "yq" "curl" "stat")
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
  echo "📦 Example (Ubuntu/Debian): sudo apt install jq yq curl coreutils"
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
  echo "❌ Error: Missing required secrets (MINIFLUX_URL or MINIFLUX_TOKEN)"
  exit 1
fi

# --- Normalise URL ---
MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

# --- Sanity Checks ---
[ -f "$CONFIG" ] || { echo "❌ Config not found: $CONFIG"; exit 1; }

log "🔐 Using Bitwarden secrets for configuration"
log "📘 Reading config: $CONFIG"
log "📏 Config size: $(stat -c%s "$CONFIG") bytes"

UPDATED_COUNT=0

# --- Process Each Feed ---
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

  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated feed $FEED_ID ($FEED_NAME)"
  } >> "$LOG_FILE"

  UPDATED_COUNT=$((UPDATED_COUNT + 1))

  # Trim log to last 200 lines safely
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 200 ]; then
    tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
done < <(yq eval -o=json --no-doc "$CONFIG" | jq -c '.feeds? // {} | to_entries[]')

log "✅ Filter sync completed. Updated $UPDATED_COUNT feed(s)."
