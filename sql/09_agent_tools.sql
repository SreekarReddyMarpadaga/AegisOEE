-- =============================================================================
-- 09_agent_tools.sql — Agent Tool Procedures
-- Mission 04, Deliverable 3
-- GET_ASSET_EVIDENCE(asset_id) + PROPOSE_WORK_ORDER(alert_id)
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- ─────────────────────────────────────────────────────────────────────────────
-- GET_ASSET_EVIDENCE(asset_id) → VARIANT
-- Returns the evidence bundle JSON per maintenance-triage skill format.
-- Read-only: no side effects.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.GET_ASSET_EVIDENCE(P_ASSET_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS $$
DECLARE
  v_health VARIANT;
  v_asset VARIANT;
  v_signals VARIANT;
  v_anomalies VARIANT;
  v_maint VARIANT;
  v_downtime VARIANT;
  v_oee VARIANT;
  v_alerts VARIANT;
BEGIN
  -- Health snapshot
  SELECT OBJECT_CONSTRUCT(
    'health_score', h.HEALTH_SCORE, 'anomaly_distance', h.ANOMALY_DISTANCE,
    'failure_probability_24h', h.FAILURE_PROBABILITY_24H,
    'predicted_mode', h.PREDICTED_MODE, 'risk_level', h.RISK_LEVEL,
    'last_reading_ts', TO_VARCHAR(h.LAST_READING_TS, 'YYYY-MM-DD HH24:MI:SS')
  ) INTO :v_health
  FROM AEGIS_OEE.FEATURES.DT_ASSET_HEALTH h WHERE h.ASSET_ID = :P_ASSET_ID;

  -- Asset metadata
  SELECT OBJECT_CONSTRUCT(
    'asset_id', a.ASSET_ID, 'line_id', a.LINE_ID, 'site_id', a.SITE_ID,
    'asset_type', a.ASSET_TYPE, 'criticality', a.CRITICALITY,
    'ideal_rpm', a.IDEAL_RPM, 'temp_limit_c', a.TEMP_LIMIT_C,
    'vib_alert_mm_s', a.VIB_ALERT_MM_S, 'vib_danger_mm_s', a.VIB_DANGER_MM_S
  ) INTO :v_asset
  FROM AEGIS_OEE.CORE.ASSET a WHERE a.ASSET_ID = :P_ASSET_ID;

  -- Recent signals (last 24h from 15-min features)
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'window_ts', TO_VARCHAR(f.WINDOW_TS, 'YYYY-MM-DD HH24:MI'),
    'vib_rms_mean', f.VIB_RMS_MEAN, 'vib_rms_max', f.VIB_RMS_MAX,
    'vib_kurtosis', f.KURTOSIS_MEAN, 'temp_mean', f.TEMP_C_MEAN, 'temp_max', f.TEMP_C_MAX,
    'rpm_mean', f.RPM_MEAN, 'load_mean', f.LOAD_PCT_MEAN,
    'vib_z_score', f.VIB_RMS_ZSCORE, 'temp_z_score', f.TEMP_C_ZSCORE,
    'vib_slope_per_day', f.VIB_RMS_SLOPE
  )) INTO :v_signals
  FROM AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN f
  WHERE f.ASSET_ID = :P_ASSET_ID AND f.WINDOW_TS >= DATEADD('hour', -24, CURRENT_TIMESTAMP());

  -- Recent anomalies (last 7 days, anomalous only)
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'ts', TO_VARCHAR(ae.TS, 'YYYY-MM-DD HH24:MI'), 'series', ae.SERIES_NAME,
    'is_anomaly', ae.IS_ANOMALY, 'distance', ae.DISTANCE,
    'percentile', ae.PERCENTILE, 'forecast', ae.FORECAST
  )) INTO :v_anomalies
  FROM AEGIS_OEE.ML.ANOMALY_EVENTS ae
  WHERE ae.ASSET_ID = :P_ASSET_ID AND ae.IS_ANOMALY = TRUE
    AND ae.TS >= DATEADD('day', -7, CURRENT_TIMESTAMP());

  -- Maintenance history
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'wo_hist_id', mh.WO_HIST_ID,
    'completed_ts', TO_VARCHAR(mh.COMPLETED_TS, 'YYYY-MM-DD HH24:MI'),
    'failure_code', mh.FAILURE_CODE, 'finding', mh.FINDING,
    'action_taken', mh.ACTION_TAKEN, 'parts_used', mh.PARTS_USED,
    'labor_hours', mh.LABOR_HOURS, 'technician_note', mh.TECHNICIAN_NOTE
  )) INTO :v_maint
  FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY mh WHERE mh.ASSET_ID = :P_ASSET_ID;

  -- Downtime events (unplanned, last 30 days)
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'event_id', de.EVENT_ID,
    'start_ts', TO_VARCHAR(de.START_TS, 'YYYY-MM-DD HH24:MI'),
    'end_ts', TO_VARCHAR(de.END_TS, 'YYYY-MM-DD HH24:MI'),
    'failure_mode', de.FAILURE_MODE, 'minutes', de.MINUTES
  )) INTO :v_downtime
  FROM AEGIS_OEE.CORE.DOWNTIME_EVENT de
  WHERE de.ASSET_ID = :P_ASSET_ID AND de.IS_PLANNED = FALSE
    AND de.START_TS >= DATEADD('day', -30, CURRENT_TIMESTAMP());

  -- OEE trend (last 7 days)
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'shift_date', TO_VARCHAR(o.SHIFT_DATE, 'YYYY-MM-DD'), 'shift_code', o.SHIFT_CODE,
    'availability', o.AVAILABILITY, 'performance', o.PERFORMANCE,
    'quality', o.QUALITY, 'oee', o.OEE
  )) INTO :v_oee
  FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE o
  WHERE o.ASSET_ID = :P_ASSET_ID AND o.SHIFT_DATE >= DATEADD('day', -7, CURRENT_DATE());

  -- Open alerts
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'alert_id', al.ALERT_ID, 'severity', al.SEVERITY,
    'predicted_mode', al.PREDICTED_MODE, 'confidence', al.CONFIDENCE,
    'failure_probability', al.FAILURE_PROBABILITY, 'oee_impact_est', al.OEE_IMPACT_EST,
    'status', al.STATUS, 'onset_ts', TO_VARCHAR(al.ONSET_TS, 'YYYY-MM-DD HH24:MI')
  )) INTO :v_alerts
  FROM AEGIS_OEE.ACTION.ALERT al
  WHERE al.ASSET_ID = :P_ASSET_ID AND al.STATUS NOT IN ('CLOSED', 'SUPPRESSED');

  -- Assemble and return
  RETURN OBJECT_CONSTRUCT(
    'asset_id', :P_ASSET_ID,
    'health', :v_health,
    'asset', :v_asset,
    'signals', :v_signals,
    'anomalies', :v_anomalies,
    'maintenance_history', :v_maint,
    'downtime_events', :v_downtime,
    'oee_trend', :v_oee,
    'open_alerts', :v_alerts,
    'sources', ARRAY_CONSTRUCT(
      'AEGIS_OEE.FEATURES.DT_ASSET_HEALTH', 'AEGIS_OEE.CORE.ASSET',
      'AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN', 'AEGIS_OEE.ML.ANOMALY_EVENTS',
      'AEGIS_OEE.CORE.MAINTENANCE_HISTORY', 'AEGIS_OEE.CORE.DOWNTIME_EVENT',
      'AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE', 'AEGIS_OEE.ACTION.ALERT'
    )
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- PROPOSE_WORK_ORDER(alert_id) → VARIANT
-- Returns a draft work-order JSON. Zero side effects except an audit row.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.PROPOSE_WORK_ORDER(P_ALERT_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS $$
DECLARE
  v_asset_id VARCHAR;
  v_severity VARCHAR;
  v_predicted_mode VARCHAR;
  v_confidence FLOAT;
  v_failure_prob FLOAT;
  v_oee_impact FLOAT;
  v_asset_type VARCHAR;
  v_line_id VARCHAR;
  v_criticality NUMBER;
  v_parts_kit VARIANT;
  v_maint_history VARIANT;
  v_wo_id VARCHAR;
  v_result VARIANT;
  v_recommended_action VARCHAR;
BEGIN
  -- 1. Fetch alert details
  SELECT ASSET_ID, SEVERITY, PREDICTED_MODE, CONFIDENCE, FAILURE_PROBABILITY, OEE_IMPACT_EST
  INTO :v_asset_id, :v_severity, :v_predicted_mode, :v_confidence, :v_failure_prob, :v_oee_impact
  FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = :P_ALERT_ID;

  -- 2. Fetch asset details
  SELECT ASSET_TYPE, LINE_ID, CRITICALITY
  INTO :v_asset_type, :v_line_id, :v_criticality
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_asset_id;

  -- 3. Resolve parts kit
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'part_id', fmp.PART_ID, 'part_name', pi.PART_NAME,
    'qty_required', fmp.QTY_REQUIRED, 'on_hand', pi.ON_HAND_QTY,
    'reserved', pi.RESERVED_QTY,
    'available', pi.ON_HAND_QTY - pi.RESERVED_QTY,
    'shortage', GREATEST(fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY), 0),
    'unit_cost', pi.UNIT_COST, 'supplier', pi.SUPPLIER_NAME,
    'lead_time_days', pi.LEAD_TIME_DAYS
  )) INTO :v_parts_kit
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  -- 4. Recent maintenance history
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    'wo_hist_id', mh.WO_HIST_ID,
    'completed_ts', TO_VARCHAR(mh.COMPLETED_TS, 'YYYY-MM-DD'),
    'failure_code', mh.FAILURE_CODE, 'finding', mh.FINDING,
    'action_taken', mh.ACTION_TAKEN
  )) INTO :v_maint_history
  FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY mh WHERE mh.ASSET_ID = :v_asset_id;

  -- 5. Generate WO ID
  v_wo_id := 'WO_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS') || '_' || :P_ALERT_ID;

  -- 6. Recommended action
  CASE :v_predicted_mode
    WHEN 'BEARING_WEAR' THEN v_recommended_action := 'Inspect bearing condition. Replace bearing set if spalling/pitting found. Re-align and grease.';
    WHEN 'LUBRICATION_LOSS' THEN v_recommended_action := 'Check lubrication system. Refill/replace lubricant. Inspect for leaks.';
    WHEN 'COOLING_RESTRICTION' THEN v_recommended_action := 'Inspect coolant system. Clear blockages, check flow rate, verify coolant level.';
    WHEN 'RPM_INSTABILITY' THEN v_recommended_action := 'Check drive system and belt tension. Inspect VFD parameters and encoder.';
    WHEN 'SENSOR_FAULT' THEN v_recommended_action := 'Verify sensor readings. Recalibrate or replace sensor. DO NOT take equipment action based on faulty sensor data.';
    ELSE v_recommended_action := 'Inspect asset and diagnose root cause.';
  END CASE;

  -- 7. Build draft
  v_result := OBJECT_CONSTRUCT(
    'wo_id', :v_wo_id, 'alert_id', :P_ALERT_ID,
    'asset_id', :v_asset_id, 'asset_type', :v_asset_type,
    'line_id', :v_line_id, 'criticality', :v_criticality,
    'priority', :v_severity, 'state', 'DRAFT',
    'predicted_mode', :v_predicted_mode, 'confidence', :v_confidence,
    'failure_probability', :v_failure_prob, 'oee_impact_est', :v_oee_impact,
    'title', '[' || :v_severity || '][' || :v_predicted_mode || '] ' || :v_asset_id || ' — inspection required',
    'recommended_action', :v_recommended_action,
    'parts_kit', :v_parts_kit,
    'maintenance_history', :v_maint_history,
    'safety_statement', 'This is a draft recommendation requiring human verification before execution. The agent does not approve or execute maintenance actions.',
    'trace', OBJECT_CONSTRUCT(
      'alert_id', :P_ALERT_ID,
      'source_objects', ARRAY_CONSTRUCT(
        'AEGIS_OEE.ACTION.ALERT', 'AEGIS_OEE.CORE.ASSET',
        'AEGIS_OEE.CORE.FAILURE_MODE_PARTS', 'AEGIS_OEE.CORE.PARTS_INVENTORY',
        'AEGIS_OEE.CORE.MAINTENANCE_HISTORY'
      )
    )
  );

  -- 8. Write audit row (the only side effect)
  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  VALUES (
    'AUD_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS') || '_PROPOSE',
    CURRENT_TIMESTAMP(), 'AEGIS_RCA_AGENT', 'PROPOSED', :v_wo_id, :v_result
  );

  RETURN v_result;
END;
$$;
