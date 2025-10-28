#!/usr/bin/env python3
# ============================================================
# Miniflux BBC Sport Deduplicator
# ------------------------------------------------------------
# Cross-feed deduplication for BBC feeds using fuzzy matching.
# Designed to run under run-all.sh (Bitwarden env + shared logs)
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

# ---- CONFIG ----
FEED_IDS = [481, 482]          # Feed IDs to compare
SENSITIVITY = 88               # Fuzzy match threshold
DELETE_MODE = False            # False = mark as read, True = delete
LOG_FILE = Path("/home/nathan/scripts/logs/dedupe_bbc_sport.log")
MAX_LOG_SIZE = 5 * 1024 * 1024  # 5 MB

# Bitwarden Secret IDs
MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# ---- INIT ----
nltk.download("stopwords", quiet=True)
STOP_WORDS = set(stopwords.words("english"))

# ---- HELPERS ----
def log(msg: str) -> None:
    """Log message to file and stdout with timestamp."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    trim_log()


def trim_log() -> None:
    """Trim log file to ~5 MB if it grows too large."""
    if LOG_FILE.exists() and LOG_FILE.stat().st_size > MAX_LOG_SIZE:
        lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
        LOG_FILE.write_text("\n".join(lines[-500:]), encoding="utf-8")
        print("🧹 Log trimmed to last 500 lines (exceeded 5 MB)")


def get_secret(secret_id: str) -> str:
    """Retrieve Bitwarden secret value using an existing BWS session."""
    try:
        result = subprocess.run(
            ["bws", "secret", "get", secret_id],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
        value = data.get("value", "").strip()
        if not value:
            raise ValueError(f"Empty secret for ID: {secret_id}")
        return value
    except Exception as e:
        log(f"❌ Failed to retrieve Bitwarden secret {secret_id}: {e}")
        raise SystemExit(1)


def clean_title(title: str) -> str:
    """Normalise title by removing punctuation, stopwords, and sorting words."""
    title = re.sub(r"[^\w\s]", " ", title)
    words = [w.lower() for w in title.split() if w.lower() not in STOP_WORDS]
    return " ".join(sorted(words))


# ---- FETCH MINIFLUX SECRETS ----
log("🔐 Retrieving Miniflux secrets from Bitwarden...")

MINIFLUX_URL = get_secret(MINIFLUX_URL_ID).rstrip("/")
if MINIFLUX_URL.endswith("/v1"):
    MINIFLUX_URL = MINIFLUX_URL[:-3]

MINIFLUX_TOKEN = get_secret(MINIFLUX_TOKEN_ID)

if not MINIFLUX_URL or not MINIFLUX_TOKEN:
    log("❌ Missing required Miniflux credentials.")
    raise SystemExit(1)

# ---- INITIALISE CLIENT ----
try:
    client = miniflux.Client(MINIFLUX_URL, api_key=MINIFLUX_TOKEN)
    client.get_feeds()  # quick sanity check
    log("✅ Miniflux connection successful.")
except Exception as e:
    log(f"❌ Failed to connect to Miniflux: {e}")
    raise SystemExit(1)


# ---- CORE LOGIC ----
def fetch_unread_entries(feed_ids):
    """Fetch unread entries from all given feeds."""
    all_entries = []
    for fid in feed_ids:
        entries = client.get_feed_entries(
            feed_id=fid, order="id", direction="asc", status=["unread"]
        )
        count = len(entries.get("entries", []))
        log(f"🔍 Checking feed {fid} ({count} unread entries)...")
        all_entries.extend(entries.get("entries", []))
    return all_entries


def find_cross_feed_duplicates(entries, sensitivity=88):
    """Identify duplicates across feeds and mark or delete them."""
    dupe_ids = []
    seen_titles = []  # (cleaned_title, entry_id, original_title, feed_id)

    for entry in entries:
        cleaned = clean_title(entry["title"])

        # Try to find a near-duplicate
        match = next(
            (
                (t, fid)
                for (t, _, _, fid) in seen_titles
                if fuzz.token_sort_ratio(cleaned, t) >= sensitivity
            ),
            None,
        )

        if match:
            dupe_ids.append(entry["id"])
            log(f"🧩 Duplicate found (matches feed {match[1]}): '{entry['title']}'")
        else:
            seen_titles.append(
                (cleaned, entry["id"], entry["title"], entry["feed"]["id"])
            )

    if dupe_ids:
        status = "removed" if DELETE_MODE else "read"
        log(f"🧹 Found {len(dupe_ids)} duplicates → marking {status}")
        try:
            client.update_entries(dupe_ids, status=status)
        except Exception as e:
            log(f"⚠️ Error updating entries: {e}")
    else:
        log("ℹ️ No cross-feed duplicates found")


# ---- RUN ----
entries = fetch_unread_entries(FEED_IDS)
find_cross_feed_duplicates(entries, SENSITIVITY)
log(f"✅ Run completed at {datetime.now():%Y-%m-%d %H:%M:%S}")