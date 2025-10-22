#!/usr/bin/env bash
# ============================================================
# Miniflux Failed Feed Refresher
# Retrieves Miniflux URL and API token securely from Bitwarden
# Refreshes only feeds currently marked as failing in Miniflux
# ============================================================

set -uo pipefail

# --- Configuration ---
LOG_FILE="$HOME/scripts/miniflux/logs/refresh_feeds.log"
MAX_LOG_LINES=200
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --- Logging Helpers ---
log() { echo "$*"; }

# --- Dependency Check ---
REQUIRED_CMDS=("bws" "jq" "curl" "mktemp" "tail")
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
  echo "📦 Example (Ubuntu/Debian): sudo apt install jq curl coreutils"
  echo "📦 Bitwarden Secrets CLI: https://bitwarden.com/help/secrets-manager-cli/#download-and-install"
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

# --- Helper: Trim log safely ---
trim_log() {
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

log "🔐 Using Bitwarden secrets for configuration"
log "📉 Fetching failing feeds from Miniflux..."

# --- Fetch failing feeds (feeds with parsing errors) ---
failing_feed_data=$(curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds" \
  | jq -c '.[] | select((.parsing_error_count > 0) or (.parsing_error_message != "")) | {id, title, parsing_error_message}')

if [ -z "$failing_feed_data" ]; then
  log "✅ No failing feeds detected."
  trim_log
  exit 0
fi

log "⚠️  Found failing feeds:"
echo "$failing_feed_data" | jq -r '.id as $id | .title | "\( $id ) \(. // "Untitled")"' | sed 's/^/   - /'

UPDATED_COUNT=0
FAILED_COUNT=0

# --- Refresh each failing feed ---
echo "$failing_feed_data" | jq -r '.id' | while read -r id; do
  if [ -z "$id" ]; then continue; fi

  STATUS_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    "$MINIFLUX_URL/v1/feeds/$id/refresh")

  case "$STATUS_CODE" in
    204)
      log "  → Refreshed feed ID $id successfully (204)"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Refreshed feed ID $id" >> "$LOG_FILE"
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      ;;
    401|403)
      log "  ⚠️ Failed to refresh feed ID $id — unauthorised ($STATUS_CODE)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
    404)
      log "  ⚠️ Feed ID $id not found ($STATUS_CODE)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
    429|5*)
      log "  ⚠️ Transient error ($STATUS_CODE) refreshing feed ID $id — retrying once..."
      sleep 2
      RETRY_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "X-Auth-Token: $MINIFLUX_TOKEN" \
        "$MINIFLUX_URL/v1/feeds/$id/refresh")
      if [ "$RETRY_STATUS" = "204" ]; then
        log "     ✅ Retry successful for feed ID $id"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retry successful for feed ID $id" >> "$LOG_FILE"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
      else
        log "     ❌ Retry failed ($RETRY_STATUS) for feed ID $id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
      fi
      ;;
    *)
      log "  ❌ Unexpected status ($STATUS_CODE) while refreshing feed ID $id"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
  esac
done

# --- Summary ---
log ""
log "===== SUMMARY ====="
log "✅ Refreshed successfully: $UPDATED_COUNT feed(s)"
log "⚠️  Failed to refresh: $FAILED_COUNT feed(s)"
log "==================="
trim_log
