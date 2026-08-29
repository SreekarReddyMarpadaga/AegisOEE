---
name: synthetic-iot-factory
description: Generate referentially consistent, physics-plausible synthetic manufacturing data on Snowflake — IoT sensor telemetry (vibration/temperature/RPM/load) correlated with ERP production, downtime, maintenance history, and labeled ground-truth failure episodes. Use when a user asks to create factory/IoT/OT demo data, predictive-maintenance training data, degradation signatures, or a live sensor replay. Reusable for any plant model; defaults target the AEGIS_OEE database.
---

# When to Use

- "Generate synthetic sensor/IoT/factory/manufacturing data"
- "Create labeled failure data for predictive maintenance"
- "Backfill telemetry correlated with ERP and maintenance records"
- "Simulate a live degradation / failure replay"

# What This Skill Provides

A contract for building **deterministic, seeded** generators whose output is credible to domain experts and usable as supervised ML ground truth. It encodes failure physics, referential-consistency rules, and a validation-report template.

# Instructions

1. **Inputs** (take from project context or defaults): asset list with types/criticality/ideal RPM/limits, day count (default 75), telemetry grain (default 1 minute), failure episodes (default 8–12 across ≥4 modes), random seed (default 42). Never generate unseeded data.
2. **Write generators as code first** (Python in `data_gen/`, loaders in `sql/`), then execute. Generators must be re-runnable: same seed → identical data.
3. **Encode failure physics** — each episode gets `degradation_start_ts` and `failure_ts` written to a ground-truth table BEFORE telemetry is generated, then telemetry is shaped to match:
   - `BEARING_WEAR`: vibration_rms ramps linearly+noise over 3–7 days (healthy baseline → alert zone → danger zone per ISO 10816-style thresholds); kurtosis rises in the first third; temp_c rises only in the final 20%.
   - `LUBRICATION_LOSS`: temp and vibration rise together, correlated with load_pct.
   - `COOLING_RESTRICTION`: temp ramps alone; vibration stays baseline.
   - `RPM_INSTABILITY`: rpm oscillation amplitude grows; cycle_time_s variance grows.
   - `SENSOR_FAULT`: inject flatlines, impossible jumps, or NULL gaps; set quality_flag accordingly; these are NOT failures.
4. **Correlate with ERP/maintenance** (mandatory):
   - Each failure episode ends in an unplanned `DOWNTIME_EVENT` with the same failure_mode.
   - A corrective `MAINTENANCE_HISTORY` row (finding + free-text technician note naming the component) completes 2–24h after failure; telemetry baselines reset after it.
   - Production events during degradation show micro-stops (short DOWN states), rising cycle_time_s, and (for thermal modes) rising reject_count.
   - Downtime windows pause produced_count and drop RPM to 0.
5. **Generate hard negatives**: high temp under heavy-but-healthy load, planned RPM changes from product changeovers, planned maintenance windows, brief sensor dropouts. At least 2 ambiguous non-failure episodes per line.
6. **Also produce**: 8–12 maintenance-manual excerpts and ~30 technician notes as text/markdown files uploaded to a stage — used later by Cortex Search.
7. **Validation report** (write to `tests/validation_report.md` + a results table): PK/FK integrity, value ranges vs asset limits, OEE invariants (good ≤ total, performance ≤ 1), timeline causality (degradation_start < failure < maintenance), label leakage check (no ground-truth columns in feature-visible tables), class balance summary, and per-episode plots-as-SQL (min/max/slope per day).
8. **Live replay mode**: provide a generator flag that streams one episode in compressed time (default: bearing wear over ~30 minutes, 10s inserts) into the raw telemetry table for live demos.

## Best Practices

- Timestamps in plant-local timezone; include a shift calendar.
- Keep noise realistic: ±5% sensor jitter, occasional missing minutes even for healthy assets.
- Never let two failure episodes overlap on one asset.
- Row-count sanity: assets × days × 1440 within ±2% after gaps.

# Examples

## Example: default run
User: `$synthetic-iot-factory generate the full AegisOEE dataset`
Assistant: reads plant model from AGENTS.md, writes `data_gen/failure_profiles.py`, `data_gen/simulator.py`, `data_gen/backfill.py`, `sql/01_ref_erp.sql`, runs backfill, prints validation summary table, ends with row counts per table.

## Example: replay
User: `$synthetic-iot-factory replay bearing wear on CNC_01_SPINDLE over 30 minutes`
Assistant: runs `python data_gen/simulator.py --replay BEARING_WEAR --asset CNC_01_SPINDLE --duration-min 30 --tick-s 10`.
