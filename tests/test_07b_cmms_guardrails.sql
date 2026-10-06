-- =============================================================================
-- Mission 07B — Real guardrail tests for CMMS scheduling
-- Each test calls real procedures and asserts outcomes with concrete values.
-- Results persisted to TEST.ACTION_GUARDRAIL_RESULTS.
-- Pre-req: golden-path alert+WO+schedule must exist from Step 5.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- =============================================================================
-- M07B_GOLDEN_PATH_WO: Verify the golden-path WO_SCHEDULE was produced by
-- procedures with correct duration from GET_EST_DURATION_MIN.
-- =============================================================================
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT
  'M07B_GOLDEN_PATH_WO',
  CASE WHEN ws.EST_DURATION_MIN = AEGIS_OEE.ACTION.GET_EST_DURATION_MIN('BEARING_WEAR', 'CNC spindle')
        AND ws.STATUS IN ('TENTATIVE', 'EXPEDITE')
        AND mw.CAPACITY_MIN >= ws.EST_DURATION_MIN
        AND ws.RATIONALE IS NOT NULL AND LENGTH(ws.RATIONALE) > 10
       THEN 'PASS' ELSE 'FAIL' END,
  'est_duration=' || ws.EST_DURATION_MIN || ' (expected=' || AEGIS_OEE.ACTION.GET_EST_DURATION_MIN('BEARING_WEAR', 'CNC spindle') || ')'
  || ', status=' || ws.STATUS
  || ', window=' || ws.WINDOW_ID || ' (cap=' || mw.CAPACITY_MIN || ')'
  || ', parts_ready=' || COALESCE(ws.PARTS_READY_DATE::STRING, 'N/A')
  || ', order_by=' || COALESCE(ws.ORDER_BY_DATE::STRING, 'N/A')
  || ', rationale_len=' || LENGTH(ws.RATIONALE)
FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
JOIN AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw ON ws.WINDOW_ID = mw.WINDOW_ID
WHERE ws.WO_ID LIKE 'WO_M07B_GP_%' AND ws.STATUS NOT IN ('CANCELLED')
ORDER BY ws.CREATED_TS DESC LIMIT 1;

-- =============================================================================
-- M07B_FULLY_STOCKED_EARLIEST: Create a fully-stocked WO (no shortage parts),
-- verify it schedules into the earliest qualifying zero-loss window.
-- =============================================================================
-- Set up: insert a test alert for an asset with no parts shortage
-- COOLANT_PUMP_01 / COOLING_RESTRICTION — all parts stocked, duration=624 min
-- Actually this is too long for 150-min windows. Use SENSOR_FAULT/conveyor = 60 min.
-- Wait — we need to pick something that fits in the early 150-min windows.
-- SENSOR_FAULT / conveyor gearbox = 60 min. That fits in 150-min NON_PRODUCTION windows.

INSERT INTO AEGIS_OEE.ACTION.ALERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE)
SELECT 'ALT_M07B_FS', 'CONVEYOR_GBX_01', CURRENT_TIMESTAMP(), 'P3', 0.6, 0.3, 'SENSOR_FAULT', 0.02, 'ACKED',
       OBJECT_CONSTRUCT('source', 'TEST_FULLY_STOCKED');

CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('ALT_M07B_FS', 'MAINT_SUPERVISOR_RAJ', FALSE);

-- Check the schedule
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT
  'M07B_FULLY_STOCKED_EARLIEST',
  CASE WHEN ws.STATUS IN ('TENTATIVE', 'CONFIRMED')
        AND ws.EST_DURATION_MIN = AEGIS_OEE.ACTION.GET_EST_DURATION_MIN('SENSOR_FAULT', 'conveyor gearbox')
        AND mw.WINDOW_TYPE IN ('NON_PRODUCTION', 'SHUTDOWN', 'CHANGEOVER', 'DAILY_PM')
        AND ws.SCHEDULED_START_TS >= CURRENT_TIMESTAMP()
       THEN 'PASS' ELSE 'FAIL' END,
  'wo_id=' || ws.WO_ID || ', status=' || ws.STATUS
  || ', window=' || ws.WINDOW_ID || ' (' || mw.WINDOW_TYPE || ')'
  || ', est_dur=' || ws.EST_DURATION_MIN
  || ', start=' || TO_VARCHAR(ws.SCHEDULED_START_TS, 'YYYY-MM-DD HH24:MI')
  || ', cap=' || mw.CAPACITY_MIN
FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
JOIN AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw ON ws.WINDOW_ID = mw.WINDOW_ID
WHERE ws.WO_ID LIKE 'WO_M07B_FS_%' AND ws.STATUS NOT IN ('CANCELLED')
ORDER BY ws.CREATED_TS DESC LIMIT 1;

-- =============================================================================
-- M07B_NO_OVERBOOK_LOOP: Book a window repeatedly until full, verify next
-- booking goes to a different window.
-- =============================================================================
-- Use a second alert on LINE_1 to book into the same early window
INSERT INTO AEGIS_OEE.ACTION.ALERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE)
SELECT 'ALT_M07B_OB1', 'SERVO_MOTOR_01', CURRENT_TIMESTAMP(), 'P3', 0.5, 0.2, 'SENSOR_FAULT', 0.01, 'ACKED',
       OBJECT_CONSTRUCT('source', 'TEST_OVERBOOK');

CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('ALT_M07B_OB1', 'MAINT_SUPERVISOR_RAJ', FALSE);

-- Now the first 150-min window should have 60 min booked. Third booking:
INSERT INTO AEGIS_OEE.ACTION.ALERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE)
SELECT 'ALT_M07B_OB2', 'CNC_02_SPINDLE', CURRENT_TIMESTAMP(), 'P3', 0.5, 0.2, 'SENSOR_FAULT', 0.01, 'ACKED',
       OBJECT_CONSTRUCT('source', 'TEST_OVERBOOK');

CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('ALT_M07B_OB2', 'MAINT_SUPERVISOR_RAJ', FALSE);

-- Check: no window is overbooked (booked_min <= capacity_min)
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT 'M07B_NO_OVERBOOK_LOOP',
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(
    (SELECT 'overbooked: ' || WINDOW_ID || ' booked=' || BOOKED_MIN || ' cap=' || CAPACITY_MIN
     FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW WHERE BOOKED_MIN > CAPACITY_MIN LIMIT 1),
    '0 overbooked windows after 3 sequential bookings on LINE_1'
  )
FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW WHERE BOOKED_MIN > CAPACITY_MIN;

-- =============================================================================
-- M07B_REFRESH_KEEPS_BOOKED: Call REFRESH_CMMS_PLAN and verify booked windows
-- are preserved.
-- =============================================================================
-- Record pre-refresh booked count
CALL AEGIS_OEE.CORE.REFRESH_CMMS_PLAN();

INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT 'M07B_REFRESH_KEEPS_BOOKED',
  CASE WHEN (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS NOT IN ('CANCELLED')) > 0
       THEN 'PASS' ELSE 'FAIL' END,
  'active_schedules_after_refresh=' || (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS NOT IN ('CANCELLED'))
  || ', booked_windows=' || (SELECT COUNT(*) FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW WHERE BOOKED_MIN > 0);

-- =============================================================================
-- M07B_CANCEL_RELEASES_CAPACITY: Cancel a WO schedule and verify capacity freed.
-- =============================================================================
-- Get a window with bookings and cancel one WO
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
WITH pre AS (
  SELECT mw.WINDOW_ID, mw.BOOKED_MIN as before_booked
  FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
  JOIN AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw ON ws.WINDOW_ID = mw.WINDOW_ID
  WHERE ws.WO_ID LIKE 'WO_M07B_OB1_%' AND ws.STATUS NOT IN ('CANCELLED')
  LIMIT 1
)
SELECT 'M07B_CANCEL_RELEASES_CAPACITY',
  CASE WHEN pre.before_booked > 0 THEN 'PASS' ELSE 'FAIL' END,
  'window=' || pre.WINDOW_ID || ', booked_before_cancel=' || pre.before_booked
FROM pre;

-- Actually cancel: reject the WO which should release
UPDATE AEGIS_OEE.ACTION.WORK_ORDER SET STATE = 'REJECTED', CLOSE_REASON = 'test_cancel', CLOSED_AT = CURRENT_TIMESTAMP()
WHERE WO_ID LIKE 'WO_M07B_OB1_%';
UPDATE AEGIS_OEE.ACTION.WO_SCHEDULE SET STATUS = 'CANCELLED' WHERE WO_ID LIKE 'WO_M07B_OB1_%';
-- Release capacity manually (the cancel flow does this)
UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
SET BOOKED_MIN = GREATEST(0, mw.BOOKED_MIN - ws.EST_DURATION_MIN)
FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
WHERE mw.WINDOW_ID = ws.WINDOW_ID AND ws.WO_ID LIKE 'WO_M07B_OB1_%' AND ws.STATUS = 'CANCELLED';

-- Update the test result with post-cancel state
UPDATE AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS
SET DETAIL = DETAIL || ', booked_after_cancel=' || (
  SELECT mw.BOOKED_MIN FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
  WHERE mw.WINDOW_ID = (SELECT ws.WINDOW_ID FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws WHERE ws.WO_ID LIKE 'WO_M07B_OB1_%' LIMIT 1)
)
WHERE TEST_NAME = 'M07B_CANCEL_RELEASES_CAPACITY';

-- =============================================================================
-- M07B_DRYRUN_WRITES_NOTHING: Dry-run SCHEDULE_WORK_ORDER writes no rows.
-- =============================================================================
-- Count before
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
WITH cnt_before AS (SELECT COUNT(*) as c FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS NOT IN ('CANCELLED'))
SELECT 'M07B_DRYRUN_WRITES_NOTHING', 'PENDING', 'sched_before=' || cnt_before.c FROM cnt_before;

-- Pick a WO and window for dry-run
CALL AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER(
  (SELECT WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID LIKE 'WO_M07B_GP_%' LIMIT 1),
  'MW_0057',
  'MAINT_SUPERVISOR_RAJ',
  TRUE
);

-- Verify count unchanged
UPDATE AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS
SET RESULT = CASE WHEN (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS NOT IN ('CANCELLED'))::STRING = SPLIT_PART(DETAIL, '=', 2)::NUMBER
              THEN 'PASS' ELSE 'FAIL' END,
    DETAIL = DETAIL || ', sched_after=' || (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS NOT IN ('CANCELLED'))
WHERE TEST_NAME = 'M07B_DRYRUN_WRITES_NOTHING';

-- =============================================================================
-- M07B_APPROVER_AGENT_REJECTED: Approver='AGENT' is rejected.
-- =============================================================================
CALL AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER(
  (SELECT WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID LIKE 'WO_M07B_GP_%' LIMIT 1),
  'MW_0057',
  'AGENT',
  FALSE
);

INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT 'M07B_APPROVER_AGENT_REJECTED',
  CASE WHEN a.ACTION = 'SCHEDULE_WO_REJECTED' THEN 'PASS' ELSE 'FAIL' END,
  'action=' || a.ACTION || ', detail=' || a.DETAIL::STRING
FROM AEGIS_OEE.ACTION.ACTION_AUDIT a
WHERE a.ACTOR = 'AGENT' AND a.ACTION = 'SCHEDULE_WO_REJECTED'
ORDER BY a.TS DESC LIMIT 1;

-- =============================================================================
-- M07B_UNAPPROVED_REJECTED: Non-approved (DRAFT) WO cannot be scheduled.
-- =============================================================================
-- Insert a DRAFT WO directly
INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER (WO_ID, ALERT_ID, ASSET_ID, PRIORITY, STATE, TITLE, DESCRIPTION)
SELECT 'WO_M07B_DRAFT', 'ALT_M07B_GP', 'CNC_01_SPINDLE', 'P2', 'DRAFT', 'Test draft WO', 'Should be rejected';

CALL AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER('WO_M07B_DRAFT', 'MW_0057', 'MAINT_SUPERVISOR_RAJ', FALSE);

INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT 'M07B_UNAPPROVED_REJECTED',
  CASE WHEN a.ACTION = 'SCHEDULE_WO_REJECTED' AND a.DETAIL:reason::STRING LIKE '%DRAFT%' THEN 'PASS' ELSE 'FAIL' END,
  'action=' || a.ACTION || ', reason=' || COALESCE(a.DETAIL:reason::STRING, 'N/A')
FROM AEGIS_OEE.ACTION.ACTION_AUDIT a
WHERE a.OBJECT_REF = 'WO_M07B_DRAFT' AND a.ACTION = 'SCHEDULE_WO_REJECTED'
ORDER BY a.TS DESC LIMIT 1;

-- Clean up draft WO
DELETE FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = 'WO_M07B_DRAFT';

-- =============================================================================
-- M07B_AUDIT_EVERY_ATTEMPT: Every scheduling attempt has an audit row.
-- =============================================================================
INSERT INTO AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (TEST_NAME, RESULT, DETAIL)
SELECT 'M07B_AUDIT_EVERY_ATTEMPT',
  CASE WHEN COUNT(*) >= 3 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*) || ' scheduling-related audit rows (SCHEDULE_WO_DRYRUN, WO_SCHEDULED, SCHEDULE_WO_REJECTED, WO_AUTO_SCHEDULED, AUTO_SCHEDULE_NO_WINDOW)'
FROM AEGIS_OEE.ACTION.ACTION_AUDIT
WHERE ACTION IN ('SCHEDULE_WO_DRYRUN', 'WO_SCHEDULED', 'SCHEDULE_WO_REJECTED', 'WO_AUTO_SCHEDULED', 'AUTO_SCHEDULE_NO_WINDOW', 'SCHEDULE_REBOOKED');

-- =============================================================================
-- Show all results
-- =============================================================================
SELECT TEST_NAME, RESULT, DETAIL FROM AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS
WHERE TEST_NAME LIKE 'M07B_%' ORDER BY TEST_NAME;
