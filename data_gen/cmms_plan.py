"""
AegisOEE Mission 07B — CMMS Shift Planning synthetic data generator.
Produces: CORE.SHIFT_PLAN, CORE.MAINTENANCE_WINDOW
Loads via CSV → PUT → COPY INTO (not write_pandas).
Usage: python data_gen/cmms_plan.py [--seed 42] [--conn aegis] [--days 14] [--dry-run]
"""
import os, sys, argparse, time, shutil
from datetime import datetime, timedelta, date, timezone
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

IST = ZoneInfo("Asia/Kolkata")
SEED = 42
HORIZON_DAYS = 14

LINES = ["LINE_1", "LINE_2"]
ASSETS_BY_LINE = {
    "LINE_1": ["CNC_01_SPINDLE", "CNC_02_SPINDLE", "COOLANT_PUMP_01", "SERVO_MOTOR_01", "CONVEYOR_GBX_01"],
    "LINE_2": ["CNC_03_SPINDLE", "CNC_04_SPINDLE", "COOLANT_PUMP_02", "AIR_COMP_01", "CONVEYOR_GBX_02"],
}

PRODUCT_CODES = ["SHAFT_A", "GEAR_B", "HOUSING_C", "FLANGE_D", "BRACKET_E"]


def generate_shift_plan(rng, start_date, days):
    rows = []
    plan_id = 1
    order_id = 5000
    for d in range(days):
        plan_date = start_date + timedelta(days=d)
        for line in LINES:
            for shift_code in ["A", "B"]:
                if shift_code == "A":
                    shift_start = datetime(plan_date.year, plan_date.month, plan_date.day, 6, 0, tzinfo=IST)
                    shift_end = datetime(plan_date.year, plan_date.month, plan_date.day, 14, 0, tzinfo=IST)
                    planned_run_min = 450  # 480 - 30 min planned maintenance
                else:
                    shift_start = datetime(plan_date.year, plan_date.month, plan_date.day, 14, 0, tzinfo=IST)
                    shift_end = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 0, tzinfo=IST)
                    planned_run_min = 480

                product = rng.choice(PRODUCT_CODES)
                planned_qty = int(rng.integers(80, 160))
                status = "FROZEN" if d < 3 else "PLANNED"

                rows.append({
                    "PLAN_ID": f"SP_{plan_id:04d}",
                    "PLAN_DATE": plan_date.strftime("%Y-%m-%d"),
                    "SHIFT_CODE": shift_code,
                    "LINE_ID": line,
                    "ORDER_ID": f"ORD_{order_id}",
                    "PLANNED_QTY": planned_qty,
                    "PLANNED_START_TS": shift_start.isoformat(),
                    "PLANNED_END_TS": shift_end.isoformat(),
                    "PLANNED_RUN_MIN": planned_run_min,
                    "STATUS": status,
                })
                plan_id += 1
                order_id += 1
    return pd.DataFrame(rows)


def generate_maintenance_windows(rng, start_date, days):
    rows = []
    win_id = 1

    for d in range(days):
        plan_date = start_date + timedelta(days=d)
        for line in LINES:
            # 1. Daily PM window: 05:30-06:00 IST
            ws = datetime(plan_date.year, plan_date.month, plan_date.day, 5, 30, tzinfo=IST)
            we = datetime(plan_date.year, plan_date.month, plan_date.day, 6, 0, tzinfo=IST)
            rows.append({
                "WINDOW_ID": f"MW_{win_id:04d}",
                "LINE_ID": line,
                "ASSET_ID": None,
                "WINDOW_START_TS": ws.isoformat(),
                "WINDOW_END_TS": we.isoformat(),
                "WINDOW_TYPE": "DAILY_PM",
                "CAPACITY_MIN": 30,
                "BOOKED_MIN": 0,
                "STATUS": "OPEN",
            })
            win_id += 1

            # 2. Changeover between shifts (22:00-22:30 IST)
            ws = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 0, tzinfo=IST)
            we = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 30, tzinfo=IST)
            rows.append({
                "WINDOW_ID": f"MW_{win_id:04d}",
                "LINE_ID": line,
                "ASSET_ID": None,
                "WINDOW_START_TS": ws.isoformat(),
                "WINDOW_END_TS": we.isoformat(),
                "WINDOW_TYPE": "CHANGEOVER",
                "CAPACITY_MIN": 30,
                "BOOKED_MIN": 0,
                "STATUS": "OPEN",
            })
            win_id += 1

    # 3. Early zero-loss NON_PRODUCTION windows (>=120 min) in first 3 days per line
    # Two per line: day 0 night (22:30-01:00 = 150 min) and day 1 night (22:30-01:00 = 150 min)
    for d in [0, 1]:
        plan_date = start_date + timedelta(days=d)
        for line in LINES:
            ws = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 30, tzinfo=IST)
            we = ws + timedelta(minutes=150)  # 22:30 to 01:00 next day = 150 min
            rows.append({
                "WINDOW_ID": f"MW_{win_id:04d}",
                "LINE_ID": line,
                "ASSET_ID": None,
                "WINDOW_START_TS": ws.isoformat(),
                "WINDOW_END_TS": we.isoformat(),
                "WINDOW_TYPE": "NON_PRODUCTION",
                "CAPACITY_MIN": 150,
                "BOOKED_MIN": 0,
                "STATUS": "OPEN",
            })
            win_id += 1

    # 4. Weekly low-load block per line (Sunday 22:00 - Monday 02:00 = 4h)
    for d in range(days):
        plan_date = start_date + timedelta(days=d)
        if plan_date.weekday() == 6:  # Sunday
            for line in LINES:
                ws = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 0, tzinfo=IST)
                we = ws + timedelta(hours=4)
                rows.append({
                    "WINDOW_ID": f"MW_{win_id:04d}",
                    "LINE_ID": line,
                    "ASSET_ID": None,
                    "WINDOW_START_TS": ws.isoformat(),
                    "WINDOW_END_TS": we.isoformat(),
                    "WINDOW_TYPE": "NON_PRODUCTION",
                    "CAPACITY_MIN": 240,
                    "BOOKED_MIN": 0,
                    "STATUS": "OPEN",
                })
                win_id += 1

    # 5. One planned SHUTDOWN per line (10-12 hours) — capacity >= 1.25 * 464 = 580 min
    # LINE_1 on day 5, LINE_2 on day 7 (early enough for golden-path scheduling)
    shutdown_days = {"LINE_1": 5, "LINE_2": 7}
    for line, sd in shutdown_days.items():
        if sd < days:
            plan_date = start_date + timedelta(days=sd)
            duration_h = int(rng.choice([10, 11, 12]))  # >= 10h = 600 min >= 580 (1.25 * 464)
            ws = datetime(plan_date.year, plan_date.month, plan_date.day, 22, 0, tzinfo=IST)
            we = ws + timedelta(hours=duration_h)
            rows.append({
                "WINDOW_ID": f"MW_{win_id:04d}",
                "LINE_ID": line,
                "ASSET_ID": None,
                "WINDOW_START_TS": ws.isoformat(),
                "WINDOW_END_TS": we.isoformat(),
                "WINDOW_TYPE": "SHUTDOWN",
                "CAPACITY_MIN": duration_h * 60,
                "BOOKED_MIN": 0,
                "STATUS": "OPEN",
            })
            win_id += 1

    return pd.DataFrame(rows)


def main():
    parser = argparse.ArgumentParser(description="Generate CMMS planning data")
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--conn", default=os.environ.get("COCO_CONN", "aegis"))
    parser.add_argument("--days", type=int, default=HORIZON_DAYS)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    today = date.today()

    print(f"=== CMMS Plan Generator ===")
    print(f"  Seed: {args.seed}, Horizon: {args.days} days from {today}")

    df_shift_plan = generate_shift_plan(rng, today, args.days)
    df_maint_windows = generate_maintenance_windows(rng, today, args.days)

    print(f"  Shift plan rows:          {len(df_shift_plan)}")
    print(f"  Maintenance window rows:  {len(df_maint_windows)}")

    if args.dry_run:
        print("\n[DRY RUN] Sample shift plan:")
        print(df_shift_plan.head(4).to_string(index=False))
        print("\n[DRY RUN] Sample maintenance windows:")
        print(df_maint_windows.head(6).to_string(index=False))
        print("\n[DRY RUN] Shutdown windows:")
        print(df_maint_windows[df_maint_windows["WINDOW_TYPE"] == "SHUTDOWN"].to_string(index=False))
        print("\n[DRY RUN] NON_PRODUCTION windows (first 3 days):")
        np_windows = df_maint_windows[df_maint_windows["WINDOW_TYPE"] == "NON_PRODUCTION"]
        print(np_windows.to_string(index=False))
        return

    # Write CSVs to /tmp then PUT to stage, COPY INTO tables
    csv_dir = "/tmp/aegis_cmms"
    os.makedirs(csv_dir, exist_ok=True)

    sp_path = os.path.join(csv_dir, "shift_plan.csv")
    mw_path = os.path.join(csv_dir, "maintenance_windows.csv")
    df_shift_plan.to_csv(sp_path, index=False)
    df_maint_windows.to_csv(mw_path, index=False)
    print(f"\n  CSVs written to {csv_dir}")

    # Connect to Snowflake
    from snowflake.snowpark import Session
    try:
        session = Session.builder.config("connection_name", args.conn).create()
    except Exception:
        import tomllib, pathlib
        toml_path = pathlib.Path.home() / ".snowflake" / "connections.toml"
        with open(toml_path, "rb") as f:
            cfg = tomllib.load(f).get(args.conn)
        if cfg is None:
            raise RuntimeError(f"Connection '{args.conn}' not found")
        params = {"account": cfg["account"], "user": cfg["user"]}
        secret = cfg.get("password") or cfg.get("token") or ""
        auth = (cfg.get("authenticator") or "").lower()
        if auth == "oauth":
            params["authenticator"] = "oauth"
            params["token"] = secret
        elif secret:
            params["password"] = secret
        else:
            params["authenticator"] = "externalbrowser"
        session = Session.builder.configs(params).create()

    session.sql("USE DATABASE AEGIS_OEE").collect()
    session.sql("USE WAREHOUSE AEGIS_WH").collect()

    # Create a temporary stage for CMMS data
    session.sql("CREATE STAGE IF NOT EXISTS AEGIS_OEE.CORE.CMMS_STAGE FILE_FORMAT = (TYPE=CSV SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='\"' NULL_IF=(''))").collect()

    # PUT files
    print("\n[1/4] PUT shift_plan.csv...")
    session.sql(f"PUT 'file://{sp_path}' @AEGIS_OEE.CORE.CMMS_STAGE/shift_plan/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE").collect()

    print("[2/4] PUT maintenance_windows.csv...")
    session.sql(f"PUT 'file://{mw_path}' @AEGIS_OEE.CORE.CMMS_STAGE/maintenance_windows/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE").collect()

    # TRUNCATE + COPY INTO
    print("[3/4] COPY INTO CORE.SHIFT_PLAN...")
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.SHIFT_PLAN").collect()
    res = session.sql("""
        COPY INTO AEGIS_OEE.CORE.SHIFT_PLAN
        (PLAN_ID, PLAN_DATE, SHIFT_CODE, LINE_ID, ORDER_ID, PLANNED_QTY,
         PLANNED_START_TS, PLANNED_END_TS, PLANNED_RUN_MIN, STATUS)
        FROM @AEGIS_OEE.CORE.CMMS_STAGE/shift_plan/
        FILE_FORMAT = (TYPE=CSV SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=(''))
        ON_ERROR = 'ABORT_STATEMENT'
    """).collect()
    print(f"  Loaded: {res}")

    print("[4/4] COPY INTO CORE.MAINTENANCE_WINDOW...")
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.MAINTENANCE_WINDOW").collect()
    res = session.sql("""
        COPY INTO AEGIS_OEE.CORE.MAINTENANCE_WINDOW
        (WINDOW_ID, LINE_ID, ASSET_ID, WINDOW_START_TS, WINDOW_END_TS,
         WINDOW_TYPE, CAPACITY_MIN, BOOKED_MIN, STATUS)
        FROM @AEGIS_OEE.CORE.CMMS_STAGE/maintenance_windows/
        FILE_FORMAT = (TYPE=CSV SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='"' NULL_IF=(''))
        ON_ERROR = 'ABORT_STATEMENT'
    """).collect()
    print(f"  Loaded: {res}")

    # Clean up stage files
    session.sql("REMOVE @AEGIS_OEE.CORE.CMMS_STAGE/shift_plan/").collect()
    session.sql("REMOVE @AEGIS_OEE.CORE.CMMS_STAGE/maintenance_windows/").collect()

    print(f"\n=== CMMS Plan generation complete ===")
    session.close()


if __name__ == "__main__":
    main()
