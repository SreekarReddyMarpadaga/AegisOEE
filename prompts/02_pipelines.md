# Mission 02 — Near-Real-Time Convergence Pipelines

Read `AGENTS.md`. Use `$oee-analytics` and the bundled `$dynamic-tables` and `$snowflake-tasks` skills. Delegate detail work to the `pipeline-engineer` subagent where useful. Non-interactive: print `MISSION 02 FAILED: <reason>` on unrecoverable errors.

## Objective

Build the declarative IT/OT convergence layer: streams, layered Dynamic Tables, the shift OEE mart, asset health context, and the actionable-alerts feed.

## Deliverables

1. `sql/02_raw_streams.sql` — `STR_SENSOR_TELEMETRY` on RAW.SENSOR_TELEMETRY (+ any stream needed for triggered tasks), executed.
2. `sql/03_dynamic_tables.sql` — executed; all DTs on `AEGIS_WH`:
   - `FEATURES.DT_SENSOR_CLEAN` (dedupe, quality_flag handling, clamps) — TARGET_LAG '1 minute'.
   - `FEATURES.DT_SENSOR_1MIN` and `FEATURES.DT_SENSOR_FEATURES_15MIN` (rolling stats, slopes, baseline z-scores, temp-to-load residual, rpm variance) — lag '1 minute' / '5 minutes'.
   - `FEATURES.DT_TELEMETRY_CONTEXT` — the convergence join: latest features + active production order + last maintenance + open downtime per asset.
3. `sql/04_oee_marts.sql` — executed:
   - `SEMANTIC.DT_SHIFT_OEE` per the oee-analytics layering pattern (numerators/denominators exposed; downtime allocated by overlap).
   - `SEMANTIC.DT_OEE_LINE_DAY`, MTBF/MTTR view, six-big-losses waterfall view.
   - `FEATURES.DT_ASSET_HEALTH` v1 (rule-based health score + placeholders for ML columns filled by Mission 03).
4. TEST checks executed and stored: refresh_mode INCREMENTAL for every DT (report any FULL and fix), OEE invariants pass, raw→mart freshness measured by inserting a probe row and timing visibility (< 120s).
5. Append run record + freshness/refresh evidence to `docs/coco-evidence.md` ("Development").

## Acceptance criteria

- Every DT INCREMENTAL; end-to-end freshness < 120s; all OEE invariants PASS; plant OEE lands in a plausible 0.55–0.85 band on healthy days and visibly dips during failure episodes.

Print `MISSION 02 COMPLETE` when done.
