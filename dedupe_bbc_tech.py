#!/usr/bin/env python3
"""
BBC Tech Deduplicator

- Groups entries by normalised title
- Keeps the oldest published entry
- Marks newer duplicates as read
- Logs one timestamped event per duplicate marked as read
"""

import re
import sys
from collections import defaultdict

import miniflux

# --------------------------------------------------
# Make shared helpers importable
# --------------------------------------------------
sys.path.append("/home/nathan/scripts/lib")
from common import (
    log,
    get_secret,
    require_bws,
    rotate_logs,
)

# --------------------------------------------------
# Configuration
# --------------------------------------------------
FEED_ID = 508   # BBC Tech
ACTION = "read"
DRY_RUN = False

MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# --------------------------------------------------
# Helpers
# --------------------------------------------------
def normalise_title(title: str) -> str:
    title = title.lower()
    title = re.sub(r"[^\w\s]", "", title)
    title = re.sub(r"\s+", " ", title)
    return title.strip()


def normalise_miniflux_url(url: str) -> str:
    url = url.rstrip("/")
    if url.endswith("/v1"):
        return url[:-3]
    return url


# --------------------------------------------------
# Main
# --------------------------------------------------
def main():
    rotate_logs()
    log("Loading Miniflux credentials from Bitwarden")

    require_bws()

    raw_url = get_secret(MINIFLUX_URL_ID)
    miniflux_url = normalise_miniflux_url(raw_url)
    miniflux_token = get_secret(MINIFLUX_TOKEN_ID)

    if raw_url != miniflux_url:
        log("Normalised Miniflux URL (stripped /v1)")

    client = miniflux.Client(miniflux_url, api_key=miniflux_token)

    log("Connected to Miniflux")
    log("Fetching unread BBC Tech entries")

    response = client.get_entries(feed_id=FEED_ID, status="unread")
    entries = response.get("entries", [])

    if not entries:
        log("No unread entries found")
        return

    grouped = defaultdict(list)

    for entry in entries:
        title = entry.get("title", "")
        if not title:
            continue
        grouped[normalise_title(title)].append(entry)

    duplicates = []

    for group in grouped.values():
        if len(group) > 1:
            group.sort(key=lambda e: e.get("published_at") or "")
            duplicates.extend(group[1:])

    if not duplicates:
        log("No duplicate entries found")
        return

    if DRY_RUN:
        for entry in duplicates:
            log(f"DRY-RUN – would mark as read: {entry.get('title', 'Untitled')}")
        return

    client.update_entries([e["id"] for e in duplicates], status="read")

    for entry in duplicates:
        log(f"Marked duplicate as read: {entry.get('title', 'Untitled')}")


# --------------------------------------------------
# Entrypoint
# --------------------------------------------------
if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Script failed: {e}")
        raise
