#!/usr/bin/env python3
"""
BBC Recently-Seen Cleanup

Feeds:
- BBC Football (482)
- BBC Sport (621)

Logic:
- Look back 24 hours
- Collect titles of READ entries
- For UNREAD entries:
    if title matches a read title → mark as read
"""

import sys
from datetime import datetime, timedelta, timezone
from collections import defaultdict

import miniflux

# --------------------------------------------------
# Shared helpers
# --------------------------------------------------
sys.path.append("/home/nathan/scripts/lib")
from common import log, get_secret, require_bws, rotate_logs

# --------------------------------------------------
# Configuration
# --------------------------------------------------
FEED_IDS = [482, 621]
WINDOW_HOURS = 24
DRY_RUN = False

MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"


# --------------------------------------------------
# Helpers
# --------------------------------------------------
def parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)


def within_window(entry: dict, now: datetime) -> bool:
    published = parse_ts(entry["published_at"])
    return now - published <= timedelta(hours=WINDOW_HOURS)


def fetch_entries(client: miniflux.Client, feed_id: int, status: str) -> list[dict]:
    resp = client.get_entries(
        feed_id=feed_id,
        status=status,
        order="published_at",
        direction="desc",
    )
    return resp.get("entries", [])


# --------------------------------------------------
# Main
# --------------------------------------------------
def main():
    rotate_logs()
    log("Loading Miniflux credentials from Bitwarden")

    require_bws()

    raw_url = get_secret(MINIFLUX_URL_ID)
    token = get_secret(MINIFLUX_TOKEN_ID)

    miniflux_url = raw_url.rstrip("/")
    if miniflux_url.endswith("/v1"):
        miniflux_url = miniflux_url[:-3]
        log("Normalised Miniflux URL (stripped /v1)")

    client = miniflux.Client(miniflux_url, api_key=token)
    log("Connected to Miniflux")

    now = datetime.now(timezone.utc)
    log(f"Checking for already-seen articles (last {WINDOW_HOURS}h)")

    # --------------------------------------------------
    # Collect READ titles in window
    # --------------------------------------------------
    seen_titles: set[str] = set()

    for fid in FEED_IDS:
        entries = fetch_entries(client, fid, status="read")
        for e in entries:
            if "published_at" in e and within_window(e, now):
                title = (e.get("title") or "").strip()
                if title:
                    seen_titles.add(title)

    if not seen_titles:
        log("No recently-read titles found")
        return

    # --------------------------------------------------
    # Find UNREAD entries with same titles
    # --------------------------------------------------
    to_mark_read: list[dict] = []

    for fid in FEED_IDS:
        entries = fetch_entries(client, fid, status="unread")
        for e in entries:
            title = (e.get("title") or "").strip()
            if title and title in seen_titles:
                to_mark_read.append(e)

    if not to_mark_read:
        log("No unread entries matched recently-seen titles")
        return

    # --------------------------------------------------
    # Apply updates
    # --------------------------------------------------
    ids = [e["id"] for e in to_mark_read if "id" in e]

    if DRY_RUN:
        for e in to_mark_read:
            ts = parse_ts(e["published_at"]).strftime("%Y-%m-%d %H:%M")
            log(f"DRY-RUN – {ts} - {e.get('title', 'Untitled')}")
        return

    client.update_entries(ids, status="read")

    for e in to_mark_read:
        ts = parse_ts(e["published_at"]).strftime("%Y-%m-%d %H:%M")
        log(f"{ts} - Marked already-seen article as read: {e.get('title', 'Untitled')}")

    log(f"Completed — marked {len(ids)} already-seen entries as read")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"Script failed: {e}")
        raise
