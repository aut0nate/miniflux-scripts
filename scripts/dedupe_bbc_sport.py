#!/usr/bin/env python3
# ============================================================
# Miniflux BBC Sport Deduplicator
# ------------------------------------------------------------
# Removes or marks duplicate entries across BBC Sport feeds.
# Writes formatted summary for ntfy notifications via run-all.sh.
# ============================================================

import re
import subprocess
import json
from datetime import datetime
from pathlib import Path
from rapidfuzz import fuzz
import nltk
from nltk.corpus import stopwords
import miniflux

# --- Config ---
LOG_DIR = Path("/home/nathan/scripts/logs")
LOG_FILE = LOG_DIR / "dedupe_bbc_sport.log"
SUMMARY_FILE = LOG_DIR / "dedupe_summary.tmp"
MAX_LOG_LINES = 300
FEED_IDS = [481, 482]
SENSITIVITY = 88
DELETE_MODE = False
MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

LOG_DIR.mkdir(parents=True, exist_ok=True)
SUMMARY_FILE.write_text("", encoding="utf-8")

nltk.download('stopwords', quiet=True)
STOP_WORDS = set(stopwords.words('english'))

# --- Logging ---
def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    trim_log()

def trim_log():
    lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
    if len(lines) > MAX_LOG_LINES:
        LOG_FILE.write_text("\n".join(lines[-MAX_LOG_LINES:]), encoding="utf-8")

# --- Bitwarden helper ---
def get_secret(secret_id):
    try:
        result = subprocess.run(
            ["bws", "secret", "get", secret_id],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
        return data.get("value", "").strip()
    except Exception as e:
        log(f"❌ Failed to get secret {secret_id}: {e}")
        exit(1)

# --- Clean title ---
def clean_title(title):
    title = re.sub(r"[^\w\s]", " ", title)
    words = [w.lower() for w in title.split() if w.lower() not in STOP_WORDS]
    return " ".join(sorted(words))

# --- Get Miniflux secrets ---
log("🔐 Loading Miniflux credentials...")
MINIFLUX_URL = get_secret(MINIFLUX_URL_ID).rstrip("/")
MINIFLUX_URL = MINIFLUX_URL.removesuffix("/v1")
MINIFLUX_TOKEN = get_secret(MINIFLUX_TOKEN_ID)

if not MINIFLUX_URL or not MINIFLUX_TOKEN:
    log("❌ Missing Miniflux credentials.")
    exit(1)

# --- Miniflux client ---
try:
    client = miniflux.Client(MINIFLUX_URL, api_key=MINIFLUX_TOKEN)
    client.get_feeds()
    log("✅ Connected to Miniflux.")
except Exception as e:
    log(f"❌ Miniflux connection failed: {e}")
    exit(1)

# --- Main deduplication ---
def fetch_unread_entries(feed_ids):
    all_entries = []
    for fid in feed_ids:
        entries = client.get_feed_entries(feed_id=fid, order="id", direction="asc", status=["unread"])
        count = len(entries.get("entries", []))
        log(f"🔍 Feed {fid}: {count} unread entries.")
        all_entries.extend(entries.get("entries", []))
    return all_entries

def find_duplicates(entries, threshold=88):
    dupe_ids = []
    dupe_details = []  # (feed_name, title)
    seen = []

    for entry in entries:
        cleaned = clean_title(entry["title"])
        feed_name = entry["feed"]["title"]

        match = next(((t, fid) for (t, _, _, fid) in seen if fuzz.token_sort_ratio(cleaned, t) >= threshold), None)
        if match:
            dupe_ids.append(entry["id"])
            dupe_details.append((feed_name, entry["title"]))
            log(f"🧩 Duplicate found (match with feed {match[1]}): {feed_name} - {entry['title']}")
        else:
            seen.append((cleaned, entry["id"], entry["title"], entry["feed"]["id"]))

    return dupe_ids, dupe_details

# --- Run deduplication ---
entries = fetch_unread_entries(FEED_IDS)
duplicates, dupe_details = find_duplicates(entries, SENSITIVITY)

if duplicates:
    status = "removed" if DELETE_MODE else "read"
    log(f"🧹 Found {len(duplicates)} duplicates → mark {status}")
    try:
        client.update_entries(duplicates, status=status)

        # Write formatted summary
        summary_lines = [f"Removed or marked {len(duplicates)} duplicates:\n"]
        for feed, title in dupe_details:
            summary_lines.append(f"{feed} – {title}")
        SUMMARY_FILE.write_text("\n".join(summary_lines), encoding="utf-8")

    except Exception as e:
        log(f"⚠️ Error updating entries: {e}")
        SUMMARY_FILE.write_text("Error updating entries.", encoding="utf-8")
else:
    log("✅ No duplicates found.")
    SUMMARY_FILE.write_text("No duplicates found.", encoding="utf-8")

log(f"🏁 Deduplication completed at {datetime.now().strftime('%H:%M:%S')}")