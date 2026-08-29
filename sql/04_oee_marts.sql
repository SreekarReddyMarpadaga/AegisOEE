-- =============================================================
-- Mission 02 — OEE Marts, Health Score, MTBF/MTTR, Loss Waterfall
-- Idempotent: safe to re-run at any time.
-- =============================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- -------------------------------------------------------
-- 1. SEMANTIC.DT_SHIFT_OEE
--    Shift-grain OEE with overlap-allocated downtime.
--    Exposes numerators/denominators for correct re-aggregation.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SEMANTIC.DT_SHIFT_OEE
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
WITH shift_production AS (
  SELECT
    a.line_id,
    pe.asset_id,
    sc.shift_date,
    sc.shift_code,
    sc.planned_minutes,
    sc.planned_downtime_minutes,
    a.ideal_cycle_s,
    SUM(pe.produced_count)  AS total_count,
    SUM(pe.good_count)      AS good_count,
    SUM(pe.reject_count)    AS reject_count
  FROM RAW.PRODUCTION_EVENT pe
  JOIN CORE.ASSET a          ON pe.asset_id = a.asset_id
  JOIN CORE.SHIFT_CALENDAR sc ON pe.ts >= sc.start_ts AND pe.ts < sc.end_ts
  GROUP BY a.line_id, pe.asset_id, sc.shift_date, sc.shift_code,
           sc.planned_minutes, sc.planned_downtime_minutes, a.ideal_cycle_s
),
shift_downtime AS (
  SELECT
    de.asset_id,
    sc.shift_date,
    sc.shift_code,
    SUM(
      GREATEST(0,
        DATEDIFF('SECOND',
          GREATEST(de.start_ts, sc.start_ts),
          LEAST(de.end_ts, sc.end_ts)
        )
      ) / 60.0
    ) AS unplanned_downtime_min
  FROM CORE.DOWNTIME_EVENT de
  JOIN CORE.SHIFT_CALENDAR sc
    ON de.start_ts < sc.end_ts
    AND de.end_ts > sc.start_ts
    AND de.is_planned = FALSE
  GROUP BY de.asset_id, sc.shift_date, sc.shift_code
)
SELECT
  sp.line_id,
  sp.asset_id,
  sp.shift_date,
  sp.shift_code,
  sp.planned_minutes,
  sp.planned_downtime_minutes,
  (sp.planned_minutes - sp.planned_downtime_minutes)                          AS planned_min,
  COALESCE(sd.unplanned_downtime_min, 0)                                      AS downtime_min,
  GREATEST(0,
    (sp.planned_minutes - sp.planned_downtime_minutes)
    - COALESCE(sd.unplanned_downtime_min, 0)
  )                                                                            AS run_min,
  sp.total_count,
  sp.good_count,
  sp.reject_count,
  sp.ideal_cycle_s,
  -- Availability = run_min / planned_min
  CASE WHEN (sp.planned_minutes - sp.planned_downtime_minutes) > 0
    THEN GREATEST(0,
           (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))
         ) / (sp.planned_minutes - sp.planned_downtime_minutes)
    ELSE 0
  END                                                                          AS availability,
  -- Performance = (ideal_cycle_s * total_count) / (run_min * 60), capped at 1.0
  CASE WHEN GREATEST(0,
              (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))
            ) > 0 AND sp.ideal_cycle_s IS NOT NULL AND sp.total_count > 0
    THEN LEAST(1.0,
           (sp.ideal_cycle_s * sp.total_count)
           / (GREATEST(0,
                (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))
              ) * 60.0)
         )
    ELSE 0
  END                                                                          AS performance,
  -- Quality = good_count / total_count
  CASE WHEN sp.total_count > 0
    THEN sp.good_count::FLOAT / sp.total_count
    ELSE 0
  END                                                                          AS quality,
  -- OEE = A * P * Q
  CASE WHEN (sp.planned_minutes - sp.planned_downtime_minutes) > 0
            AND sp.total_count > 0
            AND sp.ideal_cycle_s IS NOT NULL
    THEN
      (GREATEST(0,
         (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))
       ) / (sp.planned_minutes - sp.planned_downtime_minutes))
      * LEAST(1.0,
          (sp.ideal_cycle_s * sp.total_count)
          / (GREATEST(0,
               (sp.planned_minutes - sp.planned_downtime_minutes - COALESCE(sd.unplanned_downtime_min, 0))
             ) * 60.0)
        )
      * (sp.good_count::FLOAT / sp.total_count)
    ELSE 0
  END                                                                          AS oee
FROM shift_production sp
LEFT JOIN shift_downtime sd
  ON sp.asset_id = sd.asset_id
  AND sp.shift_date = sd.shift_date
  AND sp.shift_code = sd.shift_code;

-- -------------------------------------------------------
-- 2. SEMANTIC.DT_OEE_LINE_DAY
--    Line-day aggregation re-derived from sums.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SEMANTIC.DT_OEE_LINE_DAY
  TARGET_LAG = '5 minutes'
  REFRESH_MODE = INCREMENTAL
  WAREHOUSE = AEGIS_WH
AS
SELECT
  line_id,
  shift_date,
  SUM(planned_min)     AS planned_min,
  SUM(downtime_min)    AS downtime_min,
  SUM(run_min)         AS run_min,
  SUM(total_count)     AS total_count,
  SUM(good_count)      AS good_count,
  SUM(reject_count)    AS reject_count,
  -- Availability re-derived from sums
  CASE WHEN SUM(planned_min) > 0
    THEN SUM(run_min) / SUM(planned_min)
    ELSE 0 END                                                          AS availability,
  -- Performance re-derived: sum(ideal_seconds_used) / sum(run_seconds)
  CASE WHEN SUM(run_min) > 0
    THEN LEAST(1.0, SUM(ideal_cycle_s * total_count) / (SUM(run_min) * 60.0))
    ELSE 0 END                                                          AS performance,
  -- Quality
  CASE WHEN SUM(total_count) > 0
    THEN SUM(good_count)::FLOAT / SUM(total_count)
    ELSE 0 END                                                          AS quality,
  -- OEE re-derived
  CASE WHEN SUM(planned_min) > 0 AND SUM(total_count) > 0 AND SUM(run_min) > 0
    THEN (SUM(run_min) / SUM(planned_min))
       * LEAST(1.0, SUM(ideal_cycle_s * total_count) / (SUM(run_min) * 60.0))
       * (SUM(good_count)::FLOAT / SUM(total_count))
    ELSE 0 END                                                          AS oee
FROM SEMANTIC.DT_SHIFT_OEE
GROUP BY line_id, shift_date;

-- -------------------------------------------------------
-- 3. SEMANTIC.V_MTBF_MTTR
--    MTBF = total run_time / failure_count per asset.
--    MTTR = total unplanned downtime / failure_count.
-- -------------------------------------------------------
CREATE OR REPLACE VIEW SEMANTIC.V_MTBF_MTTR AS
WITH asset_runtime AS (
  SELECT asset_id, SUM(run_min) AS total_run_min
  FROM SEMANTIC.DT_SHIFT_OEE
  GROUP BY asset_id
),
asset_failures AS (
  SELECT
    asset_id,
    COUNT(*)     AS failure_count,
    SUM(minutes) AS total_downtime_min
  FROM CORE.DOWNTIME_EVENT
  WHERE is_planned = FALSE
  GROUP BY asset_id
)
SELECT
  a.asset_id,
  a.asset_type,
  a.line_id,
  COALESCE(af.failure_count, 0)          AS failure_count,
  COALESCE(af.total_downtime_min, 0)     AS total_unplanned_downtime_min,
  COALESCE(ar.total_run_min, 0)          AS total_run_min,
  CASE WHEN COALESCE(af.failure_count, 0) > 0
    THEN ar.total_run_min / af.failure_count
    ELSE NULL END                          AS mtbf_min,
  CASE WHEN COALESCE(af.failure_count, 0) > 0
    THEN af.total_downtime_min / af.failure_count
    ELSE NULL END                          AS mttr_min
FROM CORE.ASSET a
LEFT JOIN asset_runtime ar  ON a.asset_id = ar.asset_id
LEFT JOIN asset_failures af ON a.asset_id = af.asset_id;

-- -------------------------------------------------------
-- 4. SEMANTIC.V_SIX_BIG_LOSSES
--    Loss waterfall: breakdown + speed + quality + productive = planned.
-- -------------------------------------------------------
CREATE OR REPLACE VIEW SEMANTIC.V_SIX_BIG_LOSSES AS
SELECT
  line_id,
  asset_id,
  shift_date,
  shift_code,
  planned_min,
  -- Availability losses
  downtime_min                                                       AS breakdown_loss_min,
  -- Performance losses (speed loss = run time unused productively)
  CASE WHEN run_min > 0 AND ideal_cycle_s IS NOT NULL AND total_count > 0
    THEN GREATEST(0, run_min - LEAST(run_min, ideal_cycle_s * total_count / 60.0))
    ELSE 0
  END                                                                AS speed_loss_min,
  -- Quality losses (reject time)
  CASE WHEN total_count > 0 AND ideal_cycle_s IS NOT NULL
    THEN (total_count - good_count) * ideal_cycle_s / 60.0
    ELSE 0
  END                                                                AS quality_loss_min,
  -- Fully productive time
  CASE WHEN total_count > 0 AND ideal_cycle_s IS NOT NULL
    THEN LEAST(
      GREATEST(0, run_min - GREATEST(0, run_min - ideal_cycle_s * total_count / 60.0)),
      good_count * ideal_cycle_s / 60.0
    )
    ELSE 0
  END                                                                AS fully_productive_min,
  run_min,
  availability,
  performance,
  quality,
  oee
FROM SEMANTIC.DT_SHIFT_OEE
WHERE ideal_cycle_s IS NOT NULL;

-- -------------------------------------------------------
-- 5. FEATURES.DT_ASSET_HEALTH (v1 — rule-based)
--    Placeholders for ML columns filled by Mission 03.
-- -------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE FEATURES.DT_ASSET_HEALTH
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
  JOIN latest_ts lt
    ON f.asset_id = lt.asset_id AND f.window_ts = lt.max_window_ts
),
recent_downtime AS (
  SELECT asset_id, SUM(minutes) AS recent_down_min
  FROM CORE.DOWNTIME_EVENT
  WHERE is_planned = FALSE
    AND end_ts >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
  GROUP BY asset_id
),
scored AS (
  SELECT
    lf.asset_id,
    lf.window_ts AS last_reading_ts,
    GREATEST(0, LEAST(100,
      100
      -- Vibration penalty (up to -40)
      - CASE
          WHEN lf.vib_rms_mean >= a.vib_danger_mm_s THEN 40
          WHEN lf.vib_rms_mean >= a.vib_alert_mm_s  THEN 20 + 20 * LEAST(1.0,
                (lf.vib_rms_mean - a.vib_alert_mm_s) / NULLIF(a.vib_danger_mm_s - a.vib_alert_mm_s, 0))
          WHEN lf.vib_rms_mean >= a.vib_alert_mm_s * 0.8 THEN 10
          ELSE 0 END
      -- Temperature penalty (up to -25)
      - CASE
          WHEN lf.temp_c_mean >= a.temp_limit_c       THEN 25
          WHEN lf.temp_c_mean >= a.temp_limit_c * 0.9 THEN 15
          WHEN lf.temp_c_mean >= a.temp_limit_c * 0.8 THEN 5
          ELSE 0 END
      -- Z-score anomaly penalty (up to -15)
      - CASE
          WHEN ABS(COALESCE(lf.vib_rms_zscore, 0)) > 3   THEN 15
          WHEN ABS(COALESCE(lf.vib_rms_zscore, 0)) > 2   THEN 10
          WHEN ABS(COALESCE(lf.vib_rms_zscore, 0)) > 1.5 THEN 5
          ELSE 0 END
      -- Recent downtime penalty (up to -10)
      - CASE
          WHEN COALESCE(rd.recent_down_min, 0) > 480 THEN 10
          WHEN COALESCE(rd.recent_down_min, 0) > 120 THEN 5
          ELSE 0 END
      -- RPM variance penalty (up to -10)
      - CASE
          WHEN COALESCE(lf.rpm_variance, 0) > 10000 THEN 10
          WHEN COALESCE(lf.rpm_variance, 0) > 5000  THEN 5
          ELSE 0 END
    )) AS health_score,
    a.criticality
  FROM latest_features lf
  JOIN CORE.ASSET a ON lf.asset_id = a.asset_id
  LEFT JOIN recent_downtime rd ON lf.asset_id = rd.asset_id
)
SELECT
  asset_id,
  last_reading_ts,
  health_score,
  0::FLOAT                       AS anomaly_distance,
  0::FLOAT                       AS failure_probability_24h,
  NULL::STRING                   AS predicted_mode,
  CASE
    WHEN health_score <= 30 THEN 'CRITICAL'
    WHEN health_score <= 50 THEN 'HIGH'
    WHEN health_score <= 70 THEN 'MEDIUM'
    ELSE 'LOW'
  END                            AS risk_level
FROM scored;
