-- =============================================================
-- Mission 03 — ML Recall Check / Episode-Level Evaluation
-- Evaluates anomaly detection against ground truth failures.
-- =============================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- -------------------------------------------------------
-- 1. ML metrics table
-- -------------------------------------------------------
CREATE OR REPLACE TABLE TEST.ML_METRICS (
  METRIC_NAME    STRING,
  METRIC_VALUE   FLOAT,
  DETAIL         STRING,
  EVALUATED_AT   TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- -------------------------------------------------------
-- 2. Episode-level evaluation (ML anomaly detection models)
--    Only episodes in scoring window (>= 2026-07-15)
-- -------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TEST.TMP_EPISODE_EVAL AS
WITH episodes AS (
  SELECT
    g.FAILURE_ID,
    g.ASSET_ID,
    g.FAILURE_MODE,
    g.DEGRADATION_START_TS,
    g.FAILURE_TS,
    g.SEVERITY
  FROM TEST.GROUND_TRUTH_FAILURES g
  WHERE g.DEGRADATION_START_TS >= '2026-07-15'::TIMESTAMP_TZ
),
ml_detections AS (
  SELECT
    e.FAILURE_ID,
    MIN(a.TS) AS earliest_detection_ts,
    COUNT(*) AS anomaly_hits
  FROM episodes e
  JOIN ML.ANOMALY_EVENTS a
    ON a.ASSET_ID = e.ASSET_ID
    AND a.TS >= e.DEGRADATION_START_TS
    AND a.TS <= e.FAILURE_TS
    AND a.IS_ANOMALY = TRUE
    AND a.SERIES_NAME IN ('vibration_rms', 'temp_c', 'rpm')
  GROUP BY e.FAILURE_ID
)
SELECT
  e.FAILURE_ID,
  e.ASSET_ID,
  e.FAILURE_MODE,
  e.DEGRADATION_START_TS,
  e.FAILURE_TS,
  e.SEVERITY,
  CASE WHEN d.FAILURE_ID IS NOT NULL THEN TRUE ELSE FALSE END AS detected,
  d.earliest_detection_ts,
  d.anomaly_hits,
  CASE WHEN d.earliest_detection_ts IS NOT NULL
    THEN DATEDIFF('HOUR', d.earliest_detection_ts, e.FAILURE_TS)
    ELSE NULL
  END AS lead_time_hours
FROM episodes e
LEFT JOIN ml_detections d ON e.FAILURE_ID = d.FAILURE_ID;

-- Show per-episode results
SELECT * FROM TEST.TMP_EPISODE_EVAL ORDER BY DEGRADATION_START_TS;

-- -------------------------------------------------------
-- 3. Z-score fallback episode evaluation (all episodes)
-- -------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TEST.TMP_ZSCORE_EVAL AS
WITH zscore_detections AS (
  SELECT
    g.FAILURE_ID,
    MIN(a.TS) AS earliest_detection_ts,
    COUNT(*) AS anomaly_hits
  FROM TEST.GROUND_TRUTH_FAILURES g
  JOIN ML.ANOMALY_EVENTS a
    ON a.ASSET_ID = g.ASSET_ID
    AND a.TS >= g.DEGRADATION_START_TS
    AND a.TS <= g.FAILURE_TS
    AND a.IS_ANOMALY = TRUE
    AND a.SERIES_NAME LIKE 'zscore_%'
  GROUP BY g.FAILURE_ID
)
SELECT
  g.FAILURE_ID,
  g.ASSET_ID,
  g.FAILURE_MODE,
  g.DEGRADATION_START_TS,
  g.FAILURE_TS,
  g.SEVERITY,
  CASE WHEN zd.FAILURE_ID IS NOT NULL THEN TRUE ELSE FALSE END AS detected,
  zd.earliest_detection_ts,
  zd.anomaly_hits,
  CASE WHEN zd.earliest_detection_ts IS NOT NULL
    THEN DATEDIFF('HOUR', zd.earliest_detection_ts, g.FAILURE_TS)
    ELSE NULL
  END AS lead_time_hours
FROM TEST.GROUND_TRUTH_FAILURES g
LEFT JOIN zscore_detections zd ON g.FAILURE_ID = zd.FAILURE_ID;

-- Show z-score results
SELECT * FROM TEST.TMP_ZSCORE_EVAL ORDER BY DEGRADATION_START_TS;

-- -------------------------------------------------------
-- 4. Combined evaluation (ML + z-score, any detection)
-- -------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TEST.TMP_COMBINED_EVAL AS
WITH combined_detections AS (
  SELECT
    g.FAILURE_ID,
    MIN(a.TS) AS earliest_detection_ts,
    COUNT(*) AS anomaly_hits
  FROM TEST.GROUND_TRUTH_FAILURES g
  JOIN ML.ANOMALY_EVENTS a
    ON a.ASSET_ID = g.ASSET_ID
    AND a.TS >= g.DEGRADATION_START_TS
    AND a.TS <= g.FAILURE_TS
    AND a.IS_ANOMALY = TRUE
  GROUP BY g.FAILURE_ID
)
SELECT
  g.FAILURE_ID,
  g.ASSET_ID,
  g.FAILURE_MODE,
  g.DEGRADATION_START_TS,
  g.FAILURE_TS,
  g.SEVERITY,
  CASE WHEN cd.FAILURE_ID IS NOT NULL THEN TRUE ELSE FALSE END AS detected,
  cd.earliest_detection_ts,
  cd.anomaly_hits,
  CASE WHEN cd.earliest_detection_ts IS NOT NULL
    THEN DATEDIFF('HOUR', cd.earliest_detection_ts, g.FAILURE_TS)
    ELSE NULL
  END AS lead_time_hours
FROM TEST.GROUND_TRUTH_FAILURES g
LEFT JOIN combined_detections cd ON g.FAILURE_ID = cd.FAILURE_ID;

SELECT * FROM TEST.TMP_COMBINED_EVAL ORDER BY DEGRADATION_START_TS;

-- -------------------------------------------------------
-- 5. Baseline comparison: fixed threshold (z > 2.0, no persistence)
-- -------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TEST.TMP_BASELINE_EVAL AS
WITH baseline_detections AS (
  SELECT
    g.FAILURE_ID,
    MIN(f.WINDOW_TS) AS earliest_detection_ts,
    COUNT(*) AS anomaly_hits
  FROM TEST.GROUND_TRUTH_FAILURES g
  JOIN FEATURES.DT_SENSOR_FEATURES_15MIN f
    ON f.ASSET_ID = g.ASSET_ID
    AND f.WINDOW_TS >= g.DEGRADATION_START_TS
    AND f.WINDOW_TS <= g.FAILURE_TS
    AND (ABS(f.VIB_RMS_ZSCORE) > 2.0
      OR ABS(f.TEMP_C_ZSCORE) > 2.0
      OR ABS(f.RPM_ZSCORE) > 2.0)
  GROUP BY g.FAILURE_ID
)
SELECT
  g.FAILURE_ID,
  g.ASSET_ID,
  g.FAILURE_MODE,
  g.SEVERITY,
  CASE WHEN bd.FAILURE_ID IS NOT NULL THEN TRUE ELSE FALSE END AS detected,
  bd.earliest_detection_ts,
  bd.anomaly_hits,
  CASE WHEN bd.earliest_detection_ts IS NOT NULL
    THEN DATEDIFF('HOUR', bd.earliest_detection_ts, g.FAILURE_TS)
    ELSE NULL
  END AS lead_time_hours
FROM TEST.GROUND_TRUTH_FAILURES g
LEFT JOIN baseline_detections bd ON g.FAILURE_ID = bd.FAILURE_ID;

SELECT * FROM TEST.TMP_BASELINE_EVAL ORDER BY FAILURE_ID;

-- -------------------------------------------------------
-- 6. Compute aggregate metrics and persist
-- -------------------------------------------------------
DELETE FROM TEST.ML_METRICS;

-- ML model metrics (out-of-sample episodes only)
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'ml_recall', SUM(CASE WHEN detected THEN 1 ELSE 0 END)::FLOAT / COUNT(*),
       'ML anomaly detection recall (episodes >= 2026-07-15)'
FROM TEST.TMP_EPISODE_EVAL;

INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'ml_median_lead_time_hours', MEDIAN(lead_time_hours),
       'Median lead time in hours for ML-detected episodes'
FROM TEST.TMP_EPISODE_EVAL
WHERE detected;

-- Z-score fallback metrics (all episodes)
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'zscore_recall', SUM(CASE WHEN detected THEN 1 ELSE 0 END)::FLOAT / COUNT(*),
       'Z-score persistent anomaly recall (all 10 episodes)'
FROM TEST.TMP_ZSCORE_EVAL;

INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'zscore_median_lead_time_hours', MEDIAN(lead_time_hours),
       'Median lead time in hours for z-score detected episodes'
FROM TEST.TMP_ZSCORE_EVAL
WHERE detected;

-- Combined metrics (all episodes)
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'combined_recall', SUM(CASE WHEN detected THEN 1 ELSE 0 END)::FLOAT / COUNT(*),
       'Combined (ML + z-score) recall (all episodes)'
FROM TEST.TMP_COMBINED_EVAL;

INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'combined_median_lead_time_hours', MEDIAN(lead_time_hours),
       'Median lead time in hours for combined detections'
FROM TEST.TMP_COMBINED_EVAL
WHERE detected;

-- Baseline metrics
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'baseline_recall', SUM(CASE WHEN detected THEN 1 ELSE 0 END)::FLOAT / COUNT(*),
       'Baseline (z>2.0, no persistence) recall'
FROM TEST.TMP_BASELINE_EVAL;

INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'baseline_median_lead_time_hours', MEDIAN(lead_time_hours),
       'Baseline median lead time hours'
FROM TEST.TMP_BASELINE_EVAL
WHERE detected;

-- False alerts per asset-day (ML models)
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'ml_false_alerts_per_asset_day',
  COUNT(*)::FLOAT / (
    SELECT COUNT(DISTINCT ASSET_ID) * COUNT(DISTINCT TS::DATE)
    FROM ML.ANOMALY_EVENTS
    WHERE SERIES_NAME IN ('vibration_rms','temp_c','rpm')
      AND TS >= '2026-07-15'::TIMESTAMP_TZ
  ),
  'False anomaly alerts not overlapping any ground truth episode'
FROM ML.ANOMALY_EVENTS a
WHERE a.IS_ANOMALY = TRUE
  AND a.SERIES_NAME IN ('vibration_rms','temp_c','rpm')
  AND a.TS >= '2026-07-15'::TIMESTAMP_TZ
  AND NOT EXISTS (
    SELECT 1 FROM TEST.GROUND_TRUTH_FAILURES g
    WHERE g.ASSET_ID = a.ASSET_ID
      AND a.TS >= g.DEGRADATION_START_TS
      AND a.TS <= g.FAILURE_TS
  );

-- Golden path check: F010 CNC_01_SPINDLE BEARING_WEAR
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT 'golden_path_lead_time_hours',
  COALESCE(ce.lead_time_hours, -1),
  'F010 CNC_01_SPINDLE BEARING_WEAR lead time (target >= 48h)'
FROM TEST.TMP_COMBINED_EVAL ce
WHERE ce.FAILURE_ID = 'F010';

-- Per-mode F1 (simplified: recall per mode from combined)
INSERT INTO TEST.ML_METRICS (METRIC_NAME, METRIC_VALUE, DETAIL)
SELECT
  'mode_recall_' || FAILURE_MODE,
  SUM(CASE WHEN detected THEN 1 ELSE 0 END)::FLOAT / COUNT(*),
  'Recall for failure mode ' || FAILURE_MODE
FROM TEST.TMP_COMBINED_EVAL
GROUP BY FAILURE_MODE;

-- -------------------------------------------------------
-- 7. Print final metrics
-- -------------------------------------------------------
SELECT * FROM TEST.ML_METRICS ORDER BY METRIC_NAME;
