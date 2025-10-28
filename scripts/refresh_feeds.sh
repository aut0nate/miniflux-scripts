#!/usr/bin/env bash
# ============================================================
# Miniflux Failed Feed Refresher
# ------------------------------------------------------------
# Refreshes feeds currently marked as failing in Miniflux.
# Designed to run under run-all.sh (Bitwarden env + shared logs).
# ============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/home/nathan/scripts/logs"
LOG_FILE="$LOG_DIR/refresh_feeds.log"
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

# --- Dependency check ---
REQUIRED_CMDS=("bws" "jq" "curl" "mktemp" "tail" "stat")
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
echo "$failing_feed_data" | jq -r '.id as $id | .title | "   - (\($id)) \(. // "Untitled")"'

UPDATED_COUNT=0
FAILED_COUNT=0

# --- Refresh each failing feed ---
echo "$failing_feed_data" | jq -r '.id' | while read -r id; do
  [ -z "$id" ] && continue

  STATUS_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    "$MINIFLUX_URL/v1/feeds/$id/refresh")

  case "$STATUS_CODE" in
    204)
      log "  ✅ Refreshed feed ID $id successfully (204)"
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      ;;
    401|403)
      log "  ⚠️  Failed to refresh feed ID $id — unauthorised ($STATUS_CODE)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
    404)
      log "  ⚠️  Feed ID $id not found ($STATUS_CODE)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      ;;
    429|5*)
      log "  ⚠️  Transient error ($STATUS_CODE) refreshing feed ID $id — retrying once..."
      sleep 2
      RETRY_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "X-Auth-Token: $MINIFLUX_TOKEN" \
        "$MINIFLUX_URL/v1/feeds/$id/refresh")
      if [ "$RETRY_STATUS" = "204" ]; then
        log "     ✅ Retry successful for feed ID $id"
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

  trim_log
done

# --- Summary ---
log ""
log "===== SUMMARY ====="
log "✅ Refreshed successfully: $UPDATED_COUNT feed(s)"
log "⚠️  Failed to refresh: $FAILED_COUNT feed(s)"
log "==================="
trim_log
