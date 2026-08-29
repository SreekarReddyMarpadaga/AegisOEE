# CNC Spindle Bearing Maintenance — DMG Mori NLX/NTX Series

## Bearing Inspection Schedule
- **Daily**: Check spindle vibration via IFM VTV sensor. Normal range: 1.0–3.5 mm/s RMS.
- **Weekly**: Record vibration kurtosis trend. Rising kurtosis (>4.5) indicates early-stage bearing defect.
- **Monthly**: Thermal imaging of spindle housing. Temperature differential >10°C from baseline warrants investigation.

## ISO 10816 Vibration Severity Thresholds
| Zone | Vibration (mm/s RMS) | Action |
|------|---------------------|--------|
| A (Good) | 0.0–2.8 | Normal operation |
| B (Acceptable) | 2.8–4.5 | Monitor closely |
| C (Alert) | 4.5–7.1 | Schedule maintenance |
| D (Danger) | >7.1 | Stop immediately |

## Bearing Replacement Procedure
1. Lock out spindle drive and coolant supply (LOTO).
2. Remove tool holder and drawbar assembly.
3. Support spindle shaft; remove front bearing cap.
4. Extract bearing set using hydraulic puller (never use impact tools).
5. Inspect shaft and housing for scoring or discoloration.
6. Clean all surfaces with isopropyl alcohol.
7. Press new bearing set (SKF 7014C or equivalent) using thermal fit method (heat to 80°C max).
8. Apply Kluber Isoflex NBU 15 grease per OEM fill volume.
9. Reassemble in reverse order. Torque drawbar to 25 Nm.
10. Run-in at 2000 RPM for 15 min, then ramp to rated speed. Monitor vibration.

## Failure Indicators
- **Kurtosis rise**: First sign of bearing surface damage. Typically precedes RMS vibration increase by 1–3 days.
- **Temperature rise**: Late-stage indicator. Bearing temperature >75°C signals imminent failure.
- **Audible noise**: Grinding or clicking at spindle indicates advanced damage. Do not operate.
