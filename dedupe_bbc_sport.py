#!/usr/bin/env python3
"""
BBC Sport Deduplicator (Feed ID 621)

- Groups entries by normalised title
- Keeps the oldest published entry
- Marks newer duplicates as read
- Uses shared helpers for logging and secrets
"""

import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
import miniflux

# Make shared helpers importable
sys.path.append("/home/nathan/scripts/lib")
from common import setup_logging, log, get_secret

# --------------------------------------------------
# Configuration
# --------------------------------------------------
SCRIPT_NAME = "bbc_sport_dedup"
FEED_ID = 621
ACTION = "read"
DRY_RUN = False

MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --------------------------------------------------
# Logging
# --------------------------------------------------
LOG_FILE = setup_logging(SCRIPT_NAME)

# --------------------------------------------------
# Helpers
# --------------------------------------------------
def normalise_title(title: str) -> str:
    title = title.lower()
    title = re.sub(r"\s+", " ", title)
    return title.strip()

def parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))

# --------------------------------------------------
# Load credentials
# --------------------------------------------------
log(LOG_FILE, "🔐 Loading Miniflux credentials from Bitwarden...")

MINIFLUX_URL = get_secret(MINIFLUX_URL_ID).rstrip("/")
MINIFLUX_URL = MINIFLUX_URL.removesuffix("/v1")
MINIFLUX_TOKEN = get_secret(MINIFLUX_TOKEN_ID)

# --------------------------------------------------
# Connect to Miniflux
# --------------------------------------------------
try:
    client = miniflux.Client(MINIFLUX_URL, api_key=MINIFLUX_TOKEN)
    client.get_feeds()
    log(LOG_FILE, "✅ Connected to Miniflux.")
except Exception as e:
    log(LOG_FILE, f"❌ Miniflux connection failed: {e}")
    sys.exit(1)

# --------------------------------------------------
# Fetch unread entries
# --------------------------------------------------
log(LOG_FILE, "🔍 Fetching unread BBC Football entries...")

response = client.get_feed_entries(
    feed_id=FEED_ID,
    status="unread",
    order="published_at",
    direction="asc",
)

entries = response.get("entries", [])
log(LOG_FILE, f"Found {len(entries)} unread entries.")

# --------------------------------------------------
# Deduplication
# --------------------------------------------------
groups = defaultdict(list)
to_update = []

for entry in entries:
    key = normalise_title(entry["title"])
    groups[key].append(entry)

for items in groups.values():
    if len(items) < 2:
        continue

    items.sort(key=lambda e: parse_ts(e["published_at"]))

    for dup in items[1:]:
        ts = parse_ts(dup["published_at"]).strftime("%Y-%m-%d %H:%M")
        log(LOG_FILE, f"{ts} - {dup['title']}")
        to_update.append(dup["id"])

# --------------------------------------------------
# Apply changes
# --------------------------------------------------
if not to_update:
    log(LOG_FILE, "✅ No duplicates found.")
    sys.exit(0)

log(LOG_FILE, f"🧹 {len(to_update)} duplicate entries will be marked as '{ACTION}'")

if DRY_RUN:
    log(LOG_FILE, "⚠️ DRY RUN enabled — no changes made.")
else:
    try:
        client.update_entries(to_update, status=ACTION)
        log(LOG_FILE, "✅ Deduplication complete.")
    except Exception as e:
        log(LOG_FILE, f"❌ Failed to update entries: {e}")
        sys.exit(1)