"""
AegisOEE live simulator — replay compressed failure episodes or emit heartbeat.
Usage:
  python data_gen/simulator.py --replay BEARING_WEAR --asset CNC_01_SPINDLE --duration-min 30 --tick-s 10
  python data_gen/simulator.py --heartbeat --tick-s 60
"""
import sys, os, time, argparse
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from failure_profiles import FAILURE_GENERATORS, TelemetryModifiers
from backfill import ASSETS, ASSET_MAP, get_snowpark_session

IST = ZoneInfo("Asia/Kolkata")


def replay_episode(session, asset_id: str, mode: str,
                   duration_min: int = 30, tick_s: int = 10, seed: int = 42):
    rng = np.random.default_rng(seed)
    asset = ASSET_MAP[asset_id]
    gen = FAILURE_GENERATORS[mode]

    baseline_vib = 1.8
    baseline_kurt = 3.2
    baseline_temp = 38.0
    ideal_rpm = asset["ideal_rpm"]
    baseline_load = 60.0

    total_ticks = (duration_min * 60) // tick_s
    print(f"Replaying {mode} on {asset_id}: {total_ticks} ticks over {duration_min} min (tick={tick_s}s)")

    for i in range(total_ticks):
        t = i / max(1, total_ticks - 1)
        now = datetime.now(IST)

        if mode == "BEARING_WEAR":
            mods = gen(t, rng, asset["vib_alert_mm_s"], asset["vib_danger_mm_s"], baseline_vib)
        else:
            mods = gen(t, rng)

        load = min(100, max(0, baseline_load + mods.load_pct_add + rng.normal(0, 2)))
        vib = baseline_vib * mods.vib_rms_mult + rng.normal(0, baseline_vib * 0.05)
        kurt = baseline_kurt + mods.vib_kurtosis_add + rng.normal(0, 0.1)
        temp = baseline_temp + mods.temp_c_add + rng.normal(0, 0.5)
        rpm_val = ideal_rpm * mods.rpm_mult + rng.normal(0, ideal_rpm * 0.01)
        if mods.rpm_jitter > 0:
            rpm_val += rng.normal(0, ideal_rpm * mods.rpm_jitter)

        flag = mods.quality_flag

        sql = f"""
        INSERT INTO AEGIS_OEE.RAW.SENSOR_TELEMETRY
        (ASSET_ID, TS, VIBRATION_RMS, VIBRATION_KURTOSIS, TEMP_C, RPM, LOAD_PCT, QUALITY_FLAG)
        VALUES ('{asset_id}', '{now.isoformat()}',
                {round(max(0,vib),4)}, {round(max(1,kurt),4)},
                {round(max(15,temp),2)}, {round(max(0,rpm_val),1)},
                {round(load,1)}, '{flag}')
        """
        session.sql(sql).collect()

        phase = "HEALTHY" if t < 0.3 else ("ALERT" if t < 0.7 else "DANGER")
        print(f"  [{i+1}/{total_ticks}] t={t:.2f} phase={phase} vib={vib:.2f} temp={temp:.1f} rpm={rpm_val:.0f}")
        time.sleep(tick_s)

    print(f"Replay complete. {total_ticks} rows inserted.")


def heartbeat(session, tick_s: int = 60, seed: int = 42):
    rng = np.random.default_rng(seed)
    print(f"Heartbeat mode: emitting healthy readings for all {len(ASSETS)} assets every {tick_s}s. Ctrl+C to stop.")

    while True:
        now = datetime.now(IST)
        values = []
        for asset in ASSETS:
            vib = round(1.5 + rng.normal(0, 0.2), 4)
            kurt = round(3.0 + rng.normal(0, 0.2), 4)
            temp = round(38.0 + rng.normal(0, 1.5), 2)
            rpm = round(asset["ideal_rpm"] + rng.normal(0, asset["ideal_rpm"] * 0.01), 1)
            load = round(55 + rng.normal(0, 5), 1)
            values.append(
                f"('{asset['asset_id']}', '{now.isoformat()}', "
                f"{vib}, {kurt}, {temp}, {rpm}, {load}, 'OK')"
            )

        sql = f"""
        INSERT INTO AEGIS_OEE.RAW.SENSOR_TELEMETRY
        (ASSET_ID, TS, VIBRATION_RMS, VIBRATION_KURTOSIS, TEMP_C, RPM, LOAD_PCT, QUALITY_FLAG)
        VALUES {', '.join(values)}
        """
        session.sql(sql).collect()
        print(f"  [{now.strftime('%H:%M:%S')}] {len(ASSETS)} heartbeat rows inserted")
        time.sleep(tick_s)


def main():
    parser = argparse.ArgumentParser(description="AegisOEE Live Simulator")
    parser.add_argument("--replay", type=str, help="Failure mode to replay")
    parser.add_argument("--asset", type=str, help="Asset ID for replay")
    parser.add_argument("--duration-min", type=int, default=30)
    parser.add_argument("--tick-s", type=int, default=10)
    parser.add_argument("--heartbeat", action="store_true")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--conn", type=str, default=os.environ.get("COCO_CONN", "aegis"))
    args = parser.parse_args()

    session = get_snowpark_session(args.conn)
    session.sql("USE DATABASE AEGIS_OEE").collect()
    session.sql("USE WAREHOUSE AEGIS_WH").collect()

    try:
        if args.heartbeat:
            heartbeat(session, args.tick_s, args.seed)
        elif args.replay and args.asset:
            replay_episode(session, args.asset, args.replay,
                           args.duration_min, args.tick_s, args.seed)
        else:
            print("Usage: --replay <MODE> --asset <ID> OR --heartbeat")
            sys.exit(1)
    finally:
        session.close()


if __name__ == "__main__":
    main()
