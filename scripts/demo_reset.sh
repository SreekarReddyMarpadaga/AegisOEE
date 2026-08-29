#!/usr/bin/env bash
# Restores pristine demo state: clears live replay data, reopens the storyline cleanly.
set -u
CONN="${COCO_CONN:-aegis}"

cortex exec --file - -c "$CONN" --bypass <<'PROMPT'
Read AGENTS.md. Non-interactive demo reset for AEGIS_OEE only:
1. DELETE FROM AEGIS_OEE.RAW.SENSOR_TELEMETRY WHERE ingest_ts >= CURRENT_DATE (today's live-replay rows only; historical backfill untouched).
2. Close or delete alerts created today: UPDATE AEGIS_OEE.ACTION.ALERT SET status='CLOSED' WHERE onset_ts >= CURRENT_DATE AND status <> 'CLOSED'.
3. Mark today's non-approved work orders REJECTED with reason 'demo reset'; leave approved/synced history intact.
4. Requeue nothing; clear OUTBOX rows in status 'PENDING' created today.
5. Insert an audit row action='DEMO_RESET'.
6. Confirm DT freshness by selecting max(ts) per layer.
Print DEMO RESET COMPLETE when done.
PROMPT
