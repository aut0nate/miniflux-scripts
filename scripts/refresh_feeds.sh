#!/usr/bin/env bash
# ============================================================
# Miniflux Failed Feed Refresher
# ------------------------------------------------------------
# Refreshes feeds marked as failing in Miniflux.
# Uses Bitwarden Secrets for Miniflux credentials.
# ============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/home/nathan/scripts/logs"
LOG_FILE="$LOG_DIR/refresh_feeds.log"
REFRESHED_LIST="$LOG_DIR/refresh_feeds_updated.tmp"
MAX_LOG_SIZE=$((5 * 1024 * 1024)) # 5 MB
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

mkdir -p "$LOG_DIR"
: > "$REFRESHED_LIST"

# --- Helpers ---
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

# --- Verify dependencies ---
REQUIRED_CMDS=("bws" "jq" "curl" "stat")
for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ Missing: $cmd"; exit 1; }
done

# --- Bitwarden ---
if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  echo "❌ Missing Bitwarden session. Please run via run-all.sh or source /opt/secrets/.bws-env"
  exit 1
fi

MINIFLUX_URL="$(bws secret get "$MINIFLUX_URL_ID" | jq -r '.value' | tr -d '\r\n' | xargs)"
MINIFLUX_TOKEN="$(bws secret get "$MINIFLUX_TOKEN_ID" | jq -r '.value' | tr -d '\r\n' | xargs)"
[ -n "$MINIFLUX_URL" ] && [ -n "$MINIFLUX_TOKEN" ] || { log "❌ Missing Miniflux credentials"; exit 1; }

MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

log "🚀 Refreshing failing feeds..."
failing_feed_data=$(curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds" \
  | jq -c '.[] | select((.parsing_error_count > 0) or (.parsing_error_message != "")) | {id, title}')

if [ -z "$failing_feed_data" ]; then
  log "✅ No failing feeds detected."
  trim_log
  exit 0
fi

log "⚠️  Found failing feeds:"
echo "$failing_feed_data" | jq -r '.id as $id | .title | " - \(. // "Untitled") (\($id))"' | tee -a "$LOG_FILE"

UPDATED_COUNT=0
FAILED_COUNT=0

while read -r id; do
  [ -z "$id" ] && continue

  STATUS_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds/$id/refresh")

  if [ "$STATUS_CODE" = "204" ]; then
    title=$(echo "$failing_feed_data" | jq -r "select(.id==$id) | .title")
    log "  ✅ Refreshed: $title ($id)"
    echo "$title" >> "$REFRESHED_LIST"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
  else
    log "  ❌ Failed to refresh feed ID $id (HTTP $STATUS_CODE)"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(echo "$failing_feed_data" | jq -r '.id')

log "===== SUMMARY ====="
log "✅ Refreshed: $UPDATED_COUNT feed(s)"
log "⚠️  Failed: $FAILED_COUNT feed(s)"
log "==================="
trim_log
