# Mission 07B — CMMS Planning: Remove Shortcuts, Real Tests, Agent Coverage

Read `AGENTS.md` and `prompts/07_cmms_shift_planning.md` (the original spec). Non-interactive: print `MISSION 07B FAILED: <reason>` on unrecoverable errors. Mission 07 was reviewed and **not accepted**; this mission fixes the gaps below. Write artifacts to the repo before executing them.

## What was wrong (verified by the reviewer)

1. The golden-path WO schedule was **hand-inserted** into `ACTION.WO_SCHEDULE` with an overridden duration (360 min) after `AUTO_SCHEDULE_WO` found no qualifying window for the real estimate (464 min). The real procedure output for the headline demo was never shown working.
2. Window plan cannot host the headline repair: the longest window is 420 min (SHUTDOWN) while the golden-path corrective estimate is 464 min; the first non-trivial windows are ~7 days out, so a fully-stocked WO has no early zero-loss slot either.
3. Estimated duration is inconsistent (464 vs 360). It must come from one source of truth.
4. The new tests are vacuous: `M07_GOLDEN_PATH_P001_SHORTAGE` only checks a shortage exists, `M07_FULLY_STOCKED_EARLIEST_WINDOW` only counts windows. Neither calls the real procedures or asserts the outcome.
5. No scheduling questions were added to `TEST.AGENT_EVAL_RESULTS` (still 25 rows) and the eval was not re-run against the updated agent.
6. Test residue (alert, WO, `WO_SCHEDULE` row, reserved parts) was left in the database.

## Deliverables

1. **Duration single source of truth.** `est_duration_min` comes only from average `labor_hours × 60` for the WO's (failure_mode, asset_type) in `CORE.MAINTENANCE_HISTORY` (fallback table, never 0), computed in one function/view used by `PROPOSE_SCHEDULE`, `AUTO_SCHEDULE_WO`, `SCHEDULE_WORK_ORDER`, the app and the agent.
2. **Window plan that tells a coherent story** (change `data_gen/cmms_plan.py`, `sql/12_cmms_planning.sql`, `deploy/sql/11_cmms_planning.sql`; still seed 42, relative to run date, 14-day horizon, no hard-coded dates):
   - Every line has a **long planned shutdown** whose capacity ≥ 1.25 × the longest typical corrective duration in history (so the golden-path bearing swap fits in a single window).
   - Every line has at least **two short zero-production-loss windows (≥ 120 min) within the first 3 days** so a fully-stocked repair can be scheduled early.
   - Windows never overlap `SHIFT_PLAN` run time and `REFRESH_CMMS_PLAN()` never moves or deletes a booked window.
3. **Real golden-path behavior, no manual inserts anywhere.** Call the real procedures only: seed alert → ACK → `CREATE_WORK_ORDER` (dry-run, then approve). The approval itself must create the `WO_SCHEDULE` row through the procedures:
   - If a window ≥ duration exists with start ≥ `parts_ready_date` **and** before predicted failure → `TENTATIVE`.
   - Otherwise → `EXPEDITE`, and the row/response must also contain the **best option if parts are expedited** (assume expedited lead = CEIL(lead_time_days / 2), stated explicitly in the rationale) with the window that would then qualify and the order-by date, so the approver has an actionable choice instead of a dead end.
   - Record the final golden-path outcome (status, window, dates, rationale) in the run record exactly as the procedures produced it.
4. **Real tests** in `TEST.ACTION_GUARDRAIL_RESULTS` (names prefixed `M07B_`), each calling the real procedures and asserting outcomes, with the actual values in `detail`:
   - golden-path WO: status/window/parts_ready/order_by produced by the procedures; duration equals the single-source function; window capacity ≥ duration or status = EXPEDITE with an expedited alternative.
   - fully-stocked WO: scheduled into the earliest qualifying zero-loss window, start ≥ now, capacity ≥ duration.
   - no window overbooked after N sequential bookings (loop the real proc until a window is full, then assert the next booking moves to a different window).
   - `REFRESH_CMMS_PLAN()` keeps booked windows intact.
   - cancel/reject releases capacity; dry-run writes nothing; approver `AGENT`/NULL rejected; unapproved WO rejected; audit row for every attempt.
   Keep the 8 original guardrail tests passing.
5. **Agent and eval.** Confirm `PROPOSE_SCHEDULE` is wired as a working agent tool (call it through `DATA_AGENT_RUN` once). Add **≥ 5 scheduling questions** to the eval set (e.g. "When can we fix CNC_01_SPINDLE without losing production?", "Which work orders are at risk of missing their parts date?", "What are the order-by deadlines this week?", "How many production hours are lost to planned maintenance next week?", "Is there a window for LINE_2 in the next 3 days?"), run the **full eval** against the deployed agent, and persist all rows to `TEST.AGENT_EVAL_RESULTS`. Target ≥ 90% and no regression on the original 25. Keep the eval runner under `tests/` and make it re-runnable.
6. **App.** Redeploy the app on the **warehouse runtime** (no `runtime_name`/`compute_pool`). Run every query used by `app/pages/7_Shift_Plan.py` against the live schema to prove it returns rows with the golden-path WO present, and confirm no page imports or SQL reference a missing object. Do not claim visual verification; the human reviewer checks the UI.
7. **Idempotency.** Run `deploy/sql/11_cmms_planning.sql` twice in a row on the live account with no errors and no duplicate rows.
8. **Clean up at the end** (the account must be left pristine, not with test data): truncate `ACTION.ALERT`, `WORK_ORDER`, `WORK_ORDER_OUTBOX`, `PURCHASE_REQUISITION`, `ACTION_AUDIT`, `WO_SCHEDULE`; reset `CORE.PARTS_INVENTORY.reserved_qty` to the seeded values (P002 = 2, P005 = 1, all others 0); reset `booked_min`/`status` on every maintenance window. All tasks (including `TASK_REFRESH_CMMS_PLAN`) must be SUSPENDED when you finish. State the final task states in your output. If the SQL guard hook blocks DELETE/TRUNCATE, report it instead of working around it.
9. Update `docs/run-records.md` honestly (what failed in 07, what changed, final test counts).

## Acceptance criteria

- The golden-path `WO_SCHEDULE` row was produced by `CREATE_WORK_ORDER` → scheduling procedures with zero direct INSERTs into `WO_SCHEDULE` anywhere in the mission log or SQL files (grep proves it).
- All `M07B_` tests and the 8 original guardrails PASS; each new test's `detail` contains concrete values.
- Eval ≥ 90% with ≥ 30 rows in `TEST.AGENT_EVAL_RESULTS`.
- Post-clean state: 0 rows in the ACTION tables listed above, reserved_qty = 3 in total, all tasks suspended.

Print `MISSION 07B COMPLETE` when done.
