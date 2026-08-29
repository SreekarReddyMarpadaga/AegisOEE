# ADR-001: Dynamic Tables vs Streams+Tasks Split

**Status:** Accepted  
**Date:** 2026-08-29  
**Context:** AegisOEE Planning Session

## Context

The pipeline layer (Mission 02) transforms raw 1-minute telemetry through cleaning, aggregation, feature engineering, and OEE computation. End-to-end latency must be <120s. The system also requires side-effecting operations: alert scoring, anomaly detection scoring, and notification delivery.

## Decision

**Dynamic Tables** for all declarative, stateless transformations. **Streams + Tasks** only for operations with side effects.

### Dynamic Tables (declarative pipeline)

| DT | Schema | TARGET_LAG | Purpose |
|---|---|---|---|
| DT_SENSOR_CLEAN | FEATURES | 1 min | Dedupe, quality_flag handling, clamp impossible values |
| DT_SENSOR_1MIN | FEATURES | 1 min | Per-asset per-minute mean/max/stddev |
| DT_SENSOR_FEATURES_15MIN | FEATURES | 5 min | Rolling stats, slopes, z-scores, temp-to-load residual, rpm variance |
| DT_TELEMETRY_CONTEXT | FEATURES | 1 min | Current-state snapshot: latest features + active order + last maintenance + open downtime |
| DT_SHIFT_OEE | SEMANTIC | downstream | Shift-grain OEE with exposed numerators/denominators |
| DT_OEE_LINE_DAY | SEMANTIC | downstream | Daily line-level rollup |
| DT_ASSET_HEALTH | FEATURES | downstream | Health score, anomaly distance, failure probability, risk level |

### Streams + Tasks (side effects)

| Task | Schedule | Purpose |
|---|---|---|
| TASK_DETECT_ANOMALIES | 5 min | Calls ML scoring, writes ML.ANOMALY_EVENTS |
| TASK_SCORE_ALERTS | 5 min | Reads DT_ASSET_HEALTH + ANOMALY_EVENTS, writes ACTION.ALERT |
| TASK_OUTBOX_RETRY | 10 min | Retries failed Slack/GitHub deliveries from WORK_ORDER_OUTBOX |

## Rationale

- DTs are incremental by default, self-managing, and composable — no manual watermark/offset logic.
- DTs cannot call stored procedures or external functions with side effects — alert scoring and ML scoring must be Tasks.
- TARGET_LAG provides declarative freshness control cascading through the DAG.
- If a DT falls back to FULL refresh, it signals a query-incrementalization issue, caught by the test harness (`SHOW DYNAMIC TABLES ... refresh_mode`).

## Consequences

- ~7–8 DTs form the pipeline backbone.
- 3 Tasks handle side effects on fixed schedules.
- DT refresh mode must be tested (all INCREMENTAL) in Mission 02.
- The ML scoring Task is the most complex — it reads DT outputs and writes to ML tables, creating a DT→Task→DT dependency for DT_ASSET_HEALTH.

## Alternatives Considered

- **All Streams+Tasks:** More flexible but requires manual CDC logic, watermark tracking, and error handling per stage. Higher maintenance burden, more code, harder to reason about freshness guarantees.
- **All DTs:** Not possible — DTs cannot have side effects (writing alerts, calling ML APIs, sending notifications).
