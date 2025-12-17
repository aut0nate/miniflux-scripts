#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Filter Updater
# ---------------------------------------------------------------
# Syncs block filter rules from filters.yaml into Miniflux.
# Logs timestamped "Time - Event" entries only.
# ===============================================================

set -euo pipefail

# --------------------------------------------------
# Bootstrap
# --------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/home/nathan/scripts/logs/sync_filters.log"

# shellcheck source=/home/nathan/scripts/lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

rotate_logs
log "Starting Miniflux filter sync"

# --------------------------------------------------
# Config
# --------------------------------------------------
CONFIG="$SCRIPT_DIR/config/filters.yaml"

MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --------------------------------------------------
# Dependency checks (explicit, no magic helpers)
# --------------------------------------------------
for cmd in bws jq yq curl; do
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
# Sanity check
# --------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
  log "❌ Config not found: $CONFIG"
  exit 1
fi

log "Using config: $CONFIG"

UPDATED_COUNT=0

# --------------------------------------------------
# Process feeds
# --------------------------------------------------
yq eval -o=json --no-doc "$CONFIG" \
| jq -c '.feeds? // {} | to_entries[]' \
| while IFS= read -r entry; do

  FEED_ID="$(jq -r '.key' <<<"$entry")"
  FEED_NAME="$(jq -r '.value.name // "Unnamed Feed"' <<<"$entry")"

  BLOCK_RULES="$(
    jq -r '
      (.value.block_rules // [])
      | if type=="array" then join("\n") else tostring end
    ' <<<"$entry"
  )"

  log "Checking feed: $FEED_NAME ($FEED_ID)"

  CURRENT_RULES="$(
    curl -fsS \
      -H "X-Auth-Token: $MINIFLUX_TOKEN" \
      "$MINIFLUX_URL/v1/feeds/$FEED_ID" \
    | jq -r '.block_filter_entry_rules // ""'
  )"

  if [[ "$BLOCK_RULES" == "$CURRENT_RULES" ]]; then
    log "No changes for feed: $FEED_NAME"
    continue
  fi

  curl -fsS \
    -X PUT \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "$BLOCK_RULES" '{block_filter_entry_rules:$b}')" \
    "$MINIFLUX_URL/v1/feeds/$FEED_ID"

  log "Updated filter rules for feed: $FEED_NAME"
  UPDATED_COUNT=$((UPDATED_COUNT + 1))

done

# --------------------------------------------------
# Summary
# --------------------------------------------------
if [[ "$UPDATED_COUNT" -gt 0 ]]; then
  log "Filter sync complete — updated $UPDATED_COUNT feed(s)"
else
  log "Filter sync complete — no updates required"
fi
