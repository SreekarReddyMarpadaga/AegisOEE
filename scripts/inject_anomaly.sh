#!/usr/bin/env bash
# Demo lever: streams a compressed bearing-wear episode into RAW telemetry (golden path).
set -u
ASSET="${1:-CNC_01_SPINDLE}"
MODE="${2:-BEARING_WEAR}"
DURATION="${3:-30}"
CONN="${COCO_CONN:-aegis}"

if [ ! -f data_gen/simulator.py ]; then
  echo "simulator not built yet — run Mission 01 first (scripts/build_all.sh)"; exit 1
fi
echo "Injecting $MODE on $ASSET over ${DURATION} minutes (10s ticks)..."
python3 data_gen/simulator.py --replay "$MODE" --asset "$ASSET" --duration-min "$DURATION" --tick-s 10 --conn "$CONN"
echo "Replay finished. Alert task should fire within 5 minutes; watch ACTION.ALERT and the app."
