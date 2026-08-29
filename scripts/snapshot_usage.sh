#!/usr/bin/env bash
# Snapshots CoCo usage records into docs/runs/.
set -u
CONN="${COCO_CONN:-aegis}"
OUT="docs/runs"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d_%H%M%S)"

{
  echo "# Evidence snapshot $STAMP"
  echo; echo "## Conversations (thread IDs)"
  cortex conversations list 2>/dev/null || echo "(conversations subcommand unavailable — copy session IDs shown at cortex startup/exit)"
  echo; echo "## Automations"
  cortex automation list 2>/dev/null || echo "(automations unavailable in this account)"
  echo; echo "## MCP servers"
  cortex mcp list 2>/dev/null || true
  echo; echo "## Skills"
  cortex skill list 2>/dev/null || true
} > "$OUT/cli_snapshot_$STAMP.md"

cortex -c "$CONN" --bypass -p "Query SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY: total requests, total TOKEN_CREDITS, grouped by INTERFACE, last 30 days. Also last 7 days daily trend. Print as two markdown tables only." \
  > "$OUT/coco_usage_$STAMP.md" 2>&1 || true

echo "Snapshots written to $OUT/ — note relevant session IDs in docs/run-records.md"
