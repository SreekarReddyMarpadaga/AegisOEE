#!/usr/bin/env bash
# =============================================================================
# deploy_all.sh — Full AegisOEE deployment (no LLM required)
# Usage: ./deploy_all.sh <connection_name>
#
# Runs all steps in dependency order:
#   01 → 02 → load_data → 04 → 05 → 06 → 07 → 08 → 09_app → 10_verify
#
# Prerequisites:
#   - snow CLI installed and authenticated
#   - Python 3.12 venv with: snowflake-snowpark-python pandas numpy
#   - Snowflake privileges: CREATE DATABASE/WAREHOUSE/SCHEMA/TABLE/DT/TASK/STREAM/STAGE/STREAMLIT
# =============================================================================
set -euo pipefail

CONN="${1:?Usage: ./deploy_all.sh <connection_name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"

step() {
  echo ""
  echo "====================================================================="
  echo "  STEP: $1"
  echo "====================================================================="
}

run_sql() {
  snow sql --connection "$CONN" -f "$1"
}

# ── 01: Database, warehouses, schemas, stages ──
step "01_database_warehouses.sql"
run_sql "$SQL_DIR/01_database_warehouses.sql"

# ── 02: All tables (CORE, RAW, ACTION, ML, TEST, SEMANTIC) ──
step "02_tables.sql"
run_sql "$SQL_DIR/02_tables.sql"

# ── 03: Data load (backfill.py + doc upload — no LLM) ──
step "load_data.sh (data generation + upload)"
bash "$SCRIPT_DIR/load_data.sh" "$CONN"

# ── 04: Streams + Dynamic Tables + Views ──
step "04_streams_dynamic_tables.sql"
run_sql "$SQL_DIR/04_streams_dynamic_tables.sql"

echo "  Waiting 120s for initial DT refresh (CLEAN → 1MIN → 15MIN → OEE)..."
sleep 120

# ── 05: ML models (training ~15-30 min + backfill scoring) ──
step "05_ml_models.sql (model training + backfill — expect ~15-30 min)"
run_sql "$SQL_DIR/05_ml_models.sql"

# ── 06: Semantic view + Cortex Search ──
step "06_semantic_search.sql"
run_sql "$SQL_DIR/06_semantic_search.sql"

# ── 07: Agent (tool procs + MCP server + cortex project deploy) ──
step "07_agent.sql"
run_sql "$SQL_DIR/07_agent.sql"
echo "  Deploying agent via cortex project..."
cd "$SCRIPT_DIR/../cortex_project"
cortex project deploy --connection "$CONN" 2>/dev/null || \
  echo "  NOTE: cortex project deploy not available — deploy agent manually via Snowsight or cortex CLI"
cd "$SCRIPT_DIR"

# ── 08: Action loop (alert scoring, work orders, outbox) ──
step "08_action_loop.sql"
run_sql "$SQL_DIR/08_action_loop.sql"

# ── 09: Streamlit app ──
step "09_app.sh"
bash "$SQL_DIR/09_app.sh" "$CONN"

# ── 10: Verification ──
step "10_verify.sql"
run_sql "$SQL_DIR/10_verify.sql"

echo ""
echo "====================================================================="
echo "  DEPLOY COMPLETE"
echo "====================================================================="
echo ""
echo "Next steps:"
echo "  1. Review verification output above for any FAIL results"
echo "  2. Resume tasks when ready:"
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ML.TASK_DETECT_ANOMALIES RESUME\""
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ACTION.TASK_SCORE_ALERTS RESUME\""
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ACTION.TASK_OUTBOX_RETRY RESUME\""
echo "  3. Start the outbox dispatcher for GitHub/Slack integration:"
echo "       GITHUB_PAT=... SLACK_WEBHOOK_URL=... python scripts/outbox_dispatcher.py"
echo "  4. Open the Streamlit app: AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER"
