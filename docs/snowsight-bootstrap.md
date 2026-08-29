# AegisOEE — Snowsight CoCo Bootstrap (for teammates working WITHOUT the repo)

Send teammates everything between the markers below — they paste it as their **first message** into CoCo in Snowsight. It is fully self-contained (no repo files needed) and seeds their session with the complete plan, spec, and quality bars. They explore their own variants; we merge the best back into this repo's missions.

**Distribution notes**
- Same Snowflake account? Their Snowsight CoCo usage lands in `SNOWFLAKE_COCO_USAGE_HISTORY` as `interface='snowsight'`, documenting multi-surface CoCo usage. Encourage them to note session/thread IDs.
- Collision rule is inside the prompt: they build in `AEGIS_OEE_<NAME>`, never in `AEGIS_OEE` (the merge target this repo owns).
- To bring work back: they share generated SQL/YAML/agent specs + eval results (copy from Snowsight or via a stage); we fold winners into `prompts/` missions here.

---- COPY EVERYTHING BELOW THIS LINE ----

```text
You are my build partner for AegisOEE. Treat this message as your
persistent project memory. Confirm you've absorbed it, then help me build step by step.

# PRODUCT
AegisOEE: closed-loop predictive maintenance + OEE decision system, 100% Snowflake-native,
built and operated through CoCo. It detects equipment degradation from IoT telemetry,
explains the most likely root cause with evidence, quantifies OEE impact, and converts a
HUMAN-APPROVED recommendation into a governed work order with an immutable audit trail.
Golden path demo: CNC_01_SPINDLE bearing wear -> rising vibration RMS/kurtosis -> P1 alert
-> evidence-backed RCA by a Cortex Agent -> human approval -> governed work order -> audit.
Design priorities: real-world relevance, technical execution, solution completeness.
Use CoCo throughout planning, development, execution, and testing.

# MY SANDBOX (critical)
Build everything in database AEGIS_OEE_<MYNAME> (ask me for my name and substitute it).
NEVER create, alter, or drop anything in AEGIS_OEE — that is the team's merge target.
Schemas: RAW, CORE, FEATURES, ML, SEMANTIC, ACTION, APP, TEST. Warehouse XSMALL,
AUTO_SUSPEND=60. Timezone Asia/Kolkata. Random seed 42 everywhere (deterministic data).
Naming: dynamic tables DT_*, tasks TASK_*, streams STR_*, procs/UDFs verb-first.

# PLANT MODEL (ISA-95)
Site HYD_PRECISION -> lines LINE_1, LINE_2 -> 10 assets:
LINE_1: CNC_01_SPINDLE (golden path, criticality 5), CNC_02_SPINDLE (4),
COOLANT_PUMP_01 (3), SERVO_MOTOR_01 (3), CONVEYOR_GBX_01 (2).
LINE_2: CNC_03_SPINDLE (4), CNC_04_SPINDLE (4), COOLANT_PUMP_02 (3), AIR_COMP_01 (3),
CONVEYOR_GBX_02 (2). Shifts: A 06:00-14:00, B 14:00-22:00, C 22:00-06:00 IST.

# DATA MODEL (essential columns)
CORE.ASSET(asset_id PK, line_id, site_id, asset_type, criticality 1-5, ideal_rpm,
  ideal_cycle_s, temp_limit_c, vib_alert_mm_s, vib_danger_mm_s)
RAW.SENSOR_TELEMETRY(asset_id, ts, vibration_rms, vibration_kurtosis, temp_c, rpm,
  load_pct, quality_flag OK|GAP|FLATLINE|SPIKE, ingest_ts)  -- 1-minute grain
CORE.PRODUCTION_ORDER(order_id, line_id, product_code, planned_qty, ideal_cycle_s,
  planned_start_ts, planned_end_ts)
RAW.PRODUCTION_EVENT(asset_id, ts, order_id, state RUN|IDLE|DOWN|SETUP, produced_count,
  good_count, reject_count, cycle_time_s)
CORE.DOWNTIME_EVENT(event_id, asset_id, start_ts, end_ts, is_planned, reason_code,
  failure_mode, minutes)
CORE.MAINTENANCE_HISTORY(wo_hist_id, asset_id, completed_ts, failure_code, finding,
  action_taken, parts_used, labor_hours, technician_note free-text)
TEST.GROUND_TRUTH_FAILURES(failure_id, asset_id, failure_mode, degradation_start_ts,
  failure_ts, severity)  -- supervised labels, NEVER an ML feature input
FEATURES: DT_SENSOR_1MIN, DT_SENSOR_FEATURES_15MIN (rolling mean/max/std/slope, kurtosis,
  temp-to-load residual, rpm variance, baseline z-scores), DT_ASSET_HEALTH (health_score
  0-100, anomaly_distance, failure_probability_24h, predicted_mode, risk_level)
SEMANTIC.DT_SHIFT_OEE(line, asset, shift_date, shift_code, planned_min, downtime_min,
  run_min, total_count, good_count, availability, performance, quality, oee)
ACTION.ALERT(alert_id, asset_id, onset_ts, severity P1|P2|P3, confidence, failure_probability,
  predicted_mode, oee_impact_est, status NEW|TRIAGED|ACKED|SUPPRESSED|CLOSED, evidence VARIANT)
ACTION.WORK_ORDER(wo_id, alert_id, asset_id, priority, state DRAFT|APPROVED|SYNCED|CLOSED|
  REJECTED, title, description, evidence, approved_by, approved_ts)
ACTION.ACTION_AUDIT: append-only (no UPDATE/DELETE).

# FAILURE PHYSICS (synthetic data must encode these; 75 days, 10 labeled episodes)
BEARING_WEAR (golden): vibration_rms ramps 3-7 days pre-failure crossing alert then danger
  thresholds; kurtosis rises first; temp rises only in final 20%. -> micro-stops, slow
  cycles, breakdown.
LUBRICATION_LOSS: temp + vibration rise together under load. -> performance loss, defects.
COOLING_RESTRICTION: temp ramps alone. -> quality loss, thermal shutdown.
RPM_INSTABILITY: rpm/cycle-time oscillation grows. -> performance loss, jams.
SENSOR_FAULT: flatline/impossible jump/gaps, quality_flag set. -> NOT a failure; low
  confidence; never auto-action.
Correlation contract: every failure episode ends in an unplanned DOWNTIME_EVENT (same
mode) + corrective MAINTENANCE_HISTORY 2-24h later + telemetry baseline reset after.
Include hard negatives: hot-but-healthy heavy load, planned rpm changes, planned
maintenance windows, sensor dropouts. Episodes never overlap on one asset.

# OEE MATH (invariants — test them)
planned_production_time = shift_minutes - planned_downtime
run_time = planned_production_time - unplanned_downtime
Availability = run_time/planned_production_time; Performance = ideal_cycle_s*total_count/
(run_time*60) CAPPED at 1.0; Quality = good_count/total_count (0-safe); OEE = A*P*Q.
good_count <= total_count. Downtime pauses counts and rpm. Never average OEE percentages —
recompute from summed numerators/denominators. Plant OEE lands 0.55-0.85 on healthy days.

# ALERT SCORING + GUARDRAILS (non-negotiable)
PRIORITY_SCORE = failure_probability * (criticality/5) * imminence * expected_OEE_impact
  where imminence: 1.0 if horizon<=4h, 0.6 if <=24h, else 0.3. P1>=0.5, P2>=0.25 else P3.
CONFIDENCE = model_confidence * data_quality * evidence_agreement * persistence.
  CONFIDENCE < 0.5 -> status stays NEW ("observe"), no work-order proposal.
Dedup: one open alert per (asset, predicted_mode) — update evidence, don't duplicate.
PROPOSE_WORK_ORDER(alert_id): returns draft JSON, ZERO side effects.
CREATE_WORK_ORDER(alert_id, approver, dry_run DEFAULT TRUE): requires alert ACKED,
approver not null/'AGENT', no duplicate open WO; every attempt audited. The agent may
propose but NEVER approves or calls create with dry_run=FALSE on its own.
RCA answer structure: Assessment / Evidence / Operational impact / Alternatives considered /
Recommended action / Safety statement ("requires human verification") / Trace (sources,
model version). Causes are "most likely", never proven.

# BUILD SEQUENCE (work these steps in order; verify each before the next)
0 Foundation: DB/schemas/warehouse + capability probe table.
1 Synthetic data per physics above + validation report (PK/FK, ranges, OEE invariants,
  timeline causality, label-leakage check, class balance).
2 Pipelines: stream on raw telemetry; Dynamic Tables TARGET_LAG '1 minute' layered
  clean -> 1min -> 15min features -> telemetry context -> shift OEE mart -> asset health.
  All must refresh INCREMENTAL; raw-to-mart freshness < 120s; OEE reconciles.
3 ML: SNOWFLAKE.ML.ANOMALY_DETECTION multi-series per signal (train on healthy windows
  only), 5-min scoring task; SNOWFLAKE.ML.FORECAST for trend bands; risk fusion into
  asset health. Evaluate vs TEST.GROUND_TRUTH_FAILURES with episode-based splits:
  event recall >= 0.8, median lead >= 24h, report false alerts per asset-day vs a
  fixed-threshold baseline. Note: use valid model names in CORTEX.COMPLETE (e.g.
  llama3.1-8b); 'snowflake-arctic' is not valid.
4 Semantics + agent: semantic view (entities Site->Line->Asset, Asset->Alert->WO; metrics
  from summed measures; 15 verified queries), Cortex Search over technician notes/manuals,
  RCA agent with tools (Analyst + Search + GET_ASSET_EVIDENCE + PROPOSE_WORK_ORDER),
  25-question eval (factual/causal/routing/refusal/missing-data), pass >= 80%, causal
  answers must cite asset-specific evidence.
5 Action loop: 5-min alert task w/ scoring+dedup; approval-gated CREATE_WORK_ORDER;
  notification (Slack webhook or outbox table fallback); guardrail tests (non-ACKED
  rejected, approver 'AGENT' rejected, duplicate rejected, dry-run writes nothing).
6 Streamlit Command Center, 5 pages: Executive OEE (KPIs, loss waterfall, OEE-at-risk),
  Alert Triage, Asset Digital Twin (trends + anomaly markers + forecast bands), Ask Aegis
  (agent chat with trace), Work-Order Review (approve/reject + audit). Plus a
  "Built with CoCo" panel: SELECT interface, COUNT(*), SUM(token_credits) FROM
  SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY GROUP BY interface.

# WAYS OF WORKING
- Idempotent DDL only; write SQL before executing; show me results after each step.
- Never read ground-truth labels into ML features (leakage = disqualifying).
- Keep a running list of artifacts you created (I will export SQL/YAML/agent specs +
  eval numbers for the team merge, plus my session/thread IDs as evidence).
- If something is unavailable on this account, say so and propose the closest fallback.

Confirm understanding by summarizing: the golden path, my sandbox DB name, the three
quality bars (ML recall/lead, agent eval, OEE invariants), and which step we start with.
```

---- COPY EVERYTHING ABOVE THIS LINE ----
