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
python "$BACKFILL" --conn "$CONN"

# ── Step 2: Upload maintenance docs to DOC_STAGE ──
echo ""
echo "[2/2] Uploading maintenance docs to @AEGIS_OEE.RAW.DOC_STAGE..."

if [ -d "$DOCS_DIR" ]; then
  snow stage copy "$DOCS_DIR/*" @AEGIS_OEE.RAW.DOC_STAGE --connection "$CONN" --overwrite 2>/dev/null || \
  snow sql --connection "$CONN" -q "PUT 'file://$DOCS_DIR/*' @AEGIS_OEE.RAW.DOC_STAGE AUTO_COMPRESS=FALSE OVERWRITE=TRUE"

  # Create a file format for reading raw text files as single-column
  snow sql --connection "$CONN" -q "
    CREATE FILE FORMAT IF NOT EXISTS AEGIS_OEE.RAW.FF_RAW_TEXT
      TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE ESCAPE_UNENCLOSED_FIELD = NONE;
  "

  # Load docs into SEMANTIC.MAINTENANCE_DOCS table
  snow sql --connection "$CONN" -q "
    TRUNCATE TABLE IF EXISTS AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS;

    INSERT INTO AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS (DOC_ID, ASSET_ID, DOC_TYPE, TITLE, CONTENT, SOURCE)
    SELECT
      'DOC_' || ROW_NUMBER() OVER (ORDER BY METADATA\$FILENAME) AS DOC_ID,
      CASE
        WHEN METADATA\$FILENAME ILIKE '%spindle%' THEN 'CNC_01_SPINDLE'
        WHEN METADATA\$FILENAME ILIKE '%coolant%' THEN 'COOLANT_PUMP_01'
        WHEN METADATA\$FILENAME ILIKE '%conveyor%' OR METADATA\$FILENAME ILIKE '%gearbox%' THEN 'CONVEYOR_GBX_01'
        WHEN METADATA\$FILENAME ILIKE '%compressor%' THEN 'AIR_COMP_01'
        WHEN METADATA\$FILENAME ILIKE '%servo%' THEN 'SERVO_MOTOR_01'
        ELSE NULL
      END AS ASSET_ID,
      CASE
        WHEN METADATA\$FILENAME ILIKE '%manual%' THEN 'MANUAL'
        WHEN METADATA\$FILENAME ILIKE '%tech_note%' THEN 'TECH_NOTE'
        ELSE 'DOCUMENT'
      END AS DOC_TYPE,
      REGEXP_REPLACE(SPLIT_PART(METADATA\$FILENAME, '/', -1), '\\\\.(md|txt)\$', '') AS TITLE,
      TO_VARCHAR(\$1) AS CONTENT,
      METADATA\$FILENAME AS SOURCE
    FROM @AEGIS_OEE.RAW.DOC_STAGE (FILE_FORMAT => AEGIS_OEE.RAW.FF_RAW_TEXT)
    WHERE METADATA\$FILENAME ILIKE '%.md' OR METADATA\$FILENAME ILIKE '%.txt';
  "
  echo "  Docs loaded into SEMANTIC.MAINTENANCE_DOCS"
else
  echo "  WARNING: $DOCS_DIR not found — skipping doc upload"
fi

echo ""
echo "=== Data load complete ==="
