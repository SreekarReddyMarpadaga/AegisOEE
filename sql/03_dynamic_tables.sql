-- =============================================================
-- Mission 02 — Dynamic Tables (FEATURES layer)
-- Idempotent: safe to re-run at any time.
-- All DTs on AEGIS_WH; designed for INCREMENTAL refresh.
-- =============================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- -------------------------------------------------------
-- 1. FEATURES.DT_SENSOR_CLEAN
--    Dedupe by (asset_id, ts), quality_flag handling, clamps.
--    Uses GROUP BY + MAX_BY for incremental-friendly dedup.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FEATURES.DT_SENSOR_CLEAN
  TARGET_LAG = '1 minute'
  WAREHOUSE = AEGIS_WH
AS
WITH deduped AS (
  SELECT
    asset_id,
    ts,
    MAX_BY(quality_flag, ingest_ts)       AS quality_flag,
    MAX_BY(vibration_rms, ingest_ts)      AS vibration_rms_raw,
    MAX_BY(vibration_kurtosis, ingest_ts) AS vibration_kurtosis_raw,
    MAX_BY(temp_c, ingest_ts)             AS temp_c_raw,
    MAX_BY(rpm, ingest_ts)                AS rpm_raw,
    MAX_BY(load_pct, ingest_ts)           AS load_pct_raw,
    MAX(ingest_ts)                        AS ingest_ts
  FROM RAW.SENSOR_TELEMETRY
  GROUP BY asset_id, ts
)
SELECT
  asset_id,
  ts,
  quality_flag,
  CASE WHEN quality_flag = 'OK'
       THEN GREATEST(LEAST(vibration_rms_raw, 50.0), 0.0) END        AS vibration_rms,
  CASE WHEN quality_flag = 'OK'
       THEN vibration_kurtosis_raw END                                AS vibration_kurtosis,
  CASE WHEN quality_flag = 'OK'
       THEN GREATEST(LEAST(temp_c_raw, 200.0), 0.0) END              AS temp_c,
  CASE WHEN quality_flag = 'OK'
       THEN GREATEST(LEAST(rpm_raw, 20000.0), 0.0) END               AS rpm,
  CASE WHEN quality_flag = 'OK'
       THEN GREATEST(LEAST(load_pct_raw, 100.0), 0.0) END            AS load_pct,
  ingest_ts
FROM deduped;

-- -------------------------------------------------------
-- 2. FEATURES.DT_SENSOR_1MIN
--    Per-asset per-minute aggregates (mean/max/stddev).
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FEATURES.DT_SENSOR_1MIN
  TARGET_LAG = '1 minute'
  WAREHOUSE = AEGIS_WH
AS
SELECT
  asset_id,
  DATE_TRUNC('MINUTE', ts)   AS minute_ts,
  AVG(vibration_rms)         AS vib_rms_mean,
  MAX(vibration_rms)         AS vib_rms_max,
  STDDEV(vibration_rms)      AS vib_rms_stddev,
  AVG(vibration_kurtosis)    AS vib_kurt_mean,
  MAX(vibration_kurtosis)    AS vib_kurt_max,
  AVG(temp_c)                AS temp_c_mean,
  MAX(temp_c)                AS temp_c_max,
  STDDEV(temp_c)             AS temp_c_stddev,
  AVG(rpm)                   AS rpm_mean,
  MAX(rpm)                   AS rpm_max,
  STDDEV(rpm)                AS rpm_stddev,
  AVG(load_pct)              AS load_pct_mean,
  MAX(load_pct)              AS load_pct_max,
  STDDEV(load_pct)           AS load_pct_stddev,
  COUNT(*)                   AS sample_count
FROM FEATURES.DT_SENSOR_CLEAN
WHERE quality_flag = 'OK'
GROUP BY asset_id, DATE_TRUNC('MINUTE', ts);

-- -------------------------------------------------------
-- 3. FEATURES.DT_SENSOR_FEATURES_15MIN
--    15-min aggregates with slopes, z-scores, residuals.
--    Uses GROUP BY + JOIN (no window functions) for INCREMENTAL.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FEATURES.DT_SENSOR_FEATURES_15MIN
  TARGET_LAG = '5 minutes'
  WAREHOUSE = AEGIS_WH
AS
WITH agg_15m AS (
  SELECT
    asset_id,
    TIME_SLICE(minute_ts::TIMESTAMP_NTZ, 15, 'MINUTE', 'START')  AS window_ts,
    AVG(vib_rms_mean)                              AS vib_rms_mean,
    MAX(vib_rms_max)                               AS vib_rms_max,
    STDDEV(vib_rms_mean)                           AS vib_rms_stddev,
    AVG(vib_kurt_mean)                             AS kurtosis_mean,
    MAX(vib_kurt_max)                              AS kurtosis_max,
    AVG(temp_c_mean)                               AS temp_c_mean,
    MAX(temp_c_max)                                AS temp_c_max,
    STDDEV(temp_c_mean)                            AS temp_c_stddev,
    AVG(rpm_mean)                                  AS rpm_mean,
    VARIANCE(rpm_mean)                             AS rpm_variance,
    AVG(load_pct_mean)                             AS load_pct_mean,
    SUM(sample_count)                              AS sample_count,
    -- Slopes via linear regression within each 15-min bucket
    REGR_SLOPE(vib_rms_mean, EXTRACT(EPOCH FROM minute_ts))   AS vib_rms_slope,
    REGR_SLOPE(temp_c_mean,  EXTRACT(EPOCH FROM minute_ts))   AS temp_c_slope,
    REGR_SLOPE(rpm_mean,     EXTRACT(EPOCH FROM minute_ts))   AS rpm_slope
  FROM FEATURES.DT_SENSOR_1MIN
  GROUP BY asset_id, TIME_SLICE(minute_ts, 15, 'MINUTE', 'START')
),
baseline AS (
  SELECT
    asset_id,
    AVG(vib_rms_mean)                    AS bl_vib_mean,
    NULLIF(STDDEV(vib_rms_mean), 0)      AS bl_vib_std,
    AVG(temp_c_mean)                     AS bl_temp_mean,
    NULLIF(STDDEV(temp_c_mean), 0)       AS bl_temp_std,
    AVG(rpm_mean)                        AS bl_rpm_mean,
    NULLIF(STDDEV(rpm_mean), 0)          AS bl_rpm_std
  FROM FEATURES.DT_SENSOR_1MIN
  GROUP BY asset_id
)
SELECT
  a.asset_id,
  a.window_ts,
  a.vib_rms_mean,
  a.vib_rms_max,
  a.vib_rms_stddev,
  a.vib_rms_slope,
  a.kurtosis_mean,
  a.kurtosis_max,
  a.temp_c_mean,
  a.temp_c_max,
  a.temp_c_stddev,
  a.temp_c_slope,
  a.rpm_mean,
  a.rpm_variance,
  a.rpm_slope,
  a.load_pct_mean,
  -- Temp-to-load residual: deviation from expected thermal behavior
  a.temp_c_mean - (a.load_pct_mean * 0.5 + 20.0) AS temp_load_residual,
  -- Baseline z-scores
  (a.vib_rms_mean - b.bl_vib_mean)  / b.bl_vib_std  AS vib_rms_zscore,
  (a.temp_c_mean  - b.bl_temp_mean) / b.bl_temp_std  AS temp_c_zscore,
  (a.rpm_mean     - b.bl_rpm_mean)  / b.bl_rpm_std   AS rpm_zscore,
  a.sample_count
FROM agg_15m a
JOIN baseline b ON a.asset_id = b.asset_id;

-- -------------------------------------------------------
-- 4. FEATURES.DT_TELEMETRY_CONTEXT
--    Convergence join: latest features + production + maintenance + downtime.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FEATURES.DT_TELEMETRY_CONTEXT
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
WITH latest_ts AS (
  SELECT asset_id, MAX(window_ts) AS max_window_ts
  FROM FEATURES.DT_SENSOR_FEATURES_15MIN
  GROUP BY asset_id
),
latest_features AS (
  SELECT f.*
  FROM FEATURES.DT_SENSOR_FEATURES_15MIN f
  JOIN latest_ts lt ON f.asset_id = lt.asset_id AND f.window_ts = lt.max_window_ts
),
active_order AS (
  SELECT
    po.order_id, po.line_id, po.product_code, po.planned_qty,
    po.ideal_cycle_s, po.planned_start_ts, po.planned_end_ts
  FROM CORE.PRODUCTION_ORDER po
  WHERE CURRENT_TIMESTAMP() BETWEEN po.planned_start_ts AND po.planned_end_ts
),
last_maintenance AS (
  SELECT asset_id,
    MAX_BY(wo_hist_id, completed_ts)       AS last_wo_id,
    MAX(completed_ts)                      AS last_maintenance_ts,
    MAX_BY(failure_code, completed_ts)     AS last_failure_code,
    MAX_BY(action_taken, completed_ts)     AS last_action
  FROM CORE.MAINTENANCE_HISTORY
  GROUP BY asset_id
),
open_downtime AS (
  SELECT
    asset_id,
    MIN(start_ts)   AS downtime_start_ts,
    MAX(end_ts)     AS downtime_end_ts,
    MAX(reason_code) AS reason_code,
    MAX(failure_mode) AS failure_mode,
    SUM(minutes)     AS downtime_min
  FROM CORE.DOWNTIME_EVENT
  WHERE is_planned = FALSE
    AND end_ts >= CURRENT_TIMESTAMP()
  GROUP BY asset_id
)
SELECT
  a.asset_id,
  ast.line_id,
  ast.site_id,
  ast.asset_type,
  ast.criticality,
  -- Latest sensor features
  lf.window_ts            AS last_feature_ts,
  lf.vib_rms_mean,
  lf.vib_rms_max,
  lf.vib_rms_slope,
  lf.kurtosis_mean,
  lf.temp_c_mean,
  lf.temp_c_max,
  lf.temp_c_slope,
  lf.rpm_mean,
  lf.rpm_variance,
  lf.load_pct_mean,
  lf.temp_load_residual,
  lf.vib_rms_zscore,
  lf.temp_c_zscore,
  lf.rpm_zscore,
  -- Active production order
  ao.order_id             AS active_order_id,
  ao.product_code         AS active_product,
  ao.planned_qty,
  ao.ideal_cycle_s        AS order_ideal_cycle_s,
  -- Last maintenance
  lm.last_wo_id,
  lm.last_maintenance_ts,
  lm.last_failure_code,
  lm.last_action,
  -- Open downtime
  od.downtime_start_ts,
  od.reason_code          AS downtime_reason,
  od.failure_mode         AS downtime_failure_mode,
  od.downtime_min
FROM CORE.ASSET ast
CROSS JOIN (SELECT DISTINCT asset_id FROM latest_ts) a
JOIN latest_features lf ON a.asset_id = lf.asset_id
LEFT JOIN active_order ao ON ast.line_id = ao.line_id
LEFT JOIN last_maintenance lm ON a.asset_id = lm.asset_id
LEFT JOIN open_downtime od ON a.asset_id = od.asset_id
WHERE ast.asset_id = a.asset_id;
