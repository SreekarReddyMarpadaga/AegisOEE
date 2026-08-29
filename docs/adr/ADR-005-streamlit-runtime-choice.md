# ADR-005: Streamlit Runtime Choice (Container vs Warehouse)

**Status:** Accepted  
**Date:** 2026-08-29  
**Context:** AegisOEE Planning Session

## Context

Mission 06 deploys a Streamlit-in-Snowflake application. Two runtimes are available:

- **Container runtime:** Full network access, can call Cortex Agent REST API directly, supports `environment.yml` for Python dependencies.
- **Warehouse runtime:** More widely available, but no outbound network access — agent calls must go through a SQL stored procedure wrapper.

## Decision

Attempt container runtime first. Fall back to warehouse runtime with a proc wrapper. Record which was used.

### Container Runtime (preferred)

- Deploy with container runtime flag.
- Agent chat page calls AEGIS_RCA_AGENT via the Agent REST endpoint directly.
- External access (if needed for Slack delivery from the app) is available natively.

### Warehouse Runtime (fallback)

- Deploy without container flag.
- Agent chat page calls a stored procedure `APP.CALL_RCA_AGENT(question TEXT)` that wraps `SNOWFLAKE.CORTEX.AGENT()` and returns the response.
- All agent interactions go through SQL — slightly higher latency, limited streaming.

### Detection Logic

Mission 06 attempts container deployment. If it fails (feature not enabled, quota, etc.), it falls back to warehouse runtime and creates the proc wrapper. The runtime choice is recorded in `docs/run-records.md`.

## Rationale

- Container runtime is strictly more capable — no reason to prefer warehouse when it's available.
- The proc wrapper is simple (~20 lines of SQL) and the agent chat UX difference is minimal (no streaming, slightly slower).
- Not adding a container runtime probe to Mission 00 because the probe result may not reflect deployment-time state (container quotas, feature rollouts can change between missions).

## Consequences

- `app/streamlit_app.py` needs a runtime detection helper and conditional agent-call logic (direct REST vs proc call).
- The proc wrapper `APP.CALL_RCA_AGENT` must be created regardless (it's useful for testing and as the fallback path).
- Container runtime may incur slightly higher compute costs (container pool vs warehouse). Both use AEGIS_APP_WH (XSMALL) for SQL queries.
- The app must be tested on whichever runtime is actually deployed — smoke tests in Mission 06 must verify agent chat works.

## Alternatives Considered

- **Warehouse-only:** Simpler but loses streaming agent responses and limits future extensibility (e.g., direct API calls to external services).
- **Container-only:** Risky — if container runtime is unavailable, Mission 06 fails entirely.
- **Separate probe in Mission 00:** Over-engineering — the deployment attempt is itself the probe, and it's idempotent.
