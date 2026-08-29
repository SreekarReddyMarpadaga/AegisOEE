# Predictive Maintenance Strategy — HYD_PRECISION Plant

## Condition Monitoring Framework
We use ISO 17359 as the reference framework for condition monitoring:
1. **Baseline**: Establish normal operating signatures within 30 days of commissioning or major overhaul.
2. **Trending**: Continuous monitoring of vibration, temperature, and process parameters.
3. **Diagnosis**: When thresholds exceeded, determine root cause before scheduling repair.
4. **Prognosis**: Estimate remaining useful life based on degradation rate.

## Key Performance Indicators
- **MTBF** (Mean Time Between Failures): Target >720 hours for CNC spindles.
- **MTTR** (Mean Time To Repair): Target <8 hours for priority 1 assets.
- **PdM Hit Rate**: Percentage of predicted failures that were confirmed. Target >80%.

## Failure Mode Distribution (Historical)
| Mode | Frequency | Avg Lead Time | Typical Cost |
|------|-----------|--------------|-------------|
| Bearing Wear | 35% | 3–7 days | ₹85,000 |
| Lubrication Loss | 25% | 2–5 days | ₹25,000 |
| Cooling Restriction | 20% | 3–6 days | ₹15,000 |
| RPM Instability | 15% | 2–4 days | ₹45,000 |
| Sensor Fault | 5% | Immediate | ₹5,000 |
