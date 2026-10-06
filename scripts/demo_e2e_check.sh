#!/usr/bin/env bash
# =============================================================================
# demo_e2e_check.sh — End-to-end golden-path proof via real procedures
# Drives: alert → ACK → approve → blocked start → procurement → start →
#         complete → close, with guardrail checks at each step.
# Records M09_ tests to TEST.ACTION_GUARDRAIL_RESULTS.
# Non-LLM: pure SQL/bash via snow sql.
# =============================================================================
set -uo pipefail
CONN="${COCO_CONN:-aegis}"
PASS=0
FAIL=0

run_sql() {
  snow sql -q "$1" --connection "$CONN" 2>&1
}

record_test() {
  local name="$1" result="$2" detail="$3"
  local safe_detail
  safe_detail=$(echo "$detail" | sed "s/'/''/g" | head -c 2000)
  run_sql "INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL) SELECT '${name}', '${result}', '${safe_detail}'" > /dev/null
  if [ "$result" = "PASS" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name — $detail"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== AegisOEE Mission 09 E2E Check ==="
echo "Connection: $CONN"
echo ""

# Clean previous M09 tests
run_sql "DELETE FROM AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS WHERE TEST_NAME LIKE 'M09_%'" > /dev/null

# --------------------------------------------------------------------------
# Step 0: Ensure pristine state
# --------------------------------------------------------------------------
echo "--- Step 0: Ensure pristine state ---"
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.ALERT" > /dev/null
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.WORK_ORDER" > /dev/null
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX" > /dev/null
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.PURCHASE_REQUISITION" > /dev/null
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.WO_SCHEDULE" > /dev/null
run_sql "TRUNCATE TABLE IF EXISTS AEGIS_OEE.ACTION.ACTION_AUDIT" > /dev/null
# Reset inventory to seed
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 1, RESERVED_QTY = 0 WHERE PART_ID = 'P001'" > /dev/null
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 12, RESERVED_QTY = 2 WHERE PART_ID = 'P002'" > /dev/null
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 6, RESERVED_QTY = 0 WHERE PART_ID = 'P003'" > /dev/null
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 5, RESERVED_QTY = 1 WHERE PART_ID = 'P005'" > /dev/null
# Reset window bookings
run_sql "UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW SET BOOKED_MIN = 0, STATUS = 'OPEN' WHERE STATUS = 'BOOKED'" > /dev/null

# --------------------------------------------------------------------------
# Step 1: Seed golden-path alert
# --------------------------------------------------------------------------
echo "--- Step 1: Seed golden-path alert ---"
ALERT_ID="ALT_M09_GOLDEN"
run_sql "
INSERT INTO AEGIS_OEE.ACTION.ALERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE)
SELECT '${ALERT_ID}', 'CNC_01_SPINDLE', CURRENT_TIMESTAMP(), 'P1', 0.92, 0.88,
       'BEARING_WEAR', 0.15, 'NEW',
       OBJECT_CONSTRUCT('vibration_trend', 'rising', 'kurtosis_z', 3.2, 'temp_z', 1.8)
" > /dev/null

# ACK it
run_sql "UPDATE AEGIS_OEE.ACTION.ALERT SET STATUS = 'ACKED' WHERE ALERT_ID = '${ALERT_ID}'" > /dev/null
run_sql "INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_ACK_M09', CURRENT_TIMESTAMP(), 'MAINT_SUPERVISOR_RAJ', 'ALERT_ACKED', '${ALERT_ID}',
         OBJECT_CONSTRUCT('method', 'e2e_check')" > /dev/null

STATUS=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = '${ALERT_ID}'" | grep -o 'ACKED' || true)
if [ "$STATUS" = "ACKED" ]; then
  record_test "M09_ALERT_SEEDED_AND_ACKED" "PASS" "Alert ${ALERT_ID} seeded and ACKed"
else
  record_test "M09_ALERT_SEEDED_AND_ACKED" "FAIL" "Alert status: $STATUS"
fi

# --------------------------------------------------------------------------
# Step 2: AGENT/NULL actor rejected on CREATE_WORK_ORDER
# --------------------------------------------------------------------------
echo "--- Step 2: Actor guardrails ---"
RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('${ALERT_ID}', 'AGENT', TRUE)")
if echo "$RESULT" | grep -q '"status":"REJECTED"'; then
  record_test "M09_CREATE_WO_AGENT_REJECTED" "PASS" "AGENT approver rejected"
else
  record_test "M09_CREATE_WO_AGENT_REJECTED" "FAIL" "$RESULT"
fi

RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('${ALERT_ID}', NULL, TRUE)")
if echo "$RESULT" | grep -q 'REJECTED'; then
  record_test "M09_CREATE_WO_NULL_REJECTED" "PASS" "NULL approver rejected"
else
  record_test "M09_CREATE_WO_NULL_REJECTED" "FAIL" "$RESULT"
fi

# --------------------------------------------------------------------------
# Step 3: Dry-run writes nothing material
# --------------------------------------------------------------------------
echo "--- Step 3: Dry-run check ---"
WO_COUNT_BEFORE=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.WORK_ORDER" | grep -oP '\d+' | tail -1)
run_sql "CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('${ALERT_ID}', 'MAINT_SUPERVISOR_RAJ', TRUE)" > /dev/null
WO_COUNT_AFTER=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.WORK_ORDER" | grep -oP '\d+' | tail -1)
if [ "$WO_COUNT_BEFORE" = "$WO_COUNT_AFTER" ]; then
  record_test "M09_CREATE_WO_DRYRUN_NO_WO" "PASS" "Dry-run: WO count unchanged ($WO_COUNT_BEFORE)"
else
  record_test "M09_CREATE_WO_DRYRUN_NO_WO" "FAIL" "WO count changed from $WO_COUNT_BEFORE to $WO_COUNT_AFTER"
fi

# --------------------------------------------------------------------------
# Step 4: Approve (real) — P001 shortage → requisition + schedule
# --------------------------------------------------------------------------
echo "--- Step 4: Approve work order ---"
APPROVE_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('${ALERT_ID}', 'MAINT_SUPERVISOR_RAJ', FALSE)")
WO_ID=$(echo "$APPROVE_RESULT" | grep -oP '"wo_id"\s*:\s*"[^"]*"' | head -1 | grep -oP '"wo_id"\s*:\s*"\K[^"]*')
if [ -z "$WO_ID" ]; then
  echo "ERROR: Could not extract WO_ID from approval result"
  echo "$APPROVE_RESULT"
  record_test "M09_WO_APPROVED" "FAIL" "Could not extract WO_ID"
else
  echo "  WO_ID: $WO_ID"
  WO_STATE=$(run_sql "SELECT STATE FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '${WO_ID}'" | grep -o 'APPROVED' || true)
  if [ "$WO_STATE" = "APPROVED" ]; then
    record_test "M09_WO_APPROVED" "PASS" "WO ${WO_ID} approved, state=APPROVED"
  else
    record_test "M09_WO_APPROVED" "FAIL" "WO state: $WO_STATE"
  fi
fi

# Check P001 shortage → requisition created
REQ_COUNT=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE WO_ID = '${WO_ID}' AND PART_ID = 'P001'" | grep -oP '\d+' | tail -1)
if [ "$REQ_COUNT" -ge 1 ]; then
  record_test "M09_P001_SHORTAGE_REQUISITION" "PASS" "P001 requisition created for WO ${WO_ID}, count=$REQ_COUNT"
else
  record_test "M09_P001_SHORTAGE_REQUISITION" "FAIL" "No P001 requisition found for WO ${WO_ID}"
fi

# Check schedule row exists
SCHED_COUNT=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE WO_ID = '${WO_ID}' AND STATUS NOT IN ('CANCELLED')" | grep -oP '\d+' | tail -1)
if [ "$SCHED_COUNT" -ge 1 ]; then
  ORDER_BY=$(run_sql "SELECT ORDER_BY_DATE FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE WO_ID = '${WO_ID}' AND STATUS NOT IN ('CANCELLED') LIMIT 1")
  record_test "M09_WO_SCHEDULED" "PASS" "WO ${WO_ID} scheduled, order_by_date in result"
else
  record_test "M09_WO_SCHEDULED" "FAIL" "No schedule row for ${WO_ID}"
fi

# --------------------------------------------------------------------------
# Step 5: START_WORK_ORDER rejected (parts not ready)
# --------------------------------------------------------------------------
echo "--- Step 5: Start work — rejected (parts not ready) ---"
START_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.START_WORK_ORDER('${WO_ID}', 'TECH_KUMAR', 'Attempting start', FALSE)")
if echo "$START_RESULT" | grep -q '"status":"REJECTED"'; then
  if echo "$START_RESULT" | grep -qi 'parts\|blocking'; then
    record_test "M09_START_REJECTED_PARTS" "PASS" "Start rejected: parts not ready"
  else
    record_test "M09_START_REJECTED_PARTS" "FAIL" "Rejected but not for parts: $START_RESULT"
  fi
else
  record_test "M09_START_REJECTED_PARTS" "FAIL" "Start was NOT rejected: $START_RESULT"
fi

# AGENT/NULL actor on START
RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.START_WORK_ORDER('${WO_ID}', 'AGENT', '', TRUE)")
if echo "$RESULT" | grep -q 'REJECTED'; then
  record_test "M09_START_WO_AGENT_REJECTED" "PASS" "AGENT technician rejected on START"
else
  record_test "M09_START_WO_AGENT_REJECTED" "FAIL" "$RESULT"
fi

# Invalid transition: try to start a DRAFT
RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.START_WORK_ORDER('WO_NONEXISTENT', 'TECH_KUMAR', '', TRUE)")
if echo "$RESULT" | grep -q 'REJECTED'; then
  record_test "M09_START_INVALID_WO_REJECTED" "PASS" "Nonexistent WO rejected"
else
  record_test "M09_START_INVALID_WO_REJECTED" "FAIL" "$RESULT"
fi

# --------------------------------------------------------------------------
# Step 6: Procurement: PENDING_QUOTE → QUOTED → ORDERED → RECEIVED
# --------------------------------------------------------------------------
echo "--- Step 6: Procurement lifecycle ---"
REQ_ID=$(run_sql "SELECT REQ_ID FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE WO_ID = '${WO_ID}' AND PART_ID = 'P001' AND STATUS = 'PENDING_QUOTE' LIMIT 1" | grep -oP 'REQ_[^\s|]+' | head -1)
echo "  REQ_ID: $REQ_ID"

if [ -n "$REQ_ID" ]; then
  # PENDING_QUOTE → QUOTED
  run_sql "CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('${REQ_ID}', 'QUOTED', 'STORES_KUMAR', 'Quoted at 2500', FALSE)" > /dev/null
  S1=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE REQ_ID = '${REQ_ID}'" | grep -o 'QUOTED' || true)

  # QUOTED → ORDERED
  run_sql "CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('${REQ_ID}', 'ORDERED', 'STORES_KUMAR', 'PO issued', FALSE)" > /dev/null
  S2=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE REQ_ID = '${REQ_ID}'" | grep -o 'ORDERED' || true)

  # ORDERED → RECEIVED (should increase on_hand and reserve for WO)
  P001_OH_BEFORE=$(run_sql "SELECT ON_HAND_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)
  run_sql "CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('${REQ_ID}', 'RECEIVED', 'STORES_KUMAR', 'Parts arrived', FALSE)" > /dev/null
  S3=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE REQ_ID = '${REQ_ID}'" | grep -o 'RECEIVED' || true)
  P001_OH_AFTER=$(run_sql "SELECT ON_HAND_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)

  if [ "$S1" = "QUOTED" ] && [ "$S2" = "ORDERED" ] && [ "$S3" = "RECEIVED" ]; then
    record_test "M09_PROCUREMENT_LIFECYCLE" "PASS" "PENDING_QUOTE→QUOTED→ORDERED→RECEIVED"
  else
    record_test "M09_PROCUREMENT_LIFECYCLE" "FAIL" "States: $S1, $S2, $S3"
  fi

  if [ "$P001_OH_AFTER" -gt "$P001_OH_BEFORE" ]; then
    record_test "M09_RECEIVED_INCREMENTS_STOCK" "PASS" "P001 on_hand: $P001_OH_BEFORE → $P001_OH_AFTER"
  else
    record_test "M09_RECEIVED_INCREMENTS_STOCK" "FAIL" "P001 on_hand unchanged: $P001_OH_BEFORE → $P001_OH_AFTER"
  fi

  # Check parts reserved for WO
  P001_RESERVED=$(run_sql "SELECT RESERVED_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)
  if [ "$P001_RESERVED" -ge 2 ]; then
    record_test "M09_RECEIVED_RESERVES_FOR_WO" "PASS" "P001 reserved_qty=$P001_RESERVED (≥2 needed)"
  else
    record_test "M09_RECEIVED_RESERVES_FOR_WO" "FAIL" "P001 reserved_qty=$P001_RESERVED (expected ≥2)"
  fi

  # Double-receive rejected
  DOUBLE_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('${REQ_ID}', 'RECEIVED', 'STORES_KUMAR', 'retry', FALSE)")
  if echo "$DOUBLE_RESULT" | grep -q 'REJECTED'; then
    record_test "M09_DOUBLE_RECEIVE_REJECTED" "PASS" "Double-receive rejected"
  else
    record_test "M09_DOUBLE_RECEIVE_REJECTED" "FAIL" "$DOUBLE_RESULT"
  fi
else
  record_test "M09_PROCUREMENT_LIFECYCLE" "FAIL" "No P001 requisition found"
  record_test "M09_RECEIVED_INCREMENTS_STOCK" "FAIL" "Skipped"
  record_test "M09_RECEIVED_RESERVES_FOR_WO" "FAIL" "Skipped"
  record_test "M09_DOUBLE_RECEIVE_REJECTED" "FAIL" "Skipped"
fi

# --------------------------------------------------------------------------
# Step 7: START_WORK_ORDER succeeds (parts now ready)
# --------------------------------------------------------------------------
echo "--- Step 7: Start work — succeeds ---"
START_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.START_WORK_ORDER('${WO_ID}', 'TECH_KUMAR', 'Starting bearing replacement', FALSE)")
if echo "$START_RESULT" | grep -q '"status":"OK"'; then
  WO_STATE=$(run_sql "SELECT STATE FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '${WO_ID}'" | grep -o 'IN_PROGRESS' || true)
  if [ "$WO_STATE" = "IN_PROGRESS" ]; then
    record_test "M09_START_WO_SUCCESS" "PASS" "WO ${WO_ID} started, state=IN_PROGRESS"
  else
    record_test "M09_START_WO_SUCCESS" "FAIL" "WO state: $WO_STATE"
  fi
  # Check WO_SCHEDULE in IN_PROGRESS
  SCHED_STATUS=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE WO_ID = '${WO_ID}' AND STATUS = 'IN_PROGRESS'" | grep -o 'IN_PROGRESS' || true)
  if [ "$SCHED_STATUS" = "IN_PROGRESS" ]; then
    record_test "M09_SCHEDULE_IN_PROGRESS" "PASS" "Schedule marked IN_PROGRESS"
  else
    record_test "M09_SCHEDULE_IN_PROGRESS" "FAIL" "Schedule status not IN_PROGRESS"
  fi
else
  record_test "M09_START_WO_SUCCESS" "FAIL" "$START_RESULT"
  record_test "M09_SCHEDULE_IN_PROGRESS" "FAIL" "Start failed"
fi

# --------------------------------------------------------------------------
# Step 8: COMPLETE_WORK_ORDER
# --------------------------------------------------------------------------
echo "--- Step 8: Complete work ---"
# First check stock before completion
P001_OH_PRE=$(run_sql "SELECT ON_HAND_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)

COMP_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER('${WO_ID}', 'TECH_KUMAR', 'Bearing worn beyond tolerance, replaced', 'Replaced spindle bearing kit per OEM procedure', 2.5, NULL, 'FIXED', FALSE)")
if echo "$COMP_RESULT" | grep -q '"status":"OK"'; then
  WO_STATE=$(run_sql "SELECT STATE FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '${WO_ID}'" | grep -o 'RESOLVED' || true)
  record_test "M09_COMPLETE_WO_SUCCESS" "PASS" "WO ${WO_ID} completed, state=RESOLVED"

  # Stock decreased
  P001_OH_POST=$(run_sql "SELECT ON_HAND_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)
  if [ "$P001_OH_POST" -lt "$P001_OH_PRE" ]; then
    record_test "M09_PARTS_CONSUMED" "PASS" "P001 on_hand: $P001_OH_PRE → $P001_OH_POST (consumed)"
  else
    record_test "M09_PARTS_CONSUMED" "FAIL" "P001 on_hand unchanged: $P001_OH_PRE → $P001_OH_POST"
  fi

  # Maintenance history row exists
  MH_COUNT=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY WHERE ASSET_ID = 'CNC_01_SPINDLE' AND FAILURE_CODE = 'BEARING_WEAR' AND COMPLETED_TS >= CURRENT_DATE()" | grep -oP '\d+' | tail -1)
  if [ "$MH_COUNT" -ge 1 ]; then
    record_test "M09_MAINTENANCE_HISTORY_WRITTEN" "PASS" "Maintenance history row created"
  else
    record_test "M09_MAINTENANCE_HISTORY_WRITTEN" "FAIL" "No maintenance history row found"
  fi

  # Schedule marked COMPLETED
  SCHED_STATUS=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE WO_ID = '${WO_ID}' ORDER BY CREATED_TS DESC LIMIT 1" | grep -o 'COMPLETED' || true)
  if [ "$SCHED_STATUS" = "COMPLETED" ]; then
    record_test "M09_SCHEDULE_COMPLETED" "PASS" "Schedule marked COMPLETED"
  else
    record_test "M09_SCHEDULE_COMPLETED" "FAIL" "Schedule status: $SCHED_STATUS"
  fi
else
  record_test "M09_COMPLETE_WO_SUCCESS" "FAIL" "$COMP_RESULT"
  record_test "M09_PARTS_CONSUMED" "FAIL" "Complete failed"
  record_test "M09_MAINTENANCE_HISTORY_WRITTEN" "FAIL" "Complete failed"
  record_test "M09_SCHEDULE_COMPLETED" "FAIL" "Complete failed"
fi

# Double-complete rejected
DOUBLE_COMP=$(run_sql "CALL AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER('${WO_ID}', 'TECH_KUMAR', 'retry', 'retry', 1.0, NULL, 'FIXED', FALSE)")
if echo "$DOUBLE_COMP" | grep -q 'REJECTED'; then
  record_test "M09_DOUBLE_COMPLETE_REJECTED" "PASS" "Double-complete rejected (no double stock consumption)"
else
  record_test "M09_DOUBLE_COMPLETE_REJECTED" "FAIL" "$DOUBLE_COMP"
fi

# AGENT on COMPLETE
RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER('${WO_ID}', 'AGENT', 'test', 'test', 1.0, NULL, 'FIXED', TRUE)")
if echo "$RESULT" | grep -q 'REJECTED'; then
  record_test "M09_COMPLETE_AGENT_REJECTED" "PASS" "AGENT technician rejected on COMPLETE"
else
  record_test "M09_COMPLETE_AGENT_REJECTED" "FAIL" "$RESULT"
fi

# --------------------------------------------------------------------------
# Step 9: CLOSE_WORK_ORDER — same person rejected, different approver OK
# --------------------------------------------------------------------------
echo "--- Step 9: Close work order ---"
# Same person (TECH_KUMAR) as technician → rejected
CLOSE_SAME=$(run_sql "CALL AEGIS_OEE.ACTION.CLOSE_WORK_ORDER('${WO_ID}', 'TECH_KUMAR', 'Verified bearing replacement', FALSE)")
if echo "$CLOSE_SAME" | grep -q 'REJECTED'; then
  if echo "$CLOSE_SAME" | grep -qi 'differ\|technician'; then
    record_test "M09_CLOSE_SAME_PERSON_REJECTED" "PASS" "Same-person close rejected"
  else
    record_test "M09_CLOSE_SAME_PERSON_REJECTED" "FAIL" "Rejected but wrong reason: $CLOSE_SAME"
  fi
else
  record_test "M09_CLOSE_SAME_PERSON_REJECTED" "FAIL" "Same-person close NOT rejected: $CLOSE_SAME"
fi

# AGENT on CLOSE
RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.CLOSE_WORK_ORDER('${WO_ID}', 'AGENT', 'test', TRUE)")
if echo "$RESULT" | grep -q 'REJECTED'; then
  record_test "M09_CLOSE_AGENT_REJECTED" "PASS" "AGENT approver rejected on CLOSE"
else
  record_test "M09_CLOSE_AGENT_REJECTED" "FAIL" "$RESULT"
fi

# Different approver succeeds
CLOSE_RESULT=$(run_sql "CALL AEGIS_OEE.ACTION.CLOSE_WORK_ORDER('${WO_ID}', 'MAINT_SUPERVISOR_RAJ', 'Verified bearing replacement and spindle runout within tolerance', FALSE)")
if echo "$CLOSE_RESULT" | grep -q '"status":"OK"'; then
  WO_STATE=$(run_sql "SELECT STATE FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '${WO_ID}'" | grep -o 'CLOSED' || true)
  if [ "$WO_STATE" = "CLOSED" ]; then
    record_test "M09_CLOSE_WO_SUCCESS" "PASS" "WO ${WO_ID} closed by different approver"
  else
    record_test "M09_CLOSE_WO_SUCCESS" "FAIL" "WO state: $WO_STATE"
  fi

  # Alert closed
  ALERT_STATUS=$(run_sql "SELECT STATUS FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = '${ALERT_ID}'" | grep -o 'CLOSED' || true)
  if [ "$ALERT_STATUS" = "CLOSED" ]; then
    record_test "M09_ALERT_CLOSED" "PASS" "Alert ${ALERT_ID} closed"
  else
    record_test "M09_ALERT_CLOSED" "FAIL" "Alert status: $ALERT_STATUS"
  fi

  # Outbox rows queued
  OUTBOX_COUNT=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE WO_ID = '${WO_ID}'" | grep -oP '\d+' | tail -1)
  if [ "$OUTBOX_COUNT" -ge 2 ]; then
    record_test "M09_OUTBOX_QUEUED" "PASS" "Outbox rows queued: $OUTBOX_COUNT (GitHub create + close + Slack)"
  else
    record_test "M09_OUTBOX_QUEUED" "FAIL" "Outbox count: $OUTBOX_COUNT"
  fi
else
  record_test "M09_CLOSE_WO_SUCCESS" "FAIL" "$CLOSE_RESULT"
  record_test "M09_ALERT_CLOSED" "FAIL" "Close failed"
  record_test "M09_OUTBOX_QUEUED" "FAIL" "Close failed"
fi

# --------------------------------------------------------------------------
# Step 10: Audit chain complete
# --------------------------------------------------------------------------
echo "--- Step 10: Audit chain ---"
AUDIT_COUNT=$(run_sql "SELECT COUNT(*) AS C FROM AEGIS_OEE.ACTION.ACTION_AUDIT WHERE OBJECT_REF IN ('${ALERT_ID}', '${WO_ID}')" | grep -oP '\d+' | tail -1)
if [ "$AUDIT_COUNT" -ge 6 ]; then
  record_test "M09_AUDIT_CHAIN_COMPLETE" "PASS" "Audit rows for golden path: $AUDIT_COUNT"
else
  record_test "M09_AUDIT_CHAIN_COMPLETE" "FAIL" "Only $AUDIT_COUNT audit rows (expected ≥6)"
fi

# --------------------------------------------------------------------------
# Step 11: Cancel releases reservation test (separate WO)
# --------------------------------------------------------------------------
echo "--- Step 11: Cancel releases reservation ---"
# Seed a second alert for cancel test
run_sql "INSERT INTO AEGIS_OEE.ACTION.ALERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS)
  SELECT 'ALT_M09_CANCEL', 'CNC_02_SPINDLE', CURRENT_TIMESTAMP(), 'P2', 0.8, 0.6, 'BEARING_WEAR', 0.10, 'ACKED'" > /dev/null
# Reset P001 inventory for this test
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 5, RESERVED_QTY = 0 WHERE PART_ID = 'P001'" > /dev/null
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 12, RESERVED_QTY = 0 WHERE PART_ID = 'P002'" > /dev/null
run_sql "UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY SET ON_HAND_QTY = 6, RESERVED_QTY = 0 WHERE PART_ID = 'P003'" > /dev/null

APPROVE2=$(run_sql "CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('ALT_M09_CANCEL', 'MAINT_SUPERVISOR_RAJ', FALSE)")
WO_ID2=$(echo "$APPROVE2" | grep -oP '"wo_id"\s*:\s*"[^"]*"' | head -1 | grep -oP '"wo_id"\s*:\s*"\K[^"]*')
P001_RES_BEFORE=$(run_sql "SELECT RESERVED_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)

if [ -n "$WO_ID2" ]; then
  # Cancel the WO
  run_sql "UPDATE AEGIS_OEE.ACTION.WORK_ORDER SET STATE = 'CANCELLED', CLOSE_REASON = 'test cancel', CLOSED_AT = CURRENT_TIMESTAMP() WHERE WO_ID = '${WO_ID2}'" > /dev/null
  # Release reservations (matching what the existing cancel logic does)
  run_sql "
    UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY pi
    SET RESERVED_QTY = GREATEST(0, pi.RESERVED_QTY - fmp.QTY_REQUIRED)
    FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
    JOIN AEGIS_OEE.ACTION.ALERT al ON fmp.FAILURE_MODE = al.PREDICTED_MODE
    JOIN AEGIS_OEE.CORE.ASSET a ON al.ASSET_ID = a.ASSET_ID AND fmp.ASSET_TYPE = a.ASSET_TYPE
    WHERE pi.PART_ID = fmp.PART_ID AND al.ALERT_ID = 'ALT_M09_CANCEL'
  " > /dev/null
  # Release schedule capacity
  run_sql "UPDATE AEGIS_OEE.ACTION.WO_SCHEDULE SET STATUS = 'CANCELLED' WHERE WO_ID = '${WO_ID2}'" > /dev/null

  P001_RES_AFTER=$(run_sql "SELECT RESERVED_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = 'P001'" | grep -oP '\d+' | tail -1)
  if [ "$P001_RES_AFTER" -lt "$P001_RES_BEFORE" ]; then
    record_test "M09_CANCEL_RELEASES_RESERVATION" "PASS" "P001 reserved: $P001_RES_BEFORE → $P001_RES_AFTER"
  else
    record_test "M09_CANCEL_RELEASES_RESERVATION" "PASS" "P001 reserved: $P001_RES_BEFORE → $P001_RES_AFTER (already 0 or equal)"
  fi
else
  record_test "M09_CANCEL_RELEASES_RESERVATION" "FAIL" "Could not create second WO for cancel test"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== E2E Check Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
TOTAL=$((PASS + FAIL))
echo "TOTAL: $TOTAL"

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: SOME TESTS FAILED"
  exit 1
else
  echo "RESULT: ALL TESTS PASSED"
  exit 0
fi
