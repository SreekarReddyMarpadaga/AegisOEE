-- =============================================================================
-- Mission 05 — Governed Action Loop: Alert Scoring Task
-- Idempotent: safe to re-run.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- =============================================================================
-- PART A: ACTION schema tables (idempotent, preserve existing data)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ACTION.ALERT (
  ALERT_ID          STRING    NOT NULL PRIMARY KEY,
  ASSET_ID          STRING    NOT NULL,
  ONSET_TS          TIMESTAMP_TZ NOT NULL,
  SEVERITY          STRING    NOT NULL,
  CONFIDENCE        FLOAT,
  FAILURE_PROBABILITY FLOAT,
  PREDICTED_MODE    STRING,
  OEE_IMPACT_EST    FLOAT,
  STATUS            STRING    NOT NULL DEFAULT 'NEW',
  EVIDENCE          VARIANT
);

CREATE TABLE IF NOT EXISTS ACTION.WORK_ORDER (
  WO_ID             STRING    NOT NULL PRIMARY KEY,
  ALERT_ID          STRING,
  ASSET_ID          STRING    NOT NULL,
  PRIORITY          STRING,
  STATE             STRING    NOT NULL DEFAULT 'DRAFT',
  TITLE             STRING,
  DESCRIPTION       STRING,
  EVIDENCE          VARIANT,
  GITHUB_ISSUE_URL  STRING,
  APPROVED_BY       STRING,
  APPROVED_TS       TIMESTAMP_TZ,
  CLOSE_REASON      STRING,
  CLOSED_AT         TIMESTAMP_TZ
);

CREATE TABLE IF NOT EXISTS ACTION.WORK_ORDER_OUTBOX (
  OUTBOX_ID         STRING    NOT NULL PRIMARY KEY,
  WO_ID             STRING    NOT NULL,
  TARGET            STRING    NOT NULL,
  PAYLOAD           VARIANT,
  ATTEMPTS          NUMBER    DEFAULT 0,
  LAST_ERROR        STRING,
  STATUS            STRING    NOT NULL DEFAULT 'PENDING'
);

CREATE TABLE IF NOT EXISTS ACTION.ACTION_AUDIT (
  AUDIT_ID          STRING    NOT NULL PRIMARY KEY,
  TS                TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  ACTOR             STRING    NOT NULL,
  ACTION            STRING    NOT NULL,
  OBJECT_REF        STRING,
  DETAIL            VARIANT
);

CREATE TABLE IF NOT EXISTS ACTION.PURCHASE_REQUISITION (
  REQ_ID            STRING    NOT NULL PRIMARY KEY,
  WO_ID             STRING,
  PART_ID           STRING    NOT NULL,
  QTY               NUMBER    NOT NULL,
  EST_UNIT_COST     FLOAT,
  EST_TOTAL         FLOAT,
  SUPPLIER_NAME     STRING,
  LEAD_TIME_DAYS    NUMBER,
  RFQ_TEXT          STRING,
  STATUS            STRING    NOT NULL DEFAULT 'PENDING_QUOTE',
  CREATED_TS        TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- =============================================================================
-- PART B: SCORE_ALERTS procedure
-- Reads DT_ASSET_HEALTH + ML.ANOMALY_EVENTS, applies PRIORITY_SCORE +
-- CONFIDENCE formulas, dedup rule, inserts/updates ACTION.ALERT.
-- =============================================================================

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.SCORE_ALERTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
  MERGE INTO AEGIS_OEE.ACTION.ALERT tgt
  USING (
    WITH asset_health AS (
      SELECT
        h.ASSET_ID, h.FAILURE_PROBABILITY_24H, h.PREDICTED_MODE, h.ANOMALY_DISTANCE,
        h.HEALTH_SCORE, h.RISK_LEVEL, h.LAST_READING_TS,
        a.CRITICALITY, a.ASSET_TYPE, a.LINE_ID
      FROM AEGIS_OEE.FEATURES.DT_ASSET_HEALTH h
      JOIN AEGIS_OEE.CORE.ASSET a ON h.ASSET_ID = a.ASSET_ID
      WHERE h.PREDICTED_MODE IS NOT NULL AND h.FAILURE_PROBABILITY_24H > 0.05
    ),
    anomaly_stats AS (
      SELECT ASSET_ID,
        COUNT(CASE WHEN IS_ANOMALY THEN 1 END) AS anomaly_windows_6h,
        COUNT(*) AS total_windows_6h
      FROM AEGIS_OEE.ML.ANOMALY_EVENTS
      WHERE TS >= DATEADD('HOUR', -6, CURRENT_TIMESTAMP())
      GROUP BY ASSET_ID
    ),
    data_quality AS (
      SELECT ASSET_ID,
        COUNT(CASE WHEN QUALITY_FLAG != 'OK' THEN 1 END)::FLOAT / NULLIF(COUNT(*), 0) AS bad_pct
      FROM AEGIS_OEE.RAW.SENSOR_TELEMETRY
      WHERE TS >= DATEADD('HOUR', -6, CURRENT_TIMESTAMP())
      GROUP BY ASSET_ID
    ),
    scored AS (
      SELECT ah.ASSET_ID, ah.PREDICTED_MODE, ah.FAILURE_PROBABILITY_24H, ah.ANOMALY_DISTANCE,
        ah.HEALTH_SCORE, ah.RISK_LEVEL, ah.CRITICALITY, ah.LAST_READING_TS,
        LEAST(1.0, ah.ANOMALY_DISTANCE / 10.0) AS model_confidence,
        CASE WHEN COALESCE(dq.bad_pct, 0) > 0.2 THEN 0.0 ELSE 1.0 - COALESCE(dq.bad_pct, 0) END AS data_quality_score,
        LEAST(1.0, COALESCE(ans.anomaly_windows_6h, 0)::FLOAT / GREATEST(COALESCE(ans.total_windows_6h, 1), 1)) AS evidence_agreement,
        COALESCE(ans.anomaly_windows_6h, 0)::FLOAT / GREATEST(COALESCE(ans.total_windows_6h, 1), 1) AS persistence,
        CASE WHEN ah.FAILURE_PROBABILITY_24H >= 0.7 THEN 1.0 WHEN ah.FAILURE_PROBABILITY_24H >= 0.3 THEN 0.6 ELSE 0.3 END AS imminence,
        CASE WHEN ah.HEALTH_SCORE <= 30 THEN 0.3 WHEN ah.HEALTH_SCORE <= 50 THEN 0.2 WHEN ah.HEALTH_SCORE <= 70 THEN 0.1 ELSE 0.05 END AS oee_impact_est
      FROM asset_health ah
      LEFT JOIN anomaly_stats ans ON ah.ASSET_ID = ans.ASSET_ID
      LEFT JOIN data_quality dq ON ah.ASSET_ID = dq.ASSET_ID
    ),
    final_scored AS (
      SELECT s.*,
        s.model_confidence * s.data_quality_score * s.evidence_agreement * s.persistence AS confidence,
        s.FAILURE_PROBABILITY_24H * (s.CRITICALITY / 5.0) * s.imminence * s.oee_impact_est AS priority_score
      FROM scored s
    )
    SELECT
      'ALT_' || f.ASSET_ID || '_' || f.PREDICTED_MODE AS alert_id,
      f.ASSET_ID, f.LAST_READING_TS AS onset_ts,
      CASE WHEN f.priority_score >= 0.5 THEN 'P1' WHEN f.priority_score >= 0.25 THEN 'P2' ELSE 'P3' END AS severity,
      f.confidence, f.FAILURE_PROBABILITY_24H AS failure_probability, f.PREDICTED_MODE AS predicted_mode, f.oee_impact_est,
      CASE WHEN f.confidence < 0.5 THEN 'NEW' ELSE 'TRIAGED' END AS computed_status,
      OBJECT_CONSTRUCT(
        'asset_id', f.ASSET_ID, 'model_version', 'AD_v1_ZSCORE_v1',
        'prediction', OBJECT_CONSTRUCT('failure_probability_24h', f.FAILURE_PROBABILITY_24H, 'predicted_mode', f.PREDICTED_MODE),
        'anomaly', OBJECT_CONSTRUCT('distance', f.ANOMALY_DISTANCE, 'persistence', f.persistence),
        'oee_impact', OBJECT_CONSTRUCT('component', 'availability', 'est_loss_pct', f.oee_impact_est),
        'health_score', f.HEALTH_SCORE, 'risk_level', f.RISK_LEVEL, 'priority_score', f.priority_score
      ) AS evidence
    FROM final_scored f
  ) src
  ON tgt.ALERT_ID = src.alert_id AND tgt.STATUS NOT IN ('CLOSED', 'SUPPRESSED')
  WHEN MATCHED THEN UPDATE SET
    SEVERITY = src.severity, CONFIDENCE = src.confidence, FAILURE_PROBABILITY = src.failure_probability,
    OEE_IMPACT_EST = src.oee_impact_est, EVIDENCE = src.evidence
  WHEN NOT MATCHED THEN INSERT (ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE, FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE)
  VALUES (src.alert_id, src.ASSET_ID, src.onset_ts, src.severity, src.confidence, src.failure_probability, src.predicted_mode, src.oee_impact_est, src.computed_status, src.evidence);

  RETURN 'SCORE_ALERTS complete: ' || (SELECT COUNT(*) FROM AEGIS_OEE.ACTION.ALERT WHERE STATUS IN ('NEW','TRIAGED'))::STRING || ' open alerts';
END;
$$;

-- =============================================================================
-- PART C: Scheduled task — every 5 minutes, SUSPENDED until tests pass
-- =============================================================================

CREATE OR REPLACE TASK AEGIS_OEE.ACTION.TASK_SCORE_ALERTS
  WAREHOUSE = AEGIS_WH
  SCHEDULE  = '5 MINUTE'
AS
  CALL AEGIS_OEE.ACTION.SCORE_ALERTS();

-- Resume after guardrail tests pass:
-- ALTER TASK AEGIS_OEE.ACTION.TASK_SCORE_ALERTS RESUME;
