# AegisOEE — Risk Register

> Created during planning session, 2026-08-29. Review after each mission; update mitigations as risks materialize or are retired.

| # | Risk | Impact | Likelihood | Mitigation | Preflight Probe | Status |
|---|---|---|---|---|---|---|
| R1 | Cortex ML (ANOMALY_DETECTION / FORECAST) unavailable on account | ML missions fail, no early-warning layer, golden-path demo broken | Medium | Z-score + persistence fallback produces same output contract (ML.ANOMALY_EVENTS). Probe in Mission 00 steers Mission 03 automatically. ADR-002 documents the layered approach. | `TEST.ENV_PROBES WHERE probe_name = 'anomaly_detection_available'` | OPEN |
| R2 | Credit burn from DT refreshes + ML training on 1M+ rows | Budget exhaustion before demo; warehouse throttling | Medium | XSMALL warehouses with 60s auto-suspend. DTs use appropriate TARGET_LAG (1min/5min, not 1s). Monitor via `scripts/snapshot_usage.sh` after each mission. Aggressive TARGET_LAG tuning if burn rate too high. | `SELECT SUM(credits_used) FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY WHERE start_time > DATEADD('day', -1, CURRENT_TIMESTAMP())` post-Mission 02 | OPEN |
| R3 | MCP GitHub integration not configured or flaky | Work orders never reach external ticketing; "closed loop" narrative weakened | High | OUTBOX fallback always active (ADR-004). Demo shows OUTBOX payloads + Streamlit sync-status column. MCP is additive, not blocking. GitHub issues are a nice-to-have, not a system dependency. | `scripts/preflight_probes.sh` MCP check (step 0.4) | OPEN |
| R4 | Dynamic Table falls back to FULL refresh | OEE freshness >120s target missed; excessive credit consumption on every refresh | Medium | Mission 02 test harness checks `SHOW DYNAMIC TABLES ... refresh_mode` for every DT. If FULL detected: simplify SQL (remove non-deterministic functions, rewrite window patterns). Known incrementalization blockers: FLATTEN on VARIANT, certain lateral joins, non-deterministic UDFs. | `SELECT name, refresh_mode FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())` | OPEN |
| R5 | Agent eval <80% pass rate (Mission 04) | Semantic layer unreliable; "Ask Aegis" demo page gives wrong answers | Medium | 15 verified queries anchor Cortex Analyst accuracy on factual questions. Agent instructions enforce structured RCA responses. 25 eval questions with 5 failure budget. Iterate agent instructions/verified queries if score is low before completing mission. | Run eval in Mission 04; iterate up to 3 times before accepting best score | OPEN |
| R6 | Streamlit container runtime unavailable | Agent chat needs proc wrapper fallback; slightly degraded UX (no streaming) | Low–Med | Both paths designed (ADR-005). Proc wrapper `APP.CALL_RCA_AGENT` built regardless. Runtime detection in app code. Functional difference is minor for demo. | Attempt container deployment in Mission 06; fall back automatically | OPEN |
| R7 | Synthetic data doesn't produce plausible OEE (values outside 0.55–0.85 band) | OEE reconciliation tests fail; demo shows unrealistic numbers | Medium | Tune simulator parameters: ideal_cycle_s, reject rates, downtime durations, planned maintenance frequency. Mission 01 validation report checks OEE invariants before pipelines exist. Mission 02 reconciliation tests catch drifted values. Iterate backfill if needed. | `tests/validation_report.md` OEE invariant section; `TEST.VALIDATION_RESULTS` | OPEN |
| R8 | Build time exceeds deadline (Sept 1, 2026) | Incomplete submission; missing features | High | Cut order defined in `docs/plan.md`: XGBoost classifier → Snowsight Intelligence agent → 2nd automation (daily digest) → twin visuals polish. **Never cut**: golden path reliability, OEE reconciliation, recall stat, approval guardrail, agent eval, 3 published skills, evidence ledger, backup recording. Update status table after each mission for early warning. | `docs/plan.md` status table — if Mission 02 not done by Aug 30 EOD, activate cut order | OPEN |

## Monitoring Protocol

After each mission completes:
1. Run `scripts/snapshot_usage.sh` to capture credit consumption.
2. Update this register: retire resolved risks, escalate materialized ones.
3. If any risk escalates to "materialized," note the date and actual impact.

## Risk Retirement Criteria

- R1: Retired when Mission 00 probe runs and either ML works or z-score fallback is confirmed.
- R2: Retired when Mission 06 completes and total credit usage is within budget.
- R3: Retired when step 0.4 completes or when OUTBOX demo is explicitly accepted as sufficient.
- R4: Retired when all DTs confirmed INCREMENTAL in Mission 02.
- R5: Retired when agent eval >= 80% in Mission 04.
- R6: Retired when Mission 06 deployment succeeds on either runtime.
- R7: Retired when Mission 02 OEE reconciliation tests pass with plausible values.
- R8: Retired on successful submission before Sept 1.
