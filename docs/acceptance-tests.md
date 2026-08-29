# AegisOEE — Acceptance Tests (Definition of Done)

> Concrete, runnable assertions mapped to Missions 00–06. Each checkbox is a testable condition. A mission is COMPLETE only when all its checks pass.

---

## Mission 00 — Foundation

```sql
-- T00-01: Database and schemas exist
SELECT schema_name FROM AEGIS_OEE.INFORMATION_SCHEMA.SCHEMATA
WHERE schema_name IN ('RAW','CORE','FEATURES','ML','SEMANTIC','ACTION','APP','TEST')
ORDER BY 1;
-- EXPECT: 8 rows
```

```sql
-- T00-02: Warehouses exist with correct config
SHOW WAREHOUSES LIKE 'AEGIS%';
-- EXPECT: AEGIS_WH and AEGIS_APP_WH, both XSMALL, auto_suspend=60
```

```sql
-- T00-03: Stages exist
SHOW STAGES IN SCHEMA AEGIS_OEE.RAW;
SHOW STAGES IN SCHEMA AEGIS_OEE.APP;
-- EXPECT: DOC_STAGE (with directory table), APP_STAGE, SKILL_STAGE
```

```sql
-- T00-04: Probes recorded
SELECT probe_name, result FROM AEGIS_OEE.TEST.ENV_PROBES ORDER BY probe_name;
-- EXPECT: 6 rows, each PASS/FAIL/SKIP (failures don't fail the mission)
```

- [ ] T00-05: Idempotency — re-running Mission 00 produces no errors and refreshes probe rows.

---

## Mission 01 — Synthetic Data

```sql
-- T01-01: Telemetry row count
SELECT COUNT(*) AS cnt FROM AEGIS_OEE.RAW.SENSOR_TELEMETRY;
-- EXPECT: within ±2% of 1,080,000
```

```sql
-- T01-02: Ground truth episodes
SELECT failure_mode, COUNT(*) AS cnt
FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES
GROUP BY failure_mode ORDER BY failure_mode;
-- EXPECT: BEARING_WEAR=3, COOLING_RESTRICTION=2, LUBRICATION_LOSS=2, RPM_INSTABILITY=2, SENSOR_FAULT=1
```

```sql
-- T01-03: Golden-path episode exists
SELECT * FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES
WHERE asset_id = 'CNC_01_SPINDLE' AND failure_mode = 'BEARING_WEAR';
-- EXPECT: 1 row, degradation_start_ts within final 2 weeks of 75-day window
```

```sql
-- T01-04: Every failure has matching downtime
SELECT f.failure_id, d.event_id
FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES f
LEFT JOIN AEGIS_OEE.CORE.DOWNTIME_EVENT d
  ON f.asset_id = d.asset_id
  AND d.is_planned = FALSE
  AND d.failure_mode = f.failure_mode
  AND d.start_ts BETWEEN f.degradation_start_ts AND DATEADD('day', 1, f.failure_ts);
-- EXPECT: no NULLs in d.event_id (every failure has unplanned downtime)
```

```sql
-- T01-05: Every failure has corrective maintenance after it
SELECT f.failure_id, m.wo_hist_id
FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES f
LEFT JOIN AEGIS_OEE.CORE.MAINTENANCE_HISTORY m
  ON f.asset_id = m.asset_id
  AND m.completed_ts > f.failure_ts
  AND m.completed_ts < DATEADD('day', 1, f.failure_ts);
-- EXPECT: no NULLs in m.wo_hist_id
```

```sql
-- T01-06: No overlapping failures per asset
SELECT a.asset_id, a.failure_id, b.failure_id AS overlap_with
FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES a
JOIN AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES b
  ON a.asset_id = b.asset_id
  AND a.failure_id < b.failure_id
  AND a.failure_ts > b.degradation_start_ts
  AND b.failure_ts > a.degradation_start_ts;
-- EXPECT: 0 rows
```

```sql
-- T01-07: No label leakage — ground truth columns only in TEST
SELECT table_schema, table_name
FROM AEGIS_OEE.INFORMATION_SCHEMA.TABLES
WHERE table_name LIKE '%GROUND_TRUTH%' AND table_schema != 'TEST';
-- EXPECT: 0 rows
```

```sql
-- T01-08: Parts inventory and mapping
SELECT COUNT(*) FROM AEGIS_OEE.CORE.PARTS_INVENTORY;  -- EXPECT: ~30
SELECT COUNT(*) FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS;  -- EXPECT: ≥15 (5 modes × ≥3 asset types)
```

```sql
-- T01-09: Golden-path parts shortage
SELECT p.part_name, p.on_hand_qty, fm.qty_required
FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fm
JOIN AEGIS_OEE.CORE.PARTS_INVENTORY p ON fm.part_id = p.part_id
WHERE fm.failure_mode = 'BEARING_WEAR' AND fm.asset_type = 'CNC spindle'
  AND p.on_hand_qty < fm.qty_required;
-- EXPECT: ≥1 row (bearing kit is short)
```

- [ ] T01-10: Shift calendar exists with 75 days × 3 shifts × 2 lines of records.
- [ ] T01-11: ≥4 hard-negative episodes identifiable in the data (hot-but-healthy, planned RPM, planned maintenance, dropout).
- [ ] T01-12: Docs uploaded to @AEGIS_OEE.RAW.DOC_STAGE (~10 excerpts + ~30 technician notes).
- [ ] T01-13: `tests/validation_report.md` exists and all checks PASS.

---

## Mission 02 — Pipelines

```sql
-- T02-01: All DTs are INCREMENTAL
SELECT name, refresh_mode
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE database_name = 'AEGIS_OEE';
-- EXPECT: all rows show refresh_mode = 'INCREMENTAL'
```

```sql
-- T02-02: OEE components in valid range
SELECT
  COUNT_IF(availability < 0 OR availability > 1) AS bad_a,
  COUNT_IF(performance < 0 OR performance > 1) AS bad_p,
  COUNT_IF(quality < 0 OR quality > 1) AS bad_q,
  COUNT_IF(ABS(oee - availability * performance * quality) > 1e-9) AS bad_oee
FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE;
-- EXPECT: all zeros
```

```sql
-- T02-03: good_count <= total_count
SELECT COUNT_IF(good_count > total_count) AS violations
FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE;
-- EXPECT: 0
```

```sql
-- T02-04: Plant OEE in plausible band (healthy days)
SELECT AVG(oee) AS avg_oee
FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
WHERE shift_date NOT IN (
  SELECT DISTINCT DATE(failure_ts)
  FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES
);
-- EXPECT: between 0.55 and 0.85
```

- [ ] T02-05: End-to-end freshness test: insert a probe row into RAW.SENSOR_TELEMETRY, query DT_SHIFT_OEE — visible within 120s.
- [ ] T02-06: OEE visibly dips during known failure episodes (compare failure-day OEE to healthy-day average).
- [ ] T02-07: MTBF/MTTR views return non-NULL, positive values.

---

## Mission 03 — ML

```sql
-- T03-01: No label leakage in scoring/feature code
-- Run: grep -r 'GROUND_TRUTH' sql/05_ml_models.sql ml/ --exclude='*recall*' --exclude='*eval*'
-- EXPECT: no matches (only evaluation scripts may reference ground truth)
```

```sql
-- T03-02: Anomaly events populated
SELECT COUNT(*) FROM AEGIS_OEE.ML.ANOMALY_EVENTS;
-- EXPECT: >0 rows
```

```sql
-- T03-03: Recall calculation
WITH detected AS (
  SELECT DISTINCT gt.failure_id
  FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES gt
  JOIN AEGIS_OEE.ML.ANOMALY_EVENTS ae
    ON gt.asset_id = ae.asset_id
    AND ae.is_anomaly = TRUE
    AND ae.ts BETWEEN gt.degradation_start_ts AND gt.failure_ts
)
SELECT
  (SELECT COUNT(*) FROM detected) AS detected_count,
  (SELECT COUNT(*) FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES) AS total_failures,
  detected_count / total_failures AS recall;
-- EXPECT: recall >= 0.8
```

```sql
-- T03-04: Golden-path lead time
SELECT
  gt.failure_ts,
  MIN(ae.ts) AS first_detection,
  DATEDIFF('hour', MIN(ae.ts), gt.failure_ts) AS lead_hours
FROM AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES gt
JOIN AEGIS_OEE.ML.ANOMALY_EVENTS ae
  ON gt.asset_id = ae.asset_id
  AND ae.is_anomaly = TRUE
  AND ae.ts BETWEEN gt.degradation_start_ts AND gt.failure_ts
WHERE gt.asset_id = 'CNC_01_SPINDLE' AND gt.failure_mode = 'BEARING_WEAR'
GROUP BY gt.failure_ts;
-- EXPECT: lead_hours >= 48
```

- [ ] T03-05: ML.SIGNAL_FORECASTS populated (FORECAST output).
- [ ] T03-06: DT_ASSET_HEALTH shows health_score, failure_probability_24h, predicted_mode, risk_level for all 10 assets.
- [ ] T03-07: TEST.ML_METRICS has comparison row for fixed-threshold baseline.

---

## Mission 04 — Semantics & Agent

```sql
-- T04-01: Semantic view exists
SHOW SEMANTIC VIEWS IN SCHEMA AEGIS_OEE.SEMANTIC;
-- EXPECT: MANUFACTURING_OPERATIONS listed
```

- [ ] T04-02: 15 verified queries return numbers matching direct SQL within tolerance (±5% or ±1 unit).
- [ ] T04-03: Cortex Search service MAINTENANCE_SEARCH is operational — a test query returns results.
- [ ] T04-04: GET_ASSET_EVIDENCE('CNC_01_SPINDLE') returns well-formed JSON with signals, anomaly, history keys.
- [ ] T04-05: PROPOSE_WORK_ORDER on a test alert returns draft JSON and zero rows inserted into WORK_ORDER.
- [ ] T04-06: AEGIS_RCA_AGENT is deployed and callable.

```sql
-- T04-07: Agent eval pass rate
SELECT
  COUNT_IF(result = 'PASS') AS passed,
  COUNT(*) AS total,
  passed / total AS pass_rate
FROM AEGIS_OEE.TEST.AGENT_EVAL_RESULTS;
-- EXPECT: pass_rate >= 0.80
```

- [ ] T04-08: "Why is CNC_01_SPINDLE at risk?" returns bearing-wear assessment citing vibration + maintenance history.
- [ ] T04-09: Refusal questions actually refuse (agent does not hallucinate answers for missing-data or out-of-scope questions).

---

## Mission 05 — Action Loop

```sql
-- T05-01: ACTION tables exist
SELECT table_name FROM AEGIS_OEE.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'ACTION'
ORDER BY table_name;
-- EXPECT: ACTION_AUDIT, ALERT, PURCHASE_REQUISITION, WORK_ORDER, WORK_ORDER_OUTBOX
```

```sql
-- T05-02: Audit table is append-only (no UPDATE/DELETE privilege)
-- Verify by attempting: UPDATE AEGIS_OEE.ACTION.ACTION_AUDIT SET detail = NULL WHERE 1=0;
-- EXPECT: insufficient privileges error
```

```sql
-- T05-03: Guardrail — create on non-ACKED alert rejected
CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('<test_alert_with_status_NEW>', 'test_user', FALSE);
-- EXPECT: error or rejection message
```

```sql
-- T05-04: Guardrail — approver='AGENT' rejected
CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('<acked_alert_id>', 'AGENT', FALSE);
-- EXPECT: error or rejection message
```

- [ ] T05-05: Guardrail — duplicate WO rejected.
- [ ] T05-06: Guardrail — dry_run=TRUE writes nothing to WORK_ORDER.
- [ ] T05-07: Full golden-path pass: seed P1 alert → ACK → propose → approve (dry_run then real) → WO row + OUTBOX + Slack (or fallback) + ≥4 audit rows.
- [ ] T05-08: Parts flow — golden-path alert produces a shortage requisition with non-zero quote in PURCHASE_REQUISITION.
- [ ] T05-09: Parts flow — fully-stocked part produces no requisition.
- [ ] T05-10: Approval reserves exactly qty_required (PARTS_INVENTORY.reserved_qty incremented).
- [ ] T05-11: All guardrail test results persisted to TEST.ACTION_GUARDRAIL_RESULTS.

---

## Mission 06 — Streamlit App

- [ ] T06-01: App deployed to AEGIS_OEE.APP on AEGIS_APP_WH.
- [ ] T06-02: All 5 core capabilities reachable within 2 clicks from sidebar.
- [ ] T06-03: Executive OEE page — KPI cards with deltas, 7-day trend, loss waterfall, OEE-at-risk.
- [ ] T06-04: Alert Triage page — ranked alerts; ACK/Investigate/Suppress actions write audit rows.
- [ ] T06-05: Asset Digital Twin page — sensor trends with anomaly markers + forecast bands, health gauge, maintenance timeline.
- [ ] T06-06: Ask Aegis page — agent chat returns structured RCA with expandable evidence/trace.
- [ ] T06-07: Work Order Review page — parts panel with shortages highlighted, requisition quotes, approve/reject with typed approver name.
- [ ] T06-08: "Built with CoCo" sidebar panel displays COCO_USAGE_HISTORY data.
- [ ] T06-09: Industrial theme applied (dark slate + amber/teal accents, styled KPI cards, formatted numbers).
- [ ] T06-10: Page load <5s on XSMALL (no raw table scans — all queries on marts/DTs).
- [ ] T06-11: Runtime choice (container vs warehouse) recorded in docs/run-records.md.

---

## Cross-Cutting

- [ ] TX-01: Every mission appends a run record to `docs/run-records.md`.
- [ ] TX-02: All generated SQL files are idempotent (CREATE OR REPLACE / IF NOT EXISTS).
- [ ] TX-03: All DDL scoped to AEGIS_OEE only (no cross-database writes).
- [ ] TX-04: The golden path works end-to-end: telemetry → anomaly detection → alert → RCA → proposal → approval → WO + ticket + audit.
