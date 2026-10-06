# Mission 01B — OEE Realism (code-only, run before re-running missions 01→06)

Read `AGENTS.md` (OEE math + failure physics) and `$synthetic-iot-factory`. Non-interactive: print `MISSION 01B FAILED: <reason>` on unrecoverable errors. **Do not connect to or write to Snowflake in this mission** — it only changes generator code, tests and docs.

## Problem

The seeded dataset gives plant OEE ≈ 0.967 (Availability 0.999, Performance 0.983, Quality 0.985). `AGENTS.md` says plant OEE is typically 0.55–0.85, and `M02_plant_oee_plausible` has failed since the first build. Healthy days must look like a real plant, not a perfect one, without changing the failure physics the ML and the golden path rely on.

## Deliverables

1. `data_gen/backfill.py` (and `data_gen/failure_profiles.py` only if needed): on normal, non-failure days produce realistic losses, tracked by the Six Big Losses:
   - **Availability losses**: short unplanned stops (changeover/setup, minor jams, material wait, tool change) written to `CORE.DOWNTIME_EVENT` with `is_planned = FALSE`, `failure_mode` NULL, and reason codes that map onto the existing `V_SIX_BIG_LOSSES` view. During each stop, telemetry `rpm` and production counts must go to zero, consistent with "downtime pauses counts and RPM". The daily 05:30–06:00 maintenance window stays planned and never counts as unplanned.
   - **Performance losses**: realistic speed loss (cycle time above ideal; slow-running periods after changeovers).
   - **Quality losses**: reject rates with realistic scrap/rework, higher after changeovers, lower on stable runs.
   - Per-asset-type and per-line variation (e.g. LINE_2 slightly lower than LINE_1; spindles and conveyors differ) so charts are not flat.
2. **Target ranges (averages over all `SEMANTIC.DT_SHIFT_OEE` rows)**: Availability 0.85–0.93, Performance 0.80–0.92, Quality 0.94–0.98, **plant OEE 0.62–0.80**. Failure-episode shifts must dip clearly lower than healthy shifts (≥ 8 points). No shift outside [0,1]; good_count ≤ total_count; OEE = A×P×Q still exact.
3. **Do not break what the rest of the system depends on**:
   - Seed 42 stays deterministic. Draw the new loss effects from a **separate RNG stream** (e.g. `np.random.default_rng(seed + 1)`), so failure-episode, hard-negative, parts and golden-path generation keep the same structure.
   - The 10 labeled failures, ≥4 hard negatives, golden path (CNC_01_SPINDLE BEARING_WEAR, degradation day 65, failure day 72, vibration ~2.3 → ~6.5 mm/s) and the P001 parts shortage must be unchanged. Every failure still has a matching downtime, a corrective maintenance row after it, and a post-repair reset; no overlaps per asset.
   - New minor stops must not overlap ground-truth failure/degradation downtime on the same asset.
   - Row count of `RAW.SENSOR_TELEMETRY` stays within ±2% of the previous 717,862 (stops zero the rpm/count values, they do not delete rows).
4. Add a `--dry-run` flag to `backfill.py` that generates everything in memory with no Snowflake connection and prints: row counts per table, and approximate plant/line Availability, Performance, Quality and OEE computed with the same formulas as `DT_SHIFT_OEE`. Run it and iterate until the target ranges in (2) are met; include the final printout in the run record.
5. Update `tests/` and `sql/03_dynamic_tables.sql` validation/probe text so `plant_oee_plausible` checks the **0.55–0.85** band and failure-day dip, and update any stale OEE figures (e.g. 0.97, 0.948/0.970) in `README.md`, `docs/`, `semantic/`, `tests/analyst_eval.md`, and `prompts/` to be described by range or removed. Do not invent measured numbers; measured values are recorded when the pipeline is rebuilt.
6. Append a run record to `docs/run-records.md`.

## Acceptance criteria

- `python data_gen/backfill.py --dry-run` meets every target range and keeps all structural counts (10 failures, ≥4 hard negatives, 30 parts, 41 failure-mode-part mappings).
- No hard-coded calendar dates anywhere in new code or tests (the window is relative to run date).

Print `MISSION 01B COMPLETE` when done.
