#!/usr/bin/env bash
# ============================================================
# Add YouTube Channel to Miniflux
# ------------------------------------------------------------
# Resolves a YouTube channel URL → RSS feed and adds it to
# Miniflux if it does not already exist.
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
CATEGORY_ID=21

MINIFLUX_URL_ID="da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID="b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true && shift

# --------------------------------------------------
# Checks
# --------------------------------------------------
require_cmds bws jq curl grep
require_bws

# --------------------------------------------------
# Secrets
# --------------------------------------------------
MINIFLUX_URL="$(get_secret "$MINIFLUX_URL_ID")"
MINIFLUX_TOKEN="$(get_secret "$MINIFLUX_TOKEN_ID")"

MINIFLUX_URL="${MINIFLUX_URL%/}"
MINIFLUX_URL="${MINIFLUX_URL%/v1}"
API_ENDPOINT="$MINIFLUX_URL/v1/feeds"

# --------------------------------------------------
# Input
# --------------------------------------------------
if [ -z "${1:-}" ]; then
  echo "Usage: $(basename "$0") [--verbose] <YouTube_Channel_URL>"
  exit 1
fi

URL="$1"

$VERBOSE && log "🔎 Resolving YouTube channel from: $URL"

# --------------------------------------------------
# Resolve Channel ID
# --------------------------------------------------
if [[ "$URL" == *"/channel/"* ]]; then
  CHANNEL_ID="$(grep -oP '(?<=/channel/)[A-Za-z0-9_-]+' <<<"$URL")"
else
  HANDLE="$(grep -o '@[^/?]*' <<<"$URL" || true)"

  if [ -z "$HANDLE" ]; then
    log "❌ Unable to extract YouTube handle"
    exit 1
  fi

  HTML="$(curl -fsSL "https://www.youtube.com/$HANDLE/about")"
  CHANNEL_ID="$(grep -oP '(?<=channelId\":\")[^"]+' <<<"$HTML" | head -n 1)"
fi

if ! [[ "$CHANNEL_ID" =~ ^UC ]]; then
  log "❌ Invalid or unresolved YouTube channel"
  exit 1
fi

RSS_URL="https://www.youtube.com/feeds/videos.xml?channel_id=$CHANNEL_ID"

TITLE="$(curl -fsS "$RSS_URL" | grep -oPm1 '(?<=<title>)[^<]+' || true)"
TITLE="${TITLE:-Unknown Channel}"

log "📺 Channel: $TITLE"
log "🔗 RSS: $RSS_URL"

# --------------------------------------------------
# Check if feed already exists
# --------------------------------------------------
if curl -fsS -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds" \
  | jq -e --arg url "$RSS_URL" '.[] | select(.feed_url == $url)' >/dev/null; then
  log "ℹ️ Feed already exists — nothing to do"
  exit 0
fi

# --------------------------------------------------
# Create feed
# --------------------------------------------------
RESPONSE="$(
  curl -sS -w "\nHTTP:%{http_code}" \
    -X POST "$API_ENDPOINT" \
    -H "X-Auth-Token: $MINIFLUX_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"feed_url\":\"$RSS_URL\",\"category_id\":$CATEGORY_ID}"
)"

HTTP_CODE="$(grep -oP '(?<=HTTP:)\d+' <<<"$RESPONSE")"
BODY="$(sed -E 's/HTTP:[0-9]+//g' <<<"$RESPONSE")"

if [ "$HTTP_CODE" = "201" ]; then
  FEED_ID="$(jq -r '.feed_id' <<<"$BODY")"
  log "✅ Added \"$TITLE\" (Feed ID: $FEED_ID)"
else
  log "❌ Failed to add feed (HTTP $HTTP_CODE)"
  log "$BODY"
  exit 1
fi
