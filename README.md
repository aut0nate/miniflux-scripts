# Miniflux Automation Scripts

This repository contains a collection of scripts which I am using to automate the management and maintenance of [Miniflux](https://miniflux.app/) feeds.
Each script focuses on a specific task, from refreshing and filtering feeds to adding new subscriptions or cleaning up duplicates.
All scripts retrieve credentials securely from **Bitwarden Secrets Manager**, avoiding hard-coded secrets or environment variables in source control.

---

## Overview

| Script | Language | Purpose |
|--------|-----------|----------|
| `yt2rss.sh` | Bash | Adds a YouTube channel to Miniflux using its RSS feed. Automatically resolves a channel ID from a YouTube URL and posts it to the Miniflux API. |
| `refresh_feeds.sh` | Bash | Refreshes all Miniflux feeds matching specific domains (for example, `reddit.com` or `rsshub.autonate.dev`). Useful for keeping feeds up to date. |
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

Refresh selected feeds:

```bash
bash refresh_feeds.sh
```

```bash
python3 dedupe_bbc_sport.py
```

Logs for each script are written to the logs/ directory for traceability.

## Security Considerations

Secrets are never stored in the repository or on disk in plaintext.

All sensitive values are retrieved dynamically from Bitwarden Secrets Manager using the `bws` CLI.

Each script validates environment variables and connection credentials before execution.

For production use, ensure Bitwarden credentials are restricted to least privilege.
