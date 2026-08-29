---
name: oee-analytics
description: Compute and model Overall Equipment Effectiveness (OEE) correctly on Snowflake — availability/performance/quality math, six-big-losses taxonomy, MTBF/MTTR, shift-grain Dynamic Table marts, reconciliation tests, and semantic-view metric definitions for Cortex Analyst. Use when building OEE marts, KPI dashboards, loss waterfalls, or manufacturing semantic models.
---

# When to Use

- "Build an OEE mart / KPI / dashboard / semantic view"
- "Calculate availability, performance, quality, MTBF, MTTR"
- "Why doesn't my OEE reconcile?"

# What This Skill Provides

Authoritative OEE math with invariants, SQL layering patterns for near-real-time marts, and semantic-model conventions so natural-language answers match SQL ground truth.

# Instructions

## Formulas (never deviate)

- planned_production_time = shift_minutes − planned_downtime_minutes
- run_time = planned_production_time − unplanned_downtime_minutes
- **Availability** = run_time / planned_production_time
- **Performance** = (ideal_cycle_s × total_count) / (run_time × 60), **capped at 1.0** (flag >1 rows as data-quality errors)
- **Quality** = good_count / total_count (0 if total_count = 0; never divide by zero)
- **OEE** = A × P × Q
- MTBF = total run_time / failure_count; MTTR = total unplanned downtime / failure_count

## Six big losses mapping

Availability ← breakdowns, setup/adjustments. Performance ← micro-stops, reduced speed. Quality ← startup rejects, production rejects. Attribute every lost minute/unit to exactly one bucket — the loss waterfall must sum to (planned_time − fully_productive_time).

## SQL layering pattern (Dynamic Tables)

1. Clean layer: dedupe by (asset_id, ts), handle NULL/flatline flags, clamp impossible values.
2. Minute/window aggregates with `TARGET_LAG = '1 minute'`, incremental refresh (verify with SHOW DYNAMIC TABLES → refresh_mode).
3. Shift mart at (line, asset, shift_date, shift_code) grain joining production events + downtime + shift calendar. Downtime allocated to shifts by overlap, not by start timestamp.
4. Expose components AND numerators/denominators as columns so consumers can re-aggregate correctly (never average OEE percentages — recompute from sums).

## Reconciliation tests (write to TEST schema)

- Sum of shift-grain counts == raw event counts per day.
- A, P, Q each in [0,1]; OEE == A*P*Q within 1e-9.
- Downtime minutes per asset-day ≤ 1440.
- Loss waterfall sums exactly to time budget.

## Semantic-view conventions (Cortex Analyst)

- Metrics defined from base measures (sums), not pre-averaged ratios: oee = SUM(good_units×ideal_cycle) / SUM(planned_seconds) style derivations documented in description text.
- Rich synonyms: OEE, overall equipment effectiveness, equipment efficiency; downtime = outage = stoppage.
- ≥15 verified queries covering: lowest OEE line last week, per-shift trend, loss breakdown, MTBF/MTTR by asset type, availability impact of a named failure mode, alert counts by severity.

# Examples

User: `$oee-analytics build the shift OEE mart` → produces `sql/04_oee_marts.sql` with the layering pattern + TEST reconciliation queries, executes, reports pass/fail per invariant.
