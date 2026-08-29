# Mission 00 — Foundation

Read `AGENTS.md` first. Non-interactive mission: never ask questions; on unrecoverable errors print `MISSION 00 FAILED: <reason>` and stop.

## Objective

Provision the AegisOEE Snowflake foundation and record environment capabilities.

## Deliverables

1. `sql/00_setup.sql` — idempotent DDL, then execute it:
   - Database `AEGIS_OEE`; schemas `RAW`, `CORE`, `FEATURES`, `ML`, `SEMANTIC`, `ACTION`, `APP`, `TEST`.
   - Warehouses `AEGIS_WH` and `AEGIS_APP_WH` (XSMALL, AUTO_SUSPEND = 60, AUTO_RESUME = TRUE, INITIALLY_SUSPENDED = TRUE).
   - Stages `AEGIS_OEE.RAW.DOC_STAGE`, `AEGIS_OEE.APP.APP_STAGE`, `AEGIS_OEE.APP.SKILL_STAGE` (with directory tables enabled on DOC_STAGE).
   - Table `AEGIS_OEE.TEST.ENV_PROBES` (probe_name STRING, result STRING, detail STRING, probed_at TIMESTAMP_TZ).
2. Capability probes — run each, insert one row per probe into `TEST.ENV_PROBES` with result PASS/FAIL/SKIP:
   - `cortex_complete`: SELECT SNOWFLAKE.CORTEX.COMPLETE with a trivial prompt using the default model.
   - `anomaly_detection_available`: attempt to create + drop a throwaway `SNOWFLAKE.ML.ANOMALY_DETECTION` instance on a 10-row generated series in `AEGIS_OEE.TEST`.
   - `forecast_available`: same pattern for `SNOWFLAKE.ML.FORECAST`.
   - `execute_agent_task_grant`: check current role/user can be expected to run agent tasks (SHOW GRANTS; look for EXECUTE AGENT TASK availability to PUBLIC or current role).
   - `coco_usage_view`: SELECT count from `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY` (FAIL only on permission error; 0 rows is PASS).
   - `email_or_webhook_integration`: SHOW NOTIFICATION INTEGRATIONS — record what exists.
3. Print a probe summary table in the response.
4. Append a run record (mission, date, objects created, probe summary) to `docs/coco-evidence.md` under "Development".

## Acceptance criteria

- Re-running the mission changes nothing (idempotent) and refreshes probe rows.
- All probes recorded; failures reported but do NOT fail the mission (they steer later missions).

Print `MISSION 00 COMPLETE` when done.
