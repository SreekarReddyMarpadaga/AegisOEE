"""
AegisOEE 75-day backfill — deterministic, seeded generator.
Produces: assets, shift calendar, sensor telemetry, production orders/events,
downtime events, maintenance history, ground-truth failures, hard negatives,
MRO parts data. Loads to Snowflake via snowflake-snowpark write_pandas.
Usage: python data_gen/backfill.py [--seed 42] [--conn aegis]
"""
import sys, os, time, argparse, uuid, math
from datetime import datetime, timedelta, date, timezone
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
from failure_profiles import (
    FAILURE_GENERATORS, FAILURE_DURATIONS_DAYS, TelemetryModifiers
)

IST = ZoneInfo("Asia/Kolkata")
SEED = 42
NUM_DAYS = 75
BATCH_SIZE = 50_000

# ── Asset definitions ────────────────────────────────────────────────
ASSETS = [
    {"asset_id": "CNC_01_SPINDLE",  "line_id": "LINE_1", "site_id": "HYD_PRECISION", "asset_type": "CNC spindle",      "manufacturer": "DMG Mori",    "install_date": "2022-03-15", "criticality": 5, "ideal_rpm": 8000, "ideal_cycle_s": 45, "temp_limit_c": 85, "vib_alert_mm_s": 4.5, "vib_danger_mm_s": 7.1},
    {"asset_id": "CNC_02_SPINDLE",  "line_id": "LINE_1", "site_id": "HYD_PRECISION", "asset_type": "CNC spindle",      "manufacturer": "DMG Mori",    "install_date": "2022-06-01", "criticality": 4, "ideal_rpm": 8000, "ideal_cycle_s": 45, "temp_limit_c": 85, "vib_alert_mm_s": 4.5, "vib_danger_mm_s": 7.1},
    {"asset_id": "COOLANT_PUMP_01", "line_id": "LINE_1", "site_id": "HYD_PRECISION", "asset_type": "coolant pump",     "manufacturer": "Grundfos",    "install_date": "2022-03-15", "criticality": 3, "ideal_rpm": 3000, "ideal_cycle_s": None, "temp_limit_c": 70, "vib_alert_mm_s": 3.5, "vib_danger_mm_s": 5.5},
    {"asset_id": "SERVO_MOTOR_01",  "line_id": "LINE_1", "site_id": "HYD_PRECISION", "asset_type": "servo motor",      "manufacturer": "Siemens",     "install_date": "2022-04-01", "criticality": 3, "ideal_rpm": 6000, "ideal_cycle_s": 30, "temp_limit_c": 80, "vib_alert_mm_s": 3.0, "vib_danger_mm_s": 5.0},
    {"asset_id": "CONVEYOR_GBX_01", "line_id": "LINE_1", "site_id": "HYD_PRECISION", "asset_type": "conveyor gearbox", "manufacturer": "SEW-Eurodrive","install_date": "2022-03-15", "criticality": 2, "ideal_rpm": 1500, "ideal_cycle_s": None, "temp_limit_c": 75, "vib_alert_mm_s": 4.0, "vib_danger_mm_s": 6.0},
    {"asset_id": "CNC_03_SPINDLE",  "line_id": "LINE_2", "site_id": "HYD_PRECISION", "asset_type": "CNC spindle",      "manufacturer": "Mazak",       "install_date": "2023-01-10", "criticality": 4, "ideal_rpm": 8000, "ideal_cycle_s": 48, "temp_limit_c": 85, "vib_alert_mm_s": 4.5, "vib_danger_mm_s": 7.1},
    {"asset_id": "CNC_04_SPINDLE",  "line_id": "LINE_2", "site_id": "HYD_PRECISION", "asset_type": "CNC spindle",      "manufacturer": "Mazak",       "install_date": "2023-01-10", "criticality": 4, "ideal_rpm": 8000, "ideal_cycle_s": 48, "temp_limit_c": 85, "vib_alert_mm_s": 4.5, "vib_danger_mm_s": 7.1},
    {"asset_id": "COOLANT_PUMP_02", "line_id": "LINE_2", "site_id": "HYD_PRECISION", "asset_type": "coolant pump",     "manufacturer": "Grundfos",    "install_date": "2023-01-10", "criticality": 3, "ideal_rpm": 3000, "ideal_cycle_s": None, "temp_limit_c": 70, "vib_alert_mm_s": 3.5, "vib_danger_mm_s": 5.5},
    {"asset_id": "AIR_COMP_01",     "line_id": "LINE_2", "site_id": "HYD_PRECISION", "asset_type": "air compressor",   "manufacturer": "Atlas Copco", "install_date": "2023-02-01", "criticality": 3, "ideal_rpm": 1800, "ideal_cycle_s": None, "temp_limit_c": 90, "vib_alert_mm_s": 5.0, "vib_danger_mm_s": 8.0},
    {"asset_id": "CONVEYOR_GBX_02", "line_id": "LINE_2", "site_id": "HYD_PRECISION", "asset_type": "conveyor gearbox", "manufacturer": "SEW-Eurodrive","install_date": "2023-01-10", "criticality": 2, "ideal_rpm": 1500, "ideal_cycle_s": None, "temp_limit_c": 75, "vib_alert_mm_s": 4.0, "vib_danger_mm_s": 6.0},
]

ASSET_MAP = {a["asset_id"]: a for a in ASSETS}

# ── Failure episode schedule (10 episodes) ───────────────────────────
# day offsets relative to start_date; golden-path last
FAILURE_EPISODES = [
    {"failure_id": "F001", "asset_id": "CNC_02_SPINDLE",  "failure_mode": "BEARING_WEAR",       "degrad_day": 8,  "fail_day": 14, "severity": "HIGH"},
    {"failure_id": "F002", "asset_id": "CNC_03_SPINDLE",  "failure_mode": "BEARING_WEAR",       "degrad_day": 30, "fail_day": 35, "severity": "HIGH"},
    {"failure_id": "F003", "asset_id": "COOLANT_PUMP_01", "failure_mode": "LUBRICATION_LOSS",    "degrad_day": 15, "fail_day": 19, "severity": "MEDIUM"},
    {"failure_id": "F004", "asset_id": "SERVO_MOTOR_01",  "failure_mode": "LUBRICATION_LOSS",    "degrad_day": 42, "fail_day": 46, "severity": "MEDIUM"},
    {"failure_id": "F005", "asset_id": "COOLANT_PUMP_02", "failure_mode": "COOLING_RESTRICTION", "degrad_day": 20, "fail_day": 25, "severity": "MEDIUM"},
    {"failure_id": "F006", "asset_id": "AIR_COMP_01",     "failure_mode": "COOLING_RESTRICTION", "degrad_day": 50, "fail_day": 55, "severity": "MEDIUM"},
    {"failure_id": "F007", "asset_id": "CONVEYOR_GBX_01", "failure_mode": "RPM_INSTABILITY",     "degrad_day": 25, "fail_day": 28, "severity": "LOW"},
    {"failure_id": "F008", "asset_id": "CNC_04_SPINDLE",  "failure_mode": "RPM_INSTABILITY",     "degrad_day": 55, "fail_day": 58, "severity": "MEDIUM"},
    {"failure_id": "F009", "asset_id": "CONVEYOR_GBX_02", "failure_mode": "SENSOR_FAULT",        "degrad_day": 38, "fail_day": 38, "severity": "LOW"},
    # Golden-path: CNC_01_SPINDLE BEARING_WEAR, degradation day 65, failure day 72
    {"failure_id": "F010", "asset_id": "CNC_01_SPINDLE",  "failure_mode": "BEARING_WEAR",       "degrad_day": 65, "fail_day": 72, "severity": "CRITICAL"},
]

# ── Hard-negative episodes (≥4) ─────────────────────────────────────
HARD_NEGATIVES = [
    {"asset_id": "CNC_01_SPINDLE",  "type": "HOT_HEAVY_LOAD",    "start_day": 20, "end_day": 22, "desc": "High-temp under heavy load, not a failure"},
    {"asset_id": "CNC_03_SPINDLE",  "type": "PLANNED_RPM_CHANGE","start_day": 45, "end_day": 46, "desc": "Product changeover RPM shift"},
    {"asset_id": "SERVO_MOTOR_01",  "type": "PLANNED_MAINTENANCE","start_day": 35, "end_day": 35, "desc": "Extended planned maintenance"},
    {"asset_id": "COOLANT_PUMP_01", "type": "SENSOR_DROPOUT",    "start_day": 55, "end_day": 55, "desc": "Brief sensor dropout, healthy asset"},
    {"asset_id": "CNC_04_SPINDLE",  "type": "HOT_HEAVY_LOAD",    "start_day": 10, "end_day": 12, "desc": "Heavy batch, elevated temp, normal vibration"},
]

# ── MRO Parts ────────────────────────────────────────────────────────
PARTS = [
    {"part_id": "P001", "part_name": "CNC Spindle Bearing Kit (7014C)", "category": "bearings", "on_hand_qty": 1, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 1250.00, "supplier_name": "SKF India", "lead_time_days": 7, "bin_location": "A-01-03"},
    {"part_id": "P002", "part_name": "Spindle Grease Cartridge (Kluber)", "category": "lubricants", "on_hand_qty": 12, "reserved_qty": 2, "reorder_point": 5, "unit_cost": 85.00, "supplier_name": "Kluber India", "lead_time_days": 3, "bin_location": "B-02-01"},
    {"part_id": "P003", "part_name": "Spindle Shaft Seal (45mm)", "category": "seals", "on_hand_qty": 6, "reserved_qty": 0, "reorder_point": 4, "unit_cost": 320.00, "supplier_name": "Freudenberg", "lead_time_days": 5, "bin_location": "A-01-05"},
    {"part_id": "P004", "part_name": "Coolant Pump Impeller Assembly", "category": "pump_parts", "on_hand_qty": 3, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 890.00, "supplier_name": "Grundfos India", "lead_time_days": 10, "bin_location": "C-03-02"},
    {"part_id": "P005", "part_name": "Mechanical Shaft Seal (30mm)", "category": "seals", "on_hand_qty": 5, "reserved_qty": 1, "reorder_point": 3, "unit_cost": 210.00, "supplier_name": "Freudenberg", "lead_time_days": 5, "bin_location": "A-01-06"},
    {"part_id": "P006", "part_name": "Pump Bearing (6205-2RS)", "category": "bearings", "on_hand_qty": 8, "reserved_qty": 0, "reorder_point": 4, "unit_cost": 145.00, "supplier_name": "SKF India", "lead_time_days": 4, "bin_location": "A-02-01"},
    {"part_id": "P007", "part_name": "Lubricant Cartridge (Mobil SHC)", "category": "lubricants", "on_hand_qty": 15, "reserved_qty": 0, "reorder_point": 8, "unit_cost": 65.00, "supplier_name": "ExxonMobil India", "lead_time_days": 3, "bin_location": "B-02-03"},
    {"part_id": "P008", "part_name": "Servo Motor Brushes (Set of 4)", "category": "electrical", "on_hand_qty": 4, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 175.00, "supplier_name": "Siemens India", "lead_time_days": 6, "bin_location": "D-01-02"},
    {"part_id": "P009", "part_name": "Motor Bearing (6308-2Z)", "category": "bearings", "on_hand_qty": 6, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 195.00, "supplier_name": "SKF India", "lead_time_days": 4, "bin_location": "A-02-03"},
    {"part_id": "P010", "part_name": "Servo Encoder Cable (5m)", "category": "electrical", "on_hand_qty": 3, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 420.00, "supplier_name": "Siemens India", "lead_time_days": 8, "bin_location": "D-01-04"},
    {"part_id": "P011", "part_name": "Conveyor Drive Belt (HTD-8M-1200)", "category": "belts", "on_hand_qty": 4, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 280.00, "supplier_name": "Gates India", "lead_time_days": 5, "bin_location": "E-01-01"},
    {"part_id": "P012", "part_name": "Gearbox Bearing (32210)", "category": "bearings", "on_hand_qty": 5, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 310.00, "supplier_name": "Timken India", "lead_time_days": 6, "bin_location": "A-03-01"},
    {"part_id": "P013", "part_name": "Gearbox Oil (SAE 80W-90, 5L)", "category": "lubricants", "on_hand_qty": 10, "reserved_qty": 0, "reorder_point": 5, "unit_cost": 55.00, "supplier_name": "Shell India", "lead_time_days": 3, "bin_location": "B-03-01"},
    {"part_id": "P014", "part_name": "Gearbox Coupling Insert", "category": "couplings", "on_hand_qty": 3, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 185.00, "supplier_name": "SEW-Eurodrive India", "lead_time_days": 7, "bin_location": "E-02-01"},
    {"part_id": "P015", "part_name": "Air Filter Element (Atlas Copco)", "category": "filters", "on_hand_qty": 8, "reserved_qty": 0, "reorder_point": 4, "unit_cost": 125.00, "supplier_name": "Atlas Copco India", "lead_time_days": 4, "bin_location": "F-01-01"},
    {"part_id": "P016", "part_name": "Compressor Oil Separator", "category": "filters", "on_hand_qty": 3, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 450.00, "supplier_name": "Atlas Copco India", "lead_time_days": 8, "bin_location": "F-01-02"},
    {"part_id": "P017", "part_name": "Compressor Valve Kit", "category": "valves", "on_hand_qty": 2, "reserved_qty": 0, "reorder_point": 1, "unit_cost": 780.00, "supplier_name": "Atlas Copco India", "lead_time_days": 10, "bin_location": "F-01-03"},
    {"part_id": "P018", "part_name": "Coolant Filter Cartridge", "category": "filters", "on_hand_qty": 20, "reserved_qty": 0, "reorder_point": 10, "unit_cost": 35.00, "supplier_name": "Grundfos India", "lead_time_days": 3, "bin_location": "C-03-05"},
    {"part_id": "P019", "part_name": "Thermal Paste Tube (50g)", "category": "consumables", "on_hand_qty": 10, "reserved_qty": 0, "reorder_point": 5, "unit_cost": 22.00, "supplier_name": "Henkel India", "lead_time_days": 2, "bin_location": "G-01-01"},
    {"part_id": "P020", "part_name": "Spindle Drawbar Spring Set", "category": "springs", "on_hand_qty": 4, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 560.00, "supplier_name": "DMG Mori Parts", "lead_time_days": 14, "bin_location": "A-01-08"},
    {"part_id": "P021", "part_name": "Compressor Bearing (6310-2RS)", "category": "bearings", "on_hand_qty": 4, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 230.00, "supplier_name": "SKF India", "lead_time_days": 4, "bin_location": "A-04-01"},
    {"part_id": "P022", "part_name": "O-Ring Kit (Metric Assorted)", "category": "seals", "on_hand_qty": 15, "reserved_qty": 0, "reorder_point": 5, "unit_cost": 45.00, "supplier_name": "Parker India", "lead_time_days": 3, "bin_location": "A-05-01"},
    {"part_id": "P023", "part_name": "Proximity Sensor (Inductive M12)", "category": "sensors", "on_hand_qty": 6, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 95.00, "supplier_name": "IFM India", "lead_time_days": 5, "bin_location": "D-02-01"},
    {"part_id": "P024", "part_name": "Vibration Sensor Module (IFM VTV)", "category": "sensors", "on_hand_qty": 2, "reserved_qty": 0, "reorder_point": 1, "unit_cost": 1450.00, "supplier_name": "IFM India", "lead_time_days": 12, "bin_location": "D-02-03"},
    {"part_id": "P025", "part_name": "Temperature Sensor (PT100)", "category": "sensors", "on_hand_qty": 5, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 110.00, "supplier_name": "IFM India", "lead_time_days": 5, "bin_location": "D-02-04"},
    {"part_id": "P026", "part_name": "Motor Coupling Elastomer Insert", "category": "couplings", "on_hand_qty": 6, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 75.00, "supplier_name": "Siemens India", "lead_time_days": 4, "bin_location": "E-02-03"},
    {"part_id": "P027", "part_name": "Hydraulic Hose (1/2in, 2m)", "category": "hoses", "on_hand_qty": 8, "reserved_qty": 0, "reorder_point": 4, "unit_cost": 165.00, "supplier_name": "Parker India", "lead_time_days": 4, "bin_location": "E-03-01"},
    {"part_id": "P028", "part_name": "Coolant Concentrate (20L)", "category": "fluids", "on_hand_qty": 5, "reserved_qty": 0, "reorder_point": 3, "unit_cost": 340.00, "supplier_name": "Castrol India", "lead_time_days": 3, "bin_location": "B-04-01"},
    {"part_id": "P029", "part_name": "Belt Tensioner Assembly", "category": "belts", "on_hand_qty": 3, "reserved_qty": 0, "reorder_point": 2, "unit_cost": 220.00, "supplier_name": "Gates India", "lead_time_days": 6, "bin_location": "E-01-03"},
    {"part_id": "P030", "part_name": "Compressor Air-Oil Cooler", "category": "heat_exchangers", "on_hand_qty": 1, "reserved_qty": 0, "reorder_point": 1, "unit_cost": 2100.00, "supplier_name": "Atlas Copco India", "lead_time_days": 14, "bin_location": "F-02-01"},
]

# failure_mode x asset_type -> parts kit
FAILURE_MODE_PARTS_MAP = [
    # BEARING_WEAR
    {"failure_mode": "BEARING_WEAR", "asset_type": "CNC spindle",      "part_id": "P001", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "CNC spindle",      "part_id": "P002", "qty_required": 1},
    {"failure_mode": "BEARING_WEAR", "asset_type": "CNC spindle",      "part_id": "P003", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "coolant pump",     "part_id": "P006", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "coolant pump",     "part_id": "P007", "qty_required": 1},
    {"failure_mode": "BEARING_WEAR", "asset_type": "servo motor",      "part_id": "P009", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "servo motor",      "part_id": "P007", "qty_required": 1},
    {"failure_mode": "BEARING_WEAR", "asset_type": "conveyor gearbox", "part_id": "P012", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "conveyor gearbox", "part_id": "P013", "qty_required": 1},
    {"failure_mode": "BEARING_WEAR", "asset_type": "air compressor",   "part_id": "P021", "qty_required": 2},
    {"failure_mode": "BEARING_WEAR", "asset_type": "air compressor",   "part_id": "P007", "qty_required": 1},
    # LUBRICATION_LOSS
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "CNC spindle",      "part_id": "P002", "qty_required": 2},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "CNC spindle",      "part_id": "P003", "qty_required": 1},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "coolant pump",     "part_id": "P007", "qty_required": 2},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "coolant pump",     "part_id": "P005", "qty_required": 1},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "servo motor",      "part_id": "P007", "qty_required": 2},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "servo motor",      "part_id": "P026", "qty_required": 1},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "conveyor gearbox", "part_id": "P013", "qty_required": 2},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "conveyor gearbox", "part_id": "P014", "qty_required": 1},
    {"failure_mode": "LUBRICATION_LOSS", "asset_type": "air compressor",   "part_id": "P007", "qty_required": 2},
    # COOLING_RESTRICTION
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "CNC spindle",      "part_id": "P028", "qty_required": 1},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "CNC spindle",      "part_id": "P018", "qty_required": 2},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "coolant pump",     "part_id": "P004", "qty_required": 1},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "coolant pump",     "part_id": "P018", "qty_required": 2},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "servo motor",      "part_id": "P019", "qty_required": 1},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "conveyor gearbox", "part_id": "P013", "qty_required": 1},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "air compressor",   "part_id": "P030", "qty_required": 1},
    {"failure_mode": "COOLING_RESTRICTION", "asset_type": "air compressor",   "part_id": "P015", "qty_required": 2},
    # RPM_INSTABILITY
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "CNC spindle",      "part_id": "P020", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "CNC spindle",      "part_id": "P001", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "coolant pump",     "part_id": "P004", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "servo motor",      "part_id": "P008", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "servo motor",      "part_id": "P010", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "conveyor gearbox", "part_id": "P011", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "conveyor gearbox", "part_id": "P029", "qty_required": 1},
    {"failure_mode": "RPM_INSTABILITY", "asset_type": "air compressor",   "part_id": "P017", "qty_required": 1},
    # SENSOR_FAULT
    {"failure_mode": "SENSOR_FAULT", "asset_type": "CNC spindle",      "part_id": "P024", "qty_required": 1},
    {"failure_mode": "SENSOR_FAULT", "asset_type": "coolant pump",     "part_id": "P025", "qty_required": 1},
    {"failure_mode": "SENSOR_FAULT", "asset_type": "servo motor",      "part_id": "P023", "qty_required": 1},
    {"failure_mode": "SENSOR_FAULT", "asset_type": "conveyor gearbox", "part_id": "P023", "qty_required": 1},
    {"failure_mode": "SENSOR_FAULT", "asset_type": "air compressor",   "part_id": "P025", "qty_required": 1},
]


def get_snowpark_session(conn_name: str = "aegis"):
    from snowflake.snowpark import Session
    # Preferred: native connections.toml resolution (same path the snow CLI uses)
    try:
        session = Session.builder.config("connection_name", conn_name).create()
    except Exception as native_err:
        import tomllib, pathlib
        toml_path = pathlib.Path.home() / ".snowflake" / "connections.toml"
        with open(toml_path, "rb") as f:
            cfg = tomllib.load(f).get(conn_name)
        if cfg is None:
            raise RuntimeError(f"Connection '{conn_name}' not found in {toml_path}") from native_err
        params = {"account": cfg["account"], "user": cfg["user"]}
        secret = cfg.get("password") or cfg.get("token") or ""
        auth = (cfg.get("authenticator") or "").lower()
        if auth == "oauth":
            params["authenticator"] = "oauth"
            params["token"] = secret
        elif secret:
            params["password"] = secret  # PATs authenticate as passwords
        else:
            params["authenticator"] = "externalbrowser"
        session = Session.builder.configs(params).create()
    session.sql("USE DATABASE AEGIS_OEE").collect()
    session.sql("USE WAREHOUSE AEGIS_WH").collect()
    session.sql("USE SCHEMA RAW").collect()
    return session


def load_df(session, df: pd.DataFrame, table_fqn: str, mode: str = "append"):
    from snowflake.snowpark import functions as F
    t0 = time.time()
    schema_table = table_fqn.split(".", 1) if "." in table_fqn else ("RAW", table_fqn)
    fqn = f"AEGIS_OEE.{table_fqn}"
    # write_pandas via the session's connection
    from snowflake.snowpark._internal.utils import TempObjectType
    success, nchunks, nrows, _ = session.write_pandas(
        df, table_fqn.split(".")[-1],
        database="AEGIS_OEE",
        schema=table_fqn.split(".")[0] if "." in table_fqn else "RAW",
        auto_create_table=False,
        overwrite=(mode == "overwrite"),
        quote_identifiers=False
    )
    elapsed = time.time() - t0
    print(f"  Loaded {len(df):,} rows -> {fqn} in {elapsed:.1f}s ({nchunks} chunks)")
    return len(df)


def generate_shift_calendar(start_date: date, num_days: int) -> pd.DataFrame:
    rows = []
    for d in range(num_days):
        dt = start_date + timedelta(days=d)
        # Shift A: 06:00-14:00 IST, 30 min planned downtime
        a_start = datetime(dt.year, dt.month, dt.day, 6, 0, tzinfo=IST)
        a_end = datetime(dt.year, dt.month, dt.day, 14, 0, tzinfo=IST)
        rows.append({"SHIFT_DATE": dt, "SHIFT_CODE": "A", "START_TS": a_start,
                      "END_TS": a_end, "PLANNED_MINUTES": 480, "PLANNED_DOWNTIME_MINUTES": 30})
        # Shift B: 14:00-22:00 IST, 0 planned downtime
        b_start = datetime(dt.year, dt.month, dt.day, 14, 0, tzinfo=IST)
        b_end = datetime(dt.year, dt.month, dt.day, 22, 0, tzinfo=IST)
        rows.append({"SHIFT_DATE": dt, "SHIFT_CODE": "B", "START_TS": b_start,
                      "END_TS": b_end, "PLANNED_MINUTES": 480, "PLANNED_DOWNTIME_MINUTES": 0})
    return pd.DataFrame(rows)


def is_in_shift(ts_ist: datetime) -> bool:
    h = ts_ist.hour
    return 6 <= h < 22


def get_shift_code(ts_ist: datetime) -> str:
    return "A" if ts_ist.hour < 14 else "B"


def generate_telemetry(rng: np.random.Generator, start_date: date,
                       num_days: int, assets: list, episodes: list,
                       hard_negs: list) -> tuple:
    """Generate 1-min telemetry for all assets. Returns (telemetry_rows, downtime_rows, maint_rows, prod_event_rows)."""
    
    start_dt = datetime(start_date.year, start_date.month, start_date.day, 0, 0, tzinfo=IST)
    end_dt = start_dt + timedelta(days=num_days)
    total_minutes = num_days * 1440

    # Build episode lookup: asset_id -> list of (degrad_start_ts, fail_ts, mode, fail_id)
    episode_map = {}
    for ep in episodes:
        aid = ep["asset_id"]
        ds = start_dt + timedelta(days=ep["degrad_day"])
        ft = start_dt + timedelta(days=ep["fail_day"])
        episode_map.setdefault(aid, []).append({
            "degrad_start": ds, "fail_ts": ft,
            "mode": ep["failure_mode"], "id": ep["failure_id"],
            "severity": ep["severity"]
        })

    # Hard negative lookup
    hn_map = {}
    for hn in hard_negs:
        aid = hn["asset_id"]
        hs = start_dt + timedelta(days=hn["start_day"])
        he = start_dt + timedelta(days=hn["end_day"] + 1)
        hn_map.setdefault(aid, []).append({
            "start": hs, "end": he, "type": hn["type"]
        })

    all_telemetry = []
    all_downtime = []
    all_maintenance = []
    all_prod_events = []
    downtime_counter = [0]
    maint_counter = [0]

    for asset in assets:
        aid = asset["asset_id"]
        baseline_vib = 1.5 + rng.random() * 1.0
        baseline_kurt = 3.0 + rng.random() * 0.5
        baseline_temp = 35.0 + rng.random() * 10.0
        ideal_rpm = asset["ideal_rpm"]
        ideal_cycle = asset.get("ideal_cycle_s") or 60.0
        baseline_load = 55 + rng.random() * 15

        asset_episodes = episode_map.get(aid, [])
        asset_hns = hn_map.get(aid, [])

        # Track post-failure reset windows
        reset_windows = []  # (reset_start, reset_end)
        for ep in asset_episodes:
            if ep["mode"] != "SENSOR_FAULT":
                repair_hours = 2 + rng.integers(0, 22)
                maint_ts = ep["fail_ts"] + timedelta(hours=int(repair_hours))
                downtime_end = maint_ts
                reset_windows.append((ep["fail_ts"], downtime_end))

                downtime_counter[0] += 1
                dt_minutes = (downtime_end - ep["fail_ts"]).total_seconds() / 60
                all_downtime.append({
                    "EVENT_ID": f"DT{downtime_counter[0]:04d}",
                    "ASSET_ID": aid,
                    "START_TS": ep["fail_ts"],
                    "END_TS": downtime_end,
                    "IS_PLANNED": False,
                    "REASON_CODE": ep["mode"],
                    "FAILURE_MODE": ep["mode"],
                    "MINUTES": round(dt_minutes, 1),
                })

                maint_counter[0] += 1
                tech_notes = _gen_tech_note(rng, ep["mode"], aid)
                all_maintenance.append({
                    "WO_HIST_ID": f"WH{maint_counter[0]:04d}",
                    "ASSET_ID": aid,
                    "COMPLETED_TS": maint_ts,
                    "FAILURE_CODE": ep["mode"],
                    "FINDING": _gen_finding(ep["mode"]),
                    "ACTION_TAKEN": _gen_action(ep["mode"]),
                    "PARTS_USED": _gen_parts_used(ep["mode"], asset["asset_type"]),
                    "LABOR_HOURS": round(repair_hours * 0.8, 1),
                    "TECHNICIAN_NOTE": tech_notes,
                })
            else:
                # Sensor fault: short downtime for inspection
                insp_end = ep["fail_ts"] + timedelta(hours=1)
                reset_windows.append((ep["fail_ts"], insp_end))
                downtime_counter[0] += 1
                all_downtime.append({
                    "EVENT_ID": f"DT{downtime_counter[0]:04d}",
                    "ASSET_ID": aid,
                    "START_TS": ep["fail_ts"],
                    "END_TS": insp_end,
                    "IS_PLANNED": False,
                    "REASON_CODE": "SENSOR_FAULT",
                    "FAILURE_MODE": "SENSOR_FAULT",
                    "MINUTES": 60.0,
                })
                maint_counter[0] += 1
                all_maintenance.append({
                    "WO_HIST_ID": f"WH{maint_counter[0]:04d}",
                    "ASSET_ID": aid,
                    "COMPLETED_TS": insp_end,
                    "FAILURE_CODE": "SENSOR_FAULT",
                    "FINDING": "Vibration sensor intermittent. Connector corroded.",
                    "ACTION_TAKEN": "Replaced sensor cable and cleaned connector. Recalibrated.",
                    "PARTS_USED": "Vibration sensor module",
                    "LABOR_HOURS": 1.0,
                    "TECHNICIAN_NOTE": "Sensor replaced. Readings returned to normal. Root cause: moisture ingress at junction box.",
                })

        # Generate minute-by-minute telemetry
        asset_telem = []
        current_ts = start_dt
        prod_count_acc = 0
        good_count_acc = 0
        reject_count_acc = 0
        last_prod_event_hour = None

        while current_ts < end_dt:
            ts_ist = current_ts

            # Skip non-shift hours (22:00-06:00)
            if not is_in_shift(ts_ist):
                current_ts += timedelta(minutes=1)
                continue

            # Check if in downtime/reset window
            in_reset = False
            for rw_start, rw_end in reset_windows:
                if rw_start <= ts_ist < rw_end:
                    in_reset = True
                    break

            # Random gap (~0.3% of readings missing)
            if rng.random() < 0.003 and not in_reset:
                current_ts += timedelta(minutes=1)
                continue

            if in_reset:
                # During downtime: rpm=0, minimal readings
                row = {
                    "ASSET_ID": aid, "TS": ts_ist,
                    "VIBRATION_RMS": round(rng.normal(0.3, 0.1), 4),
                    "VIBRATION_KURTOSIS": round(rng.normal(3.0, 0.2), 4),
                    "TEMP_C": round(baseline_temp * 0.6 + rng.normal(0, 1), 2),
                    "RPM": 0.0,
                    "LOAD_PCT": 0.0,
                    "QUALITY_FLAG": "OK",
                }
                asset_telem.append(row)
                current_ts += timedelta(minutes=1)
                continue

            # Determine modifiers from failure episodes
            mods = TelemetryModifiers()
            active_mode = None
            for ep in asset_episodes:
                if ep["degrad_start"] <= ts_ist < ep["fail_ts"]:
                    total_dur = (ep["fail_ts"] - ep["degrad_start"]).total_seconds()
                    elapsed = (ts_ist - ep["degrad_start"]).total_seconds()
                    t = min(1.0, elapsed / total_dur)
                    gen = FAILURE_GENERATORS[ep["mode"]]
                    if ep["mode"] == "BEARING_WEAR":
                        mods = gen(t, rng, asset["vib_alert_mm_s"],
                                   asset["vib_danger_mm_s"], baseline_vib)
                    else:
                        mods = gen(t, rng)
                    active_mode = ep["mode"]
                    break

            # Hard negatives
            for hn in asset_hns:
                if hn["start"] <= ts_ist < hn["end"]:
                    if hn["type"] == "HOT_HEAVY_LOAD":
                        mods.temp_c_add += 12 + rng.normal(0, 2)
                        mods.load_pct_add += 15
                        mods.vib_rms_mult = 1.0 + rng.normal(0, 0.05)
                    elif hn["type"] == "PLANNED_RPM_CHANGE":
                        mods.rpm_mult = 0.75 + rng.normal(0, 0.02)
                        mods.cycle_time_mult = 1.3
                    elif hn["type"] == "SENSOR_DROPOUT":
                        if rng.random() < 0.3:
                            mods.quality_flag = "GAP"
                    break

            # Compute telemetry values
            load = min(100, max(0, baseline_load + mods.load_pct_add + rng.normal(0, 3)))
            vib = baseline_vib * mods.vib_rms_mult + rng.normal(0, baseline_vib * 0.05)
            kurt = baseline_kurt + mods.vib_kurtosis_add + rng.normal(0, 0.15)
            temp = baseline_temp + mods.temp_c_add + rng.normal(0, 0.8)
            rpm_val = ideal_rpm * mods.rpm_mult
            if mods.rpm_jitter > 0:
                rpm_val += rng.normal(0, ideal_rpm * mods.rpm_jitter)
            rpm_val += rng.normal(0, ideal_rpm * 0.01)

            # Micro-stop check
            if mods.micro_stop_prob > 0 and rng.random() < mods.micro_stop_prob:
                rpm_val = 0
                vib = rng.normal(0.3, 0.1)
                load = 0

            flag = mods.quality_flag

            row = {
                "ASSET_ID": aid, "TS": ts_ist,
                "VIBRATION_RMS": round(max(0, vib), 4),
                "VIBRATION_KURTOSIS": round(max(1, kurt), 4),
                "TEMP_C": round(max(15, temp), 2),
                "RPM": round(max(0, rpm_val), 1),
                "LOAD_PCT": round(load, 1),
                "QUALITY_FLAG": flag,
            }
            asset_telem.append(row)

            # Production events (hourly summary for assets with cycle_time)
            if asset.get("ideal_cycle_s") is not None:
                current_hour = ts_ist.replace(minute=0, second=0, microsecond=0)
                if last_prod_event_hour is None or current_hour > last_prod_event_hour:
                    if last_prod_event_hour is not None and rpm_val > 0:
                        cycle_s = ideal_cycle * mods.cycle_time_mult + rng.normal(0, ideal_cycle * 0.03)
                        parts_per_hour = max(0, int(3600 / max(cycle_s, 10)))
                        base_reject = 0.02
                        reject_rate = base_reject + mods.reject_rate_add
                        rejects = int(parts_per_hour * reject_rate)
                        good = parts_per_hour - rejects
                        prod_count_acc += parts_per_hour
                        good_count_acc += good
                        reject_count_acc += rejects

                        state = "RUN"
                        if mods.micro_stop_prob > 0.1:
                            state = rng.choice(["RUN", "RUN", "DOWN"]) if rng.random() < mods.micro_stop_prob else "RUN"

                        all_prod_events.append({
                            "ASSET_ID": aid, "TS": current_hour,
                            "ORDER_ID": None,
                            "STATE": state,
                            "PRODUCED_COUNT": parts_per_hour,
                            "GOOD_COUNT": good,
                            "REJECT_COUNT": rejects,
                            "CYCLE_TIME_S": round(cycle_s, 2),
                        })
                    last_prod_event_hour = current_hour

            current_ts += timedelta(minutes=1)

        all_telemetry.extend(asset_telem)
        print(f"  {aid}: {len(asset_telem):,} telemetry rows")

    return all_telemetry, all_downtime, all_maintenance, all_prod_events


def _gen_tech_note(rng, mode, asset_id):
    notes = {
        "BEARING_WEAR": [
            f"Inspected {asset_id}. Main spindle bearing showing significant wear pattern. Inner race pitting visible. Replaced both bearings with new SKF 7014C set. Greased to spec. Test run satisfactory — vibration back within limits.",
            f"Bearing failure on {asset_id}. Kurtosis had been trending high for days. Outer race spalling confirmed. Swapped bearing kit, cleaned housing, applied fresh grease. Ran for 30 min — all readings nominal.",
            f"{asset_id} down due to bearing degradation. Found metal debris in grease — classic fatigue wear. Replaced bearing set and shaft seal. Re-aligned spindle. Post-repair vibration 1.8 mm/s, well within spec.",
        ],
        "LUBRICATION_LOSS": [
            f"Lubrication failure on {asset_id}. Oil level critically low — likely slow leak from shaft seal. Replaced seal, topped off oil, and ran cleaning cycle. Temp and vib both dropped to normal within 15 min of restart.",
            f"{asset_id} overheating with elevated vibration. Grease had dried out in bearing cavity. Re-greased per OEM spec (Kluber Isoflex NBU 15), replaced felt seals. All readings nominal post-repair.",
        ],
        "COOLING_RESTRICTION": [
            f"Thermal shutdown on {asset_id}. Found coolant filter completely clogged with swarf. Replaced filter, flushed coolant lines, topped off reservoir with fresh coolant. Temp stabilized at 42°C after restart.",
            f"{asset_id} running hot. Coolant flow reduced to trickle — blockage in delivery tube. Cleared obstruction, replaced filter cartridge, bled air from system. Quality improved immediately.",
        ],
        "RPM_INSTABILITY": [
            f"RPM oscillation on {asset_id}. Drive belt showing cracking and uneven tension. Replaced belt and tensioner assembly. RPM stable at 1500±5 after adjustment.",
            f"{asset_id} experiencing speed hunting. Found worn coupling insert causing backlash. Replaced coupling elastomer and re-aligned shafts. Cycle time variance reduced from ±15% to ±2%.",
        ],
        "SENSOR_FAULT": [
            f"Sensor readings erratic on {asset_id}. Found corroded connector at junction box. Replaced cable and sensor module. Calibrated against reference. Readings stable.",
        ],
    }
    options = notes.get(mode, [f"Corrective maintenance on {asset_id} for {mode}."])
    return rng.choice(options)


def _gen_finding(mode):
    findings = {
        "BEARING_WEAR": "Inner/outer race pitting and spalling detected on main bearing.",
        "LUBRICATION_LOSS": "Insufficient lubrication; oil level low or grease degraded.",
        "COOLING_RESTRICTION": "Coolant flow restricted; filter clogged or line blocked.",
        "RPM_INSTABILITY": "Speed oscillation due to mechanical wear in drive train.",
        "SENSOR_FAULT": "Sensor malfunction; intermittent readings due to cable/connector issue.",
    }
    return findings.get(mode, f"Issue related to {mode}")


def _gen_action(mode):
    actions = {
        "BEARING_WEAR": "Replaced bearing set, re-greased, re-aligned, test run passed.",
        "LUBRICATION_LOSS": "Replaced seals, replenished lubricant, cleaned housing.",
        "COOLING_RESTRICTION": "Replaced filter, flushed coolant lines, bled air from system.",
        "RPM_INSTABILITY": "Replaced worn drive components (belt/coupling), re-aligned.",
        "SENSOR_FAULT": "Replaced sensor module and cable, recalibrated.",
    }
    return actions.get(mode, f"Corrective action for {mode}")


def _gen_parts_used(mode, asset_type):
    parts_map = {
        "BEARING_WEAR": "Bearing kit x2, grease cartridge, shaft seal",
        "LUBRICATION_LOSS": "Lubricant cartridge x2, shaft seal",
        "COOLING_RESTRICTION": "Coolant filter x2, coolant concentrate",
        "RPM_INSTABILITY": "Drive belt/coupling, tensioner",
        "SENSOR_FAULT": "Vibration sensor module, cable",
    }
    return parts_map.get(mode, "Misc consumables")


def generate_production_orders(rng, start_date, num_days, lines) -> list:
    orders = []
    products = ["PART_A100", "PART_B200", "PART_C300", "PART_D400"]
    order_num = 0
    for d in range(num_days):
        dt = start_date + timedelta(days=d)
        for line in lines:
            for shift_code in ["A", "B"]:
                order_num += 1
                if shift_code == "A":
                    start_ts = datetime(dt.year, dt.month, dt.day, 6, 0, tzinfo=IST)
                    end_ts = datetime(dt.year, dt.month, dt.day, 14, 0, tzinfo=IST)
                else:
                    start_ts = datetime(dt.year, dt.month, dt.day, 14, 0, tzinfo=IST)
                    end_ts = datetime(dt.year, dt.month, dt.day, 22, 0, tzinfo=IST)
                product = rng.choice(products)
                planned_qty = int(rng.integers(200, 500))
                cycle_s = 45.0 if "A" in product or "B" in product else 48.0
                orders.append({
                    "ORDER_ID": f"PO{order_num:05d}",
                    "LINE_ID": line,
                    "PRODUCT_CODE": product,
                    "PLANNED_QTY": planned_qty,
                    "IDEAL_CYCLE_S": cycle_s,
                    "PLANNED_START_TS": start_ts,
                    "PLANNED_END_TS": end_ts,
                })
    return orders


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--conn", type=str, default=os.environ.get("COCO_CONN", "aegis"))
    parser.add_argument("--days", type=int, default=NUM_DAYS)
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    today = date.today()
    yesterday = today - timedelta(days=1)
    start_date = yesterday - timedelta(days=args.days - 1)
    print(f"=== AegisOEE Backfill ===")
    print(f"Seed: {args.seed}, Days: {args.days}, Range: {start_date} to {yesterday}")
    print(f"Connection: {args.conn}")

    t_start = time.time()

    print("\nConnecting to Snowflake...")
    session = get_snowpark_session(args.conn)
    session.sql("USE DATABASE AEGIS_OEE").collect()
    session.sql("USE WAREHOUSE AEGIS_WH").collect()

    # ── 1. Load assets ──
    print("\n[1/8] Loading CORE.ASSET...")
    df_assets = pd.DataFrame(ASSETS)
    df_assets.columns = [c.upper() for c in df_assets.columns]
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.ASSET").collect()
    load_df(session, df_assets, "CORE.ASSET", mode="overwrite")

    # ── 2. Shift calendar ──
    print("\n[2/8] Loading CORE.SHIFT_CALENDAR...")
    df_cal = generate_shift_calendar(start_date, args.days)
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.SHIFT_CALENDAR").collect()
    load_df(session, df_cal, "CORE.SHIFT_CALENDAR", mode="overwrite")

    # ── 3. Ground truth failures ──
    print("\n[3/8] Loading TEST.GROUND_TRUTH_FAILURES...")
    start_dt = datetime(start_date.year, start_date.month, start_date.day, 0, 0, tzinfo=IST)
    gt_rows = []
    for ep in FAILURE_EPISODES:
        gt_rows.append({
            "FAILURE_ID": ep["failure_id"],
            "ASSET_ID": ep["asset_id"],
            "FAILURE_MODE": ep["failure_mode"],
            "DEGRADATION_START_TS": start_dt + timedelta(days=ep["degrad_day"]),
            "FAILURE_TS": start_dt + timedelta(days=ep["fail_day"]),
            "SEVERITY": ep["severity"],
        })
    df_gt = pd.DataFrame(gt_rows)
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.TEST.GROUND_TRUTH_FAILURES").collect()
    load_df(session, df_gt, "TEST.GROUND_TRUTH_FAILURES", mode="overwrite")

    # ── 4. Production orders ──
    print("\n[4/8] Loading CORE.PRODUCTION_ORDER...")
    orders = generate_production_orders(rng, start_date, args.days, ["LINE_1", "LINE_2"])
    df_orders = pd.DataFrame(orders)
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.PRODUCTION_ORDER").collect()
    load_df(session, df_orders, "CORE.PRODUCTION_ORDER", mode="overwrite")

    # ── 5. Generate telemetry + correlated events ──
    print("\n[5/8] Generating telemetry (this takes a while)...")
    telemetry, downtime, maintenance, prod_events = generate_telemetry(
        rng, start_date, args.days, ASSETS, FAILURE_EPISODES, HARD_NEGATIVES
    )

    # ── 6. Load telemetry in batches ──
    print(f"\n[6/8] Loading RAW.SENSOR_TELEMETRY ({len(telemetry):,} rows)...")
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.RAW.SENSOR_TELEMETRY").collect()
    df_telem = pd.DataFrame(telemetry)
    for i in range(0, len(df_telem), BATCH_SIZE):
        batch = df_telem.iloc[i:i+BATCH_SIZE]
        load_df(session, batch, "RAW.SENSOR_TELEMETRY")

    # ── 7. Load downtime, maintenance, production events ──
    print(f"\n[7/8] Loading correlated tables...")
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.DOWNTIME_EVENT").collect()
    if downtime:
        load_df(session, pd.DataFrame(downtime), "CORE.DOWNTIME_EVENT", mode="overwrite")

    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.MAINTENANCE_HISTORY").collect()
    if maintenance:
        load_df(session, pd.DataFrame(maintenance), "CORE.MAINTENANCE_HISTORY", mode="overwrite")

    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.RAW.PRODUCTION_EVENT").collect()
    if prod_events:
        load_df(session, pd.DataFrame(prod_events), "RAW.PRODUCTION_EVENT", mode="overwrite")

    # ── 8. MRO parts data ──
    print(f"\n[8/8] Loading MRO parts data...")
    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.PARTS_INVENTORY").collect()
    df_parts = pd.DataFrame(PARTS)
    df_parts.columns = [c.upper() for c in df_parts.columns]
    load_df(session, df_parts, "CORE.PARTS_INVENTORY", mode="overwrite")

    session.sql("TRUNCATE TABLE IF EXISTS AEGIS_OEE.CORE.FAILURE_MODE_PARTS").collect()
    df_fmp = pd.DataFrame(FAILURE_MODE_PARTS_MAP)
    df_fmp.columns = [c.upper() for c in df_fmp.columns]
    load_df(session, df_fmp, "CORE.FAILURE_MODE_PARTS", mode="overwrite")

    elapsed = time.time() - t_start
    print(f"\n=== Backfill complete in {elapsed:.0f}s ===")
    print(f"  Telemetry rows:     {len(telemetry):,}")
    print(f"  Downtime events:    {len(downtime)}")
    print(f"  Maintenance records:{len(maintenance)}")
    print(f"  Production events:  {len(prod_events):,}")
    print(f"  Production orders:  {len(orders)}")
    print(f"  Ground truth:       {len(gt_rows)}")
    print(f"  Parts inventory:    {len(PARTS)}")
    print(f"  Failure-mode parts: {len(FAILURE_MODE_PARTS_MAP)}")

    session.close()


if __name__ == "__main__":
    main()
