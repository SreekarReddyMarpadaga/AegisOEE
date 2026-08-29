# Servo Motor Diagnostic Guide — Siemens 1FK7 Series

## Vibration Analysis
- Normal operating vibration: <3.0 mm/s RMS at motor housing.
- Alert threshold: 3.0 mm/s — schedule bearing inspection.
- Danger threshold: 5.0 mm/s — stop and inspect immediately.

## Temperature Monitoring
- Class F insulation rated to 155°C, but bearing life degrades above 80°C.
- Monitor winding temperature via PTC thermistor and bearing temperature via external PT100.
- Temperature differential between drive end and non-drive end >15°C suggests bearing issue.

## Brush Replacement (DC Servo Only)
1. De-energize and lock out drive.
2. Remove brush caps (4 locations, 90° apart).
3. Extract worn brushes. Minimum length: 10mm. Replace if <12mm.
4. Install new brushes. Ensure correct spring tension (2.5–3.0 N).
5. Run at reduced speed (50%) for 2 hours to seat brushes.
6. Check commutator surface for scoring. Dress with fine stone if needed.

## Encoder Cable
- Degraded encoder cables cause RPM instability and position errors.
- Check cable shield continuity annually. Replace if resistance >1 ohm.
- Use only shielded cables with 360° bonding at connector.
