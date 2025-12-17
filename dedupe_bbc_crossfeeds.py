#!/usr/bin/env python3
"""
Cross-feed deduper for Miniflux.

Feeds:
- BBC Football (482)  [kept]
- BBC Sport    (621)  [duplicates marked as read]

Behaviour:
- Fetch unread entries from both feeds
- Normalise titles and detect duplicates across feeds
- Keep the entry in KEEP_FEED_ID
- Mark duplicates in the other feed as read
- Log one timestamped event per marked entry
"""

import re
import sys
from collections import defaultdict

import miniflux

# --------------------------------------------------
# Make shared helpers importable
# --------------------------------------------------
sys.path.append("/home/nathan/scripts/lib")
from common import log, get_secret, require_bws, rotate_logs

# --------------------------------------------------
# Configuration
# --------------------------------------------------
FEED_FOOTBALL = 482
FEED_SPORT = 621

KEEP_FEED_ID = FEED_FOOTBALL          # keep this feed's copy
DEDUP_FEED_IDS = [FEED_FOOTBALL, FEED_SPORT]

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


def fetch_unread(client: miniflux.Client, feed_id: int) -> list[dict]:
    # miniflux.Client.get_entries returns a dict: {"total":..., "entries":[...]}
    resp = client.get_entries(feed_id=feed_id, status="unread")
    return resp.get("entries", [])


# --------------------------------------------------
# Main
# --------------------------------------------------
def main():
    rotate_logs()
    log("Loading Miniflux credentials from Bitwarden")

    require_bws()

    raw_url = get_secret(MINIFLUX_URL_ID)
    miniflux_url = normalise_miniflux_url(raw_url)
    token = get_secret(MINIFLUX_TOKEN_ID)

    if raw_url != miniflux_url:
        log("Normalised Miniflux URL (stripped /v1)")

    client = miniflux.Client(miniflux_url, api_key=token)

    log("Connected to Miniflux")
    log(f"Fetching unread entries for feeds: {DEDUP_FEED_IDS}")

    entries_by_feed: dict[int, list[dict]] = {}
    for fid in DEDUP_FEED_IDS:
        entries_by_feed[fid] = fetch_unread(client, fid)

    # Build: normalised_title -> list of (feed_id, entry)
    by_title: dict[str, list[tuple[int, dict]]] = defaultdict(list)

    for fid, entries in entries_by_feed.items():
        for e in entries:
            title = e.get("title") or ""
            if not title:
                continue
            by_title[normalise_title(title)].append((fid, e))

    # Find titles that appear in >1 feed (cross-feed dupes)
    to_mark_read: list[dict] = []

    for _norm_title, items in by_title.items():
        feeds_present = {fid for fid, _ in items}
        if len(feeds_present) <= 1:
            continue

        # Keep any entry from KEEP_FEED_ID if present; otherwise keep the first encountered.
        keep_feed = KEEP_FEED_ID if KEEP_FEED_ID in feeds_present else items[0][0]

        for fid, e in items:
            if fid == keep_feed:
                continue
            to_mark_read.append(e)

    if not to_mark_read:
        log("No cross-feed duplicates found")
        return

    if DRY_RUN:
        for e in to_mark_read:
            log(f"DRY-RUN – would mark cross-feed duplicate as read: {e.get('title', 'Untitled')}")
        return

    ids = [e["id"] for e in to_mark_read if "id" in e]

    if not ids:
        log("No valid entry IDs found to update")
        return

    client.update_entries(ids, status="read")

    # Log each item as a timestamped event
    for e in to_mark_read:
        title = e.get("title", "Untitled")
        feed_id = e.get("feed_id", "unknown")
        log(f"Marked cross-feed duplicate as read: {title} (feed {feed_id})")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Script failed: {e}")
        raise
