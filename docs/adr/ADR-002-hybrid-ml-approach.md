# ADR-002: Hybrid ML (Anomaly + Classifier) vs Single Method

**Status:** Accepted  
**Date:** 2026-08-29  
**Context:** AegisOEE Planning Session

## Context

The system must detect equipment degradation 24+ hours before failure across 5 modes with recall >= 0.8. Snowflake offers built-in ANOMALY_DETECTION and FORECAST. The account may or may not have these features enabled (probe-gated).

## Decision

Layered approach with graceful degradation:

1. **Primary — SNOWFLAKE.ML.ANOMALY_DETECTION:** 3 models (one per signal family: vibration_rms, temp_c, rpm), each trained multi-series with `series_column = 'ASSET_ID'` on healthy-only windows. Outputs distance, percentile, bounds.
2. **Secondary — SNOWFLAKE.ML.FORECAST:** Hourly vibration + OEE trend forecasts for the digital-twin visualization. Not used for alerting.
3. **Stretch — XGBoost classifier:** Snowpark ML, predicting failure-within-24h + mode from FEATURES tables. Registered in Model Registry. Only attempted if Missions 00–02 complete ahead of schedule.
4. **Fallback — Z-score + persistence:** Pure SQL rolling z-scores with persistence detector. Same output contract (ML.ANOMALY_EVENTS schema). Used if Cortex ML probes fail.

### Risk Fusion

DT_ASSET_HEALTH combines: anomaly distance (or z-score), classifier probability (0 if absent), trend persistence (fraction of recent windows anomalous), asset criticality → single health_score (0–100), failure_probability_24h, predicted_mode, risk_level.

## Rationale

- ANOMALY_DETECTION is unsupervised — no labeled training data needed. Labels used only for evaluation. Matches "degradation ramp" physics well.
- Mode prediction (which failure?) requires supervised features — hence XGBoost as stretch goal, using FEATURES tables (never ground truth as model input).
- Z-score fallback ensures the demo works regardless of account capabilities.
- 3 models (not 30) keeps training manageable and leverages Snowflake's multi-series API efficiently.

## Consequences

- Mission 03 is probe-dependent: checks TEST.ENV_PROBES before choosing path.
- The z-score fallback must be built regardless (it's the safety net).
- Without the XGBoost classifier, mode prediction relies on which signal family triggered the anomaly (vibration → bearing/lubrication, temp alone → cooling, rpm → instability). This heuristic is less precise but sufficient for the demo.
- Training SQL may reference TEST.GROUND_TRUTH_FAILURES solely for date-range exclusion (healthy window filter). Scoring and feature tables must never reference it.

## Alternatives Considered

- **Single method (anomaly detection only):** Simpler but cannot predict failure mode. Mode information is critical for the parts-kit lookup in the action loop.
- **Single method (classifier only):** Requires labeled data for training (available), but supervised models can overfit small datasets (10 episodes). Anomaly detection is more robust for the detection task.
- **External ML (SageMaker, Vertex):** Violates the "everything inside Snowflake" constraint.
