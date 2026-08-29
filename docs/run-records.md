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

| Date | Activity | Session/Thread ID |
|---|---|---|
| | Planning session (`prompts/planning_session.md`) | |
| | Missions 00–06 (see `docs/runs/`) | |
| | Scheduled triage / digest runs | |
