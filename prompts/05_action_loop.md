# Mission 05 — Governed Action Loop (Alerts → Approval → Ticket)

Read `AGENTS.md` and `$maintenance-triage` (authoritative for all rules here). Use bundled `$alert`, `$notification`, `$snowflake-tasks` skills. Non-interactive: print `MISSION 05 FAILED: <reason>` on unrecoverable errors.

## Objective

The closed loop: scored alerts with dedup + confidence gating, human-approval work-order creation with audit, Slack notification, GitHub Issue sync with OUTBOX fallback.

## Deliverables

1. `sql/06_alert_task.sql` — executed:
   - ACTION tables per AGENTS.md: `ALERT`, `WORK_ORDER`, `WORK_ORDER_OUTBOX`, `ACTION_AUDIT` (audit append-only: no UPDATE/DELETE grants).
   - `TASK_SCORE_ALERTS` every 5 min on `AEGIS_WH`: reads DT_ASSET_HEALTH + ML.ANOMALY_EVENTS, applies PRIORITY_SCORE + CONFIDENCE formulas, dedup rule (one open alert per asset+mode → update evidence), inserts/updates `ACTION.ALERT`. Create SUSPENDED; resume after tests pass.
2. `sql/10_action_procs.sql` — executed:
   - `ACTION.CREATE_WORK_ORDER(alert_id, approver, dry_run DEFAULT TRUE)` — enforces: alert exists and status='ACKED'; approver NOT IN (NULL,'','AGENT'); no duplicate open WO for (asset, mode); dry_run=TRUE returns preview only. Writes WO + audit; sets alert→TRIAGED history in audit.
   - `ACTION.NOTIFY_SLACK(payload)` — external access integration + secret for `SLACK_WEBHOOK_URL` if permitted; else write to OUTBOX with target='SLACK'. Wrap so failures always land in OUTBOX.
   - `ACTION.QUEUE_GITHUB_SYNC(wo_id)` — builds the GitHub issue payload per the triage skill template into OUTBOX target='GITHUB' (the MCP leg is executed by the triage automation/CLI, not by SQL).
   - `TASK_OUTBOX_RETRY` every 10 min: increments attempts, retries Slack deliveries, marks dead after 5 attempts.
3. Wire post-approval flow: successful non-dry-run CREATE_WORK_ORDER → QUEUE_GITHUB_SYNC + NOTIFY_SLACK automatically (proc call or triggered task).
4. Guardrail tests executed and persisted to `TEST.ACTION_GUARDRAIL_RESULTS`: create on non-ACKED alert rejected; approver='AGENT' rejected; duplicate WO rejected; dry-run writes nothing; audit rows appear for every attempt.
5. Append run record to `docs/coco-evidence.md` ("Development" + "Testing").

## Acceptance criteria

- Full simulated pass: seed a synthetic P1 alert → ACK it via SQL → propose → approve (dry-run then real) → WO row + OUTBOX GitHub payload + Slack delivery (or OUTBOX fallback) + ≥4 audit rows.
- All guardrail tests PASS.

Print `MISSION 05 COMPLETE` when done.
