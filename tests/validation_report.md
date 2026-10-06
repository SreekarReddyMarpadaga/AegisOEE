# AegisOEE Mission 01 — Validation Report

**Generated**: 2026-10-05 | **Seed**: 42 | **Days**: 75 (2026-07-22 to 2026-10-04)

## Summary

| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | Telemetry row count | **PASS** | 718,129 rows — 99.74% of 720,000 expected (within ±2%) |
| 2 | Ground truth count | **PASS** | 10 episodes: 3× BEARING_WEAR, 2× LUBRICATION_LOSS, 2× COOLING_RESTRICTION, 2× RPM_INSTABILITY, 1× SENSOR_FAULT |
| 3 | GT ↔ downtime correlation | **PASS** | All 10 failures have matching `DOWNTIME_EVENT` (same asset, same failure_mode) |
| 4 | GT ↔ maintenance correlation | **PASS** | All 10 failures have corrective `MAINTENANCE_HISTORY` row after failure_ts |
| 5 | No overlapping failures | **PASS** | Zero overlapping failure episodes per asset |
| 6 | Label leakage check | **PASS** | No ground-truth-derived columns exist outside TEST schema |
| 7 | OEE: good ≤ total | **PASS** | 0 violations in 5,909 production events |
| 8 | Shift calendar | **PASS** | 150 rows = 75 days × 2 shifts (2026-07-22 to 2026-10-04) |
| 9 | Golden-path bearing shortage | **PASS** | P001 on_hand=1, required=2 → exercises requisition path |
| 10 | Golden-path vibration ramp | **PASS** | CNC_01_SPINDLE: 2.03 avg → 5.74 avg over degradation window |
| 11 | Parts mapping completeness | **PASS** | All 8 used (failure_mode × asset_type) combos have parts kits |
| 12 | Asset count | **PASS** | 10 assets matching AGENTS.md spec |
| 13 | Doc stage upload | **PASS** | 40 docs uploaded to @AEGIS_OEE.RAW.DOC_STAGE |
| 14 | Hard negatives | **PASS** | 5 episodes (HOT_HEAVY_LOAD ×2, PLANNED_RPM_CHANGE, PLANNED_MAINTENANCE, SENSOR_DROPOUT) |
| 15 | GT timeline causality | **PASS** | All 10: degradation_start ≤ failure_ts < maintenance_completed (SENSOR_FAULT instantaneous by design) |

**Result: 15/15 PASS**

## Table Row Counts

| Table | Rows |
|-------|------|
| RAW.SENSOR_TELEMETRY | 718,129 |
| RAW.PRODUCTION_EVENT | 5,909 |
| CORE.ASSET | 10 |
| CORE.SHIFT_CALENDAR | 150 |
| CORE.PRODUCTION_ORDER | 300 |
| CORE.DOWNTIME_EVENT | 5,741 |
| CORE.MAINTENANCE_HISTORY | 10 |
| CORE.PARTS_INVENTORY | 30 |
| CORE.FAILURE_MODE_PARTS | 41 |
| TEST.GROUND_TRUTH_FAILURES | 10 |

## Golden-Path Episode: CNC_01_SPINDLE BEARING_WEAR (F010)

- **Degradation start**: 2026-09-25 IST (day 65)
- **Failure**: 2026-10-02 IST (day 72) — 7-day ramp
- **Post-repair reset**: ~2026-10-02
- **Bearing kit shortage**: P001 on_hand=1, needs=2

### Daily Vibration Trend (days 55–75)

| Day | Date | Vib Min | Vib Max | Vib Avg | Phase |
|-----|------|---------|---------|---------|-------|
| 56 | 2026-09-15 | 0.07 | 2.57 | 1.97 | Healthy |
| 57 | 2026-09-16 | 0.05 | 2.64 | 2.01 | Healthy |
| 58 | 2026-09-17 | 0.08 | 2.63 | 1.99 | Healthy |
| 59 | 2026-09-18 | 0.08 | 2.64 | 2.05 | Healthy |
| 60 | 2026-09-19 | 0.05 | 2.57 | 2.00 | Healthy |
| 61 | 2026-09-20 | 0.06 | 2.65 | 2.05 | Healthy |
| 62 | 2026-09-21 | 0.02 | 2.61 | 2.09 | Healthy |
| 63 | 2026-09-22 | 0.00 | 2.74 | 2.01 | Healthy |
| 64 | 2026-09-23 | 0.09 | 2.61 | 2.00 | Healthy |
| **65** | **2026-09-24** | 0.05 | 2.62 | 2.03 | Healthy → Degradation onset |
| **66** | **2026-09-25** | 0.00 | 3.25 | 2.39 | **Degradation** |
| 67 | 2026-09-26 | 0.05 | 4.31 | 2.90 | Degradation |
| 68 | 2026-09-27 | 0.03 | 4.89 | 3.47 | Alert zone |
| 69 | 2026-09-28 | 0.08 | 5.71 | 4.03 | Alert zone |
| 70 | 2026-09-29 | -0.01 | 6.85 | 4.59 | Danger approaching |
| 71 | 2026-09-30 | -0.05 | 7.35 | 5.10 | **Danger zone** |
| **72** | **2026-10-01** | 0.03 | 8.10 | 5.74 | **Failure + downtime** |
| 73 | 2026-10-02 | 0.03 | 0.66 | 0.30 | Post-repair reset |
| 74 | 2026-10-03 | -0.06 | 2.62 | 2.02 | Healthy |
| 75 | 2026-10-04 | 0.01 | 2.61 | 2.04 | Healthy |

## Failure Episode Summary

| ID | Asset | Mode | Degrad Start | Failure | Duration | Severity |
|----|-------|------|-------------|---------|----------|----------|
| F001 | CNC_02_SPINDLE | BEARING_WEAR | 2026-07-30 | 2026-08-05 | 6 days | HIGH |
| F002 | CNC_03_SPINDLE | BEARING_WEAR | 2026-08-21 | 2026-08-26 | 5 days | HIGH |
| F003 | COOLANT_PUMP_01 | LUBRICATION_LOSS | 2026-08-06 | 2026-08-10 | 4 days | MEDIUM |
| F004 | SERVO_MOTOR_01 | LUBRICATION_LOSS | 2026-09-02 | 2026-09-06 | 4 days | MEDIUM |
| F005 | COOLANT_PUMP_02 | COOLING_RESTRICTION | 2026-08-11 | 2026-08-16 | 5 days | MEDIUM |
| F006 | AIR_COMP_01 | COOLING_RESTRICTION | 2026-09-10 | 2026-09-15 | 5 days | MEDIUM |
| F007 | CONVEYOR_GBX_01 | RPM_INSTABILITY | 2026-08-16 | 2026-08-19 | 3 days | LOW |
| F008 | CNC_04_SPINDLE | RPM_INSTABILITY | 2026-09-15 | 2026-09-18 | 3 days | MEDIUM |
| F009 | CONVEYOR_GBX_02 | SENSOR_FAULT | 2026-08-29 | 2026-08-29 | <1 day | LOW |
| F010 | CNC_01_SPINDLE | BEARING_WEAR | 2026-09-25 | 2026-10-02 | 7 days | CRITICAL |

## Hard Negatives

| Asset | Type | Days | Description |
|-------|------|------|-------------|
| CNC_01_SPINDLE | HOT_HEAVY_LOAD | 20–22 | High temp under heavy load, not a failure |
| CNC_03_SPINDLE | PLANNED_RPM_CHANGE | 45–46 | Product changeover RPM shift |
| SERVO_MOTOR_01 | PLANNED_MAINTENANCE | 35 | Extended planned maintenance window |
| COOLANT_PUMP_01 | SENSOR_DROPOUT | 55 | Brief sensor dropout, healthy asset |
| CNC_04_SPINDLE | HOT_HEAVY_LOAD | 10–12 | Heavy batch, elevated temp, normal vibration |
