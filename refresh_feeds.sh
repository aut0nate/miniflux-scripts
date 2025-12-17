#!/usr/bin/env bash
# ============================================================
# Miniflux Failed Feed Refresher
# ------------------------------------------------------------
# Refreshes feeds marked as failing in Miniflux.
# Logs timestamped "Time - Event" entries only.
# ============================================================

set -euo pipefail

# --------------------------------------------------
# Bootstrap
# --------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/home/nathan/scripts/logs/refresh_feeds.log"

# shellcheck source=/home/nathan/scripts/lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

rotate_logs
log "Starting failed feed refresh"

# --------------------------------------------------
# Config
# --------------------------------------------------
MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --------------------------------------------------
# Dependency checks
# --------------------------------------------------
for cmd in bws jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    log "❌ Missing dependency: $cmd"
    exit 1
  }
done

# --------------------------------------------------
# Bitwarden + secrets
# --------------------------------------------------
require_bws

RAW_MINIFLUX_URL="$(get_secret "$MINIFLUX_URL_ID")"
MINIFLUX_TOKEN="$(get_secret "$MINIFLUX_TOKEN_ID")"

# Normalise URL (allow /v1 in secret)
MINIFLUX_URL="${RAW_MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

if [[ "$RAW_MINIFLUX_URL" != "$MINIFLUX_URL" ]]; then
  log "Normalised Miniflux URL (stripped /v1)"
fi

# --------------------------------------------------
# Fetch failing feeds
# --------------------------------------------------
log "Checking for failing feeds"

failing_feeds="$(
  curl -fsS \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    "$MINIFLUX_URL/v1/feeds" \
  | jq -c '
      .[]
      | select(
          (.parsing_error_count > 0)
          or (.parsing_error_message != "")
        )
      | {id, title}
    '
)"

if [[ -z "$failing_feeds" ]]; then
  log "No failing feeds detected"
  exit 0
fi

# --------------------------------------------------
# Refresh feeds
# --------------------------------------------------
UPDATED_COUNT=0
FAILED_COUNT=0

while IFS= read -r feed_id; do
  [[ -z "$feed_id" ]] && continue

  status_code="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      -X PUT \
      -H "X-Auth-Token: $MINIFLUX_TOKEN" \
      "$MINIFLUX_URL/v1/feeds/$feed_id/refresh"
  )"

  title="$(
    echo "$failing_feeds" \
    | jq -r "select(.id==$feed_id) | .title // \"Untitled\""
  )"

  if [[ "$status_code" == "204" ]]; then
    log "Refreshed failing feed: $title ($feed_id)"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
  else
    log "Failed to refresh feed: $title ($feed_id) – HTTP $status_code"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(echo "$failing_feeds" | jq -r '.id')

# --------------------------------------------------
# Summary
# --------------------------------------------------
log "Refresh complete — refreshed=$UPDATED_COUNT failed=$FAILED_COUNT"
