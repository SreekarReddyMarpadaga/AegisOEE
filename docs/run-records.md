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

### Mission 01 — Synthetic Factory Data (2026-08-29)

**Objects created/loaded:**
- **Files**: `sql/01_ref_erp.sql`, `data_gen/failure_profiles.py`, `data_gen/backfill.py`, `data_gen/simulator.py`, `data_gen/__init__.py`, `tests/validation_report.md`, 10 manual excerpts + 30 technician notes in `data_gen/docs/`
- **Tables**: CORE.ASSET (10), CORE.SHIFT_CALENDAR (150), CORE.PRODUCTION_ORDER (300), CORE.DOWNTIME_EVENT (10), CORE.MAINTENANCE_HISTORY (10), CORE.PARTS_INVENTORY (30), CORE.FAILURE_MODE_PARTS (41), RAW.SENSOR_TELEMETRY (717,862), RAW.PRODUCTION_EVENT (5,922), TEST.GROUND_TRUTH_FAILURES (10), TEST.VALIDATION_RESULTS (15)
- **Stage**: @AEGIS_OEE.RAW.DOC_STAGE — 40 markdown docs (10 manuals + 30 tech notes)
- **Stage**: @AEGIS_OEE.RAW.BACKFILL_STAGE — temp staging (can be dropped)

**Parameters**: Seed=42, 75 days (2026-06-15 to 2026-08-28), 10 assets, 10 failure episodes, 5 hard negatives.

**Validation**: 15/15 checks PASS. See `tests/validation_report.md`.

| Check | Result |
|---|---|
| Telemetry rows (±2% of 720K) | PASS (717,862 = 99.70%) |
| GT downtime + maintenance correlated | PASS (10/10) |
| No overlapping failures | PASS |
| Label leakage | PASS |
| OEE invariants (good ≤ total) | PASS |
| Golden-path shortage (P001) | PASS (on_hand=1, need=2) |
| Golden-path vib ramp | PASS (2.28→6.55 avg) |
| Parts mapping completeness | PASS (8/8 combos) |

### Mission 02 — Convergence Pipelines (2026-08-29)

**Objects created/altered:**

| Object | Schema | Type | Refresh Mode |
|---|---|---|---|
| STR_SENSOR_TELEMETRY | RAW | Stream (append-only) | — |
| STR_PRODUCTION_EVENT | RAW | Stream (append-only) | — |
| DT_SENSOR_CLEAN | FEATURES | Dynamic Table | INCREMENTAL |
| DT_SENSOR_1MIN | FEATURES | Dynamic Table | INCREMENTAL |
| DT_SENSOR_FEATURES_15MIN | FEATURES | Dynamic Table | INCREMENTAL |
| DT_TELEMETRY_CONTEXT | FEATURES | Dynamic Table | INCREMENTAL |
| DT_SHIFT_OEE | SEMANTIC | Dynamic Table | INCREMENTAL |
| DT_OEE_LINE_DAY | SEMANTIC | Dynamic Table | INCREMENTAL |
| DT_ASSET_HEALTH | FEATURES | Dynamic Table | INCREMENTAL |
| V_MTBF_MTTR | SEMANTIC | View | — |
| V_SIX_BIG_LOSSES | SEMANTIC | View | — |

**Files modified:** `sql/03_dynamic_tables.sql` (TIME_SLICE cast fix), `sql/04_oee_marts.sql` (added REFRESH_MODE=INCREMENTAL to 3 DTs).

**Fixes applied:**
1. TIME_SLICE does not accept TIMESTAMP_TZ — cast `minute_ts::TIMESTAMP_NTZ` in DT_SENSOR_FEATURES_15MIN.
2. Four DTs defaulted to FULL refresh — recreated with explicit `REFRESH_MODE = INCREMENTAL`.

**Freshness probe:** 46 seconds (RAW insert → DT_SENSOR_CLEAN visibility).

**Validation:** 7/8 PASS, 1 FAIL (plant_oee_plausible: avg_oee=0.9668, above 0.95 ceiling — data characteristic, not pipeline bug).

| Check | Result | Detail |
|---|---|---|
| oee_apq_range | PASS | 0 violations |
| oee_product_check | PASS | 0 violations |
| downtime_max_1440 | PASS | 0 violations |
| good_le_total | PASS | 0 violations |
| plant_oee_plausible | FAIL | avg=0.9668, min=0.245, max=0.9879 |
| oee_dips_on_failures | PASS | failure_day=0.8407, healthy_day=0.968 |
| dt_row_counts | PASS | clean=717862, 1min=717567, 15min=48000, oee=747, health=10 |
| freshness_probe | PASS | latency_s=46 |

**OEE sample ranges:** Availability 0.24–1.0, Performance 0.76–1.0, Quality 0.98–0.99, OEE 0.24–0.99.

**Asset health:** All 10 assets scored, range 85–100, all risk_level=LOW (no active degradation at simulation end).

