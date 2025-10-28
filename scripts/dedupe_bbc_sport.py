#!/usr/bin/env python3
# ============================================================
# Miniflux BBC Sport Deduplicator
# Retrieves Miniflux URL and API token securely from Bitwarden
# ============================================================

import re
import subprocess
from datetime import datetime
from pathlib import Path

from rapidfuzz import fuzz
import nltk
from nltk.corpus import stopwords
import miniflux

# ---- CONFIG ----
FEED_IDS = [481, 482]  # BBC Sport feed IDs
SENSITIVITY = 88       # Similarity threshold
DELETE_MODE = False    # False = mark "read", True = remove
LOG_FILE = Path("/home/nathan/scripts/miniflux/logs/dedupe_bbc_sport.log")
MAX_LOG_LINES = 100

# Bitwarden Secret IDs
MINIFLUX_URL_ID = "da481d5f-140a-4ff6-8d89-b37e00c5b84f"
MINIFLUX_TOKEN_ID = "b5f9eed2-b3ed-4d9c-8f58-b37e00c03041"

# ---- INIT ----
nltk.download('stopwords', quiet=True)
STOP_WORDS = set(stopwords.words('english'))

# ---- HELPER FUNCTIONS ----

def log(msg: str):
    """Append a simple line to the log file."""
    print(msg)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"{msg}\n")

    # Trim log
    lines = LOG_FILE.read_text(encoding="utf-8").splitlines()
    if len(lines) > MAX_LOG_LINES:
        LOG_FILE.write_text("\n".join(lines[-MAX_LOG_LINES:]), encoding="utf-8")

def get_secret(secret_id: str) -> str:
    """Fetch only the secret's 'value' field from Bitwarden."""
    try:
        result = subprocess.run(
            ["bws", "secret", "get", secret_id],
            capture_output=True,
            text=True,
            check=True
        )
        # Extract only the .value field from the JSON
        import json
        data = json.loads(result.stdout)
        value = data.get("value", "").strip()
        if not value:
            raise ValueError(f"Empty secret for ID: {secret_id}")
        return value
    except subprocess.CalledProcessError as e:
        log(f"❌ Error retrieving Bitwarden secret {secret_id}: {e.stderr.strip()}")
        raise SystemExit(1)
    except json.JSONDecodeError:
        log(f"❌ Failed to parse JSON from Bitwarden for secret {secret_id}")
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

# ---- INITIALISE MINIFLUX CLIENT ----
try:
    client = miniflux.Client(MINIFLUX_URL, api_key=MINIFLUX_TOKEN)
    client.get_feeds()  # sanity check
    log("✅ Miniflux connection successful.")
except Exception as e:
    log(f"❌ Failed to connect to Miniflux: {e}")
    raise SystemExit(1)

# ---- MAIN LOGIC (cross-feed deduplication) ----

def fetch_unread_entries(feed_ids):
    """Fetch unread entries from multiple feeds."""
    all_entries = []
    for fid in feed_ids:
        entries = client.get_feed_entries(feed_id=fid, order="id", direction="asc", status=["unread"])
        count = len(entries.get("entries", []))
        log(f"🔍 Checking feed {fid} ({count} unread entries)...")
        all_entries.extend(entries.get("entries", []))
    return all_entries


def find_cross_feed_duplicates(entries, sensitivity=88):
    """Find duplicates across multiple feeds."""
    dupe_ids = []
    seen_titles = []  # (cleaned_title, entry_id, original_title, feed_id)

    for entry in entries:
        cleaned = clean_title(entry["title"])

        # Try to find a near match in previously seen titles
        match = next(
            ((t, fid) for (t, _, _, fid) in seen_titles if fuzz.token_sort_ratio(cleaned, t) >= sensitivity),
            None
        )

        if match:
            dupe_ids.append(entry["id"])
            log(f"🧩 Duplicate found between feeds (match in feed {match[1]}): '{entry['title']}'")
        else:
            seen_titles.append((cleaned, entry["id"], entry["title"], entry["feed"]["id"]))

    if dupe_ids:
        status = "removed" if DELETE_MODE else "read"
        log(f"🧹 Found {len(dupe_ids)} duplicates across feeds -> mark {status}")
        try:
            client.update_entries(dupe_ids, status=status)
        except Exception as e:
            log(f"⚠️ Error updating entries: {e}")
    else:
        log("ℹ️ No cross-feed duplicates found")


# ---- RUN ----
entries = fetch_unread_entries(FEED_IDS)
find_cross_feed_duplicates(entries, SENSITIVITY)

log(f"✅ Run completed at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
