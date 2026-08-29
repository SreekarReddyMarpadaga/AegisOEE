---
name: maintenance-triage
description: Governed alert-to-work-order triage runbook for predictive maintenance — severity/priority scoring, confidence gating, deduplication, evidence bundles, propose-vs-create separation with human approval, GitHub/Slack notification with outbox fallback, and immutable audit. Use when triaging equipment alerts, drafting maintenance work orders, or wiring alert automation.
---

# When to Use

- "Triage new/open alerts"
- "Draft a work order for this anomaly"
- "Run the maintenance triage workflow / automation"

# What This Skill Provides

The complete triage state machine and guardrails so an AI agent can act **safely**: it may analyze, prioritize, and propose — it may never approve or execute its own recommendation.

# Instructions

## State machine

ALERT: NEW → (confidence gate) → TRIAGED → ACKED (human) → WO DRAFT → APPROVED (human) → SYNCED (GitHub) → CLOSED. Alternative: SUPPRESSED (human, with reason). Never skip states.

## Scoring

- PRIORITY_SCORE = failure_probability × (criticality/5) × imminence × expected_OEE_impact, where imminence = 1.0 if predicted horizon ≤ 4h, 0.6 if ≤ 24h, 0.3 otherwise. P1 ≥ 0.5, P2 ≥ 0.25, else P3.
- CONFIDENCE = model_confidence × data_quality × evidence_agreement × persistence. persistence = fraction of last 6 windows anomalous. data_quality = 0 if quality_flag ≠ 'OK' on >20% of source rows (sensor-fault suspicion → "observe" only).
- Gate: CONFIDENCE < 0.5 → leave status NEW with note "observe"; do not propose work.

## Dedup rules

One open alert per (asset_id, predicted_mode). On re-detection, update evidence + last_seen, never insert a duplicate. One open work order per (asset_id, failure_mode); duplicates must be rejected by the create procedure.

## Evidence bundle (VARIANT, attach to alert and WO)

```json
{
  "alert_id": "...", "asset_id": "...", "model_version": "...",
  "window": {"start": "...", "end": "..."},
  "signals": [{"name": "vibration_rms", "baseline": 1.1, "current": 4.2, "slope_per_day": 0.8}],
  "anomaly": {"distance": 0.0, "percentile": 0.0, "persistence": 0.0},
  "prediction": {"failure_probability_24h": 0.0, "predicted_mode": "...", "horizon_h": 0},
  "history": [{"wo_hist_id": "...", "finding": "...", "completed_ts": "..."}],
  "oee_impact": {"component": "availability", "est_loss_pct": 0.0},
  "sources": ["FQN table names and ids used"]
}
```

## Propose vs create (hard guardrail)

- `PROPOSE_WORK_ORDER(alert_id)` → returns draft JSON (title, priority, recommended action, parts, planned window, evidence). **Zero side effects.**
- `CREATE_WORK_ORDER(alert_id, approver, dry_run)` → requires alert in ACKED state, non-null approver ≠ 'AGENT', no duplicate open WO; `dry_run` defaults TRUE and must be explicitly FALSE to write. Writes WO + audit row.
- Every proposal, approval, rejection, sync attempt → append to the audit table. The agent never calls CREATE with dry_run=FALSE on its own initiative.

## Notification & ticketing

- Slack webhook message: severity emoji, asset, mode, confidence, top signal, link to command center.
- GitHub Issue (via MCP when available): title `[P1][BEARING_WEAR] CNC_01_SPINDLE — bearing inspection required`, body = draft WO markdown with evidence table + audit ref. Label by severity + mode.
- If GitHub/Slack call fails: write payload to the outbox table with attempts+error, retry later; never lose an approved action.

## Work-order draft template

Title, Asset (id, line, criticality), Most likely failure mode + confidence, Evidence summary (3–5 timestamped bullets), Operational impact (OEE component + estimate), Recommended action (inspection/part/urgency/window), Alternatives considered, Safety statement ("requires human verification before execution"), Trace (alert id, model version, source objects).

# Examples

User: `$maintenance-triage triage all NEW alerts` → agent scores, gates, dedups, proposes drafts for qualifying alerts, posts Slack summaries, prints a per-alert decision table, ends `TRIAGE COMPLETE: n triaged, m observed, 0 auto-approved`.
