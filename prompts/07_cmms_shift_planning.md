# Mission 07 — CMMS Shift Planning & Maintenance Windows

Read `AGENTS.md` and `$maintenance-triage` first. Use bundled `$snowflake-tasks`, `$dynamic-tables`, `$agent-studio`, `$developing-with-streamlit`. Non-interactive: print `MISSION 07 FAILED: <reason>` on unrecoverable errors. Write every artifact to the repo before executing it.

## Objective

Today an approved work order has no place in the production calendar. Add a CMMS-style forward plan so maintenance is scheduled into non-production time, aligned with parts procurement lead time, instead of interrupting production.

## Deliverables

1. **Synthetic CMMS plan** — `data_gen/cmms_plan.py` (seed 42, dates relative to today, 14-day forward horizon; load via CSV → stage → COPY INTO, **not** `write_pandas`; copy files to `/tmp` before `PUT`). Creates and loads, in `sql/12_cmms_planning.sql`:
   - `CORE.SHIFT_PLAN` (plan_id, plan_date, shift_code, line_id, order_id FK `CORE.PRODUCTION_ORDER`, planned_qty, planned_start_ts, planned_end_ts, planned_run_min, status 'PLANNED'|'FROZEN').
   - `CORE.MAINTENANCE_WINDOW` (window_id, line_id, asset_id NULL = line-wide, window_start_ts, window_end_ts, window_type 'DAILY_PM'|'CHANGEOVER'|'NON_PRODUCTION'|'SHUTDOWN', capacity_min, booked_min, status 'OPEN'|'BOOKED'). Include the existing daily 05:30–06:00 IST window, order changeovers, a weekly low-load block per line, and one 6–8 h planned shutdown per line inside the horizon. Windows must not overlap `SHIFT_PLAN` run time.
   - `ACTION.WO_SCHEDULE` (schedule_id, wo_id FK, window_id FK, scheduled_start_ts, scheduled_end_ts, est_duration_min, parts_ready_date, order_by_date, status 'TENTATIVE'|'CONFIRMED'|'EXPEDITE'|'CANCELLED', rationale, created_ts).
   - `CORE.REFRESH_CMMS_PLAN()` — idempotent rolling-horizon refresh; add `TASK_REFRESH_CMMS_PLAN` daily, created SUSPENDED.
2. **Scheduling logic** (`sql/12_cmms_planning.sql`, procs per AGENTS.md naming):
   - `ACTION.PROPOSE_SCHEDULE(wo_id)` — zero side effects. Returns ranked window options with reasons. Rules:
     - est_duration_min from average `labor_hours` for the same failure_mode/asset_type in `CORE.MAINTENANCE_HISTORY` (fallback table, never zero).
     - parts_ready_date = today + max(`lead_time_days`) of shortage parts from the WO's open requisitions (+1 day receiving); 0 if fully stocked.
     - A window qualifies only if open capacity ≥ est_duration_min AND window_start ≥ parts_ready_date AND it covers the asset's line.
     - Rank: zero production loss first, then earliest start, then smallest wasted capacity.
     - If the best qualifying window is later than the predicted failure time (from `FEATURES.DT_ASSET_HEALTH` / alert evidence) → status `EXPEDITE` with a recommendation (expedite shipping, or approved unplanned stop). Never silently schedule past predicted failure.
   - `ACTION.SCHEDULE_WORK_ORDER(wo_id, window_id, approver, dry_run DEFAULT TRUE)` — same guardrails as `CREATE_WORK_ORDER` (approver NOT IN (NULL,'','AGENT'), WO must be APPROVED, no double-booking, window capacity respected). Writes `WO_SCHEDULE`, updates `booked_min`, audit rows.
   - Hook into non-dry-run `ACTION.CREATE_WORK_ORDER`: after approval, auto-book the top-ranked option as `TENTATIVE` (an approver can rebook via `SCHEDULE_WORK_ORDER`). Set `order_by_date = window_start − lead_time − 1 day` and update the linked `PURCHASE_REQUISITION` requested-delivery date and RFQ text. Add schedule + order-by date to the GitHub Issue payload and Slack message.
   - All proposals, bookings, rebooks and cancellations land in `ACTION.ACTION_AUDIT`. Cancelling/rejecting a WO releases its window capacity.
   - Planned windows never count as unplanned downtime; do not change OEE math.
3. **Semantic layer & agent** — add `SHIFT_PLAN`, `MAINTENANCE_WINDOW`, `WO_SCHEDULE` to `semantic/manufacturing_operations.yaml` (and `cortex_project/MANUFACTURING_OPERATIONS.sv.yaml`) with relationships and ≥4 verified queries (e.g. next open window per line, WOs at risk of missing their parts date, order-by deadlines this week, production hours lost to planned maintenance). Add `PROPOSE_SCHEDULE` as an agent tool and update agent instructions so RCA answers include a scheduling recommendation. Re-run the agent eval; existing 25/25 must still pass; add ≥4 scheduling questions.
4. **Streamlit page** — `app/pages/7_Shift_Plan.py`: 14-day Gantt per line (production vs maintenance windows vs booked WOs), WO schedule table with parts_ready/order-by dates and EXPEDITE flags, and a rebook control that calls `SCHEDULE_WORK_ORDER` (dry-run preview first, approver required). Streamlit-in-Snowflake rules: warehouse runtime only (never set `runtime_name`/`compute_pool`; no container runtime), `environment.yml` must be listed in `snowflake.yml` artifacts, conda deps use bare names or `=ver` only (no `>=`, never list `streamlit`), use `st.rerun()`, deploy only via `deploy/sql/09_app.sh` (stage-based, `RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'`); never `snow streamlit deploy`, which defaults to container runtime.
5. **Tests** persisted to `TEST.ACTION_GUARDRAIL_RESULTS`: no window overbooked; window never starts before parts_ready_date; unapproved WO cannot be scheduled; approver='AGENT' rejected; dry-run writes nothing; golden-path WO (P001 shortage, 7-day lead) is scheduled ≥ 8 days out or flagged EXPEDITE vs predicted failure; fully-stocked WO gets the earliest zero-loss window; cancel releases capacity; audit rows for every attempt.
6. **Deploy parity** — append the same DDL/procs to `deploy/sql/` (new `11_cmms_planning.sql`, wired into `deploy/deploy_all.sh` before the verify step and checked in `10_verify.sql`) so Method B reproduces it. Update `scripts/demo_reset.sh` to rebuild the plan.
7. Update `AGENTS.md` canonical data model table, append to `docs/run-records.md`, add the mission to `scripts/build_all.sh`.

## Acceptance criteria

- Simulated pass: golden-path alert → ACK → approve → WO + TENTATIVE `WO_SCHEDULE` + order-by date on the requisition + schedule in GitHub/Slack payloads + audit chain.
- Ask Aegis answers "when can we fix CNC_01_SPINDLE without losing production?" from the new tables.
- All guardrail tests PASS; app page renders with no errors.

Print `MISSION 07 COMPLETE` when done.
