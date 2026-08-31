# Mission 06 — Streamlit Command Center

Read `AGENTS.md`. Use the bundled `$developing-with-streamlit` skill; delegate to the `app-builder` subagent. Non-interactive: print `MISSION 06 FAILED: <reason>` on unrecoverable errors.

## Objective

Deploy the AegisOEE Command Center as Streamlit in Snowflake (container runtime preferred; check `TEST.ENV_PROBES`, fall back to warehouse runtime + proc wrapper for agent calls, and record which).

## Deliverables

1. `app/Home.py` + `app/pages/` + `app/environment.yml` — structure the app for **ease of use and comprehension, not a fixed page count**: the six core capabilities below are mandatory, but split or merge pages wherever it improves clarity. Every core capability must be reachable within two clicks from the sidebar; avoid fragmenting into more than ~7 pages.
   - **1_Executive_OEE**: OEE/A/P/Q KPI cards with deltas, line comparison, 7-day trend, six-big-losses waterfall, "OEE at risk" card (sum of open-alert est. impact) and avoided-downtime scenario.
   - **2_Alert_Triage**: ranked open alerts (priority, confidence, mode, horizon, OEE impact), actions Acknowledge / Investigate (link to twin) / Suppress-with-reason, each writing audit rows.
   - **3_Asset_Digital_Twin**: asset selector with **line and asset-type filters**; sensor trends with anomaly markers + forecast bands from ML.SIGNAL_FORECASTS; ground-truth-free health gauge; maintenance timeline; open WOs; top model drivers.
   - **4_Ask_Aegis**: chat to `AEGIS_RCA_AGENT` (Agent REST on container runtime; proc wrapper fallback) with expandable evidence/tool-trace and source records.
   - **5_Work_Order_Review**: 5 tabs — Pending Drafts, Active WOs, Past WOs, **Procurement**, Audit. Proposed drafts with full evidence; **parts panel per draft: required kit, on-hand vs reserved, shortages highlighted, linked purchase requisitions with quote (cost, supplier, lead time) and expandable RFQ text; planned window shows parts-driven delay when applicable**; Approve (typed approver name + confirmation → CREATE_WORK_ORDER dry_run=FALSE) / Reject with reason; audit history table; GitHub/OUTBOX sync status. **WO closure status display: show CLOSE_REASON and CLOSED_AT for terminal-state WOs (RESOLVED/CANCELLED/CLOSED/REJECTED)**. The **Procurement tab** shows all PURCHASE_REQUISITION rows with status, linked WO, part details, costs, and supplier info.
   - **6_Asset_Map**: ISA-95 plant hierarchy (site → lines → assets) as colored tiles. Color by health score (green/amber/red), show OEE and alert count per asset. Click-through to Digital Twin page.
   - Sidebar "Built with CoCo" panel: SNOWFLAKE_COCO_USAGE_HISTORY by INTERFACE (guarded try/except), plus mission/evidence counts from docs metadata table if present.
2. **UI quality bar (non-negotiable)** — apply the `$developing-with-streamlit` skill's theming guidance:
   - Consistent visual identity: custom CSS theme (industrial palette — dark slate + amber/teal accents), branded header with product name and plant selector, consistent spacing and card layout across pages.
   - KPI tiles as styled metric cards with deltas and severity color semantics (green/amber/red tied to thresholds, consistent everywhere).
   - Charts (Altair or Plotly): titled, labeled axes, formatted units (%, °C, mm/s, ₹/$ for quotes), anomaly markers and forecast bands visually distinct, legends only when needed.
   - Formatted numbers everywhere — percentages to 1 decimal, currency for quotes, relative timestamps ("12 min ago"); never dump raw unformatted dataframes.
   - Clear state communication: loading spinners, friendly empty states ("No open alerts — plant healthy"), destructive/approval actions behind confirmation with distinct button styling.
   - Snappy: cache queries (st.cache_data with sensible TTLs), target < 5s per page on XSMALL.
3. **SiS deployment rules (non-negotiable)**:
   - `app/snowflake.yml`: `main_file: Home.py`, `environment.yml` listed in `artifacts`, all page files listed explicitly.
   - `app/environment.yml`: conda deps bare or `=version` (never `>=`); never list `streamlit` itself (provided by runtime).
   - Use `st.rerun()` not `st.experimental_rerun()`.
   - Deploy to `AEGIS_OEE.APP` on `AEGIS_APP_WH` via `snow streamlit deploy --replace --prune`; grants for the demo role; record the app URL/name.
4. Smoke tests: every page renders against current data; approval flow works end-to-end in dry-run; agent chat answers the golden-path question; parts panel shows the seeded shortage with its requisition quote.
5. Append run record + app object name to `docs/run-records.md`.

## Acceptance criteria

- All core capabilities functional and discoverable on XSMALL, querying marts only (no raw-table scans); approval writes audit rows; runtime choice recorded; the app looks like a polished product, not a prototype — consistent theme, styled KPI cards, formatted charts and numbers.

Print `MISSION 06 COMPLETE` when done.
