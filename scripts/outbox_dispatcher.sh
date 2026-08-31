#!/usr/bin/env bash
# AegisOEE Outbox Dispatcher — thin wrapper around outbox_dispatcher.py.
# Handles: outbound dispatch (GitHub Issues + Slack), GitHub closure sync-back,
# inbound sync (GitHub issue close → WO state transition + parts release).
#
# Required env vars:
#   GITHUB_PAT          — fine-grained PAT with Issues RW
#   SLACK_WEBHOOK_URL   — Slack incoming webhook URL
#
# Usage:
#   GITHUB_PAT=... SLACK_WEBHOOK_URL=... bash scripts/outbox_dispatcher.sh
#   # or as a cron job / CoCo automation

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec python3 "$SCRIPT_DIR/outbox_dispatcher.py"
