# Mission 08 — Separate Parts Procurement from Work Order Review

Read `AGENTS.md`, `prompts/06_app.md` (SiS rules) and `prompts/07_cmms_shift_planning.md`. Non-interactive: print `MISSION 08 FAILED: <reason>` on unrecoverable errors. Do not use Snowpark/container runtime; deploy only via `deploy/sql/09_app.sh` (stage-based, `RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'`).

## Problem

`app/pages/5_Work_Order_Review.py` has a "Procurement" tab. Parts procurement is a **different process** from maintenance work-order execution (different owner: stores/purchasing vs maintenance planner; different lifecycle: requisition → quote → order → receipt vs draft → approve → execute → close). Work orders and requisitions are linked by `wo_id`/`part_id` but must not be managed on the same page.

## Deliverables

1. **New page `app/pages/<NN>_Parts_Procurement.py`**, placed directly after Work Order Review in the sidebar order (renumber later pages if needed and update every reference: `app/snowflake.yml` artifacts, `Home.py` links/cards, `deploy/sql/09_app.sh`, README/docs/prompts that list pages). It owns:
   - **Requisitions**: all `ACTION.PURCHASE_REQUISITION` rows with status, supplier, quote, lead time, linked WO, **order-by date** (from `ACTION.WO_SCHEDULE`, highlighting overdue or at-risk ones), RFQ text in an expander. Filters by status/supplier/asset.
   - **Inventory**: `CORE.PARTS_INVENTORY` with on_hand, reserved, **available**, reorder point, below-reorder flag, lead time, bin; shortage vs open work orders.
   - **Suppliers**: spend, open requisitions and average lead time per supplier.
   - **Actions** (approver required, never `AGENT`, confirmation step, audit row for every attempt) through a new procedure `ACTION.UPDATE_REQUISITION_STATUS(req_id, new_status, actor, note, dry_run DEFAULT TRUE)` that enforces valid transitions only: `PENDING_QUOTE → QUOTED → ORDERED → RECEIVED`, and `CANCELLED` from any non-received state. On `RECEIVED` it increases `PARTS_INVENTORY.on_hand_qty` by the requisition qty exactly once; on `CANCELLED` it does not touch stock. Guard against double-receive.
2. **Slim down `5_Work_Order_Review.py`**: remove the Procurement tab and the procurement overview. Keep one compact "Parts readiness" panel inside each draft/active WO (per-part available vs required, shortage, requisition status, expected delivery) with a `st.page_link` to the new page. Work order tabs become: Pending Drafts, Active, Past, Audit History. Fix captions/tooltips that still describe procurement as part of work orders.
3. **Sync artifacts**: add the new procedure to `sql/10_action_procs.sql` (or the right numbered file) and to `deploy/sql/` (parity with the live account; idempotent), update `semantic/manufacturing_operations.yaml` / `cortex_project/MANUFACTURING_OPERATIONS.sv.yaml` only if they describe the old page structure, and update any README/docs wording.
4. **Tests** appended to `TEST.ACTION_GUARDRAIL_RESULTS` (prefix `M08_`), each calling the real procedure and recording concrete values: invalid transition rejected; `AGENT`/NULL actor rejected; dry-run writes nothing; `RECEIVED` increments stock exactly once and double-receive is rejected; `CANCELLED` leaves stock unchanged; audit row for every attempt. Use a throwaway requisition row for tests (no manual edits of results); remove it afterwards.
5. **Deploy and prove**: redeploy the app via `deploy/sql/09_app.sh`; `DESCRIBE STREAMLIT` must show `compute_pool` empty and `SYSTEM$WAREHOUSE_RUNTIME`; list the deployed files and show the new page and `environment.yml` are present; run every SQL query used by the new and modified pages against the live schema and show they return without errors. Do not claim visual verification (the human checks the UI).
6. **Leave the account pristine**: truncate `ACTION.ALERT/WORK_ORDER/WORK_ORDER_OUTBOX/PURCHASE_REQUISITION/ACTION_AUDIT/WO_SCHEDULE` created by tests, reset `PARTS_INVENTORY` reserved_qty (P002 = 2, P005 = 1, others 0) and on_hand_qty to the seeded values, reset window bookings; all tasks SUSPENDED (list final task states). If the SQL guard hook blocks a statement, report it; do not work around it.
7. Append an honest run record to `docs/run-records.md`.

## Acceptance criteria

- The Work Order Review page has no procurement tab; the new page covers requisitions, inventory, suppliers, and guarded status changes.
- All `M08_` tests PASS with concrete values in `detail`, and all earlier guardrail tests still PASS.
- `DESCRIBE STREAMLIT` shows the warehouse runtime; ACTION tables empty, stock restored to seed, tasks suspended.

Print `MISSION 08 COMPLETE` when done.
