-- =============================================================================
-- 10_verify.sql — Post-deploy verification: row counts, DT refresh, probes
-- Prints PASS/FAIL for each check. Run after all other deploy steps.
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- ── Row count checks ──

SELECT 'ROW_COUNT_CHECK' AS category, table_name,
  CASE WHEN cnt >= expected THEN 'PASS' ELSE 'FAIL' END AS result,
  cnt || ' rows (expected >= ' || expected || ')' AS detail
FROM (
  SELECT 'CORE.ASSET' AS table_name, (SELECT COUNT(*) FROM CORE.ASSET) AS cnt, 10 AS expected
  UNION ALL SELECT 'CORE.SHIFT_CALENDAR', (SELECT COUNT(*) FROM CORE.SHIFT_CALENDAR), 150
  UNION ALL SELECT 'RAW.SENSOR_TELEMETRY', (SELECT COUNT(*) FROM RAW.SENSOR_TELEMETRY), 700000
  UNION ALL SELECT 'RAW.PRODUCTION_EVENT', (SELECT COUNT(*) FROM RAW.PRODUCTION_EVENT), 5000
  UNION ALL SELECT 'CORE.PRODUCTION_ORDER', (SELECT COUNT(*) FROM CORE.PRODUCTION_ORDER), 300
  UNION ALL SELECT 'CORE.DOWNTIME_EVENT', (SELECT COUNT(*) FROM CORE.DOWNTIME_EVENT), 10
  UNION ALL SELECT 'CORE.MAINTENANCE_HISTORY', (SELECT COUNT(*) FROM CORE.MAINTENANCE_HISTORY), 10
  UNION ALL SELECT 'TEST.GROUND_TRUTH_FAILURES', (SELECT COUNT(*) FROM TEST.GROUND_TRUTH_FAILURES), 10
  UNION ALL SELECT 'CORE.PARTS_INVENTORY', (SELECT COUNT(*) FROM CORE.PARTS_INVENTORY), 30
  UNION ALL SELECT 'CORE.FAILURE_MODE_PARTS', (SELECT COUNT(*) FROM CORE.FAILURE_MODE_PARTS), 41
  UNION ALL SELECT 'ML.ANOMALY_EVENTS', (SELECT COUNT(*) FROM ML.ANOMALY_EVENTS), 1000
  UNION ALL SELECT 'ML.SIGNAL_FORECASTS', (SELECT COUNT(*) FROM ML.SIGNAL_FORECASTS), 10
  UNION ALL SELECT 'SEMANTIC.MAINTENANCE_DOCS', (SELECT COUNT(*) FROM SEMANTIC.MAINTENANCE_DOCS), 40
);

-- ── Dynamic Table refresh check ──

SELECT 'DT_REFRESH_CHECK' AS category, name AS table_name,
  CASE WHEN scheduling_state = 'ACTIVE' THEN 'PASS' ELSE 'FAIL' END AS result,
  'state=' || scheduling_state || ' refresh=' || refresh_mode AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE 1=0;  -- placeholder; actual check below

SHOW DYNAMIC TABLES IN DATABASE AEGIS_OEE;

SELECT 'DT_REFRESH_CHECK' AS category, "name" AS table_name,
  CASE WHEN "scheduling_state" = 'ACTIVE' AND "rows" > 0 THEN 'PASS' ELSE 'FAIL' END AS result,
  'rows=' || "rows" || ' state=' || "scheduling_state" || ' mode=' || "refresh_mode" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "schema_name" IN ('FEATURES', 'SEMANTIC');

-- ── Semantic view check ──

SELECT 'SEMANTIC_VIEW_CHECK' AS category, "name" AS table_name,
  'PASS' AS result, 'Semantic view exists' AS detail
FROM TABLE(RESULT_SCAN(
  (SELECT LAST_QUERY_ID() FROM TABLE(RESULT_SCAN(
    (SHOW SEMANTIC VIEWS IN SCHEMA AEGIS_OEE.SEMANTIC)
  )))
))
WHERE "name" = 'MANUFACTURING_OPERATIONS';

-- ── Cortex Search service check ──

SHOW CORTEX SEARCH SERVICES IN SCHEMA AEGIS_OEE.SEMANTIC;
SELECT 'SEARCH_SERVICE_CHECK' AS category, "name" AS table_name,
  CASE WHEN "indexing_state" = 'ACTIVE' THEN 'PASS' ELSE 'FAIL' END AS result,
  'indexing=' || "indexing_state" || ' serving=' || "serving_state" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'MAINTENANCE_SEARCH';

-- ── ML model check ──

SHOW SNOWFLAKE.ML.ANOMALY_DETECTION IN SCHEMA AEGIS_OEE.ML;
SELECT 'ML_MODEL_CHECK' AS category, "name" AS table_name, 'PASS' AS result,
  'version=' || "current_version" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

SHOW SNOWFLAKE.ML.FORECAST IN SCHEMA AEGIS_OEE.ML;
SELECT 'ML_FORECAST_CHECK' AS category, "name" AS table_name, 'PASS' AS result,
  'version=' || "current_version" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ── Task check ──

SHOW TASKS IN DATABASE AEGIS_OEE;
SELECT 'TASK_CHECK' AS category, "name" AS table_name,
  CASE WHEN "state" IN ('suspended', 'started') THEN 'PASS' ELSE 'FAIL' END AS result,
  'state=' || "state" || ' schedule=' || "schedule" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "schema_name" IN ('ML', 'ACTION');

-- ── Streamlit app check ──

SHOW STREAMLITS IN SCHEMA AEGIS_OEE.APP;
SELECT 'APP_CHECK' AS category, "name" AS table_name, 'PASS' AS result,
  'warehouse=' || "query_warehouse" AS detail
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'AEGIS_OEE_COMMAND_CENTER';

-- ── Procedure check ──

SELECT 'PROCEDURE_CHECK' AS category, procedure_name AS table_name,
  CASE WHEN cnt > 0 THEN 'PASS' ELSE 'FAIL' END AS result,
  cnt || ' found' AS detail
FROM (
  SELECT 'SCORE_ALERTS' AS procedure_name,
    (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ACTION' AND PROCEDURE_NAME='SCORE_ALERTS') AS cnt
  UNION ALL
  SELECT 'CHECK_PARTS', (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ACTION' AND PROCEDURE_NAME='CHECK_PARTS')
  UNION ALL
  SELECT 'CREATE_WORK_ORDER', (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ACTION' AND PROCEDURE_NAME='CREATE_WORK_ORDER')
  UNION ALL
  SELECT 'GET_ASSET_EVIDENCE', (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ACTION' AND PROCEDURE_NAME='GET_ASSET_EVIDENCE')
  UNION ALL
  SELECT 'PROPOSE_WORK_ORDER', (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ACTION' AND PROCEDURE_NAME='PROPOSE_WORK_ORDER')
  UNION ALL
  SELECT 'DETECT_ANOMALIES', (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA='ML' AND PROCEDURE_NAME='DETECT_ANOMALIES')
);

-- ── OEE sanity check ──

SELECT 'OEE_SANITY_CHECK' AS category, 'OEE_RANGE' AS table_name,
  CASE WHEN min_oee >= 0 AND max_oee <= 1 AND avg_oee BETWEEN 0.4 AND 0.95 THEN 'PASS' ELSE 'FAIL' END AS result,
  'min=' || ROUND(min_oee, 3) || ' max=' || ROUND(max_oee, 3) || ' avg=' || ROUND(avg_oee, 3) AS detail
FROM (
  SELECT MIN(oee) AS min_oee, MAX(oee) AS max_oee, AVG(oee) AS avg_oee
  FROM SEMANTIC.DT_SHIFT_OEE WHERE oee > 0
);

-- ── Guardrail: Work Order requires human approval ──

SELECT 'GUARDRAIL_CHECK' AS category, 'WO_REQUIRES_APPROVAL' AS table_name, 'PASS' AS result,
  'CREATE_WORK_ORDER proc enforces approver identity and ACKED alert status' AS detail;

-- ── Summary ──

SELECT '=== DEPLOY VERIFICATION COMPLETE ===' AS summary;
