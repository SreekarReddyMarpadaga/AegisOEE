#!/usr/bin/env bash
# One-command build: runs CoCo missions 00→09 headlessly; stops on first failure.
# Reproducibility contract: each mission checks whether its artifacts already exist
# in the repo and executes/validates them instead of regenerating. Regenerate or
# edit only when a check fails. See AGENTS.md "Reproducibility contract" section.
set -u
CONN="${COCO_CONN:-aegis}"
MODEL="${COCO_MODEL:-auto}"
LOG_DIR="docs/runs"
mkdir -p "$LOG_DIR"

# Reproducibility preamble: passed to every mission via --bypass
export AEGIS_REPRODUCIBILITY_CONTRACT="true"

MISSIONS=(
  "prompts/00_foundation.md"
  "prompts/01_synthetic_data.md"
  "prompts/01b_oee_realism.md"
  "prompts/02_pipelines.md"
  "prompts/03_ml.md"
  "prompts/04_semantics_agent.md"
  "prompts/05_action_loop.md"
  "prompts/06_app.md"
  "prompts/06b_app_warehouse_runtime.md"
  "prompts/07_cmms_shift_planning.md"
  "prompts/07b_cmms_hardening.md"
  "prompts/08_parts_procurement.md"
  "prompts/09_work_order_execution.md"
)

for m in "${MISSIONS[@]}"; do
  nn="$(basename "$m" | cut -d_ -f1 | tr '[:lower:]' '[:upper:]')"
  log="$LOG_DIR/mission_${nn}_$(date +%Y%m%d_%H%M%S).log"
  echo "==> Mission $nn : $m (log: $log)"
  # --bypass: headless runs auto-reject tool calls otherwise; sql-guard hook remains the safety net
  if ! cortex exec --file "$m" -c "$CONN" -m "$MODEL" --bypass 2>&1 | tee "$log"; then
    echo "BUILD HALTED: mission $nn returned non-zero"; exit 1
  fi
  if ! grep -q "MISSION ${nn} COMPLETE" "$log"; then
    echo "BUILD HALTED: mission $nn did not print its completion line"; exit 1
  fi
done

echo "==> All missions complete. Suspending tasks (missions may resume them) and capturing usage snapshot..."
for t in ML.TASK_DETECT_ANOMALIES ACTION.TASK_SCORE_ALERTS ACTION.TASK_OUTBOX_RETRY CORE.TASK_REFRESH_CMMS_PLAN; do
  snow sql -c "$CONN" -q "ALTER TASK IF EXISTS AEGIS_OEE.$t SUSPEND" >/dev/null 2>&1 || true
done
bash scripts/snapshot_usage.sh || true
echo "BUILD COMPLETE"
