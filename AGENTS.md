# AegisOEE — Project Context for CoCo

You are building **AegisOEE**, a closed-loop predictive-maintenance and OEE decision system, entirely on Snowflake. This file is the single source of truth for names, conventions, and guardrails. Every mission in `prompts/` assumes you have read it.

## Non-negotiables

1. Everything runs **inside Snowflake** (tables, Dynamic Tables, tasks, ML, agents, Streamlit). No external compute except the local data simulator and MCP calls.
2. Write every generated artifact to the repo (`sql/`, `data_gen/`, `ml/`, `semantic/`, `app/`, `tests/`, `scripts/`, `deploy/`, `cortex_project/`) **before** executing it, so runs are reviewable and repeatable.
3. Never ask interactive questions in `exec` missions. If a prerequisite is missing, print `MISSION <NN> FAILED: <reason>` and stop.
4. End every successful mission with the exact line `MISSION <NN> COMPLETE`.
5. Append a run record (date, mission, session id if known, objects created) to `docs/run-records.md`.

## Snowflake environment

| Item | Value |
|---|---|
| Connection alias | `aegis` (override via `$COCO_CONN`) |
| Database | `AEGIS_OEE` |
| Schemas | `RAW`, `CORE`, `FEATURES`, `ML`, `SEMANTIC`, `ACTION`, `APP`, `TEST` |
| Warehouses | `AEGIS_WH` (XSMALL, auto-suspend 60s — build/DT/tasks), `AEGIS_APP_WH` (XSMALL, auto-suspend 60s — app/agent) |
| Timezone | `Asia/Kolkata` |
| Stages | `AEGIS_OEE.RAW.DOC_STAGE` (manuals/notes), `AEGIS_OEE.APP.APP_STAGE` (Streamlit), `AEGIS_OEE.APP.SKILL_STAGE` (published skills) |

Naming: Dynamic Tables prefixed `DT_`; tasks `TASK_`; alerts `ALERT_`; streams `STR_`; UDFs/procs verb-first (`GET_`, `PROPOSE_`, `CREATE_`). All DDL idempotent (`CREATE OR REPLACE` / `IF NOT EXISTS`) and scoped to `AEGIS_OEE` only.

## Plant model (ISA-95)

Site `HYD_PRECISION` (Hyderabad Precision Components) → lines `LINE_1`, `LINE_2` → 10 assets:

| Asset ID | Line | Type | Notes |
|---|---|---|---|
| `CNC_01_SPINDLE` | LINE_1 | CNC spindle | **golden-path asset**, criticality 5 |
| `CNC_02_SPINDLE` | LINE_1 | CNC spindle | criticality 4 |
| `COOLANT_PUMP_01` | LINE_1 | coolant pump | criticality 3 |
| `SERVO_MOTOR_01` | LINE_1 | servo motor | criticality 3 |
| `CONVEYOR_GBX_01` | LINE_1 | conveyor gearbox | criticality 2 |
| `CNC_03_SPINDLE` | LINE_2 | CNC spindle | criticality 4 |
| `CNC_04_SPINDLE` | LINE_2 | CNC spindle | criticality 4 |
| `COOLANT_PUMP_02` | LINE_2 | coolant pump | criticality 3 |
| `AIR_COMP_01` | LINE_2 | air compressor | criticality 3 |
| `CONVEYOR_GBX_02` | LINE_2 | conveyor gearbox | criticality 2 |

Shifts: A 06:00–14:00, B 14:00–22:00 IST; 7 days/week. Daily 30-min planned-maintenance window (05:30–06:00 IST, before Shift A). Planned production time = shift minutes − planned downtime minutes (from `CORE.SHIFT_CALENDAR`).

## Canonical data model

| Object | Grain / essential columns |
|---|---|
| `CORE.ASSET` | asset_id PK, line_id, site_id, asset_type, manufacturer, install_date, criticality 1–5, ideal_rpm, ideal_cycle_s, temp_limit_c, vib_alert_mm_s, vib_danger_mm_s |
| `RAW.SENSOR_TELEMETRY` | asset_id, ts, vibration_rms, vibration_kurtosis, temp_c, rpm, load_pct, quality_flag ('OK','GAP','FLATLINE','SPIKE'), ingest_ts |
| `CORE.PRODUCTION_ORDER` | order_id PK, line_id, product_code, planned_qty, ideal_cycle_s, planned_start_ts, planned_end_ts |
| `RAW.PRODUCTION_EVENT` | asset_id, ts, order_id, state ('RUN','IDLE','DOWN','SETUP'), produced_count, good_count, reject_count, cycle_time_s |
| `CORE.DOWNTIME_EVENT` | event_id PK, asset_id, start_ts, end_ts, is_planned, reason_code, failure_mode, minutes |
| `CORE.MAINTENANCE_HISTORY` | wo_hist_id PK, asset_id, completed_ts, failure_code, finding, action_taken, parts_used, labor_hours, technician_note (free text) |
| `CORE.SHIFT_CALENDAR` | shift_date, shift_code (A/B), start_ts TIMESTAMP_TZ, end_ts TIMESTAMP_TZ, planned_minutes (480), planned_downtime_minutes (30 for A, 0 for B) — plant-wide, not per-asset |
| `TEST.GROUND_TRUTH_FAILURES` | failure_id PK, asset_id, failure_mode, degradation_start_ts, failure_ts, severity — supervised labels, **never** an ML input |
| `CORE.PARTS_INVENTORY` | part_id PK, part_name, category, on_hand_qty, reserved_qty, reorder_point, unit_cost, supplier_name, lead_time_days, bin_location |
| `CORE.FAILURE_MODE_PARTS` | failure_mode, asset_type, part_id FK, qty_required — maps each failure mode per asset type to its repair parts kit |
| `ACTION.PURCHASE_REQUISITION` | req_id PK, wo_id FK (nullable — requisitions may precede WO creation), part_id FK, qty, est_unit_cost, est_total, supplier_name, lead_time_days, rfq_text, status ('PENDING_QUOTE','QUOTED','ORDERED','RECEIVED','CANCELLED'), created_ts |
| `FEATURES.DT_SENSOR_1MIN` | asset_id, minute_ts + per-sensor mean/max/stddev |
| `FEATURES.DT_SENSOR_FEATURES_15MIN` | asset_id, window_ts + rolling mean/max/stddev/slope, kurtosis, temp-to-load residual, rpm variance, baseline z-scores |
| `FEATURES.DT_ASSET_HEALTH` | asset_id (current) — health_score 0–100, anomaly_distance, failure_probability_24h, predicted_mode, risk_level |
| `SEMANTIC.DT_SHIFT_OEE` | line_id, asset_id, shift_date, shift_code — planned_min, downtime_min, run_min, total_count, good_count, availability, performance, quality, oee |
| `ML.ANOMALY_EVENTS` | asset_id, ts, series_name, is_anomaly, distance, percentile, forecast, lower, upper |
| `ACTION.ALERT` | alert_id PK, asset_id, onset_ts, severity P1/P2/P3, confidence 0–1, failure_probability, predicted_mode, oee_impact_est, status ('NEW','TRIAGED','ACKED','SUPPRESSED','CLOSED'), evidence VARIANT |
| `ACTION.WORK_ORDER` | wo_id PK, alert_id FK, asset_id, priority, state ('DRAFT','APPROVED','SYNCED','IN_PROGRESS','RESOLVED','CANCELLED','CLOSED','REJECTED'), title, description, evidence VARIANT, github_issue_url, approved_by, approved_ts, close_reason, closed_at TIMESTAMP_TZ |
| `ACTION.WORK_ORDER_OUTBOX` | outbox_id, wo_id, target ('GITHUB','SLACK'), payload VARIANT, attempts, last_error, status |
| `ACTION.ACTION_AUDIT` | append-only: audit_id, ts, actor, action, object_ref, detail VARIANT |

## Failure physics (simulator + ML must agree)

| Mode | Telemetry signature | Consequence chain |
|---|---|---|
| `BEARING_WEAR` (golden) | vibration_rms ramps 3–7 days pre-failure (ISO 10816: cross vib_alert then vib_danger), kurtosis rises first, temp follows late | micro-stops → slower cycles → breakdown |
| `LUBRICATION_LOSS` | temp + vibration rise together under load | performance loss, defects rise |
| `COOLING_RESTRICTION` | temp ramps, vibration normal | quality loss → thermal shutdown |
| `RPM_INSTABILITY` | rpm/cycle-time oscillation | performance loss, jams |
| `SENSOR_FAULT` | impossible jump, flatline, or gaps | low-confidence alert; **never auto-action** |

Every ground-truth failure must have: matching `CORE.DOWNTIME_EVENT` (unplanned, same mode), a corrective `CORE.MAINTENANCE_HISTORY` row after it, and degradation resets post-maintenance. Include hard negatives: hot-but-healthy heavy load, planned RPM changes, maintenance windows, sensor dropouts.

## OEE math (invariants tested in TEST schema)

- planned_production_time = `CORE.SHIFT_CALENDAR.planned_minutes` − `planned_downtime_minutes` (per shift row)
- run_time = planned_production_time − unplanned_downtime_minutes (from `CORE.DOWNTIME_EVENT` allocated by overlap)
- Availability = run_time / planned_production_time
- Performance = (ideal_cycle_s × total_count) / run_time, capped at 1.0
- Quality = good_count / total_count; good_count ≤ total_count
- OEE = A × P × Q; each component in [0,1]; plant OEE typically 0.55–0.85
- Downtime pauses counts and RPM. Planned maintenance (the daily 30-min window) never counts as unplanned downtime.

## Alert & action rules

- PRIORITY_SCORE = failure_probability × (criticality/5) × imminence × expected_OEE_impact → P1 ≥ 0.5, P2 ≥ 0.25, else P3
- CONFIDENCE = model_confidence × data_quality × evidence_agreement × persistence; below 0.5 → status stays `NEW` labeled "observe", no work-order proposal
- Dedup: one open alert per (asset_id, predicted_mode); refresh evidence instead of inserting duplicates
- The agent may call `PROPOSE_WORK_ORDER` (returns a draft, zero side effects). Only `CREATE_WORK_ORDER` writes, and it requires approver identity + open alert in `ACKED` state + no duplicate open WO; `DRY_RUN` defaults TRUE. Every proposal/approval/rejection/sync lands in `ACTION.ACTION_AUDIT`.
- **Parts check (MRO)**: every work-order draft resolves its parts kit via `FAILURE_MODE_PARTS`, compares against `PARTS_INVENTORY` (on_hand − reserved). Shortages auto-create `PURCHASE_REQUISITION` rows with a computed quote (qty × unit_cost, supplier, lead time) and an AI-drafted RFQ text. Approving a WO reserves available parts (increments reserved_qty) and links open requisitions; parts lead time extends the WO's planned window and is shown to the approver.
- **Outbox dispatcher** (`scripts/outbox_dispatcher.py`): handles outbound GitHub Issue + Slack delivery, GitHub closure sync-back (WO closed/rejected → close linked Issue), and inbound sync (Issue closed externally → WO transitions to RESOLVED/CANCELLED, releases reserved parts on cancellation). All state transitions produce `ACTION_AUDIT` rows. For accounts with EAI, `sql/11_integrations.sql` has native Snowflake procedure versions.
- RCA answers always use the structure: Assessment / Evidence / Operational impact / Alternatives considered / Recommended action / Safety statement / Trace. Causes are "most likely", never proven.

## Skills in this repo

Invoke by name when the mission says so: `$synthetic-iot-factory` (data generation), `$oee-analytics` (OEE SQL + semantics), `$maintenance-triage` (alert triage runbook). Prefer bundled skills `$dynamic-tables`, `$agent-studio`, `$developing-with-streamlit`, `$snowflake-tasks`, `$alert`, `$notification` for their domains.
