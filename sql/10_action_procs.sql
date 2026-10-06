-- =============================================================================
-- Mission 05 — Governed Action Loop: Action Procedures
-- CHECK_PARTS, CREATE_WORK_ORDER, NOTIFY_SLACK, QUEUE_GITHUB_SYNC,
-- RETRY_OUTBOX, TASK_OUTBOX_RETRY
-- Idempotent: safe to re-run.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- =============================================================================
-- 1. CHECK_PARTS(alert_id) → VARIANT
-- Resolves parts kit via FAILURE_MODE_PARTS, computes availability,
-- inserts PURCHASE_REQUISITION for shortages with AI-drafted RFQ text.
-- Audit row: PARTS_CHECKED.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.CHECK_PARTS(P_ALERT_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_asset_id VARCHAR;
  v_predicted_mode VARCHAR;
  v_asset_type VARCHAR;
  v_parts_result VARIANT;
BEGIN
  SELECT ASSET_ID, PREDICTED_MODE
  INTO :v_asset_id, :v_predicted_mode
  FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :P_ALERT_ID;

  IF (:v_asset_id IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('error', 'Alert not found: ' || :P_ALERT_ID);
  END IF;

  SELECT ASSET_TYPE INTO :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_asset_id;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'part_id', fmp.PART_ID, 'part_name', pi.PART_NAME,
    'qty_required', fmp.QTY_REQUIRED, 'on_hand', pi.ON_HAND_QTY,
    'reserved', pi.RESERVED_QTY,
    'available', pi.ON_HAND_QTY - pi.RESERVED_QTY,
    'shortage', GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)),
    'unit_cost', pi.UNIT_COST, 'supplier', pi.SUPPLIER_NAME,
    'lead_time_days', pi.LEAD_TIME_DAYS
  )) INTO :v_parts_result
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  -- Insert PURCHASE_REQUISITION for shortages with AI-drafted RFQ
  INSERT INTO AEGIS_OEE.ACTION.PURCHASE_REQUISITION (REQ_ID, WO_ID, PART_ID, QTY, EST_UNIT_COST, EST_TOTAL,
    SUPPLIER_NAME, LEAD_TIME_DAYS, RFQ_TEXT, STATUS, CREATED_TS)
  SELECT
    'REQ_' || :P_ALERT_ID || '_' || fmp.PART_ID,
    NULL, fmp.PART_ID,
    GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)),
    pi.UNIT_COST,
    GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)) * pi.UNIT_COST,
    pi.SUPPLIER_NAME, pi.LEAD_TIME_DAYS,
    SNOWFLAKE.CORTEX.COMPLETE('llama3.1-8b',
      'Draft a professional purchase requisition email for: '
      || pi.PART_NAME || ' (Part ID: ' || fmp.PART_ID || '). '
      || 'Quantity needed: ' || GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY))::STRING || '. '
      || 'Supplier: ' || pi.SUPPLIER_NAME || '. '
      || 'Unit cost: USD ' || pi.UNIT_COST::STRING || '. '
      || 'Requested delivery within ' || pi.LEAD_TIME_DAYS::STRING || ' business days. '
      || 'For maintenance of ' || :v_asset_id || ' (' || :v_asset_type || ') predicted failure mode: ' || :v_predicted_mode || '. '
      || 'Keep the email concise and professional. Max 150 words.'
    ),
    'PENDING_QUOTE', CURRENT_TIMESTAMP()
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode
    AND fmp.ASSET_TYPE = :v_asset_type
    AND fmp.QTY_REQUIRED > (pi.ON_HAND_QTY - pi.RESERVED_QTY)
    AND NOT EXISTS (
      SELECT 1 FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION pr
      WHERE pr.REQ_ID = 'REQ_' || :P_ALERT_ID || '_' || fmp.PART_ID
        AND pr.STATUS NOT IN ('CANCELLED', 'RECEIVED')
    );

  -- Audit (use SELECT to handle VARIANT column)
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT
    'AUD_PARTS_' || :P_ALERT_ID || '_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS'),
    CURRENT_TIMESTAMP(), 'SYSTEM', 'PARTS_CHECKED', :P_ALERT_ID, :v_parts_result;

  RETURN OBJECT_CONSTRUCT(
    'alert_id', :P_ALERT_ID,
    'asset_id', :v_asset_id,
    'predicted_mode', :v_predicted_mode,
    'asset_type', :v_asset_type,
    'parts', :v_parts_result,
    'shortages_count', (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION
                        WHERE REQ_ID LIKE 'REQ_' || :P_ALERT_ID || '_%'
                          AND STATUS = 'PENDING_QUOTE')
  );
END;
$$;

-- =============================================================================
-- 2. CREATE_WORK_ORDER(alert_id, approver, dry_run DEFAULT TRUE)
-- Enforces: alert ACKED; approver not null/empty/AGENT; no dup open WO.
-- dry_run=TRUE returns preview only. Non-dry-run writes WO + audit,
-- reserves parts, links requisitions, fires QUEUE_GITHUB_SYNC + NOTIFY_SLACK.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.CREATE_WORK_ORDER(
  P_ALERT_ID VARCHAR,
  P_APPROVER VARCHAR,
  P_DRY_RUN BOOLEAN DEFAULT TRUE
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_alert_status VARCHAR;
  v_asset_id VARCHAR;
  v_severity VARCHAR;
  v_predicted_mode VARCHAR;
  v_confidence FLOAT;
  v_failure_prob FLOAT;
  v_oee_impact FLOAT;
  v_evidence VARIANT;
  v_asset_type VARCHAR;
  v_line_id VARCHAR;
  v_criticality NUMBER;
  v_wo_id VARCHAR;
  v_title VARCHAR;
  v_dup_count NUMBER;
  v_parts VARIANT;
  v_max_lead_days NUMBER DEFAULT 0;
BEGIN
  SELECT STATUS, ASSET_ID, SEVERITY, PREDICTED_MODE, CONFIDENCE, FAILURE_PROBABILITY, OEE_IMPACT_EST, EVIDENCE
  INTO :v_alert_status, :v_asset_id, :v_severity, :v_predicted_mode, :v_confidence, :v_failure_prob, :v_oee_impact, :v_evidence
  FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :P_ALERT_ID;

  IF (:v_alert_status IS NULL) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_CWOFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), COALESCE(:P_APPROVER, 'UNKNOWN'), 'CREATE_WO_REJECTED',
           :P_ALERT_ID, OBJECT_CONSTRUCT('reason', 'Alert not found');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Alert not found: ' || :P_ALERT_ID);
  END IF;

  IF (:v_alert_status != 'ACKED') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_CWOFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), COALESCE(:P_APPROVER, 'UNKNOWN'), 'CREATE_WO_REJECTED',
           :P_ALERT_ID, OBJECT_CONSTRUCT('reason', 'Alert status is ' || :v_alert_status || ', must be ACKED');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Alert must be in ACKED state, currently: ' || :v_alert_status);
  END IF;

  IF (:P_APPROVER IS NULL OR TRIM(:P_APPROVER) = '' OR UPPER(TRIM(:P_APPROVER)) = 'AGENT') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_CWOFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), COALESCE(:P_APPROVER, 'UNKNOWN'), 'CREATE_WO_REJECTED',
           :P_ALERT_ID, OBJECT_CONSTRUCT('reason', 'Invalid approver: ' || COALESCE(:P_APPROVER, 'NULL'));
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Approver must be a real person, not NULL/empty/AGENT');
  END IF;

  SELECT COUNT(*) INTO :v_dup_count
  FROM AEGIS_OEE.ACTION.WORK_ORDER wo
  JOIN AEGIS_OEE.ACTION.ALERT al ON wo.ALERT_ID = al.ALERT_ID
  WHERE wo.ASSET_ID = :v_asset_id AND al.PREDICTED_MODE = :v_predicted_mode
    AND wo.STATE NOT IN ('CLOSED', 'REJECTED');

  IF (:v_dup_count > 0) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_CWOFAIL_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), :P_APPROVER, 'CREATE_WO_REJECTED',
           :P_ALERT_ID, OBJECT_CONSTRUCT('reason', 'Duplicate open WO for asset+mode');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Duplicate open work order exists for ' || :v_asset_id || ' / ' || :v_predicted_mode);
  END IF;

  SELECT ASSET_TYPE, LINE_ID, CRITICALITY INTO :v_asset_type, :v_line_id, :v_criticality
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_asset_id;

  CALL AEGIS_OEE.ACTION.CHECK_PARTS(:P_ALERT_ID);

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'part_id', fmp.PART_ID, 'part_name', pi.PART_NAME,
    'qty_required', fmp.QTY_REQUIRED, 'available', pi.ON_HAND_QTY - pi.RESERVED_QTY,
    'shortage', GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)),
    'unit_cost', pi.UNIT_COST, 'supplier', pi.SUPPLIER_NAME, 'lead_time_days', pi.LEAD_TIME_DAYS
  )) INTO :v_parts
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  SELECT COALESCE(MAX(pi.LEAD_TIME_DAYS), 0) INTO :v_max_lead_days
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type
    AND fmp.QTY_REQUIRED > (pi.ON_HAND_QTY - pi.RESERVED_QTY);

  v_wo_id := 'WO_' || REPLACE(:P_ALERT_ID, 'ALT_', '') || '_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');
  v_title := '[' || :v_severity || '][' || :v_predicted_mode || '] ' || :v_asset_id || ' — inspection required';

  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT 'AUD_DRYRUN_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
           CURRENT_TIMESTAMP(), :P_APPROVER, 'CREATE_WO_DRYRUN', :P_ALERT_ID,
           OBJECT_CONSTRUCT('wo_id', :v_wo_id, 'title', :v_title, 'preview', TRUE);
    RETURN OBJECT_CONSTRUCT(
      'status', 'DRY_RUN_PREVIEW', 'wo_id', :v_wo_id, 'alert_id', :P_ALERT_ID,
      'asset_id', :v_asset_id, 'priority', :v_severity, 'title', :v_title,
      'predicted_mode', :v_predicted_mode, 'confidence', :v_confidence,
      'failure_probability', :v_failure_prob, 'parts', :v_parts,
      'max_lead_time_days', :v_max_lead_days, 'approver', :P_APPROVER
    );
  END IF;

  -- Real execution: write WO
  INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER (WO_ID, ALERT_ID, ASSET_ID, PRIORITY, STATE, TITLE, DESCRIPTION, EVIDENCE, APPROVED_BY, APPROVED_TS)
  SELECT :v_wo_id, :P_ALERT_ID, :v_asset_id, :v_severity, 'APPROVED', :v_title,
         :v_predicted_mode || ' predicted with confidence ' || ROUND(:v_confidence, 3)::STRING
         || '. Failure probability: ' || ROUND(:v_failure_prob, 3)::STRING
         || '. Parts lead time: ' || :v_max_lead_days::STRING || ' days.',
         :v_evidence, :P_APPROVER, CURRENT_TIMESTAMP();

  -- Reserve available parts
  UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY pi
  SET RESERVED_QTY = pi.RESERVED_QTY + LEAST(fmp.QTY_REQUIRED, pi.ON_HAND_QTY - pi.RESERVED_QTY)
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  WHERE pi.PART_ID = fmp.PART_ID
    AND fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type
    AND (pi.ON_HAND_QTY - pi.RESERVED_QTY) > 0;

  -- Link open requisitions to WO
  UPDATE AEGIS_OEE.ACTION.PURCHASE_REQUISITION
  SET WO_ID = :v_wo_id
  WHERE REQ_ID LIKE 'REQ_' || :P_ALERT_ID || '_%' AND STATUS = 'PENDING_QUOTE' AND WO_ID IS NULL;

  -- Update alert status
  UPDATE AEGIS_OEE.ACTION.ALERT SET STATUS = 'TRIAGED' WHERE ALERT_ID = :P_ALERT_ID AND STATUS = 'ACKED';

  -- Audit: approval
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_APPROVED_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), :P_APPROVER, 'WO_APPROVED', :v_wo_id,
         OBJECT_CONSTRUCT('alert_id', :P_ALERT_ID, 'asset_id', :v_asset_id,
                          'priority', :v_severity, 'predicted_mode', :v_predicted_mode);

  -- Auto-fire GitHub sync + Slack notification
  CALL AEGIS_OEE.ACTION.QUEUE_GITHUB_SYNC(:v_wo_id);
  CALL AEGIS_OEE.ACTION.NOTIFY_SLACK(OBJECT_CONSTRUCT(
    'text', :v_severity || ' Work Order Approved: ' || :v_title,
    'wo_id', :v_wo_id, 'asset_id', :v_asset_id,
    'approver', :P_APPROVER, 'predicted_mode', :v_predicted_mode
  ));

  -- Auto-schedule into the best maintenance window (TENTATIVE or EXPEDITE)
  CALL AEGIS_OEE.ACTION.AUTO_SCHEDULE_WO(:v_wo_id, :P_APPROVER);

  RETURN OBJECT_CONSTRUCT(
    'status', 'APPROVED', 'wo_id', :v_wo_id, 'alert_id', :P_ALERT_ID,
    'asset_id', :v_asset_id, 'priority', :v_severity, 'title', :v_title,
    'approver', :P_APPROVER, 'parts_reserved', TRUE,
    'max_lead_time_days', :v_max_lead_days, 'github_queued', TRUE, 'slack_queued', TRUE
  );
END;
$$;

-- =============================================================================
-- 3. NOTIFY_SLACK(payload) → writes to OUTBOX (fallback-first design)
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.NOTIFY_SLACK(P_PAYLOAD VARIANT)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, ATTEMPTS, STATUS)
  SELECT 'OB_SLACK_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         COALESCE(:P_PAYLOAD:wo_id::STRING, 'UNKNOWN'), 'SLACK', :P_PAYLOAD, 0, 'PENDING';

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_SLACK_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), 'SYSTEM', 'SLACK_QUEUED',
         COALESCE(:P_PAYLOAD:wo_id::STRING, 'UNKNOWN'), :P_PAYLOAD;

  RETURN 'Slack notification queued to OUTBOX';
END;
$$;

-- =============================================================================
-- 4. QUEUE_GITHUB_SYNC(wo_id) → builds GitHub issue payload into OUTBOX
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.QUEUE_GITHUB_SYNC(P_WO_ID VARCHAR)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_wo VARIANT;
  v_alert VARIANT;
  v_parts VARIANT;
  v_reqs VARIANT;
  v_asset_type VARCHAR;
  v_predicted_mode VARCHAR;
BEGIN
  SELECT OBJECT_CONSTRUCT(
    'wo_id', wo.WO_ID, 'alert_id', wo.ALERT_ID, 'asset_id', wo.ASSET_ID,
    'priority', wo.PRIORITY, 'state', wo.STATE, 'title', wo.TITLE,
    'description', wo.DESCRIPTION, 'approved_by', wo.APPROVED_BY,
    'approved_ts', wo.APPROVED_TS::STRING
  ) INTO :v_wo
  FROM AEGIS_OEE.ACTION.WORK_ORDER wo WHERE wo.WO_ID = :P_WO_ID;

  IF (:v_wo IS NULL) THEN
    RETURN 'WO not found: ' || :P_WO_ID;
  END IF;

  SELECT OBJECT_CONSTRUCT(
    'alert_id', al.ALERT_ID, 'severity', al.SEVERITY, 'predicted_mode', al.PREDICTED_MODE,
    'confidence', al.CONFIDENCE, 'failure_probability', al.FAILURE_PROBABILITY,
    'oee_impact_est', al.OEE_IMPACT_EST, 'onset_ts', al.ONSET_TS::STRING
  ) INTO :v_alert
  FROM AEGIS_OEE.ACTION.ALERT al WHERE al.ALERT_ID = :v_wo:alert_id::STRING;

  v_predicted_mode := :v_alert:predicted_mode::STRING;

  SELECT ASSET_TYPE INTO :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_wo:asset_id::STRING;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'part_id', fmp.PART_ID, 'part_name', pi.PART_NAME,
    'qty_required', fmp.QTY_REQUIRED,
    'available', pi.ON_HAND_QTY - pi.RESERVED_QTY,
    'shortage', GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)),
    'unit_cost', pi.UNIT_COST, 'lead_time_days', pi.LEAD_TIME_DAYS
  )) INTO :v_parts
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'req_id', pr.REQ_ID, 'part_id', pr.PART_ID, 'qty', pr.QTY,
    'est_total', pr.EST_TOTAL, 'supplier', pr.SUPPLIER_NAME,
    'lead_time_days', pr.LEAD_TIME_DAYS, 'status', pr.STATUS
  )) INTO :v_reqs
  FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION pr WHERE pr.WO_ID = :P_WO_ID;

  INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, ATTEMPTS, STATUS)
  SELECT 'OB_GH_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         :P_WO_ID, 'GITHUB',
         OBJECT_CONSTRUCT(
           'title', :v_wo:title::STRING,
           'labels', ARRAY_CONSTRUCT(:v_alert:severity::STRING, :v_predicted_mode, 'maintenance'),
           'body_data', OBJECT_CONSTRUCT(
             'work_order', :v_wo, 'alert', :v_alert,
             'parts_availability', :v_parts, 'purchase_requisitions', :v_reqs,
             'safety_statement', 'This work order requires on-site human verification before execution.',
             'generated_by', 'AegisOEE Governed Action Loop'
           )
         ), 0, 'PENDING';

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_GH_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), 'SYSTEM', 'GITHUB_QUEUED', :P_WO_ID,
         OBJECT_CONSTRUCT('outbox_target', 'GITHUB');

  RETURN 'GitHub sync queued for WO: ' || :P_WO_ID;
END;
$$;

-- =============================================================================
-- 5. RETRY_OUTBOX — retries Slack, marks dead after 5 attempts
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.RETRY_OUTBOX()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  SET STATUS = 'DEAD', LAST_ERROR = 'Max attempts reached'
  WHERE STATUS = 'PENDING' AND ATTEMPTS >= 5;

  UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  SET ATTEMPTS = ATTEMPTS + 1,
      LAST_ERROR = 'No SLACK_WEBHOOK_URL configured - outbox fallback active',
      STATUS = CASE WHEN ATTEMPTS + 1 >= 5 THEN 'DEAD' ELSE 'PENDING' END
  WHERE TARGET = 'SLACK' AND STATUS = 'PENDING' AND ATTEMPTS < 5;

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT 'AUD_RETRY_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         CURRENT_TIMESTAMP(), 'SYSTEM', 'OUTBOX_RETRY', 'OUTBOX',
         OBJECT_CONSTRUCT(
           'pending_slack', (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET='SLACK' AND STATUS='PENDING'),
           'pending_github', (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET='GITHUB' AND STATUS='PENDING'),
           'dead', (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE STATUS='DEAD')
         );

  RETURN 'Outbox retry complete';
END;
$$;

-- =============================================================================
-- 6. TASK_OUTBOX_RETRY — every 10 min
-- =============================================================================

CREATE OR REPLACE TASK AEGIS_OEE.ACTION.TASK_OUTBOX_RETRY
  WAREHOUSE = AEGIS_WH
  SCHEDULE  = '10 MINUTE'
AS
  CALL AEGIS_OEE.ACTION.RETRY_OUTBOX();

-- =============================================================================
-- 7. Guardrail test results table
-- =============================================================================

CREATE TABLE IF NOT EXISTS AEGIS_OEE.TEST.ACTION_GUARDRAIL_RESULTS (
  TEST_NAME    STRING    NOT NULL,
  RESULT       STRING    NOT NULL,
  DETAIL       STRING,
  TESTED_AT    TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- 8. UPDATE_REQUISITION_STATUS(req_id, new_status, actor, note, dry_run)
-- Valid transitions: PENDING_QUOTE→QUOTED→ORDERED→RECEIVED, and CANCELLED from
-- any non-RECEIVED state.  RECEIVED increments on_hand_qty exactly once.
-- Double-receive guard, AGENT/NULL actor rejection, audit on every attempt.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS(
  P_REQ_ID     VARCHAR,
  P_NEW_STATUS VARCHAR,
  P_ACTOR      VARCHAR,
  P_NOTE       VARCHAR DEFAULT '',
  P_DRY_RUN    BOOLEAN DEFAULT TRUE
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  v_cur_status VARCHAR;
  v_part_id VARCHAR;
  v_qty NUMBER;
  v_wo_id VARCHAR;
  v_valid BOOLEAN DEFAULT FALSE;
  v_audit_id VARCHAR;
  v_reason VARCHAR DEFAULT '';
BEGIN
  -- Generate audit ID upfront (every attempt gets one)
  v_audit_id := 'AUD_REQUPD_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3');

  -- Actor validation
  IF (:P_ACTOR IS NULL OR TRIM(:P_ACTOR) = '' OR UPPER(TRIM(:P_ACTOR)) = 'AGENT') THEN
    v_reason := 'Invalid actor: ' || COALESCE(:P_ACTOR, 'NULL') || ' — must be a real person';
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), COALESCE(:P_ACTOR, 'UNKNOWN'),
           'REQ_STATUS_REJECTED', :P_REQ_ID,
           OBJECT_CONSTRUCT('reason', :v_reason, 'requested_status', :P_NEW_STATUS);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', :v_reason);
  END IF;

  -- Fetch current requisition
  SELECT STATUS, PART_ID, QTY, WO_ID
  INTO :v_cur_status, :v_part_id, :v_qty, :v_wo_id
  FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION
  WHERE REQ_ID = :P_REQ_ID;

  IF (:v_cur_status IS NULL) THEN
    v_reason := 'Requisition not found: ' || :P_REQ_ID;
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_ACTOR,
           'REQ_STATUS_REJECTED', :P_REQ_ID,
           OBJECT_CONSTRUCT('reason', :v_reason, 'requested_status', :P_NEW_STATUS);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', :v_reason);
  END IF;

  -- Transition validation
  v_valid := CASE
    WHEN :v_cur_status = 'PENDING_QUOTE' AND :P_NEW_STATUS = 'QUOTED'   THEN TRUE
    WHEN :v_cur_status = 'QUOTED'        AND :P_NEW_STATUS = 'ORDERED'  THEN TRUE
    WHEN :v_cur_status = 'ORDERED'       AND :P_NEW_STATUS = 'RECEIVED' THEN TRUE
    WHEN :P_NEW_STATUS = 'CANCELLED' AND :v_cur_status != 'RECEIVED'    THEN TRUE
    ELSE FALSE
  END;

  IF (NOT :v_valid) THEN
    v_reason := 'Invalid transition: ' || :v_cur_status || ' → ' || :P_NEW_STATUS;
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_ACTOR,
           'REQ_STATUS_REJECTED', :P_REQ_ID,
           OBJECT_CONSTRUCT('reason', :v_reason, 'from', :v_cur_status, 'to', :P_NEW_STATUS);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', :v_reason);
  END IF;

  -- Dry-run: preview only
  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_ACTOR,
           'REQ_STATUS_DRYRUN', :P_REQ_ID,
           OBJECT_CONSTRUCT('from', :v_cur_status, 'to', :P_NEW_STATUS, 'note', :P_NOTE);
    RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN_PREVIEW', 'req_id', :P_REQ_ID,
           'from', :v_cur_status, 'to', :P_NEW_STATUS, 'part_id', :v_part_id, 'qty', :v_qty);
  END IF;

  -- Execute transition
  UPDATE AEGIS_OEE.ACTION.PURCHASE_REQUISITION
  SET STATUS = :P_NEW_STATUS
  WHERE REQ_ID = :P_REQ_ID AND STATUS = :v_cur_status;

  -- RECEIVED: increment on_hand_qty exactly once (the WHERE STATUS guard above
  -- plus the transition check ensures this cannot fire twice for the same req)
  IF (:P_NEW_STATUS = 'RECEIVED') THEN
    UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY
    SET ON_HAND_QTY = ON_HAND_QTY + :v_qty
    WHERE PART_ID = :v_part_id;

    -- Reserve received qty for the linked WO (up to the WO's shortage for that part)
    IF (:v_wo_id IS NOT NULL) THEN
      LET v_wo_asset_id VARCHAR := (SELECT ASSET_ID FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = :v_wo_id);
      LET v_wo_alert_id VARCHAR := (SELECT ALERT_ID FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = :v_wo_id);
      LET v_wo_mode VARCHAR := (SELECT PREDICTED_MODE FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :v_wo_alert_id);
      LET v_wo_asset_type VARCHAR := (SELECT ASSET_TYPE FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_wo_asset_id);
      LET v_needed NUMBER := (
        SELECT COALESCE(fmp.QTY_REQUIRED, 0)
        FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
        WHERE fmp.FAILURE_MODE = :v_wo_mode AND fmp.ASSET_TYPE = :v_wo_asset_type AND fmp.PART_ID = :v_part_id
      );
      LET v_already_reserved NUMBER := (SELECT RESERVED_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = :v_part_id);
      LET v_on_hand NUMBER := (SELECT ON_HAND_QTY FROM AEGIS_OEE.CORE.PARTS_INVENTORY WHERE PART_ID = :v_part_id);
      LET v_reserve_amount NUMBER := LEAST(:v_qty, GREATEST(:v_needed - :v_already_reserved, 0), :v_on_hand - :v_already_reserved);
      IF (:v_reserve_amount > 0) THEN
        UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY
        SET RESERVED_QTY = RESERVED_QTY + :v_reserve_amount
        WHERE PART_ID = :v_part_id;
      END IF;
    END IF;
  END IF;

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_ACTOR,
         'REQ_STATUS_CHANGED', :P_REQ_ID,
         OBJECT_CONSTRUCT('from', :v_cur_status, 'to', :P_NEW_STATUS,
                          'part_id', :v_part_id, 'qty', :v_qty, 'note', :P_NOTE);

  RETURN OBJECT_CONSTRUCT('status', 'OK', 'req_id', :P_REQ_ID,
         'from', :v_cur_status, 'to', :P_NEW_STATUS, 'part_id', :v_part_id, 'qty', :v_qty);
END;
$$;

-- =============================================================================
-- 9. START_WORK_ORDER(wo_id, technician, note, dry_run)
-- APPROVED|SYNCED → IN_PROGRESS. Rejected if required parts not available.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.START_WORK_ORDER(
  P_WO_ID      VARCHAR,
  P_TECHNICIAN VARCHAR,
  P_NOTE       VARCHAR DEFAULT '',
  P_DRY_RUN    BOOLEAN DEFAULT TRUE
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
  v_predicted_mode VARCHAR;
  v_asset_type VARCHAR;
  v_audit_id VARCHAR;
  v_blockers VARIANT;
  v_blocker_count NUMBER DEFAULT 0;
BEGIN
  v_audit_id := 'AUD_START_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3');

  -- Actor validation
  IF (:P_TECHNICIAN IS NULL OR TRIM(:P_TECHNICIAN) = '' OR UPPER(TRIM(:P_TECHNICIAN)) = 'AGENT') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), COALESCE(:P_TECHNICIAN, 'UNKNOWN'),
           'START_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid technician: ' || COALESCE(:P_TECHNICIAN, 'NULL'));
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Technician must be a real person, not NULL/empty/AGENT');
  END IF;

  -- Fetch WO
  SELECT STATE, ASSET_ID, ALERT_ID
  INTO :v_wo_state, :v_asset_id, :v_alert_id
  FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = :P_WO_ID;

  IF (:v_wo_state IS NULL) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'START_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Work order not found');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Work order not found: ' || :P_WO_ID);
  END IF;

  -- Valid transitions: APPROVED|SYNCED → IN_PROGRESS
  IF (:v_wo_state NOT IN ('APPROVED', 'SYNCED')) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'START_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid transition: ' || :v_wo_state || ' → IN_PROGRESS');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
           'Cannot start WO in state ' || :v_wo_state || '; must be APPROVED or SYNCED');
  END IF;

  -- Get failure mode + asset type
  SELECT PREDICTED_MODE INTO :v_predicted_mode
  FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :v_alert_id;

  SELECT ASSET_TYPE INTO :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_asset_id;

  -- Parts gate: check that reserved parts cover the full kit for this WO
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'part_id', fmp.PART_ID, 'part_name', pi.PART_NAME,
    'qty_required', fmp.QTY_REQUIRED,
    'on_hand', pi.ON_HAND_QTY, 'reserved', pi.RESERVED_QTY,
    'shortage', GREATEST(0, fmp.QTY_REQUIRED - pi.RESERVED_QTY)
  )) INTO :v_blockers
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type
    AND fmp.QTY_REQUIRED > pi.RESERVED_QTY;

  v_blocker_count := COALESCE(ARRAY_SIZE(:v_blockers), 0);

  IF (:v_blocker_count > 0) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'START_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Parts not ready', 'blockers', :v_blockers);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Required parts not available for this WO',
           'blocking_parts', :v_blockers, 'action', 'Receive outstanding requisitions via Parts Procurement page');
  END IF;

  -- Dry-run preview
  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'START_WO_DRYRUN', :P_WO_ID,
           OBJECT_CONSTRUCT('from', :v_wo_state, 'to', 'IN_PROGRESS', 'note', :P_NOTE);
    RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN_PREVIEW', 'wo_id', :P_WO_ID,
           'from', :v_wo_state, 'to', 'IN_PROGRESS', 'technician', :P_TECHNICIAN, 'parts_ready', TRUE);
  END IF;

  -- Execute: transition WO to IN_PROGRESS
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER
  SET STATE = 'IN_PROGRESS'
  WHERE WO_ID = :P_WO_ID AND STATE IN ('APPROVED', 'SYNCED');

  -- Mark linked WO_SCHEDULE row IN_PROGRESS
  UPDATE AEGIS_OEE.ACTION.WO_SCHEDULE
  SET STATUS = 'IN_PROGRESS'
  WHERE WO_ID = :P_WO_ID AND STATUS NOT IN ('CANCELLED', 'COMPLETED');

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
         'WO_STARTED', :P_WO_ID,
         OBJECT_CONSTRUCT('from', :v_wo_state, 'to', 'IN_PROGRESS',
                          'note', :P_NOTE, 'technician', :P_TECHNICIAN);

  RETURN OBJECT_CONSTRUCT('status', 'OK', 'wo_id', :P_WO_ID,
         'from', :v_wo_state, 'to', 'IN_PROGRESS', 'technician', :P_TECHNICIAN);
END;
$$;

-- =============================================================================
-- 10. COMPLETE_WORK_ORDER(wo_id, technician, finding, action_taken, labor_hours,
--     parts_used, outcome, dry_run)
-- IN_PROGRESS → RESOLVED. Consumes parts exactly once, writes MAINTENANCE_HISTORY.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER(
  P_WO_ID        VARCHAR,
  P_TECHNICIAN   VARCHAR,
  P_FINDING      VARCHAR,
  P_ACTION_TAKEN VARCHAR,
  P_LABOR_HOURS  FLOAT,
  P_PARTS_USED   VARIANT DEFAULT NULL,
  P_OUTCOME      VARCHAR DEFAULT 'FIXED',
  P_DRY_RUN      BOOLEAN DEFAULT TRUE
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
  v_predicted_mode VARCHAR;
  v_asset_type VARCHAR;
  v_audit_id VARCHAR;
  v_hist_id VARCHAR;
  v_schedule_id VARCHAR;
  v_est_duration NUMBER;
  v_actual_duration NUMBER;
BEGIN
  v_audit_id := 'AUD_COMP_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3');

  -- Actor validation
  IF (:P_TECHNICIAN IS NULL OR TRIM(:P_TECHNICIAN) = '' OR UPPER(TRIM(:P_TECHNICIAN)) = 'AGENT') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), COALESCE(:P_TECHNICIAN, 'UNKNOWN'),
           'COMPLETE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid technician: ' || COALESCE(:P_TECHNICIAN, 'NULL'));
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Technician must be a real person, not NULL/empty/AGENT');
  END IF;

  -- Outcome validation
  IF (:P_OUTCOME NOT IN ('FIXED', 'PARTIAL')) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'COMPLETE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid outcome: ' || :P_OUTCOME);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Outcome must be FIXED or PARTIAL');
  END IF;

  -- Fetch WO
  SELECT STATE, ASSET_ID, ALERT_ID
  INTO :v_wo_state, :v_asset_id, :v_alert_id
  FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = :P_WO_ID;

  IF (:v_wo_state IS NULL) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'COMPLETE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Work order not found');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Work order not found: ' || :P_WO_ID);
  END IF;

  -- Valid transition: IN_PROGRESS → RESOLVED only
  IF (:v_wo_state != 'IN_PROGRESS') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'COMPLETE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid transition: ' || :v_wo_state || ' → RESOLVED');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
           'Cannot complete WO in state ' || :v_wo_state || '; must be IN_PROGRESS');
  END IF;

  -- Get failure mode + asset type
  SELECT PREDICTED_MODE INTO :v_predicted_mode
  FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :v_alert_id;

  SELECT ASSET_TYPE INTO :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_asset_id;

  -- Dry-run preview
  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
           'COMPLETE_WO_DRYRUN', :P_WO_ID,
           OBJECT_CONSTRUCT('outcome', :P_OUTCOME, 'labor_hours', :P_LABOR_HOURS);
    RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN_PREVIEW', 'wo_id', :P_WO_ID,
           'from', 'IN_PROGRESS', 'to', 'RESOLVED', 'outcome', :P_OUTCOME,
           'technician', :P_TECHNICIAN, 'labor_hours', :P_LABOR_HOURS,
           'finding', :P_FINDING, 'action_taken', :P_ACTION_TAKEN);
  END IF;

  -- Execute: transition WO to RESOLVED
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER
  SET STATE = 'RESOLVED', CLOSE_REASON = :P_OUTCOME
  WHERE WO_ID = :P_WO_ID AND STATE = 'IN_PROGRESS';

  -- Consume parts exactly once: decrease on_hand_qty and reserved_qty
  UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY pi
  SET ON_HAND_QTY  = pi.ON_HAND_QTY  - LEAST(fmp.QTY_REQUIRED, pi.ON_HAND_QTY),
      RESERVED_QTY = pi.RESERVED_QTY - LEAST(fmp.QTY_REQUIRED, pi.RESERVED_QTY)
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  WHERE pi.PART_ID = fmp.PART_ID
    AND fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  -- Write MAINTENANCE_HISTORY row
  v_hist_id := 'MH_' || REPLACE(:P_WO_ID, 'WO_', '') || '_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');

  INSERT INTO AEGIS_OEE.CORE.MAINTENANCE_HISTORY
    (WO_HIST_ID, ASSET_ID, COMPLETED_TS, FAILURE_CODE, FINDING, ACTION_TAKEN, PARTS_USED, LABOR_HOURS, TECHNICIAN_NOTE)
  SELECT :v_hist_id, :v_asset_id, CURRENT_TIMESTAMP(), :v_predicted_mode,
         :P_FINDING, :P_ACTION_TAKEN,
         COALESCE(:P_PARTS_USED, (
           SELECT ARRAY_AGG(OBJECT_CONSTRUCT('part_id', fmp.PART_ID, 'qty', fmp.QTY_REQUIRED))
           FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
           WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type
         ))::STRING,
         :P_LABOR_HOURS,
         :P_OUTCOME || ' by ' || :P_TECHNICIAN || '. ' || COALESCE(:P_FINDING, '');

  -- Mark WO_SCHEDULE as COMPLETED, record actual vs estimated duration
  SELECT ws.SCHEDULE_ID, ws.EST_DURATION_MIN
  INTO :v_schedule_id, :v_est_duration
  FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
  WHERE ws.WO_ID = :P_WO_ID AND ws.STATUS = 'IN_PROGRESS'
  ORDER BY ws.CREATED_TS DESC LIMIT 1;

  IF (:v_schedule_id IS NOT NULL) THEN
    v_actual_duration := ROUND(:P_LABOR_HOURS * 60);
    UPDATE AEGIS_OEE.ACTION.WO_SCHEDULE
    SET STATUS = 'COMPLETED',
        RATIONALE = COALESCE(RATIONALE, '') || ' | Completed: actual=' || :v_actual_duration || 'min vs est=' || :v_est_duration || 'min'
    WHERE SCHEDULE_ID = :v_schedule_id;
  END IF;

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_TECHNICIAN,
         'WO_COMPLETED', :P_WO_ID,
         OBJECT_CONSTRUCT('outcome', :P_OUTCOME, 'finding', :P_FINDING,
                          'action_taken', :P_ACTION_TAKEN, 'labor_hours', :P_LABOR_HOURS,
                          'maintenance_history_id', :v_hist_id,
                          'schedule_id', :v_schedule_id);

  RETURN OBJECT_CONSTRUCT('status', 'OK', 'wo_id', :P_WO_ID,
         'from', 'IN_PROGRESS', 'to', 'RESOLVED', 'outcome', :P_OUTCOME,
         'maintenance_history_id', :v_hist_id, 'technician', :P_TECHNICIAN);
END;
$$;

-- =============================================================================
-- 11. CLOSE_WORK_ORDER(wo_id, approver, verification_note, dry_run)
-- RESOLVED → CLOSED. Approver must differ from technician. Closes alert.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.CLOSE_WORK_ORDER(
  P_WO_ID             VARCHAR,
  P_APPROVER          VARCHAR,
  P_VERIFICATION_NOTE VARCHAR,
  P_DRY_RUN           BOOLEAN DEFAULT TRUE
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
  v_audit_id VARCHAR;
  v_technician VARCHAR;
BEGIN
  v_audit_id := 'AUD_CLOSE_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3');

  -- Actor validation
  IF (:P_APPROVER IS NULL OR TRIM(:P_APPROVER) = '' OR UPPER(TRIM(:P_APPROVER)) = 'AGENT') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), COALESCE(:P_APPROVER, 'UNKNOWN'),
           'CLOSE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid approver: ' || COALESCE(:P_APPROVER, 'NULL'));
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Approver must be a real person, not NULL/empty/AGENT');
  END IF;

  -- Verification note required
  IF (:P_VERIFICATION_NOTE IS NULL OR TRIM(:P_VERIFICATION_NOTE) = '') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
           'CLOSE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Verification note required');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Verification note is required to close a work order');
  END IF;

  -- Fetch WO
  SELECT STATE, ASSET_ID, ALERT_ID
  INTO :v_wo_state, :v_asset_id, :v_alert_id
  FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = :P_WO_ID;

  IF (:v_wo_state IS NULL) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
           'CLOSE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Work order not found');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason', 'Work order not found: ' || :P_WO_ID);
  END IF;

  -- Valid transition: RESOLVED → CLOSED
  IF (:v_wo_state != 'RESOLVED') THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
           'CLOSE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Invalid transition: ' || :v_wo_state || ' → CLOSED');
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
           'Cannot close WO in state ' || :v_wo_state || '; must be RESOLVED');
  END IF;

  -- Approver must differ from the technician who started the work
  SELECT aa.ACTOR INTO :v_technician
  FROM AEGIS_OEE.ACTION.ACTION_AUDIT aa
  WHERE aa.OBJECT_REF = :P_WO_ID AND aa.ACTION = 'WO_STARTED'
  ORDER BY aa.TS DESC LIMIT 1;

  IF (:v_technician IS NOT NULL AND UPPER(TRIM(:P_APPROVER)) = UPPER(TRIM(:v_technician))) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
           'CLOSE_WO_REJECTED', :P_WO_ID,
           OBJECT_CONSTRUCT('reason', 'Approver must differ from technician',
                            'technician', :v_technician, 'approver', :P_APPROVER);
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason',
           'Approver (' || :P_APPROVER || ') must differ from technician (' || :v_technician || ')');
  END IF;

  -- Dry-run preview
  IF (:P_DRY_RUN) THEN
    INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
    SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
           'CLOSE_WO_DRYRUN', :P_WO_ID,
           OBJECT_CONSTRUCT('verification_note', :P_VERIFICATION_NOTE);
    RETURN OBJECT_CONSTRUCT('status', 'DRY_RUN_PREVIEW', 'wo_id', :P_WO_ID,
           'from', 'RESOLVED', 'to', 'CLOSED', 'approver', :P_APPROVER,
           'verification_note', :P_VERIFICATION_NOTE, 'technician', :v_technician);
  END IF;

  -- Execute: transition WO to CLOSED
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER
  SET STATE = 'CLOSED',
      CLOSE_REASON = 'Verified: ' || :P_VERIFICATION_NOTE,
      CLOSED_AT = CURRENT_TIMESTAMP()
  WHERE WO_ID = :P_WO_ID AND STATE = 'RESOLVED';

  -- Close linked alert
  UPDATE AEGIS_OEE.ACTION.ALERT
  SET STATUS = 'CLOSED'
  WHERE ALERT_ID = :v_alert_id AND STATUS NOT IN ('CLOSED');

  -- Queue GitHub-close + Slack message to OUTBOX
  INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, ATTEMPTS, STATUS)
  SELECT 'OB_GH_CLOSE_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISSFF3'),
         :P_WO_ID, 'GITHUB',
         OBJECT_CONSTRUCT('action', 'close', 'wo_id', :P_WO_ID,
                          'state_reason', 'completed',
                          'comment', 'Work order closed by ' || :P_APPROVER || ': ' || :P_VERIFICATION_NOTE),
         0, 'PENDING';

  CALL AEGIS_OEE.ACTION.NOTIFY_SLACK(OBJECT_CONSTRUCT(
    'text', 'Work Order Closed: ' || :P_WO_ID,
    'wo_id', :P_WO_ID, 'asset_id', :v_asset_id,
    'closed_by', :P_APPROVER, 'verification', :P_VERIFICATION_NOTE
  ));

  -- Audit
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT :v_audit_id, CURRENT_TIMESTAMP(), :P_APPROVER,
         'WO_CLOSED', :P_WO_ID,
         OBJECT_CONSTRUCT('verification_note', :P_VERIFICATION_NOTE,
                          'alert_closed', :v_alert_id, 'technician', :v_technician);

  RETURN OBJECT_CONSTRUCT('status', 'OK', 'wo_id', :P_WO_ID,
         'from', 'RESOLVED', 'to', 'CLOSED', 'approver', :P_APPROVER,
         'alert_closed', :v_alert_id, 'outbox_queued', TRUE);
END;
$$;
