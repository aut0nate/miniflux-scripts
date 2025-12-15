#!/usr/bin/env bash
# ============================================================
# Miniflux Failed Feed Refresher
# ------------------------------------------------------------
# Refreshes feeds marked as failing in Miniflux.
# Uses Bitwarden Secrets via common.sh
# ============================================================

set -euo pipefail

# --------------------------------------------------
# Bootstrap
# --------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

log_init
log_rotate

# --------------------------------------------------
# Config
# --------------------------------------------------
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"
REFRESHED_LIST="$LOG_ROOT/refresh_feeds.log"

: > "$REFRESHED_LIST"

# --------------------------------------------------
# Checks
# --------------------------------------------------
require_cmds bws jq curl
require_bws

# --------------------------------------------------
# Secrets
# --------------------------------------------------
MINIFLUX_URL="$(get_secret "$MINIFLUX_URL_ID")"
MINIFLUX_TOKEN="$(get_secret "$MINIFLUX_TOKEN_ID")"

MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

# --------------------------------------------------
# Fetch failing feeds
# --------------------------------------------------
log "🚀 Checking for failing feeds…"

failing_feeds="$(curl -fsS \
  -H "X-Auth-Token: $MINIFLUX_TOKEN" \
  "$MINIFLUX_URL/v1/feeds" | jq -c '
    .[]
    | select(
        (.parsing_error_count > 0)
        or (.parsing_error_message != "")
      )
    | {id, title}
  ')"

if [ -z "$failing_feeds" ]; then
  log "✅ No failing feeds detected."
  exit 0
fi

log "⚠️  Failing feeds detected:"
echo "$failing_feeds" | jq -r '" - \(.title // "Untitled") (\(.id))"' | tee -a "$LOG_FILE"

# --------------------------------------------------
# Refresh feeds
# --------------------------------------------------
UPDATED_COUNT=0
FAILED_COUNT=0

while read -r feed_id; do
  [ -z "$feed_id" ] && continue

  status_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    "$MINIFLUX_URL/v1/feeds/$feed_id/refresh")"

  if [ "$status_code" = "204" ]; then
    title="$(echo "$failing_feeds" | jq -r "select(.id==$feed_id) | .title")"
    log "✅ Refreshed: $title ($feed_id)"
    echo "$title" >> "$REFRESHED_LIST"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
  else
    log "❌ Failed to refresh feed ID $feed_id (HTTP $status_code)"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(echo "$failing_feeds" | jq -r '.id')

# --------------------------------------------------
# Summary
# --------------------------------------------------
log "===== SUMMARY ====="
log "✅ Refreshed: $UPDATED_COUNT feed(s)"
log "⚠️  Failed: $FAILED_COUNT feed(s)"
log "==================="