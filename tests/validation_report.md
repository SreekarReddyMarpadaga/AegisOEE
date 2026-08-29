# AegisOEE Mission 01 — Validation Report

**Generated**: 2026-08-29 | **Seed**: 42 | **Days**: 75 (2026-06-15 to 2026-08-28)

## Summary

| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | Telemetry row count | **PASS** | 717,862 rows — 99.70% of 720,000 expected (within ±2%) |
| 2 | Ground truth count | **PASS** | 10 episodes: 3× BEARING_WEAR, 2× LUBRICATION_LOSS, 2× COOLING_RESTRICTION, 2× RPM_INSTABILITY, 1× SENSOR_FAULT |
| 3 | GT ↔ downtime correlation | **PASS** | All 10 failures have matching `DOWNTIME_EVENT` (same asset, same failure_mode) |
| 4 | GT ↔ maintenance correlation | **PASS** | All 10 failures have corrective `MAINTENANCE_HISTORY` row after failure_ts |
| 5 | No overlapping failures | **PASS** | Zero overlapping failure episodes per asset |
| 6 | Label leakage check | **PASS** | No ground-truth-derived columns exist outside TEST schema |
| 7 | OEE: good ≤ total | **PASS** | 0 violations in 5,922 production events |
| 8 | OEE: count integrity | **PASS** | good_count + reject_count = produced_count for all events |
| 9 | Golden-path bearing shortage | **PASS** | P001 on_hand=1, required=2 → exercises requisition path |
| 10 | Golden-path vibration ramp | **PASS** | CNC_01_SPINDLE: 2.28 avg → 6.55 avg over degradation window |
| 11 | Parts mapping completeness | **PASS** | All 8 used (failure_mode × asset_type) combos have parts kits |
| 12 | Shift calendar | **PASS** | 150 rows = 75 days × 2 shifts |
| 13 | Asset count | **PASS** | 10 assets matching AGENTS.md spec |
| 14 | Doc stage upload | **PASS** | 40 docs uploaded to @AEGIS_OEE.RAW.DOC_STAGE |
| 15 | Hard negatives | **PASS** | 5 episodes (HOT_HEAVY_LOAD ×2, PLANNED_RPM_CHANGE, PLANNED_MAINTENANCE, SENSOR_DROPOUT) |

**Result: 15/15 PASS**

## Table Row Counts

| Table | Rows |
|-------|------|
| RAW.SENSOR_TELEMETRY | 717,862 |
| RAW.PRODUCTION_EVENT | 5,922 |
| CORE.ASSET | 10 |
| CORE.SHIFT_CALENDAR | 150 |
| CORE.PRODUCTION_ORDER | 300 |
| CORE.DOWNTIME_EVENT | 10 |
| CORE.MAINTENANCE_HISTORY | 10 |
| CORE.PARTS_INVENTORY | 30 |
| CORE.FAILURE_MODE_PARTS | 41 |
| TEST.GROUND_TRUTH_FAILURES | 10 |

## Golden-Path Episode: CNC_01_SPINDLE BEARING_WEAR (F010)

- **Degradation start**: 2026-08-19 (day 65)
- **Failure**: 2026-08-26 (day 72) — 7-day ramp
- **Post-repair reset**: 2026-08-26 23:00 IST
- **Bearing kit shortage**: P001 on_hand=1, needs=2

### Daily Vibration Trend (days 55–75)

| Day | Date | Vib Min | Vib Max | Vib Avg | Readings | Phase |
|-----|------|---------|---------|---------|----------|-------|
| 55 | 2026-08-08 | 1.921 | 2.582 | 2.282 | 565 | Healthy |
| 56 | 2026-08-09 | 1.934 | 2.648 | 2.272 | 956 | Healthy |
| 57 | 2026-08-10 | 1.897 | 2.631 | 2.282 | 958 | Healthy |
| 58 | 2026-08-11 | 1.835 | 2.592 | 2.281 | 957 | Healthy |
| 59 | 2026-08-12 | 1.856 | 2.592 | 2.278 | 958 | Healthy |
| 60 | 2026-08-13 | 1.923 | 2.745 | 2.284 | 956 | Healthy |
| 61 | 2026-08-14 | 1.933 | 2.649 | 2.279 | 958 | Healthy |
| 62 | 2026-08-15 | 1.883 | 2.674 | 2.281 | 958 | Healthy |
| 63 | 2026-08-16 | 1.928 | 2.623 | 2.281 | 960 | Healthy |
| 64 | 2026-08-17 | 1.953 | 2.647 | 2.277 | 957 | Healthy |
| 65 | 2026-08-18 | 1.910 | 2.648 | 2.275 | 957 | Healthy |
| **65** | **2026-08-19** | **0.124** | **3.324** | **2.692** | 959 | **Degradation starts** |
| 66 | 2026-08-20 | 0.097 | 4.210 | 3.386 | 957 | Degradation |
| 67 | 2026-08-21 | 0.061 | 4.901 | 4.026 | 958 | Alert zone |
| 68 | 2026-08-22 | 0.000 | 5.755 | 4.664 | 958 | Alert zone |
| 69 | 2026-08-23 | 0.052 | 6.579 | 5.112 | 958 | Danger approaching |
| 70 | 2026-08-24 | 0.000 | 7.442 | 5.748 | 956 | **Danger zone** |
| 71 | 2026-08-25 | 0.042 | 8.194 | 6.548 | 955 | Danger zone |
| **72** | **2026-08-26** | -0.019 | 0.645 | 0.302 | 960 | **Failure + reset** |
| 73 | 2026-08-27 | 1.810 | 2.631 | 2.276 | 957 | Post-repair healthy |
| 74 | 2026-08-28 | 1.942 | 2.641 | 2.281 | 957 | Healthy |

## Failure Episode Summary

| ID | Asset | Mode | Degrad Start | Failure | Duration | Severity |
|----|-------|------|-------------|---------|----------|----------|
| F001 | CNC_02_SPINDLE | BEARING_WEAR | 2026-06-23 | 2026-06-29 | 6 days | HIGH |
| F002 | CNC_03_SPINDLE | BEARING_WEAR | 2026-07-15 | 2026-07-20 | 5 days | HIGH |
| F003 | COOLANT_PUMP_01 | LUBRICATION_LOSS | 2026-06-30 | 2026-07-04 | 4 days | MEDIUM |
| F004 | SERVO_MOTOR_01 | LUBRICATION_LOSS | 2026-07-27 | 2026-07-31 | 4 days | MEDIUM |
| F005 | COOLANT_PUMP_02 | COOLING_RESTRICTION | 2026-07-05 | 2026-07-10 | 5 days | MEDIUM |
| F006 | AIR_COMP_01 | COOLING_RESTRICTION | 2026-08-04 | 2026-08-09 | 5 days | MEDIUM |
| F007 | CONVEYOR_GBX_01 | RPM_INSTABILITY | 2026-07-10 | 2026-07-13 | 3 days | LOW |
| F008 | CNC_04_SPINDLE | RPM_INSTABILITY | 2026-08-09 | 2026-08-12 | 3 days | MEDIUM |
| F009 | CONVEYOR_GBX_02 | SENSOR_FAULT | 2026-07-23 | 2026-07-23 | <1 day | LOW |
| F010 | CNC_01_SPINDLE | BEARING_WEAR | 2026-08-19 | 2026-08-26 | 7 days | CRITICAL |

## Hard Negatives

| Asset | Type | Days | Description |
|-------|------|------|-------------|
| CNC_01_SPINDLE | HOT_HEAVY_LOAD | 20–22 | High temp under heavy load, not a failure |
| CNC_03_SPINDLE | PLANNED_RPM_CHANGE | 45–46 | Product changeover RPM shift |
| SERVO_MOTOR_01 | PLANNED_MAINTENANCE | 35 | Extended planned maintenance window |
| COOLANT_PUMP_01 | SENSOR_DROPOUT | 55 | Brief sensor dropout, healthy asset |
| CNC_04_SPINDLE | HOT_HEAVY_LOAD | 10–12 | Heavy batch, elevated temp, normal vibration |
