#!/usr/bin/env bash
# =============================================================================
# load_data.sh — LLM-free data pipeline: backfill.py → CSVs → PUT → COPY INTO
# Requires: Python 3.12 venv with snowflake-snowpark-python, pandas, numpy
# =============================================================================
set -euo pipefail
CONN="${1:-aegis}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKFILL="$REPO_DIR/data_gen/backfill.py"
DOCS_DIR="$REPO_DIR/data_gen/docs"

echo "=== AegisOEE Data Load (seed 42, deterministic) ==="
echo "Connection: $CONN"

# ── Step 1: Run backfill.py ──
# backfill.py uses write_pandas to load directly to Snowflake (no CSV intermediary).
# It is seeded (np.random.seed(42)) for deterministic output.
echo ""
echo "[1/2] Running data_gen/backfill.py (75-day seeded data generation)..."
echo "  This loads 10 tables: CORE.ASSET, CORE.SHIFT_CALENDAR, RAW.SENSOR_TELEMETRY,"
echo "  RAW.PRODUCTION_EVENT, CORE.PRODUCTION_ORDER, CORE.DOWNTIME_EVENT,"
echo "  CORE.MAINTENANCE_HISTORY, TEST.GROUND_TRUTH_FAILURES, CORE.PARTS_INVENTORY,"
echo "  CORE.FAILURE_MODE_PARTS"

cd "$REPO_DIR"
python "$BACKFILL" --connection "$CONN"

# ── Step 2: Upload maintenance docs to DOC_STAGE ──
echo ""
echo "[2/2] Uploading maintenance docs to @AEGIS_OEE.RAW.DOC_STAGE..."

if [ -d "$DOCS_DIR" ]; then
  snow stage copy "$DOCS_DIR/*" @AEGIS_OEE.RAW.DOC_STAGE --connection "$CONN" --overwrite 2>/dev/null || \
  snow sql --connection "$CONN" -q "PUT 'file://$DOCS_DIR/*' @AEGIS_OEE.RAW.DOC_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

  # Load docs into SEMANTIC.MAINTENANCE_DOCS table
  snow sql --connection "$CONN" -q "
    TRUNCATE TABLE IF EXISTS AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS;

    INSERT INTO AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS (DOC_ID, ASSET_ID, DOC_TYPE, TITLE, CONTENT, SOURCE)
    SELECT
      'DOC_' || ROW_NUMBER() OVER (ORDER BY RELATIVE_PATH) AS DOC_ID,
      CASE
        WHEN RELATIVE_PATH ILIKE '%CNC_01%' THEN 'CNC_01_SPINDLE'
        WHEN RELATIVE_PATH ILIKE '%CNC_02%' THEN 'CNC_02_SPINDLE'
        WHEN RELATIVE_PATH ILIKE '%CNC_03%' THEN 'CNC_03_SPINDLE'
        WHEN RELATIVE_PATH ILIKE '%CNC_04%' THEN 'CNC_04_SPINDLE'
        WHEN RELATIVE_PATH ILIKE '%COOLANT_PUMP_01%' THEN 'COOLANT_PUMP_01'
        WHEN RELATIVE_PATH ILIKE '%COOLANT_PUMP_02%' THEN 'COOLANT_PUMP_02'
        WHEN RELATIVE_PATH ILIKE '%SERVO%' THEN 'SERVO_MOTOR_01'
        WHEN RELATIVE_PATH ILIKE '%CONVEYOR%GBX_01%' THEN 'CONVEYOR_GBX_01'
        WHEN RELATIVE_PATH ILIKE '%CONVEYOR%GBX_02%' THEN 'CONVEYOR_GBX_02'
        WHEN RELATIVE_PATH ILIKE '%AIR_COMP%' THEN 'AIR_COMP_01'
        WHEN RELATIVE_PATH ILIKE '%spindle%' THEN 'CNC_01_SPINDLE'
        WHEN RELATIVE_PATH ILIKE '%coolant%' THEN 'COOLANT_PUMP_01'
        WHEN RELATIVE_PATH ILIKE '%gearbox%' OR RELATIVE_PATH ILIKE '%conveyor%' THEN 'CONVEYOR_GBX_01'
        WHEN RELATIVE_PATH ILIKE '%compressor%' THEN 'AIR_COMP_01'
        WHEN RELATIVE_PATH ILIKE '%servo%' THEN 'SERVO_MOTOR_01'
        ELSE NULL
      END AS ASSET_ID,
      CASE
        WHEN RELATIVE_PATH ILIKE '%manual%' THEN 'MANUAL'
        WHEN RELATIVE_PATH ILIKE '%tech_note%' OR RELATIVE_PATH ILIKE '%note%' THEN 'TECH_NOTE'
        ELSE 'DOCUMENT'
      END AS DOC_TYPE,
      REGEXP_REPLACE(SPLIT_PART(RELATIVE_PATH, '/', -1), '\\.(md|txt)$', '') AS TITLE,
      TO_VARCHAR(\$1) AS CONTENT,
      RELATIVE_PATH AS SOURCE
    FROM @AEGIS_OEE.RAW.DOC_STAGE (FILE_FORMAT => (TYPE=CSV FIELD_DELIMITER=NONE RECORD_DELIMITER=NONE ESCAPE_UNENCLOSED_FIELD=NONE))
    WHERE RELATIVE_PATH ILIKE '%.md' OR RELATIVE_PATH ILIKE '%.txt';
  "
  echo "  Docs loaded into SEMANTIC.MAINTENANCE_DOCS"
else
  echo "  WARNING: $DOCS_DIR not found — skipping doc upload"
fi

echo ""
echo "=== Data load complete ==="
