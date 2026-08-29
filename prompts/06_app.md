# Mission 06 — Streamlit Command Center

Read `AGENTS.md`. Use the bundled `$developing-with-streamlit` skill; delegate to the `app-builder` subagent. Non-interactive: print `MISSION 06 FAILED: <reason>` on unrecoverable errors.

## Objective

Deploy the AegisOEE Command Center as Streamlit in Snowflake (container runtime preferred; check `TEST.ENV_PROBES`, fall back to warehouse runtime + proc wrapper for agent calls, and record which).

## Deliverables

1. `app/streamlit_app.py` + `app/pages/` + `app/environment.yml` — five pages exactly:
   - **1_Executive_OEE**: OEE/A/P/Q KPI cards with deltas, line comparison, 7-day trend, six-big-losses waterfall, "OEE at risk" card (sum of open-alert est. impact) and avoided-downtime scenario.
   - **2_Alert_Triage**: ranked open alerts (priority, confidence, mode, horizon, OEE impact), actions Acknowledge / Investigate (link to twin) / Suppress-with-reason, each writing audit rows.
   - **3_Asset_Digital_Twin**: asset selector; sensor trends with anomaly markers + forecast bands from ML.SIGNAL_FORECASTS; ground-truth-free health gauge; maintenance timeline; open WOs; top model drivers.
   - **4_Ask_Aegis**: chat to `AEGIS_RCA_AGENT` (Agent REST on container runtime; proc wrapper fallback) with expandable evidence/tool-trace and source records.
   - **5_Work_Order_Review**: proposed drafts with full evidence; Approve (typed approver name + confirmation → CREATE_WORK_ORDER dry_run=FALSE) / Reject with reason; audit history table; GitHub/OUTBOX sync status.
   - Sidebar "Built with CoCo" panel: SNOWFLAKE_COCO_USAGE_HISTORY by INTERFACE (guarded try/except), plus mission/evidence counts from docs metadata table if present.
2. Deploy to `AEGIS_OEE.APP` on `AEGIS_APP_WH`; grants for the demo role; record the app URL/name.
3. Smoke tests: every page renders against current data; approval flow works end-to-end in dry-run; agent chat answers the golden-path question.
4. Append run record + app object name to `docs/coco-evidence.md` ("Development").

## Acceptance criteria

- All 5 pages functional on XSMALL, querying marts only (no raw-table scans); approval writes audit rows; runtime choice recorded.

Print `MISSION 06 COMPLETE` when done.
