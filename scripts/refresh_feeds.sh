#!/usr/bin/env bash
# ============================================================
# Miniflux Feed Refresher
# Retrieves Miniflux URL and API token securely from Bitwarden
# ============================================================

set -uo pipefail

# --- Configuration ---
LOG_FILE="$HOME/scripts/miniflux/logs/refresh_feeds.log"
MAX_LOG_LINES=100
DOMAINS=("reddit.com" "rsshub.autonate.dev")
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

# --- Helper: Trim log safely ---
trim_log() {
  if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

log "🔐 Using Bitwarden secrets for configuration"
log "🔁 Starting feed refresh run"

# --- Build jq filter ---
jq_filter=""
for domain in "${DOMAINS[@]}"; do
  [[ -n "$jq_filter" ]] && jq_filter+=" or "
  jq_filter+="(.feed_url | contains(\"$domain\"))"
done

# --- Fetch matching feed IDs ---
feed_ids=$(curl -s -H "X-Auth-Token: $MINIFLUX_TOKEN" "$MINIFLUX_URL/v1/feeds" \
  | jq -r ".[] | select($jq_filter) | .id")

if [ -z "$feed_ids" ]; then
  log "ℹ️ No matching feeds found for domains: ${DOMAINS[*]}"
  log "✅ Run completed — no updates required."
  trim_log
  exit 0
fi

# --- Refresh each feed ---
UPDATED_COUNT=0
for id in $feed_ids; do
  if curl -fs -H "X-Auth-Token: $MINIFLUX_TOKEN" -X PUT "$MINIFLUX_URL/v1/feeds/$id/refresh" >/dev/null; then
    log "  → Refreshed feed ID $id"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
  else
    log "  ⚠️ Failed to refresh feed ID $id"
  fi
done

log "✅ Feed refresh completed — $UPDATED_COUNT feed(s) refreshed."
trim_log
