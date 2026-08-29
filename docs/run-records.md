# Run Records & Usage Logs

Where this project's build and operations records live, and how to query CoCo usage on any account after a rebuild.

## Record locations

| Record | Location |
|---|---|
| Mission run transcripts | `docs/runs/` (each headless run tees its full log here; regenerated on rebuild) |
| Session transcripts | `cortex conversations list` → `cortex conversations transcript <id>` |
| SQL guardrail log | `.cortex/hooks/tool-log.jsonl` — every tool call the sql-guard hook inspected |
| Pipeline/task history | Snowflake: `INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY`, `TASK_HISTORY` |
| Test results | `AEGIS_OEE.TEST` schema (`VALIDATION_RESULTS`, `ML_METRICS`, `AGENT_EVAL_RESULTS`, `ACTION_GUARDRAIL_RESULTS`) + `tests/` |
| Planning artifacts | `docs/adr/`, `docs/risk-register.md`, `docs/acceptance-tests.md` |
| Usage snapshots | `bash scripts/snapshot_usage.sh` → `docs/runs/` |

## Querying CoCo usage

Account-level usage (also rendered in the app sidebar):

```sql
SELECT interface, COUNT(*) AS requests, SUM(token_credits) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
GROUP BY interface;
```

View latency is up to ~1 hour; history covers 365 days.

## Session log

| Date | Activity | Objects Created | Session/Thread ID |
|---|---|---|---|
| 2026-08-29 | Planning session (`prompts/planning_session.md`, 21m) | `docs/adr/ADR-001..005.md`, `docs/risk-register.md`, `docs/acceptance-tests.md` | `731c0df1-28de-4cdd-a68c-1c7d7c5c6d63` |

### Planning Decisions Log (2026-08-29)

| # | Decision | Applied to |
|---|---|---|
| D1 | Add `CORE.SHIFT_CALENDAR` — plant-wide, 2 shifts (A 06:00–14:00, B 14:00–22:00 IST), 7 days/week, Shift A has 30-min planned maintenance | `AGENTS.md` (data model + shifts + OEE math), `prompts/01_synthetic_data.md` (DDL + backfill) |
| D2 | Pin golden-path CNC_01_SPINDLE BEARING_WEAR to final 2 weeks (degradation day 62–68, failure within last 7 days) | `prompts/01_synthetic_data.md` |
| D3 | Remove non-existent `$search-optimization` skill reference | `prompts/04_semantics_agent.md` |
| D4 | Confirm 3 anomaly models (one per signal family, multi-series by asset_id) | `prompts/03_ml.md` |
| D5 | Confirm `PURCHASE_REQUISITION.wo_id` is nullable FK | `AGENTS.md` |
| D6 | OUTBOX is canonical write path; Slack wired at script level; GitHub MCP stays interactive-only; no further integration wiring before missions | No file change (confirms ADR-004) |
| D7 | Mission 06 attempt-and-fallback for Streamlit runtime, no pre-probe | No file change (confirms ADR-005) |
| D8 | Skip XGBoost in main pass — anomaly detection + forecast + z-score fallback only | `prompts/03_ml.md` |

### Mission 00 — Foundation (2026-08-29)

**Objects created:** DB `AEGIS_OEE`; schemas RAW, CORE, FEATURES, ML, SEMANTIC, ACTION, APP, TEST; warehouses AEGIS_WH, AEGIS_APP_WH; stages DOC_STAGE (w/ directory), APP_STAGE, SKILL_STAGE; table TEST.ENV_PROBES; file `sql/00_setup.sql`.

| Probe | Result | Detail |
|---|---|---|
| anomaly_detection_available | PASS | model created and dropped successfully |
| coco_usage_view | PASS | 83 rows |
| cortex_complete | PASS | Hello (llama3.1-8b) |
| email_or_webhook_integration | PASS | No notification integrations found |
| execute_agent_task_grant | PASS | EXECUTE AGENT TASK on ACCOUNTADMIN |
| forecast_available | PASS | model created and dropped successfully |
