# AegisOEE - Parity Report (CoCo build vs direct deploy)

This report compares an account built by the CoCo CLI missions (Path B) with an
account built by the direct deploy scripts in this folder (Path A).

| | CoCo-built account | Direct-deploy account |
|---|---|---|
| Method | `prompts/00..10` missions run by CoCo | `deploy/deploy_all.sh <connection>` (no LLM, no CoCo) |
| Verification | `deploy/sql/10_verify.sql` | `deploy/sql/10_verify.sql` |
| Result | 53 PASS / 0 FAIL | 53 PASS / 0 FAIL |

Both paths need an account with Cortex AI enabled (a paid account). Trial
accounts cannot run `SNOWFLAKE.CORTEX.COMPLETE` or Cortex Search, so the
procurement text, the search service and the agent tools do not work there.

## Object inventory (identical on both)

| Object type | Count | Notes |
|---|---|---|
| Schemas | 8 | RAW, CORE, FEATURES, ML, SEMANTIC, ACTION, APP, TEST |
| Warehouses | 2 | AEGIS_WH, AEGIS_APP_WH (XSMALL, auto-suspend 60 s) |
| Dynamic Tables | 7 | All incremental, all with rows |
| ML models | 5 | 3 anomaly detection, 2 forecast |
| Tasks | 4 | Created and left SUSPENDED |
| Semantic view | 1 | MANUFACTURING_OPERATIONS (schema PUBLIC) |
| Cortex Search | 1 | MAINTENANCE_SEARCH (schema PUBLIC) |
| Cortex Agent | 1 | AEGIS_RCA_AGENT (schema ACTION) |
| Streamlit app | 1 | AEGIS_OEE_COMMAND_CENTER, warehouse runtime, 9 pages |
| Work-order procedures | 3+ | START, COMPLETE, CLOSE (plus create, schedule, requisition) |

## Seeded data (identical on both)

| Table | Rows |
|---|---|
| RAW.SENSOR_TELEMETRY | 718,129 |
| ML.ANOMALY_EVENTS | 392,722 (can differ slightly after a re-train) |
| ACTION.ALERT / WORK_ORDER | 0 / 0 (clean start) |

## Expected differences

- ML scoring is not bit-for-bit deterministic, so anomaly counts can differ by a small amount between trainings.
- The CoCo-built account also contains the audit trail of the missions that built it.
