# Mission 05 — Governed Action Loop (Alerts → Approval → Ticket)

Read `AGENTS.md` and `$maintenance-triage` (authoritative for all rules here). Use bundled `$alert`, `$notification`, `$snowflake-tasks` skills. Non-interactive: print `MISSION 05 FAILED: <reason>` on unrecoverable errors.

## Objective

The closed loop: scored alerts with dedup + confidence gating, human-approval work-order creation with audit, Slack notification, GitHub Issue sync with OUTBOX fallback.

## Deliverables

1. `sql/06_alert_task.sql` — executed:
   - ACTION tables per AGENTS.md: `ALERT`, `WORK_ORDER`, `WORK_ORDER_OUTBOX`, `ACTION_AUDIT` (audit append-only: no UPDATE/DELETE grants).
   - `TASK_SCORE_ALERTS` every 5 min on `AEGIS_WH`: reads DT_ASSET_HEALTH + ML.ANOMALY_EVENTS, applies PRIORITY_SCORE + CONFIDENCE formulas, dedup rule (one open alert per asset+mode → update evidence), inserts/updates `ACTION.ALERT`. Create SUSPENDED; resume after tests pass.
2. `sql/10_action_procs.sql` — executed:
   - `ACTION.CREATE_WORK_ORDER(alert_id, approver, dry_run DEFAULT TRUE)` — enforces: alert exists and status='ACKED'; approver NOT IN (NULL,'','AGENT'); no duplicate open WO for (asset, mode); dry_run=TRUE returns preview only. Writes WO + audit; sets alert→TRIAGED history in audit. **Non-dry-run also reserves available parts (PARTS_INVENTORY.reserved_qty += allocated) and links any open requisitions for the WO.**
   - `ACTION.CHECK_PARTS(alert_id)` — resolves the parts kit via FAILURE_MODE_PARTS for the alert's (predicted_mode, asset_type); for each part computes available = on_hand_qty − reserved_qty vs qty_required; returns availability JSON. For every shortage, inserts an `ACTION.PURCHASE_REQUISITION` row: quote = shortage_qty × unit_cost, supplier, lead_time_days, plus an RFQ email text drafted with AI_COMPLETE (professional tone, part spec, qty, requested delivery date). Called automatically inside PROPOSE_WORK_ORDER so every draft carries a parts panel; audit row 'PARTS_CHECKED'.
   - `ACTION.NOTIFY_SLACK(payload)` — external access integration + secret for `SLACK_WEBHOOK_URL` if permitted; else write to OUTBOX with target='SLACK'. Wrap so failures always land in OUTBOX.
   - `ACTION.QUEUE_GITHUB_SYNC(wo_id)` — builds the GitHub issue payload per the triage skill template into OUTBOX target='GITHUB' (the MCP leg is executed by the triage automation/CLI, not by SQL). **Issue body includes the parts availability table and any requisition quotes.**
   - `TASK_OUTBOX_RETRY` every 10 min: increments attempts, retries Slack deliveries, marks dead after 5 attempts.
3. Wire post-approval flow: successful non-dry-run CREATE_WORK_ORDER → QUEUE_GITHUB_SYNC + NOTIFY_SLACK automatically (proc call or triggered task).
4. **Work Order status model**: WORK_ORDER.STATE supports the full lifecycle: DRAFT → APPROVED → SYNCED → IN_PROGRESS → RESOLVED | CANCELLED | CLOSED | REJECTED. Add columns `CLOSE_REASON VARCHAR` and `CLOSED_AT TIMESTAMP_TZ` to WORK_ORDER. The outbox dispatcher (scripts/outbox_dispatcher.py) handles the terminal-state transitions:
   - **Outbound dispatch**: polls WORK_ORDER_OUTBOX for PENDING items, creates GitHub Issues (with parts table, requisition quotes, safety statement) and sends Slack notifications.
   - **GitHub closure sync-back**: when a work order is CLOSED or REJECTED, the dispatcher closes the linked GitHub Issue with a comment and state_reason (completed or not_planned).
   - **Inbound sync**: polls linked GitHub issues for open WOs; if an issue was closed externally, transitions the WO to RESOLVED (completed) or CANCELLED (not_planned), releases reserved parts on cancellation, and queues a Slack notification.
   - All state transitions produce ACTION_AUDIT rows. The dispatcher runs locally via `GITHUB_PAT=... SLACK_WEBHOOK_URL=... python scripts/outbox_dispatcher.py`. For accounts with EAI, sql/11_integrations.sql has the native Snowflake procedure versions (commented, requires EAI setup).
5. Guardrail tests executed and persisted to `TEST.ACTION_GUARDRAIL_RESULTS`: create on non-ACKED alert rejected; approver='AGENT' rejected; duplicate WO rejected; dry-run writes nothing; audit rows appear for every attempt; **parts flow: golden-path alert produces a shortage requisition with a non-zero quote; a fully-stocked part produces no requisition; approval reserves exactly qty_required**.
6. Append run record to `docs/run-records.md`.

## Acceptance criteria

- Full simulated pass: seed a synthetic P1 alert → ACK it via SQL → propose → approve (dry-run then real) → WO row + OUTBOX GitHub payload + Slack delivery (or OUTBOX fallback) + ≥4 audit rows.
- All guardrail tests PASS.

Print `MISSION 05 COMPLETE` when done.
