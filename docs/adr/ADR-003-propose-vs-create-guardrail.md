# ADR-003: Propose-vs-Create Human Approval Guardrail

**Status:** Accepted  
**Date:** 2026-08-29  
**Context:** AegisOEE Planning Session

## Context

An AI agent (AEGIS_RCA_AGENT) can analyze equipment health, score alerts, and recommend maintenance actions. It must never autonomously execute maintenance work. A hard trust boundary is needed between recommendation and execution.

## Decision

Two-procedure separation with 4 preconditions on the write path.

### PROPOSE_WORK_ORDER(alert_id) — Safe to expose to agent

- Returns draft JSON: title, priority, recommended action, evidence, parts kit, planned window.
- **Zero side effects** on maintenance state.
- Exception: the embedded CHECK_PARTS call may insert PURCHASE_REQUISITION rows — these are procurement paperwork preparation, not maintenance action. This is intentional: procurement lead times must be visible in the draft so the approver knows about delays.
- Writes one ACTION_AUDIT row with action='PROPOSED'.

### CREATE_WORK_ORDER(alert_id, approver, dry_run DEFAULT TRUE) — Never called by agent

4 hard preconditions, all enforced in the procedure:

1. Alert exists and status = 'ACKED' (human acknowledged the risk).
2. Approver is not NULL, not empty, and not 'AGENT' (human identity required).
3. No duplicate open work order for the same (asset_id, failure_mode).
4. dry_run must be explicitly FALSE to write (defaults TRUE — accidental calls return preview only).

On success: creates WO, reserves available parts (increments PARTS_INVENTORY.reserved_qty), links open requisitions, queues GitHub/Slack notifications, writes audit rows.

### Audit Trail

Every state transition — proposal, acknowledgment, approval, rejection, suppression, sync attempt, sync failure — appends to ACTION.ACTION_AUDIT. This table has no UPDATE or DELETE grants. The audit is immutable.

## Rationale

- The propose/create split is the simplest enforceable boundary. The agent has access to PROPOSE but not CREATE (it's not registered as an agent tool).
- DRY_RUN defaulting TRUE means even a human accidentally calling CREATE without the flag gets a preview, not a side effect.
- The approver identity check prevents automated approval loops (agent cannot impersonate a human).
- Immutable audit provides compliance evidence and demo credibility.

## Consequences

- The Streamlit approval flow must collect a typed approver name (not auto-populated from session).
- Rejections also write audit rows with reason — there's no silent discard path.
- The triage automation (hourly) may call PROPOSE but never CREATE. Human approval happens only in the Streamlit UI.
- Parts reservation at approval time means reserved_qty must be decremented if a WO is later cancelled (a cleanup path needed but not in MVP scope — noted as tech debt).

## Alternatives Considered

- **Single procedure with role-based access:** Harder to enforce "agent cannot approve" since the agent runs under the same Snowflake role. The procedural check on approver identity is simpler.
- **Approval via external system (GitHub PR review):** Adds latency and external dependency. The Streamlit in-app approval is faster and self-contained.
- **Multi-signature approval:** Over-engineered for a demo with a single maintenance team. Could be added later by requiring two distinct approver values.
