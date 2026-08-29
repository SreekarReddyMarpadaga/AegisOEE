# OEE Calculation Guide — HYD_PRECISION Plant

## Definitions
- **Availability** = Run Time / Planned Production Time
  - Planned Production Time = Shift Duration − Planned Downtime
  - Run Time = Planned Production Time − Unplanned Downtime
- **Performance** = (Ideal Cycle Time × Total Count) / Run Time
  - Capped at 1.0 (100%). Values >100% indicate cycle time faster than ideal (verify settings).
- **Quality** = Good Count / Total Count
- **OEE** = Availability × Performance × Quality

## Target Values
| Metric | World Class | Plant Target | Current Avg |
|--------|------------|-------------|-------------|
| Availability | >90% | >85% | 82% |
| Performance | >95% | >90% | 87% |
| Quality | >99% | >98% | 96% |
| OEE | >85% | >75% | 69% |

## Six Big Losses
1. Equipment failure (unplanned downtime) → Availability
2. Setup and adjustment → Availability
3. Idling and minor stops → Performance
4. Reduced speed → Performance
5. Process defects → Quality
6. Reduced yield (startup losses) → Quality
