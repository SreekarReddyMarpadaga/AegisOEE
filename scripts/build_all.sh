#!/usr/bin/env bash
# One-command build: runs CoCo missions 00→06 headlessly; stops on first failure.
set -u
CONN="${COCO_CONN:-aegis}"
MODEL="${COCO_MODEL:-auto}"
LOG_DIR="docs/runs"
mkdir -p "$LOG_DIR"

MISSIONS=(
  "prompts/00_foundation.md"
  "prompts/01_synthetic_data.md"
  "prompts/02_pipelines.md"
  "prompts/03_ml.md"
  "prompts/04_semantics_agent.md"
  "prompts/05_action_loop.md"
  "prompts/06_app.md"
)

for m in "${MISSIONS[@]}"; do
  nn="$(basename "$m" | cut -c1-2)"
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

echo "==> All missions complete. Capturing usage snapshot..."
bash scripts/snapshot_usage.sh || true
echo "BUILD COMPLETE"
