#!/usr/bin/env bash
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

# --------------------------------------------------
# Input
# --------------------------------------------------
if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <search_term>"
  exit 1
fi

SEARCH_TERM="$1"

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
# Logic
# --------------------------------------------------
log "🔍 Searching Miniflux feeds for '$SEARCH_TERM'"

response="$(curl -fsS \
  -H "X-Auth-Token: $MINIFLUX_TOKEN" \
  "$MINIFLUX_URL/v1/feeds")"

matches="$(echo "$response" | jq --arg term "$SEARCH_TERM" \
  '.[] | select(.title | test($term; "i")) | {id, title, feed_url}')"

if [ -z "$matches" ]; then
  log "No feeds matched '$SEARCH_TERM'"
  exit 0
fi

echo "$matches" | jq -r '
"id: \(.id)
title: \(.title)
feed_url: \(.feed_url)
---"' | tee -a "$LOG_FILE"

log "Search complete for '$SEARCH_TERM'"
