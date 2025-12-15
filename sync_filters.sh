#!/usr/bin/env bash
# ===============================================================
# Miniflux Feed Filter Updater
# ---------------------------------------------------------------
# Syncs block filter rules from filters.yaml into Miniflux.
# Runs every 15 minutes via cron.
# ===============================================================

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
CONFIG="$SCRIPT_DIR/config/filters.yaml"
UPDATED_FEEDS_TMP="$LOG_ROOT/sync_filters.log"

MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

: > "$UPDATED_FEEDS_TMP"

# --------------------------------------------------
# Checks
# --------------------------------------------------
require_cmds bws jq yq curl
require_bws

[ -f "$CONFIG" ] || { log "❌ Config not found: $CONFIG"; exit 1; }

# --------------------------------------------------
# Secrets
# --------------------------------------------------
MINIFLUX_URL="$(get_secret "$MINIFLUX_URL_ID")"
MINIFLUX_TOKEN="$(get_secret "$MINIFLUX_TOKEN_ID")"

MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"

# --------------------------------------------------
# Start
# --------------------------------------------------
log "🚀 Starting Miniflux filter sync"
log "📘 Config: $CONFIG"
log "📏 Config size: $(stat -c%s "$CONFIG") bytes"

UPDATED_COUNT=0

# --------------------------------------------------
# Process feeds
# --------------------------------------------------
yq eval -o=json --no-doc "$CONFIG" \
| jq -c '.feeds? // {} | to_entries[]' \
| while IFS= read -r entry; do

  FEED_ID="$(jq -r '.key' <<<"$entry")"
  FEED_NAME="$(jq -r '.value.name // "Unnamed Feed"' <<<"$entry")"
  FEED_URL="$(jq -r '.value.feed_url // "N/A"' <<<"$entry")"

  BLOCK_RULES="$(
    jq -r '
      (.value.block_rules // [])
      | if type=="array" then join("\n") else tostring end
    ' <<<"$entry"
  )"

  log "🔍 Checking feed $FEED_ID ($FEED_NAME)"

  CURRENT_RULES="$(
    curl -fsS \
      -H "X-Auth-Token: $MINIFLUX_TOKEN" \
      "$MINIFLUX_URL/v1/feeds/$FEED_ID" \
    | jq -r '.block_filter_entry_rules // ""'
  )"

  if [ "$BLOCK_RULES" = "$CURRENT_RULES" ]; then
    log "  → No changes"
    continue
  fi

  curl -fsS \
    -X PUT \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg b "$BLOCK_RULES" '{block_filter_entry_rules:$b}')" \
    "$MINIFLUX_URL/v1/feeds/$FEED_ID"

  log "  ✅ Updated feed: $FEED_NAME"
  echo "$FEED_NAME" >> "$UPDATED_FEEDS_TMP"
  UPDATED_COUNT=$((UPDATED_COUNT + 1))

done

# --------------------------------------------------
# Summary
# --------------------------------------------------
if [ "$UPDATED_COUNT" -gt 0 ]; then
  log "🎉 Sync complete — updated $UPDATED_COUNT feed(s)"
  sort -u "$UPDATED_FEEDS_TMP" | sed 's/^/  - /' | tee -a "$LOG_FILE"
else
  log "✅ Sync complete — no updates required"
fi
