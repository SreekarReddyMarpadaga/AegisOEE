-- =============================================================================
-- Mission 07B — CMMS Shift Planning & Maintenance Windows (hardened)
-- Tables: CORE.SHIFT_PLAN, CORE.MAINTENANCE_WINDOW, ACTION.WO_SCHEDULE
-- UDF:  ACTION.GET_EST_DURATION_MIN (single source of truth)
-- Procs: CORE.REFRESH_CMMS_PLAN, ACTION.PROPOSE_SCHEDULE,
--        ACTION.SCHEDULE_WORK_ORDER, ACTION.AUTO_SCHEDULE_WO,
--        ACTION.ENRICH_OUTBOX_WITH_SCHEDULE
-- Task: CORE.TASK_REFRESH_CMMS_PLAN (daily, SUSPENDED)
-- Idempotent: safe to re-run.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- =============================================================================
-- 1. Table DDL
-- =============================================================================

CREATE TABLE IF NOT EXISTS AEGIS_OEE.CORE.SHIFT_PLAN (
    PLAN_ID        STRING    NOT NULL,
    PLAN_DATE      DATE      NOT NULL,
    SHIFT_CODE     STRING    NOT NULL,
    LINE_ID        STRING    NOT NULL,
    ORDER_ID       STRING,
    PLANNED_QTY    NUMBER,
    PLANNED_START_TS TIMESTAMP_TZ NOT NULL,
    PLANNED_END_TS   TIMESTAMP_TZ NOT NULL,
    PLANNED_RUN_MIN  NUMBER    NOT NULL,
    STATUS         STRING    NOT NULL DEFAULT 'PLANNED'
);

CREATE TABLE IF NOT EXISTS AEGIS_OEE.CORE.MAINTENANCE_WINDOW (
    WINDOW_ID      STRING    NOT NULL,
    LINE_ID        STRING    NOT NULL,
    ASSET_ID       STRING,
    WINDOW_START_TS TIMESTAMP_TZ NOT NULL,
    WINDOW_END_TS   TIMESTAMP_TZ NOT NULL,
    WINDOW_TYPE    STRING    NOT NULL,
    CAPACITY_MIN   NUMBER    NOT NULL,
    BOOKED_MIN     NUMBER    NOT NULL DEFAULT 0,
    STATUS         STRING    NOT NULL DEFAULT 'OPEN'
);

CREATE TABLE IF NOT EXISTS AEGIS_OEE.ACTION.WO_SCHEDULE (
    SCHEDULE_ID       STRING    NOT NULL,
    WO_ID             STRING    NOT NULL,
    WINDOW_ID         STRING    NOT NULL,
    SCHEDULED_START_TS TIMESTAMP_TZ,
    SCHEDULED_END_TS   TIMESTAMP_TZ,
    EST_DURATION_MIN   NUMBER    NOT NULL,
    PARTS_READY_DATE   DATE,
    ORDER_BY_DATE      DATE,
    STATUS             STRING    NOT NULL DEFAULT 'TENTATIVE',
    RATIONALE          STRING,
    CREATED_TS         TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- Stage for CSV loading
CREATE STAGE IF NOT EXISTS AEGIS_OEE.CORE.CMMS_STAGE
    FILE_FORMAT = (TYPE=CSV SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=(''));

-- =============================================================================
-- 1b. GET_EST_DURATION_MIN — single source of truth for estimated repair duration
-- Returns CEIL(AVG(labor_hours) * 60) for (failure_mode, asset_type) from
-- CORE.MAINTENANCE_HISTORY. Falls back to 120 min if no history exists.
-- =============================================================================

CREATE OR REPLACE FUNCTION AEGIS_OEE.ACTION.GET_EST_DURATION_MIN(
    P_FAILURE_MODE VARCHAR,
    P_ASSET_TYPE VARCHAR
)
RETURNS NUMBER
AS
$$
    SELECT COALESCE(
        NULLIF(CEIL(AVG(mh.LABOR_HOURS) * 60), 0),
        120
    )::NUMBER
    FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY mh
    JOIN AEGIS_OEE.CORE.ASSET a ON mh.ASSET_ID = a.ASSET_ID
    WHERE mh.FAILURE_CODE = P_FAILURE_MODE AND a.ASSET_TYPE = P_ASSET_TYPE
$$;

-- =============================================================================
-- 2. REFRESH_CMMS_PLAN() — idempotent rolling-horizon refresh
-- Never moves or deletes a BOOKED window.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.CORE.REFRESH_CMMS_PLAN()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  -- Remove past plan entries (keep today+)
  DELETE FROM AEGIS_OEE.CORE.SHIFT_PLAN WHERE PLAN_DATE < CURRENT_DATE();

  -- Remove past maintenance windows ONLY if they are not booked
  DELETE FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW
  WHERE WINDOW_END_TS < CURRENT_TIMESTAMP() AND STATUS = 'OPEN' AND BOOKED_MIN = 0;

  -- Remove WO_SCHEDULE for cancelled/closed WOs
  DELETE FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
  WHERE ws.WO_ID IN (
    SELECT wo.WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER wo
    WHERE wo.STATE IN ('CANCELLED', 'CLOSED', 'REJECTED', 'RESOLVED')
  );

  -- Release booked capacity for removed schedules
  UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
  SET BOOKED_MIN = GREATEST(0, mw.BOOKED_MIN - COALESCE(
    (SELECT SUM(ws.EST_DURATION_MIN) FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
     WHERE ws.WINDOW_ID = mw.WINDOW_ID AND ws.STATUS = 'CANCELLED'), 0))
  WHERE mw.WINDOW_ID IN (
    SELECT ws.WINDOW_ID FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws WHERE ws.STATUS = 'CANCELLED'
  );

  DELETE FROM AEGIS_OEE.ACTION.WO_SCHEDULE WHERE STATUS = 'CANCELLED';

  RETURN 'CMMS plan refreshed at ' || CURRENT_TIMESTAMP()::STRING;
END;
$$;

-- =============================================================================
-- 3. PROPOSE_SCHEDULE(wo_id) — zero side effects, returns ranked window options
-- Uses GET_EST_DURATION_MIN for duration.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.PROPOSE_SCHEDULE(P_WO_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_asset_id VARCHAR;
  v_line_id VARCHAR;
  v_failure_mode VARCHAR;
  v_asset_type VARCHAR;
  v_wo_state VARCHAR;
  v_alert_id VARCHAR;
  v_est_duration_min NUMBER DEFAULT 120;
  v_parts_ready_date DATE;
  v_max_lead_days NUMBER DEFAULT 0;
  v_predicted_failure_ts TIMESTAMP_TZ;
  v_options VARIANT;
  v_status VARCHAR DEFAULT 'TENTATIVE';
  v_expedited_lead NUMBER DEFAULT 0;
  v_expedited_ready_date DATE;
  v_expedited_window VARIANT;
BEGIN
  -- 1. Fetch WO details
  SELECT wo.ASSET_ID, wo.STATE, wo.ALERT_ID
  INTO :v_asset_id, :v_wo_state, :v_alert_id
  FROM AEGIS_OEE.ACTION.WORK_ORDER wo WHERE wo.WO_ID = :P_WO_ID;

  IF (:v_asset_id IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Work order not found: ' || :P_WO_ID);
  END IF;

  -- 2. Get asset info
  SELECT a.LINE_ID, a.ASSET_TYPE
  INTO :v_line_id, :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET a WHERE a.ASSET_ID = :v_asset_id;

  -- 3. Get failure mode from alert
  SELECT al.PREDICTED_MODE INTO :v_failure_mode
  FROM AEGIS_OEE.ACTION.ALERT al WHERE al.ALERT_ID = :v_alert_id;

  -- 4. Estimate duration via single-source UDF
  v_est_duration_min := AEGIS_OEE.ACTION.GET_EST_DURATION_MIN(:v_failure_mode, :v_asset_type);
  IF (:v_est_duration_min IS NULL OR :v_est_duration_min = 0) THEN
    v_est_duration_min := 120;
  END IF;

  -- 5. Compute parts_ready_date from open requisitions with shortage lead times
  SELECT COALESCE(MAX(pr.LEAD_TIME_DAYS), 0) INTO :v_max_lead_days
  FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION pr
  WHERE pr.WO_ID = :P_WO_ID AND pr.STATUS IN ('PENDING_QUOTE', 'QUOTED', 'ORDERED');

  IF (:v_max_lead_days > 0) THEN
    v_parts_ready_date := DATEADD('day', :v_max_lead_days + 1, CURRENT_DATE());
  ELSE
    v_parts_ready_date := CURRENT_DATE();
  END IF;

  -- 6. Get predicted failure time from DT_ASSET_HEALTH or alert evidence
  BEGIN
    SELECT DATEADD('hour',
      CASE WHEN h.FAILURE_PROBABILITY_24H >= 0.8 THEN 24
           WHEN h.FAILURE_PROBABILITY_24H >= 0.5 THEN 72
           ELSE 168 END,
      CURRENT_TIMESTAMP())
    INTO :v_predicted_failure_ts
    FROM AEGIS_OEE.FEATURES.DT_ASSET_HEALTH h WHERE h.ASSET_ID = :v_asset_id;
  EXCEPTION
    WHEN OTHER THEN
      v_predicted_failure_ts := DATEADD('day', 7, CURRENT_TIMESTAMP());
  END;

  -- 7. Find qualifying windows: open capacity >= est_duration, on the right line, after parts_ready_date
  SELECT ARRAY_AGG(obj) WITHIN GROUP (ORDER BY production_loss, window_start_ts, wasted_min)
  INTO :v_options
  FROM (
    SELECT OBJECT_CONSTRUCT(
      'window_id', mw.WINDOW_ID,
      'line_id', mw.LINE_ID,
      'window_type', mw.WINDOW_TYPE,
      'window_start_ts', TO_VARCHAR(mw.WINDOW_START_TS, 'YYYY-MM-DD HH24:MI'),
      'window_end_ts', TO_VARCHAR(mw.WINDOW_END_TS, 'YYYY-MM-DD HH24:MI'),
      'capacity_min', mw.CAPACITY_MIN,
      'booked_min', mw.BOOKED_MIN,
      'available_min', mw.CAPACITY_MIN - mw.BOOKED_MIN,
      'wasted_min', (mw.CAPACITY_MIN - mw.BOOKED_MIN) - :v_est_duration_min,
      'production_loss', CASE WHEN mw.WINDOW_TYPE IN ('NON_PRODUCTION','SHUTDOWN','CHANGEOVER','DAILY_PM') THEN 0 ELSE 1 END
    ) AS obj,
    CASE WHEN mw.WINDOW_TYPE IN ('NON_PRODUCTION','SHUTDOWN','CHANGEOVER','DAILY_PM') THEN 0 ELSE 1 END AS production_loss,
    mw.WINDOW_START_TS AS window_start_ts,
    (mw.CAPACITY_MIN - mw.BOOKED_MIN) - :v_est_duration_min AS wasted_min
    FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
    WHERE mw.LINE_ID = :v_line_id
      AND mw.STATUS = 'OPEN'
      AND (mw.CAPACITY_MIN - mw.BOOKED_MIN) >= :v_est_duration_min
      AND mw.WINDOW_START_TS >= :v_parts_ready_date::TIMESTAMP_TZ
      AND mw.WINDOW_END_TS > CURRENT_TIMESTAMP()
  );

  -- 8. Check if best window is after predicted failure → EXPEDITE
  IF (:v_options IS NOT NULL AND ARRAY_SIZE(:v_options) > 0) THEN
    LET v_first_window_ts TIMESTAMP_TZ := (
      SELECT MIN(mw.WINDOW_START_TS) FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
      WHERE mw.LINE_ID = :v_line_id AND mw.STATUS = 'OPEN'
        AND (mw.CAPACITY_MIN - mw.BOOKED_MIN) >= :v_est_duration_min
        AND mw.WINDOW_START_TS >= :v_parts_ready_date::TIMESTAMP_TZ
        AND mw.WINDOW_END_TS > CURRENT_TIMESTAMP()
    );
    IF (:v_first_window_ts > :v_predicted_failure_ts) THEN
      v_status := 'EXPEDITE';
    END IF;
  ELSE
    -- No qualifying windows at all with normal lead → always EXPEDITE
    v_status := 'EXPEDITE';
  END IF;

  -- 9. If EXPEDITE, compute expedited-parts alternative
  IF (:v_status = 'EXPEDITE' AND :v_max_lead_days > 0) THEN
    v_expedited_lead := CEIL(:v_max_lead_days / 2.0);
    v_expedited_ready_date := DATEADD('day', :v_expedited_lead + 1, CURRENT_DATE());

    -- Find windows that qualify with expedited lead
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
      'window_id', mw.WINDOW_ID,
      'window_type', mw.WINDOW_TYPE,
      'window_start_ts', TO_VARCHAR(mw.WINDOW_START_TS, 'YYYY-MM-DD HH24:MI'),
      'window_end_ts', TO_VARCHAR(mw.WINDOW_END_TS, 'YYYY-MM-DD HH24:MI'),
      'capacity_min', mw.CAPACITY_MIN,
      'available_min', mw.CAPACITY_MIN - mw.BOOKED_MIN
    )) INTO :v_expedited_window
    FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
    WHERE mw.LINE_ID = :v_line_id
      AND mw.STATUS = 'OPEN'
      AND (mw.CAPACITY_MIN - mw.BOOKED_MIN) >= :v_est_duration_min
      AND mw.WINDOW_START_TS >= :v_expedited_ready_date::TIMESTAMP_TZ
      AND mw.WINDOW_END_TS > CURRENT_TIMESTAMP()
    ORDER BY
      CASE WHEN mw.WINDOW_TYPE IN ('NON_PRODUCTION','SHUTDOWN','CHANGEOVER','DAILY_PM') THEN 0 ELSE 1 END,
      mw.WINDOW_START_TS
    LIMIT 3;
  END IF;

  RETURN OBJECT_CONSTRUCT(
    'wo_id', :P_WO_ID,
    'asset_id', :v_asset_id,
    'line_id', :v_line_id,
    'failure_mode', :v_failure_mode,
    'est_duration_min', :v_est_duration_min,
    'parts_ready_date', :v_parts_ready_date::STRING,
    'max_lead_days', :v_max_lead_days,
    'predicted_failure_ts', TO_VARCHAR(:v_predicted_failure_ts, 'YYYY-MM-DD HH24:MI'),
    'recommended_status', :v_status,
    'expedite_reason', CASE WHEN :v_status = 'EXPEDITE'
      THEN 'Earliest qualifying window is after predicted failure. Recommend expediting parts shipment (expedited lead=' || :v_expedited_lead::STRING || ' days, parts ready by ' || :v_expedited_ready_date::STRING || ') or scheduling an approved production stop.'
      ELSE NULL END,
    'expedited_lead_days', CASE WHEN :v_status = 'EXPEDITE' THEN :v_expedited_lead ELSE NULL END,
    'expedited_ready_date', CASE WHEN :v_status = 'EXPEDITE' THEN :v_expedited_ready_date::STRING ELSE NULL END,
    'expedited_windows', :v_expedited_window,
    'qualifying_windows', :v_options
  );
END;
$$;

-- =============================================================================
-- 4. SCHEDULE_WORK_ORDER(wo_id, window_id, approver, dry_run)
-- Uses GET_EST_DURATION_MIN for duration.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER(
  P_WO_ID VARCHAR,
  P_WINDOW_ID VARCHAR,
  P_APPROVER VARCHAR,
  P_DRY_RUN BOOLEAN DEFAULT TRUE
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_wo_state VARCHAR;
  v_asset_id VARCHAR;
  v_alert_id VARCHAR;
  v_failure_mode VARCHAR;
  v_asset_type VARCHAR;
  v_line_id VARCHAR;
  v_window_line VARCHAR;
  v_window_start TIMESTAMP_TZ;
  v_window_end TIMESTAMP_TZ;
  v_window_capacity NUMBER;
  v_window_booked NUMBER;
  v_est_duration_min NUMBER DEFAULT 120;
  v_parts_ready_date DATE;
  v_max_lead_days NUMBER DEFAULT 0;
  v_schedule_id VARCHAR;
  v_order_by_date DATE;
  v_dup_count NUMBER;
BEGIN
  -- Validate approver
  IF (:P_APPROVER IS NULL OR TRIM(:P_APPROVER) = '' OR UPPER(TRIM(:P_APPROVER)) = 'AGENT') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_SCHFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), COALESCE(:P_APPROVER, 'UNKNOWN'), 'SCHEDULE_WO_REJECTED',
           :P_WO_ID, OBJECT_CONSTRUCT('reason', 'Invalid approver');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Approver must be a real person');
  END IF;

  -- Validate WO exists and is APPROVED
  SELECT wo.STATE, wo.ASSET_ID, wo.ALERT_ID
  INTO :v_wo_state, :v_asset_id, :v_alert_id
  FROM AEGIS_OEE.ACTION.WORK_ORDER wo WHERE wo.WO_ID = :P_WO_ID;

  IF (:v_wo_state IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Work order not found');
  END IF;

  IF (:v_wo_state NOT IN ('APPROVED', 'SYNCED', 'IN_PROGRESS')) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_SCHFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), :P_APPROVER, 'SCHEDULE_WO_REJECTED',
           :P_WO_ID, OBJECT_CONSTRUCT('reason', 'WO state is ' || :v_wo_state || ', must be APPROVED/SYNCED/IN_PROGRESS');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'WO must be in APPROVED state, currently: ' || :v_wo_state);
  END IF;

  -- No double-booking same WO — cancel existing (rebook scenario), but only on real execution
  SELECT COUNT(*) INTO :v_dup_count
  FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
  WHERE ws.WO_ID = :P_WO_ID AND ws.STATUS NOT IN ('CANCELLED');

  IF (:v_dup_count > 0 AND NOT :P_DRY_RUN) THEN
    UPDATE AEGIS_OEE.ACTION.WO_SCHEDULE
    SET STATUS = 'CANCELLED'
    WHERE WO_ID = :P_WO_ID AND STATUS NOT IN ('CANCELLED');

    -- Release old window capacity
    UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
    SET BOOKED_MIN = GREATEST(0, mw.BOOKED_MIN - ws.EST_DURATION_MIN)
    FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
    WHERE mw.WINDOW_ID = ws.WINDOW_ID AND ws.WO_ID = :P_WO_ID AND ws.STATUS = 'CANCELLED';

    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_REBOOK_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), :P_APPROVER, 'SCHEDULE_REBOOKED', :P_WO_ID,
           OBJECT_CONSTRUCT('old_schedules_cancelled', :v_dup_count);
  END IF;

  -- Validate window
  SELECT mw.LINE_ID, mw.WINDOW_START_TS, mw.WINDOW_END_TS, mw.CAPACITY_MIN, mw.BOOKED_MIN
  INTO :v_window_line, :v_window_start, :v_window_end, :v_window_capacity, :v_window_booked
  FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw WHERE mw.WINDOW_ID = :P_WINDOW_ID;

  IF (:v_window_line IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Window not found');
  END IF;

  -- Get asset info + failure mode
  SELECT a.LINE_ID, a.ASSET_TYPE INTO :v_line_id, :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET a WHERE a.ASSET_ID = :v_asset_id;

  IF (:v_window_line != :v_line_id) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Window line ' || :v_window_line || ' does not match asset line ' || :v_line_id);
  END IF;

  SELECT al.PREDICTED_MODE INTO :v_failure_mode
  FROM AEGIS_OEE.ACTION.ALERT al WHERE al.ALERT_ID = :v_alert_id;

  -- Estimate duration via single-source UDF
  v_est_duration_min := AEGIS_OEE.ACTION.GET_EST_DURATION_MIN(:v_failure_mode, :v_asset_type);
  IF (:v_est_duration_min IS NULL OR :v_est_duration_min = 0) THEN
    v_est_duration_min := 120;
  END IF;

  -- Check capacity
  IF ((:v_window_capacity - :v_window_booked) < :v_est_duration_min) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
      'Insufficient window capacity: ' || (:v_window_capacity - :v_window_booked) || ' min available, need ' || :v_est_duration_min || ' min');
  END IF;

  -- Compute parts_ready_date
  SELECT COALESCE(MAX(pr.LEAD_TIME_DAYS), 0) INTO :v_max_lead_days
  FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION pr
  WHERE pr.WO_ID = :P_WO_ID AND pr.STATUS IN ('PENDING_QUOTE', 'QUOTED', 'ORDERED');

  IF (:v_max_lead_days > 0) THEN
    v_parts_ready_date := DATEADD('day', :v_max_lead_days + 1, CURRENT_DATE());
  ELSE
    v_parts_ready_date := CURRENT_DATE();
  END IF;

  -- Window must not start before parts ready
  IF (:v_window_start < :v_parts_ready_date::TIMESTAMP_TZ) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
      'Window starts before parts ready date ' || :v_parts_ready_date::STRING);
  END IF;

  -- Generate schedule ID and order-by date
  v_schedule_id := 'SCH_' || REPLACE(:P_WO_ID, 'WO_', '') || '_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');
  v_order_by_date := DATEADD('day', -(:v_max_lead_days + 1), :v_window_start::DATE);

  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_SCHDRY_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), :P_APPROVER, 'SCHEDULE_WO_DRYRUN', :P_WO_ID,
           OBJECT_CONSTRUCT('window_id', :P_WINDOW_ID, 'est_duration_min', :v_est_duration_min);
    RETURN OBJECT_CONSTRUCT(
      'status', 'DRY_RUN_PREVIEW', 'schedule_id', :v_schedule_id,
      'wo_id', :P_WO_ID, 'window_id', :P_WINDOW_ID,
      'scheduled_start_ts', TO_VARCHAR(:v_window_start, 'YYYY-MM-DD HH24:MI'),
      'scheduled_end_ts', TO_VARCHAR(DATEADD('minute', :v_est_duration_min, :v_window_start), 'YYYY-MM-DD HH24:MI'),
      'est_duration_min', :v_est_duration_min,
      'parts_ready_date', :v_parts_ready_date::STRING,
      'order_by_date', :v_order_by_date::STRING,
      'approver', :P_APPROVER
    );
  END IF;

  -- Real execution: write WO_SCHEDULE
  INSERT INTO AEGIS_OEE.ACTION.WO_SCHEDULE
    (SCHEDULE_ID, WO_ID, WINDOW_ID, SCHEDULED_START_TS, SCHEDULED_END_TS,
     EST_DURATION_MIN, PARTS_READY_DATE, ORDER_BY_DATE, STATUS, RATIONALE, CREATED_TS)
  VALUES (
    :v_schedule_id, :P_WO_ID, :P_WINDOW_ID,
    :v_window_start, DATEADD('minute', :v_est_duration_min, :v_window_start),
    :v_est_duration_min, :v_parts_ready_date, :v_order_by_date,
    'CONFIRMED', 'Scheduled by ' || :P_APPROVER, CURRENT_TIMESTAMP()
  );

  -- Update window booked capacity
  UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW
  SET BOOKED_MIN = BOOKED_MIN + :v_est_duration_min
  WHERE WINDOW_ID = :P_WINDOW_ID;

  -- Update linked purchase requisitions with order-by date
  UPDATE AEGIS_OEE.ACTION.PURCHASE_REQUISITION
  SET RFQ_TEXT = RFQ_TEXT || CHR(10) || CHR(10) || 'ORDER BY DATE: ' || :v_order_by_date::STRING
      || '. Scheduled maintenance window: ' || TO_VARCHAR(:v_window_start, 'YYYY-MM-DD HH24:MI')
      || '. Please ensure delivery before ' || :v_parts_ready_date::STRING || '.'
  WHERE WO_ID = :P_WO_ID AND STATUS IN ('PENDING_QUOTE', 'QUOTED');

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_SCHED_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), :P_APPROVER, 'WO_SCHEDULED', :P_WO_ID,
         OBJECT_CONSTRUCT('schedule_id', :v_schedule_id, 'window_id', :P_WINDOW_ID,
                          'est_duration_min', :v_est_duration_min,
                          'parts_ready_date', :v_parts_ready_date::STRING,
                          'order_by_date', :v_order_by_date::STRING);

  RETURN OBJECT_CONSTRUCT(
    'status', 'CONFIRMED', 'schedule_id', :v_schedule_id,
    'wo_id', :P_WO_ID, 'window_id', :P_WINDOW_ID,
    'scheduled_start_ts', TO_VARCHAR(:v_window_start, 'YYYY-MM-DD HH24:MI'),
    'scheduled_end_ts', TO_VARCHAR(DATEADD('minute', :v_est_duration_min, :v_window_start), 'YYYY-MM-DD HH24:MI'),
    'est_duration_min', :v_est_duration_min,
    'parts_ready_date', :v_parts_ready_date::STRING,
    'order_by_date', :v_order_by_date::STRING,
    'approver', :P_APPROVER
  );
END;
$$;

-- =============================================================================
-- 5. AUTO_SCHEDULE_WO — called by CREATE_WORK_ORDER after approval
-- Picks top-ranked window from PROPOSE_SCHEDULE, writes TENTATIVE or EXPEDITE.
-- If EXPEDITE, includes expedited-parts alternative in rationale.
-- Uses GET_EST_DURATION_MIN for duration.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.AUTO_SCHEDULE_WO(P_WO_ID VARCHAR, P_APPROVER VARCHAR)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_proposal VARIANT;
  v_windows VARIANT;
  v_best_window_id VARCHAR;
  v_est_duration NUMBER;
  v_parts_ready DATE;
  v_max_lead NUMBER;
  v_order_by DATE;
  v_schedule_id VARCHAR;
  v_window_start TIMESTAMP_TZ;
  v_status VARCHAR;
  v_rationale VARCHAR;
BEGIN
  -- Get scheduling proposal
  CALL AEGIS_OEE.ACTION.PROPOSE_SCHEDULE(:P_WO_ID);
  v_proposal := (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));

  v_windows := :v_proposal:qualifying_windows;
  v_status := COALESCE(:v_proposal:recommended_status::STRING, 'TENTATIVE');

  -- If no qualifying windows with normal lead, try expedited windows for EXPEDITE
  IF ((:v_windows IS NULL OR ARRAY_SIZE(:v_windows) = 0) AND :v_status = 'EXPEDITE') THEN
    LET v_exp_windows VARIANT := :v_proposal:expedited_windows;
    IF (:v_exp_windows IS NOT NULL AND ARRAY_SIZE(:v_exp_windows) > 0) THEN
      v_windows := :v_exp_windows;
    END IF;
  END IF;

  IF (:v_windows IS NULL OR ARRAY_SIZE(:v_windows) = 0) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_NOWIN_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), 'SYSTEM', 'AUTO_SCHEDULE_NO_WINDOW', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'No qualifying maintenance windows found',
                            'est_duration_min', :v_proposal:est_duration_min,
                            'parts_ready_date', :v_proposal:parts_ready_date,
                            'recommended_status', :v_proposal:recommended_status);
    RETURN 'No qualifying windows for auto-schedule';
  END IF;

  -- Pick the top-ranked window
  v_best_window_id := :v_windows[0]:window_id::STRING;
  v_est_duration := :v_proposal:est_duration_min::NUMBER;
  v_parts_ready := :v_proposal:parts_ready_date::DATE;
  v_max_lead := :v_proposal:max_lead_days::NUMBER;
  v_status := :v_proposal:recommended_status::STRING;

  -- Get the window start
  SELECT mw.WINDOW_START_TS INTO :v_window_start
  FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw WHERE mw.WINDOW_ID = :v_best_window_id;

  -- Compute order-by date
  v_order_by := DATEADD('day', -(:v_max_lead + 1), :v_window_start::DATE);
  v_schedule_id := 'SCH_AUTO_' || REPLACE(:P_WO_ID, 'WO_', '') || '_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');

  -- Build rationale
  IF (:v_status = 'EXPEDITE') THEN
    v_rationale := 'Auto-scheduled on approval (EXPEDITE). ' || COALESCE(:v_proposal:expedite_reason::STRING, '');
    -- Include expedited alternative if available
    IF (:v_proposal:expedited_windows IS NOT NULL AND ARRAY_SIZE(:v_proposal:expedited_windows) > 0) THEN
      v_rationale := :v_rationale || ' EXPEDITED ALTERNATIVE: If parts are expedited (lead='
        || COALESCE(:v_proposal:expedited_lead_days::STRING, '?') || ' days, ready by '
        || COALESCE(:v_proposal:expedited_ready_date::STRING, '?') || '), window '
        || :v_proposal:expedited_windows[0]:window_id::STRING || ' ('
        || :v_proposal:expedited_windows[0]:window_type::STRING || ' at '
        || :v_proposal:expedited_windows[0]:window_start_ts::STRING || ') would qualify. Order by: '
        || DATEADD('day', -(COALESCE(:v_proposal:expedited_lead_days::NUMBER, 0) + 1), :v_window_start::DATE)::STRING || '.';
    END IF;
  ELSE
    v_rationale := 'Auto-scheduled on approval. Window ' || :v_best_window_id
      || ' (' || :v_windows[0]:window_type::STRING || ') with '
      || :v_windows[0]:available_min::STRING || ' min available.';
  END IF;

  -- Insert schedule row
  INSERT INTO AEGIS_OEE.ACTION.WO_SCHEDULE
    (SCHEDULE_ID, WO_ID, WINDOW_ID, SCHEDULED_START_TS, SCHEDULED_END_TS,
     EST_DURATION_MIN, PARTS_READY_DATE, ORDER_BY_DATE, STATUS, RATIONALE, CREATED_TS)
  VALUES (
    :v_schedule_id, :P_WO_ID, :v_best_window_id,
    :v_window_start, DATEADD('minute', :v_est_duration, :v_window_start),
    :v_est_duration, :v_parts_ready, :v_order_by,
    CASE WHEN :v_status = 'EXPEDITE' THEN 'EXPEDITE' ELSE 'TENTATIVE' END,
    :v_rationale,
    CURRENT_TIMESTAMP()
  );

  -- Book window capacity
  UPDATE AEGIS_OEE.CORE.MAINTENANCE_WINDOW
  SET BOOKED_MIN = BOOKED_MIN + :v_est_duration
  WHERE WINDOW_ID = :v_best_window_id;

  -- Update purchase requisitions with order-by date
  UPDATE AEGIS_OEE.ACTION.PURCHASE_REQUISITION
  SET RFQ_TEXT = RFQ_TEXT || CHR(10) || CHR(10) || 'ORDER BY DATE: ' || :v_order_by::STRING
      || '. Scheduled window: ' || TO_VARCHAR(:v_window_start, 'YYYY-MM-DD HH24:MI')
      || '. Deliver before ' || :v_parts_ready::STRING || '.'
  WHERE WO_ID = :P_WO_ID AND STATUS IN ('PENDING_QUOTE', 'QUOTED');

  -- Enrich outbox with schedule
  CALL AEGIS_OEE.ACTION.ENRICH_OUTBOX_WITH_SCHEDULE(:P_WO_ID);

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_AUTOSCH_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), 'SYSTEM', 'WO_AUTO_SCHEDULED', :P_WO_ID,
         OBJECT_CONSTRUCT('schedule_id', :v_schedule_id, 'window_id', :v_best_window_id,
                          'status', CASE WHEN :v_status = 'EXPEDITE' THEN 'EXPEDITE' ELSE 'TENTATIVE' END,
                          'est_duration_min', :v_est_duration,
                          'parts_ready_date', :v_parts_ready::STRING,
                          'order_by_date', :v_order_by::STRING,
                          'rationale', :v_rationale);

  RETURN 'Auto-scheduled: ' || :v_schedule_id || ' (' || :v_status || ')';
END;
$$;

-- =============================================================================
-- 6. Daily refresh task (SUSPENDED)
-- =============================================================================

CREATE OR REPLACE TASK AEGIS_OEE.CORE.TASK_REFRESH_CMMS_PLAN
  WAREHOUSE = AEGIS_WH
  SCHEDULE = 'USING CRON 0 5 * * * Asia/Kolkata'
AS
  CALL AEGIS_OEE.CORE.REFRESH_CMMS_PLAN();

-- Created SUSPENDED per AGENTS.md convention

-- =============================================================================
-- 7. ENRICH_OUTBOX_WITH_SCHEDULE — adds schedule info to outbox payloads
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.ENRICH_OUTBOX_WITH_SCHEDULE(P_WO_ID VARCHAR)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_schedule VARIANT;
BEGIN
  SELECT OBJECT_CONSTRUCT(
    'schedule_id', ws.SCHEDULE_ID,
    'window_id', ws.WINDOW_ID,
    'scheduled_start_ts', TO_VARCHAR(ws.SCHEDULED_START_TS, 'YYYY-MM-DD HH24:MI'),
    'scheduled_end_ts', TO_VARCHAR(ws.SCHEDULED_END_TS, 'YYYY-MM-DD HH24:MI'),
    'est_duration_min', ws.EST_DURATION_MIN,
    'parts_ready_date', ws.PARTS_READY_DATE::STRING,
    'order_by_date', ws.ORDER_BY_DATE::STRING,
    'status', ws.STATUS
  ) INTO :v_schedule
  FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
  WHERE ws.WO_ID = :P_WO_ID AND ws.STATUS NOT IN ('CANCELLED')
  ORDER BY ws.CREATED_TS DESC LIMIT 1;

  IF (:v_schedule IS NOT NULL) THEN
    UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
    SET PAYLOAD = OBJECT_INSERT(PAYLOAD, 'schedule', :v_schedule, TRUE)
    WHERE WO_ID = :P_WO_ID AND STATUS = 'PENDING';
  END IF;

  RETURN 'Outbox enriched with schedule for ' || :P_WO_ID;
END;
$$;
