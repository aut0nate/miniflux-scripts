# Miniflux Automation Scripts

This repository contains a collection of scripts which I am using to automate the management and maintenance of [Miniflux](https://miniflux.app/) feeds.
Each script focuses on a specific task, from refreshing and filtering feeds to adding new subscriptions or cleaning up duplicates.
All scripts retrieve credentials securely from **Bitwarden Secrets Manager**, avoiding hard-coded secrets or environment variables in source control.

## Overview

| Script | Language | Purpose |
|--------|-----------|----------|
| `yt2rss.sh` | Bash | Adds a YouTube channel to Miniflux using its RSS feed. Automatically resolves a channel ID from a YouTube URL and posts it to the Miniflux API. |
| `refresh_feeds.sh` | Bash | Attempts to refresh all Miniflux feeds which are reporting failures to refresh |
| `sync_filters.sh` | Bash | Synchronises feed-specific filtering rules from a YAML configuration file with Miniflux via its API. Ensures block rules are consistent between local and remote configurations. |
| `dedupe_bbc_sport.py` | Python | Detects and removes duplicate entries from BBC Sport feeds based on fuzzy title matching using `rapidfuzz` and `nltk`. Can optionally mark duplicates as read or delete them. |


## Prerequisites

Before running any of the scripts, ensure the following tools are installed and configured on your system:

### Required Tools

- [Bitwarden Secrets Manager CLI (`bws`)](https://bitwarden.com/help/secrets-manager-cli/)
- [jq](https://stedolan.github.io/jq/) – for processing JSON
- [yq](https://mikefarah.gitbook.io/yq/) – required only by `sync_filters.sh`
- [curl](https://curl.se/) – for making API requests
- [Python 3](https://www.python.org/) – for running Python scripts
- [rapidfuzz](https://github.com/maxbachmann/RapidFuzz) and [nltk](https://www.nltk.org/) – required by `dedupe_bbc_sport.py`

You must also have access to your **Bitwarden Secrets Manager** account and a valid access token.


## Bitwarden Configuration

All Miniflux credentials are stored in Bitwarden Secrets Manager and accessed at runtime using the `bws` CLI.

The following secrets are required:

| Secret Name | Purpose |
|--------------|----------|
| `MINIFLUX_URL` | Base API URL for your Miniflux instance (e.g. `https://rss.example.com/v1`) |
| `MINIFLUX_TOKEN` | API token for authenticating with Miniflux |

You can store and retrieve these secrets securely as follows:

### Store secrets in Bitwarden

```bash
bws secret create --project-id <your_project_id> --key MINIFLUX_URL --value "https://rss.example.com/v1"
bws secret create --project-id <your_project_id> --key MINIFLUX_TOKEN --value "<your_api_token>"
```

### Retrieve secrets in scripts

```bash
bws secret get <secret_id> | jq -r '.value'
```

If you prefer, you can store your Bitwarden access token in /opt/secrets/.bws-env:

```bash
export BWS_ACCESS_TOKEN="<your_access_token>"
```
Then load it automatically at shell startup by adding this to your profile:

```bash
source /opt/secrets/.bws-env
```

## Usage

Each script is designed to be run independently.

### Example Commands

Add a YouTube channel to Miniflux:

```bash
bash yt2rss.sh https://www.youtube.com/@Bitwarden
```

Example output of feed being transformed into an RSS feed and added to Miniflux:

```bash
🔗 Resolved RSS Feed: https://www.youtube.com/feeds/videos.xml?channel_id=UCId9a_jQqvJre0_dE2lE_Rw
📺 Channel Title: Bitwarden
✅ Successfully added "Bitwarden" (Feed ID: 609) to Miniflux (Category: 21)
```

Example output of a feed which has already been added to Miniflux:

```bash
🔗 Resolved RSS Feed: https://www.youtube.com/feeds/videos.xml?channel_id=UCId9a_jQqvJre0_dE2lE_Rw
📺 Channel Title: Bitwarden
ℹ️ Feed already exists in Miniflux. Skipping creation.
```

Refresh failed feeds:

```bash
bash refresh_feeds.sh
```
Example of failed feeds being refreshed:

```bash
🔐 Using Bitwarden secrets for configuration
📉 Fetching failing feeds from Miniflux...
⚠️  Found failing feeds:
   - (546) r/Linux
   - (547) BBC Sport
  → Refreshed feed ID 546 successfully (204)
  ⚠️ Transient error (500) refreshing feed ID 547 — retrying once...
     ✅ Retry successful for feed ID 547

===== SUMMARY =====
✅ Refreshed successfully: 2 feed(s)
⚠️  Failed to refresh: 0 feed(s)
===================
```

Check for duplicates across BBC Sport feeds and mark them as read:

```bash
python3 dedupe_bbc_sport.py
```

Example of duplicate feeds being detected and marked as read:

```bash
🔐 Retrieving Miniflux secrets from Bitwarden...
✅ Miniflux connection successful.
🔍 Checking feed 481 (2 unread entries)...
ℹ️ No duplicates found in feed 481
🔍 Checking feed 482 (9 unread entries)...
🧹 Feed 482: 1 duplicates -> mark read
   Examples: The rise and fall of North Korea - the sleeping giant of women's football
✅ Run completed at 2025-10-22 16:58:29
```

Logs for each script are written to the logs/ directory for traceability.

## Security Considerations

Secrets are never stored in the repository or on disk in plaintext.

All sensitive values are retrieved dynamically from Bitwarden Secrets Manager using the `bws` CLI.

Each script validates environment variables and connection credentials before execution.

For production use, ensure Bitwarden credentials are restricted to least privilege.

## Information

These scripts were developed as part of my ongoing exploration of the Miniflux API.
They serve as practical examples for automating common tasks such as adding new feeds, updating filter rules, and refreshing failing subscriptions.

While there may be more efficient or advanced ways to achieve similar results, the primary goal of this project has been to learn through experimentation — combining shell scripting, API interaction, and Bitwarden-based secret management in a real-world context.

You’re welcome to modify, extend, or adapt any of these scripts to suit your own setup or workflow.
If you discover improvements, optimisations, or alternative approaches, feel free to share them with me.
