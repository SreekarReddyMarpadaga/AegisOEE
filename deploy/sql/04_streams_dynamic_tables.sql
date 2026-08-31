-- =============================================================================
-- 04_streams_dynamic_tables.sql — Streams, Dynamic Tables, and Views
-- Exported from live AEGIS_OEE. 7 DTs + 2 streams + 5 views.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- ── Streams (append-only on raw ingest tables) ──

CREATE OR REPLACE STREAM RAW.STR_SENSOR_TELEMETRY
  ON TABLE AEGIS_OEE.RAW.SENSOR_TELEMETRY
  APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM RAW.STR_PRODUCTION_EVENT
  ON TABLE AEGIS_OEE.RAW.PRODUCTION_EVENT
  APPEND_ONLY = TRUE;

-- ── Dynamic Tables: FEATURES pipeline ──
-- Order matters: CLEAN → 1MIN → 15MIN → CONTEXT → ASSET_HEALTH

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.FEATURES.DT_SENSOR_CLEAN
  TARGET_LAG = '1 minute'
  WAREHOUSE = AEGIS_WH
AS
WITH deduped AS (
  SELECT
    asset_id, ts,
    MAX_BY(quality_flag, ingest_ts)       AS quality_flag,
    MAX_BY(vibration_rms, ingest_ts)      AS vibration_rms_raw,
    MAX_BY(vibration_kurtosis, ingest_ts) AS vibration_kurtosis_raw,
    MAX_BY(temp_c, ingest_ts)             AS temp_c_raw,
    MAX_BY(rpm, ingest_ts)                AS rpm_raw,
    MAX_BY(load_pct, ingest_ts)           AS load_pct_raw,
    MAX(ingest_ts)                        AS ingest_ts
  FROM AEGIS_OEE.RAW.SENSOR_TELEMETRY
  GROUP BY asset_id, ts
)
SELECT
  asset_id, ts, quality_flag,
  CASE WHEN quality_flag = 'OK' THEN GREATEST(LEAST(vibration_rms_raw, 50.0), 0.0) END        AS vibration_rms,
  CASE WHEN quality_flag = 'OK' THEN vibration_kurtosis_raw END                                AS vibration_kurtosis,
  CASE WHEN quality_flag = 'OK' THEN GREATEST(LEAST(temp_c_raw, 200.0), 0.0) END              AS temp_c,
  CASE WHEN quality_flag = 'OK' THEN GREATEST(LEAST(rpm_raw, 20000.0), 0.0) END               AS rpm,
  CASE WHEN quality_flag = 'OK' THEN GREATEST(LEAST(load_pct_raw, 100.0), 0.0) END            AS load_pct,
  ingest_ts
FROM deduped;

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.FEATURES.DT_SENSOR_1MIN
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
FROM AEGIS_OEE.FEATURES.DT_SENSOR_CLEAN
WHERE quality_flag = 'OK'
GROUP BY asset_id, DATE_TRUNC('MINUTE', ts);

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN
  TARGET_LAG = '5 minutes'
  WAREHOUSE = AEGIS_WH
AS
WITH agg_15m AS (
  SELECT
    asset_id,
    TIME_SLICE(minute_ts::TIMESTAMP_NTZ, 15, 'MINUTE', 'START') AS window_ts,
    AVG(vib_rms_mean)       AS vib_rms_mean,
    MAX(vib_rms_max)        AS vib_rms_max,
    STDDEV(vib_rms_mean)    AS vib_rms_stddev,
    AVG(vib_kurt_mean)      AS kurtosis_mean,
    MAX(vib_kurt_max)       AS kurtosis_max,
    AVG(temp_c_mean)        AS temp_c_mean,
    MAX(temp_c_max)         AS temp_c_max,
    STDDEV(temp_c_mean)     AS temp_c_stddev,
    AVG(rpm_mean)           AS rpm_mean,
    VARIANCE(rpm_mean)      AS rpm_variance,
    AVG(load_pct_mean)      AS load_pct_mean,
    SUM(sample_count)       AS sample_count,
    REGR_SLOPE(vib_rms_mean, EXTRACT(EPOCH FROM minute_ts)) AS vib_rms_slope,
    REGR_SLOPE(temp_c_mean,  EXTRACT(EPOCH FROM minute_ts)) AS temp_c_slope,
    REGR_SLOPE(rpm_mean,     EXTRACT(EPOCH FROM minute_ts)) AS rpm_slope
  FROM AEGIS_OEE.FEATURES.DT_SENSOR_1MIN
  GROUP BY asset_id, TIME_SLICE(minute_ts::TIMESTAMP_NTZ, 15, 'MINUTE', 'START')
),
baseline AS (
  SELECT
    asset_id,
    AVG(vib_rms_mean)               AS bl_vib_mean,
    NULLIF(STDDEV(vib_rms_mean), 0) AS bl_vib_std,
    AVG(temp_c_mean)                AS bl_temp_mean,
    NULLIF(STDDEV(temp_c_mean), 0)  AS bl_temp_std,
    AVG(rpm_mean)                   AS bl_rpm_mean,
    NULLIF(STDDEV(rpm_mean), 0)     AS bl_rpm_std
  FROM AEGIS_OEE.FEATURES.DT_SENSOR_1MIN
  GROUP BY asset_id
)
SELECT
  a.asset_id, a.window_ts,
  a.vib_rms_mean, a.vib_rms_max, a.vib_rms_stddev, a.vib_rms_slope,
  a.kurtosis_mean, a.kurtosis_max,
  a.temp_c_mean, a.temp_c_max, a.temp_c_stddev, a.temp_c_slope,
  a.rpm_mean, a.rpm_variance, a.rpm_slope,
  a.load_pct_mean,
  a.temp_c_mean - (a.load_pct_mean * 0.5 + 20.0) AS temp_load_residual,
  (a.vib_rms_mean - b.bl_vib_mean)  / b.bl_vib_std  AS vib_rms_zscore,
  (a.temp_c_mean  - b.bl_temp_mean) / b.bl_temp_std  AS temp_c_zscore,
  (a.rpm_mean     - b.bl_rpm_mean)  / b.bl_rpm_std   AS rpm_zscore,
  a.sample_count
FROM agg_15m a
JOIN baseline b ON a.asset_id = b.asset_id;

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.FEATURES.DT_TELEMETRY_CONTEXT
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
WITH latest_ts AS (
  SELECT asset_id, MAX(window_ts) AS max_window_ts
  FROM AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN
  GROUP BY asset_id
),
latest_features AS (
  SELECT f.*
  FROM AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN f
  JOIN latest_ts lt ON f.asset_id = lt.asset_id AND f.window_ts = lt.max_window_ts
),
active_order AS (
  SELECT order_id, line_id, product_code, planned_qty, ideal_cycle_s, planned_start_ts, planned_end_ts
  FROM AEGIS_OEE.CORE.PRODUCTION_ORDER
  WHERE CURRENT_TIMESTAMP() BETWEEN planned_start_ts AND planned_end_ts
),
last_maintenance AS (
  SELECT asset_id,
    MAX_BY(wo_hist_id, completed_ts)   AS last_wo_id,
    MAX(completed_ts)                  AS last_maintenance_ts,
    MAX_BY(failure_code, completed_ts) AS last_failure_code,
    MAX_BY(action_taken, completed_ts) AS last_action
  FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY
  GROUP BY asset_id
),
open_downtime AS (
  SELECT asset_id,
    MIN(start_ts) AS downtime_start_ts, MAX(end_ts) AS downtime_end_ts,
    MAX(reason_code) AS reason_code, MAX(failure_mode) AS failure_mode,
    SUM(minutes) AS downtime_min
  FROM AEGIS_OEE.CORE.DOWNTIME_EVENT
  WHERE is_planned = FALSE AND end_ts >= CURRENT_TIMESTAMP()
  GROUP BY asset_id
)
SELECT
  a.asset_id, ast.line_id, ast.site_id, ast.asset_type, ast.criticality,
  lf.window_ts AS last_feature_ts,
  lf.vib_rms_mean, lf.vib_rms_max, lf.vib_rms_slope, lf.kurtosis_mean,
  lf.temp_c_mean, lf.temp_c_max, lf.temp_c_slope,
  lf.rpm_mean, lf.rpm_variance, lf.load_pct_mean,
  lf.temp_load_residual, lf.vib_rms_zscore, lf.temp_c_zscore, lf.rpm_zscore,
  ao.order_id AS active_order_id, ao.product_code AS active_product,
  ao.planned_qty, ao.ideal_cycle_s AS order_ideal_cycle_s,
  lm.last_wo_id, lm.last_maintenance_ts, lm.last_failure_code, lm.last_action,
  od.downtime_start_ts, od.reason_code AS downtime_reason,
  od.failure_mode AS downtime_failure_mode, od.downtime_min
FROM AEGIS_OEE.CORE.ASSET ast
CROSS JOIN (SELECT DISTINCT asset_id FROM latest_ts) a
JOIN latest_features lf ON a.asset_id = lf.asset_id
LEFT JOIN active_order ao ON ast.line_id = ao.line_id
LEFT JOIN last_maintenance lm ON a.asset_id = lm.asset_id
LEFT JOIN open_downtime od ON a.asset_id = od.asset_id
WHERE ast.asset_id = a.asset_id;

-- ── Dynamic Tables: SEMANTIC pipeline (OEE marts) ──

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
WITH shift_production AS (
  SELECT
    a.line_id, pe.asset_id, sc.shift_date, sc.shift_code,
    sc.planned_minutes, sc.planned_downtime_minutes, a.ideal_cycle_s,
    SUM(pe.produced_count) AS total_count,
    SUM(pe.good_count)     AS good_count,
    SUM(pe.reject_count)   AS reject_count
  FROM AEGIS_OEE.RAW.PRODUCTION_EVENT pe
  JOIN AEGIS_OEE.CORE.ASSET a          ON pe.asset_id = a.asset_id
  JOIN AEGIS_OEE.CORE.SHIFT_CALENDAR sc ON pe.ts >= sc.start_ts AND pe.ts < sc.end_ts
  GROUP BY a.line_id, pe.asset_id, sc.shift_date, sc.shift_code,
           sc.planned_minutes, sc.planned_downtime_minutes, a.ideal_cycle_s
),
shift_downtime AS (
  SELECT
    de.asset_id, sc.shift_date, sc.shift_code,
    SUM(GREATEST(0, DATEDIFF('SECOND',
      GREATEST(de.start_ts, sc.start_ts), LEAST(de.end_ts, sc.end_ts)) / 60.0
    )) AS unplanned_downtime_min
  FROM AEGIS_OEE.CORE.DOWNTIME_EVENT de
  JOIN AEGIS_OEE.CORE.SHIFT_CALENDAR sc
    ON de.start_ts < sc.end_ts AND de.end_ts > sc.start_ts AND de.is_planned = FALSE
  GROUP BY de.asset_id, sc.shift_date, sc.shift_code
)
SELECT
  sp.line_id, sp.asset_id, sp.shift_date, sp.shift_code,
  sp.planned_minutes, sp.planned_downtime_minutes,
  (sp.planned_minutes - sp.planned_downtime_minutes) AS planned_min,
  COALESCE(sd.unplanned_downtime_min, 0) AS downtime_min,
  GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes) - COALESCE(sd.unplanned_downtime_min, 0)) AS run_min,
  sp.total_count, sp.good_count, sp.reject_count, sp.ideal_cycle_s,
  CASE WHEN (sp.planned_minutes - sp.planned_downtime_minutes) > 0
    THEN GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0)))
         / (sp.planned_minutes - sp.planned_downtime_minutes) ELSE 0 END AS availability,
  CASE WHEN GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))) > 0
            AND sp.ideal_cycle_s IS NOT NULL AND sp.total_count > 0
    THEN LEAST(1.0, (sp.ideal_cycle_s * sp.total_count)
         / (GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))) * 60.0))
    ELSE 0 END AS performance,
  CASE WHEN sp.total_count > 0 THEN sp.good_count::FLOAT / sp.total_count ELSE 0 END AS quality,
  CASE WHEN (sp.planned_minutes - sp.planned_downtime_minutes) > 0 AND sp.total_count > 0 AND sp.ideal_cycle_s IS NOT NULL
    THEN (GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0)))
          / (sp.planned_minutes - sp.planned_downtime_minutes))
       * LEAST(1.0, (sp.ideal_cycle_s * sp.total_count)
          / (GREATEST(0, (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))) * 60.0))
       * (sp.good_count::FLOAT / sp.total_count)
    ELSE 0 END AS oee
FROM shift_production sp
LEFT JOIN shift_downtime sd
  ON sp.asset_id = sd.asset_id AND sp.shift_date = sd.shift_date AND sp.shift_code = sd.shift_code;

CREATE OR REPLACE DYNAMIC TABLE AEGIS_OEE.SEMANTIC.DT_OEE_LINE_DAY
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
SELECT
  line_id, shift_date,
  SUM(planned_min) AS planned_min, SUM(downtime_min) AS downtime_min,
  SUM(run_min) AS run_min, SUM(total_count) AS total_count,
  SUM(good_count) AS good_count, SUM(reject_count) AS reject_count,
  CASE WHEN SUM(planned_min) > 0 THEN SUM(run_min) / SUM(planned_min) ELSE 0 END AS availability,
  CASE WHEN SUM(run_min) > 0
    THEN LEAST(1.0, SUM(ideal_cycle_s * total_count) / (SUM(run_min) * 60.0)) ELSE 0 END AS performance,
  CASE WHEN SUM(total_count) > 0 THEN SUM(good_count)::FLOAT / SUM(total_count) ELSE 0 END AS quality,
  CASE WHEN SUM(planned_min) > 0 AND SUM(total_count) > 0 AND SUM(run_min) > 0
    THEN (SUM(run_min) / SUM(planned_min))
       * LEAST(1.0, SUM(ideal_cycle_s * total_count) / (SUM(run_min) * 60.0))
       * (SUM(good_count)::FLOAT / SUM(total_count))
    ELSE 0 END AS oee
FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
GROUP BY line_id, shift_date;

-- ── Views ──

CREATE OR REPLACE VIEW SEMANTIC.V_MTBF_MTTR AS
WITH asset_runtime AS (
  SELECT asset_id, SUM(run_min) AS total_run_min
  FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE GROUP BY asset_id
),
asset_failures AS (
  SELECT asset_id, COUNT(*) AS failure_count, SUM(minutes) AS total_downtime_min
  FROM AEGIS_OEE.CORE.DOWNTIME_EVENT WHERE is_planned = FALSE GROUP BY asset_id
)
SELECT
  a.asset_id, a.asset_type, a.line_id,
  COALESCE(af.failure_count, 0) AS failure_count,
  COALESCE(af.total_downtime_min, 0) AS total_unplanned_downtime_min,
  COALESCE(ar.total_run_min, 0) AS total_run_min,
  CASE WHEN COALESCE(af.failure_count, 0) > 0 THEN ar.total_run_min / af.failure_count ELSE NULL END AS mtbf_min,
  CASE WHEN COALESCE(af.failure_count, 0) > 0 THEN af.total_downtime_min / af.failure_count ELSE NULL END AS mttr_min
FROM AEGIS_OEE.CORE.ASSET a
LEFT JOIN asset_runtime ar ON a.asset_id = ar.asset_id
LEFT JOIN asset_failures af ON a.asset_id = af.asset_id;

CREATE OR REPLACE VIEW SEMANTIC.V_SIX_BIG_LOSSES AS
SELECT
  line_id, asset_id, shift_date, shift_code, planned_min,
  downtime_min AS breakdown_loss_min,
  CASE WHEN run_min > 0 AND ideal_cycle_s IS NOT NULL AND total_count > 0
    THEN GREATEST(0, run_min - LEAST(run_min, ideal_cycle_s * total_count / 60.0)) ELSE 0 END AS speed_loss_min,
  CASE WHEN total_count > 0 AND ideal_cycle_s IS NOT NULL
    THEN (total_count - good_count) * ideal_cycle_s / 60.0 ELSE 0 END AS quality_loss_min,
  CASE WHEN total_count > 0 AND ideal_cycle_s IS NOT NULL
    THEN LEAST(
      GREATEST(0, run_min - GREATEST(0, run_min - ideal_cycle_s * total_count / 60.0)),
      good_count * ideal_cycle_s / 60.0) ELSE 0 END AS fully_productive_min,
  run_min, availability, performance, quality, oee
FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
WHERE ideal_cycle_s IS NOT NULL;

CREATE OR REPLACE VIEW ML.V_VIB_HOURLY AS
SELECT ASSET_ID, DATE_TRUNC('HOUR', MINUTE_TS)::TIMESTAMP_NTZ AS HOUR_TS, AVG(VIB_RMS_MEAN) AS VIB_RMS_MEAN
FROM FEATURES.DT_SENSOR_1MIN WHERE VIB_RMS_MEAN IS NOT NULL
GROUP BY ASSET_ID, DATE_TRUNC('HOUR', MINUTE_TS);

CREATE OR REPLACE VIEW ML.V_OEE_DAILY AS
SELECT LINE_ID, SHIFT_DATE::TIMESTAMP_NTZ AS DAY_TS, AVG(OEE)::FLOAT AS OEE_AVG
FROM SEMANTIC.DT_SHIFT_OEE GROUP BY LINE_ID, SHIFT_DATE;

CREATE OR REPLACE VIEW ML.V_TRAIN_VIB_HEALTHY AS
SELECT s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START') AS MINUTE_TS, AVG(s.VIB_RMS_MEAN) AS VIB_RMS_MEAN
FROM FEATURES.DT_SENSOR_1MIN s
WHERE s.VIB_RMS_MEAN IS NOT NULL AND s.MINUTE_TS < '2026-07-15'::TIMESTAMP_TZ
  AND NOT EXISTS (SELECT 1 FROM TEST.GROUND_TRUTH_FAILURES g WHERE g.ASSET_ID = s.ASSET_ID AND s.MINUTE_TS >= g.DEGRADATION_START_TS AND s.MINUTE_TS <= g.FAILURE_TS)
GROUP BY s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START');

CREATE OR REPLACE VIEW ML.V_TRAIN_TEMP_HEALTHY AS
SELECT s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START') AS MINUTE_TS, AVG(s.TEMP_C_MEAN) AS TEMP_C_MEAN
FROM FEATURES.DT_SENSOR_1MIN s
WHERE s.TEMP_C_MEAN IS NOT NULL AND s.MINUTE_TS < '2026-07-15'::TIMESTAMP_TZ
  AND NOT EXISTS (SELECT 1 FROM TEST.GROUND_TRUTH_FAILURES g WHERE g.ASSET_ID = s.ASSET_ID AND s.MINUTE_TS >= g.DEGRADATION_START_TS AND s.MINUTE_TS <= g.FAILURE_TS)
GROUP BY s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START');

CREATE OR REPLACE VIEW ML.V_TRAIN_RPM_HEALTHY AS
SELECT s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START') AS MINUTE_TS, AVG(s.RPM_MEAN) AS RPM_MEAN
FROM FEATURES.DT_SENSOR_1MIN s
WHERE s.RPM_MEAN IS NOT NULL AND s.MINUTE_TS < '2026-07-15'::TIMESTAMP_TZ
  AND NOT EXISTS (SELECT 1 FROM TEST.GROUND_TRUTH_FAILURES g WHERE g.ASSET_ID = s.ASSET_ID AND s.MINUTE_TS >= g.DEGRADATION_START_TS AND s.MINUTE_TS <= g.FAILURE_TS)
GROUP BY s.ASSET_ID, TIME_SLICE(s.MINUTE_TS::TIMESTAMP_NTZ, 5, 'MINUTE', 'START');
