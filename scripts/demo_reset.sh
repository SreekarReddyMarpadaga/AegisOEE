#!/usr/bin/env bash
# Restores pristine demo state: pure SQL via snow sql (no cortex exec).
set -euo pipefail
CONN="${COCO_CONN:-aegis}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Running demo reset on connection: $CONN"
snow sql -f "$SCRIPT_DIR/demo_reset.sql" --connection "$CONN"
echo "==> Demo reset complete. All tasks suspended, ACTION tables empty, inventory at seed."
