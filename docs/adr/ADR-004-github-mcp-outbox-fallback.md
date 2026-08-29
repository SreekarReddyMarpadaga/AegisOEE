# ADR-004: GitHub Issues via MCP with OUTBOX Fallback

**Status:** Accepted  
**Date:** 2026-08-29  
**Context:** AegisOEE Planning Session

## Context

Approved work orders must sync to an external ticketing system for visibility outside Snowflake. GitHub Issues was chosen over Jira (no license). MCP (Model Context Protocol) enables CoCo-based automation to call the GitHub API, but MCP availability is not guaranteed — it depends on PAT configuration, network access, and the MCP server being registered.

## Decision

Three-tier delivery with guaranteed persistence:

### Tier 1 — MCP (preferred)

The triage automation (CoCo CLI, not SQL) attempts to create a GitHub Issue via the configured MCP server. Issue body follows the work-order template: title with severity/mode/asset, evidence table, parts availability, audit reference, labels by severity + mode.

### Tier 2 — OUTBOX (automatic fallback)

If MCP call fails (or MCP is not configured), the full GitHub Issue payload is written to `ACTION.WORK_ORDER_OUTBOX` with `target='GITHUB'`, `status='PENDING'`, `attempts=0`.

### Tier 3 — Retry Task

`TASK_OUTBOX_RETRY` runs every 10 minutes. For Slack entries, it retries HTTP delivery via external access integration. For GitHub entries, it increments the attempt counter (actual MCP delivery requires the CLI context). After 5 failed attempts, entries are marked `DEAD` — they remain visible in the Streamlit UI for manual follow-up.

### Slack (parallel path)

Slack notifications use an external access integration + stored secret for SLACK_WEBHOOK_URL when available. On failure, same OUTBOX pattern. Slack payloads include: severity emoji, asset, mode, confidence, top signal, command-center link.

## Rationale

- MCP calls cannot be made from SQL stored procedures — they run in the CoCo CLI/automation context. The SQL layer only prepares payloads (QUEUE_GITHUB_SYNC writes to OUTBOX); the automation leg executes the MCP call.
- The OUTBOX pattern ensures no approved action is silently lost, even if all external systems are down.
- Slack is simpler than GitHub (HTTP POST vs MCP API), but both get the same fallback for consistency.
- OUTBOX entries are demo-friendly: the Streamlit UI can show pending/failed sync status as evidence of the resilient design.

## Consequences

- Step 0.4 (GitHub PAT / MCP / Slack webhook) must be completed for full notification flow. Without it, everything lands in OUTBOX — the demo still works by showing OUTBOX entries + "would sync when configured."
- The triage automation prompt must include the MCP call logic.
- DEAD entries need a manual retry or resolution path in the Streamlit UI (show payload, allow re-queue).
- GitHub Issue creation includes the parts panel (availability, shortages, requisition quotes) — the template is defined in the maintenance-triage skill.

## Alternatives Considered

- **Direct HTTP to GitHub API from SQL (external access integration):** Possible but requires managing PAT as a Snowflake secret, building REST calls in SQL, and handling pagination/rate limits. MCP is simpler for the CoCo context.
- **Jira integration:** No license available. GitHub Issues are sufficient for the demo scope.
- **No external ticketing:** Loses the "closed loop" narrative. The OUTBOX at minimum proves the system tried.
- **Synchronous-only (no OUTBOX):** Silent failures would violate the "never lose an approved action" requirement.
