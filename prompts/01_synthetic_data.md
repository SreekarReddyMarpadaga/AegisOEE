# Mission 01 — Synthetic Factory Data with Ground Truth

Read `AGENTS.md`. Use the `$synthetic-iot-factory` skill. Non-interactive: print `MISSION 01 FAILED: <reason>` on unrecoverable errors.

## Objective

Generate the full AegisOEE dataset: 75 days of correlated telemetry + ERP + maintenance for the 10 assets in AGENTS.md, with labeled failure episodes, hard negatives, docs for search, and a validation report. Seed = 42, deterministic.

## Deliverables

1. `sql/01_ref_erp.sql` — DDL for all CORE/RAW/TEST tables in the AGENTS.md data model (idempotent), executed. Includes `CORE.SHIFT_CALENDAR` (plant-wide, two 8h shifts A 06:00–14:00 and B 14:00–22:00 IST, 7 days/week; Shift A has 30 min planned downtime, Shift B has 0). Backfill populates the calendar for the full 75-day window.
2. `data_gen/failure_profiles.py` — the five failure-mode signature generators with parameters matching the physics table in AGENTS.md.
3. `data_gen/backfill.py` — seeded 75-day backfill ending yesterday 23:59 IST:
   - 10 assets × 1-min telemetry (~1.08M rows) with jitter, gaps, shift structure.
   - 10 labeled failure episodes total: 3× BEARING_WEAR (one on CNC_01_SPINDLE with degradation starting between day 62 and day 68, failure within the final 7 days — so the golden-path asset is currently at risk or recently failed at demo time), 2× LUBRICATION_LOSS, 2× COOLING_RESTRICTION, 2× RPM_INSTABILITY, 1× SENSOR_FAULT — each written to `TEST.GROUND_TRUTH_FAILURES` and fully correlated (downtime + corrective maintenance + telemetry reset).
   - ≥4 hard-negative episodes (hot-but-healthy, planned RPM changes, planned maintenance, dropouts).
   - Production orders/events consistent with shifts; downtime pauses counts and RPM.
   - Loads via Snowpark or write_pandas in batches; report timing.
4. `data_gen/simulator.py` — live mode: `--replay <MODE> --asset <ID> --duration-min 30 --tick-s 10` streams a compressed episode into RAW.SENSOR_TELEMETRY from healthy baseline through danger zone (used by scripts/inject_anomaly.sh). Also `--heartbeat` mode emitting healthy sensor readings and hourly production events for all assets every 60s.
5. ~10 manual excerpts + ~30 technician notes as markdown files under `data_gen/docs/`, uploaded to `@AEGIS_OEE.RAW.DOC_STAGE`.
6. **MRO parts data** (per AGENTS.md model): `CORE.PARTS_INVENTORY` — ~30 realistic spare parts (spindle bearing kits, shaft seals, lubricant cartridges, pump impellers, motor brushes, drive belts, air filters, couplings) with unit costs, suppliers, lead times (2–14 days), reorder points; `CORE.FAILURE_MODE_PARTS` mapping every (failure_mode, asset_type) pair to its repair kit (e.g., BEARING_WEAR + CNC spindle → 2× bearing kit + 1× grease cartridge). **Seed the golden-path shortage**: the CNC spindle bearing kit must have on_hand_qty below the golden-path WO's requirement so the demo exercises the requisition path; most other parts adequately stocked.
7. Validation per the skill: `tests/validation_report.md` + `TEST.VALIDATION_RESULTS` table. Include the golden-path episode plot data (daily vibration min/max/slope for CNC_01_SPINDLE days 55–62) and a parts-mapping completeness check (every failure_mode×asset_type in use has a kit).
8. Append run record to `docs/run-records.md`.

## Acceptance criteria

- All validation checks PASS (report any FAIL and fix before completing).
- `SELECT COUNT(*) FROM RAW.SENSOR_TELEMETRY` within ±2% of expected.
- Ground-truth episodes: every failure has downtime + maintenance + post-reset; zero overlaps per asset.
- No ground-truth-derived columns exist outside TEST.

Print `MISSION 01 COMPLETE` when done.
