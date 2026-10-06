#!/usr/bin/env bash
# =============================================================================
# deploy_all.sh — Full AegisOEE deployment (no LLM, no cortex CLI required)
# Usage: ./deploy_all.sh <connection_name> [--only <step>] [--from <step>]
#
# Steps: 01 02 03 04 05 06 07 08 11 09 10
#   01 = database/warehouses/schemas/stages
#   02 = tables
#   03 = data load (backfill + docs + CMMS)
#   04 = streams + dynamic tables + views
#   05 = ML models (training + backfill scoring) — slowest step
#   06 = semantic view + Cortex Search
#   07 = agent (tool procs + MCP server + Cortex Agent via SQL)
#   08 = action loop (alert scoring, work orders, outbox procs, tasks)
#   11 = CMMS planning (scheduling procs + task)
#   09 = Streamlit app
#   10 = verification
#
# Flags:
#   --only <step>  Run only the specified step number
#   --from <step>  Resume from the specified step (inclusive)
#
# Prerequisites:
#   - snow CLI installed and authenticated
#   - Python 3.12 venv with: snowflake-snowpark-python pandas numpy pyarrow
#   - Snowflake privileges: CREATE DATABASE/WAREHOUSE/TABLE/DT/TASK/STREAM/STAGE
# =============================================================================
set -euo pipefail

# ── Parse arguments ──
CONN=""
ONLY=""
FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    -*) echo "ERROR: Unknown flag $1"; exit 1 ;;
    *) CONN="$1"; shift ;;
  esac
done

if [ -z "$CONN" ]; then
  echo "Usage: ./deploy_all.sh <connection_name> [--only <step>] [--from <step>]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOTAL_START=$(date +%s)

# Ordered step list (execution order, not numeric order)
STEPS=(01 02 03 04 05 06 07 08 11 09 10)

get_step_name() {
  case "$1" in
    01) echo "Database, warehouses, schemas, stages" ;;
    02) echo "Tables (CORE, RAW, ACTION, ML, TEST, SEMANTIC)" ;;
    03) echo "Data load (backfill.py + docs + CMMS plan)" ;;
    04) echo "Streams, Dynamic Tables, views" ;;
    05) echo "ML models (training + backfill scoring)" ;;
    06) echo "Semantic view + Cortex Search" ;;
    07) echo "Agent (tool procs + MCP + Cortex Agent)" ;;
    08) echo "Action loop (alert scoring, work orders, tasks)" ;;
    11) echo "CMMS planning (scheduling procs + task)" ;;
    09) echo "Streamlit app (warehouse runtime)" ;;
    10) echo "Verification" ;;
    *)  echo "Unknown step $1" ;;
  esac
}

# ── Helper functions ──

step_banner() {
  local num=$1
  echo ""
  echo "====================================================================="
  echo "  STEP $num: $(get_step_name $num)"
  echo "====================================================================="
}

run_sql_file() {
  snow sql --connection "$CONN" -f "$1"
}

run_sql_query() {
  snow sql --connection "$CONN" -q "$1"
}

should_run() {
  local step=$1
  if [ -n "$ONLY" ]; then
    [ "$step" = "$ONLY" ] && return 0 || return 1
  fi
  if [ -n "$FROM" ]; then
    local found=false
    for s in "${STEPS[@]}"; do
      [ "$s" = "$FROM" ] && found=true
      if $found && [ "$s" = "$step" ]; then return 0; fi
    done
    return 1
  fi
  return 0
}

elapsed() {
  local start=$1
  local end=$(date +%s)
  local dur=$((end - start))
  printf "%dm%02ds" $((dur / 60)) $((dur % 60))
}

poll_dynamic_tables() {
  echo "  Polling Dynamic Tables for readiness (up to 10 min)..."
  local max_wait=600
  local interval=15
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local pending
    pending=$(snow sql --connection "$CONN" -q "
      SELECT COUNT(*) AS c FROM AEGIS_OEE.INFORMATION_SCHEMA.TABLES
      WHERE TABLE_SCHEMA IN ('FEATURES','SEMANTIC') AND IS_DYNAMIC = 'YES' AND ROW_COUNT = 0;
    " 2>&1 | grep -oP '\d+' | tail -1 || echo "7")
    if [ "$pending" = "0" ]; then
      echo "  All Dynamic Tables ready (${waited}s)"
      return 0
    fi
    echo "  $pending DTs still initializing... (${waited}s elapsed)"
    sleep $interval
    waited=$((waited + interval))
  done
  echo "  WARNING: DT polling timed out after ${max_wait}s — some may still be refreshing"
}

# ── Preflight checks ──
echo "====================================================================="
echo "  AegisOEE Deploy — Preflight Checks"
echo "====================================================================="

# Check snow CLI
if ! command -v snow &> /dev/null; then
  echo "FAIL: 'snow' CLI not found. Install: pip install snowflake-cli"
  exit 1
fi
echo "  snow CLI: $(snow --version 2>/dev/null | head -1)"

# Check Python + packages
if ! command -v python &> /dev/null && ! command -v python3 &> /dev/null; then
  echo "FAIL: Python not found."
  exit 1
fi
PYTHON=$(command -v python3 || command -v python)
echo "  Python: $($PYTHON --version 2>&1)"

for pkg in snowflake.snowpark pandas numpy; do
  if ! $PYTHON -c "import $pkg" 2>/dev/null; then
    echo "FAIL: Python package '$pkg' not found. Install: pip install snowflake-snowpark-python pandas numpy pyarrow"
    exit 1
  fi
done
echo "  Python packages: snowflake-snowpark-python, pandas, numpy OK"

# Check connection works
if ! snow sql --connection "$CONN" -q "SELECT 1" &>/dev/null; then
  echo "FAIL: Cannot connect to Snowflake with connection '$CONN'."
  echo "  Check: snow connection test --connection $CONN"
  exit 1
fi
echo "  Connection '$CONN': OK"

# Check role privileges
CAN_CREATE=$(snow sql --connection "$CONN" -q "SELECT CURRENT_ROLE()" 2>&1 || true)
ROLE_NAME=$(echo "$CAN_CREATE" | grep -oP '[A-Z_]+' | head -1 || echo "unknown")
echo "  Role: $ROLE_NAME"

# Check Cortex availability (best effort — don't fail the deploy)
set +e
CORTEX_OK=$(snow sql --connection "$CONN" -q "SELECT SNOWFLAKE.CORTEX.COMPLETE('snowflake-arctic','test') AS t" 2>&1)
CORTEX_RC=$?
set -e
if [ $CORTEX_RC -ne 0 ]; then
  echo "  WARNING: Cortex AI may not be available in this region."
  echo "    CHECK_PARTS proc (RFQ text), Search service, and Agent may fail."
  echo "    All other objects will deploy successfully."
else
  echo "  Cortex AI: available"
fi

# Confirm no cortex CLI references in deploy/
CORTEX_REFS=$(grep -ri 'cortex ' "$SCRIPT_DIR/" --include='*.sh' --include='*.sql' -l 2>/dev/null | grep -v 'CORTEX\.' | grep -v 'cortex_project' | grep -v '#' || true)
# This is just informational — SQL references to Cortex features are expected

echo ""
echo "  Preflight: ALL CHECKS PASSED"
echo "  Connection: $CONN"
[ -n "$ONLY" ] && echo "  Mode: --only $ONLY"
[ -n "$FROM" ] && echo "  Mode: --from $FROM"
echo ""

# ── Step execution ──

# ── 01: Database, warehouses, schemas, stages ──
if should_run 01; then
  step_banner 01
  S=$(date +%s)
  run_sql_file "$SQL_DIR/01_database_warehouses.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 02: Tables ──
if should_run 02; then
  step_banner 02
  S=$(date +%s)
  run_sql_file "$SQL_DIR/02_tables.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 03: Data load ──
if should_run 03; then
  step_banner 03
  S=$(date +%s)
  bash "$SCRIPT_DIR/load_data.sh" "$CONN"
  echo "  Done ($(elapsed $S))"
fi

# ── 04: Streams + Dynamic Tables + Views ──
if should_run 04; then
  step_banner 04
  S=$(date +%s)
  run_sql_file "$SQL_DIR/04_streams_dynamic_tables.sql"
  poll_dynamic_tables
  echo "  Done ($(elapsed $S))"
fi

# ── 05: ML models (training ~15-30 min + backfill scoring) ──
if should_run 05; then
  step_banner 05
  S=$(date +%s)
  echo "  This step trains 5 ML models + runs historical scoring. Expect 15-30 min."
  run_sql_file "$SQL_DIR/05_ml_models.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 06: Semantic view + Cortex Search ──
if should_run 06; then
  step_banner 06
  S=$(date +%s)
  run_sql_file "$SQL_DIR/06_semantic_search.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 07: Agent (tool procs + MCP server + Cortex Agent via SQL) ──
if should_run 07; then
  step_banner 07
  S=$(date +%s)
  run_sql_file "$SQL_DIR/07_agent.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 08: Action loop (alert scoring, work orders, outbox) ──
if should_run 08; then
  step_banner 08
  S=$(date +%s)
  run_sql_file "$SQL_DIR/08_action_loop.sql"
  echo "  Done ($(elapsed $S))"
fi

# ── 11: CMMS planning (shift plan, maintenance windows, scheduling) ──
if should_run 11; then
  step_banner 11
  S=$(date +%s)
  run_sql_file "$SQL_DIR/11_cmms_planning.sql"
  echo "  Loading CMMS plan data..."
  cd "$REPO_DIR"
  $PYTHON data_gen/cmms_plan.py --conn "$CONN" --seed 42 --days 14
  cd "$SCRIPT_DIR"
  echo "  Done ($(elapsed $S))"
fi

# ── 09: Streamlit app ──
if should_run 09; then
  step_banner 09
  S=$(date +%s)
  bash "$SQL_DIR/09_app.sh" "$CONN"
  echo "  Done ($(elapsed $S))"
fi

# ── 10: Verification ──
if should_run 10; then
  step_banner 10
  S=$(date +%s)
  echo ""
  echo "  Running verification checks..."
  echo ""

  VERIFY_OUTPUT=$(run_sql_file "$SQL_DIR/10_verify.sql" 2>&1)
  echo "$VERIFY_OUTPUT"

  FAIL_COUNT=$(echo "$VERIFY_OUTPUT" | grep -c '| FAIL ' || true)
  PASS_COUNT=$(echo "$VERIFY_OUTPUT" | grep -c '| PASS ' || true)

  echo ""
  echo "  Verification: $PASS_COUNT PASS, $FAIL_COUNT FAIL ($(elapsed $S))"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  WARNING: Some verification checks failed. Review output above."
  fi
fi

# ── Summary ──
TOTAL_END=$(date +%s)
TOTAL_DUR=$(( TOTAL_END - TOTAL_START ))

echo ""
echo "====================================================================="
echo "  DEPLOY COMPLETE — $(printf '%dm%02ds' $((TOTAL_DUR / 60)) $((TOTAL_DUR % 60)))"
echo "====================================================================="
echo ""
echo "Next steps:"
echo "  1. Review verification output above for any FAIL results"
echo "  2. Resume tasks when ready:"
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ML.TASK_DETECT_ANOMALIES RESUME\""
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ACTION.TASK_SCORE_ALERTS RESUME\""
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.ACTION.TASK_OUTBOX_RETRY RESUME\""
echo "       snow sql -c $CONN -q \"ALTER TASK AEGIS_OEE.CORE.TASK_REFRESH_CMMS_PLAN RESUME\""
echo "  3. Start the outbox dispatcher for GitHub/Slack integration:"
echo "       GITHUB_PAT=... SLACK_WEBHOOK_URL=... python scripts/outbox_dispatcher.py"
echo "  4. Open the Streamlit app: AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER"
