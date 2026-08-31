-- =============================================================
-- Mission 01 — Reference & ERP DDL
-- Idempotent: safe to re-run at any time.
-- =============================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- -------------------------------------------------------
-- CORE.ASSET
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.ASSET (
  asset_id        STRING    NOT NULL,
  line_id         STRING    NOT NULL,
  site_id         STRING    NOT NULL,
  asset_type      STRING    NOT NULL,
  manufacturer    STRING,
  install_date    DATE,
  criticality     NUMBER(1) NOT NULL,
  ideal_rpm       NUMBER(10,2),
  ideal_cycle_s   NUMBER(10,2),
  temp_limit_c    NUMBER(10,2),
  vib_alert_mm_s  NUMBER(10,4),
  vib_danger_mm_s NUMBER(10,4),
  CONSTRAINT pk_asset PRIMARY KEY (asset_id)
);

-- -------------------------------------------------------
-- RAW.SENSOR_TELEMETRY
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.SENSOR_TELEMETRY (
  asset_id           STRING        NOT NULL,
  ts                 TIMESTAMP_TZ  NOT NULL,
  vibration_rms      FLOAT,
  vibration_kurtosis FLOAT,
  temp_c             FLOAT,
  rpm                FLOAT,
  load_pct           FLOAT,
  quality_flag       STRING        DEFAULT 'OK',
  ingest_ts          TIMESTAMP_TZ  DEFAULT CURRENT_TIMESTAMP()
);

-- -------------------------------------------------------
-- CORE.PRODUCTION_ORDER
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.PRODUCTION_ORDER (
  order_id        STRING       NOT NULL,
  line_id         STRING       NOT NULL,
  product_code    STRING       NOT NULL,
  planned_qty     NUMBER(10)   NOT NULL,
  ideal_cycle_s   NUMBER(10,2) NOT NULL,
  planned_start_ts TIMESTAMP_TZ NOT NULL,
  planned_end_ts  TIMESTAMP_TZ NOT NULL,
  CONSTRAINT pk_production_order PRIMARY KEY (order_id)
);

-- -------------------------------------------------------
-- RAW.PRODUCTION_EVENT
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS RAW.PRODUCTION_EVENT (
  asset_id       STRING       NOT NULL,
  ts             TIMESTAMP_TZ NOT NULL,
  order_id       STRING,
  state          STRING       NOT NULL,
  produced_count NUMBER(10)   DEFAULT 0,
  good_count     NUMBER(10)   DEFAULT 0,
  reject_count   NUMBER(10)   DEFAULT 0,
  cycle_time_s   FLOAT
);

-- -------------------------------------------------------
-- CORE.DOWNTIME_EVENT
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.DOWNTIME_EVENT (
  event_id     STRING       NOT NULL,
  asset_id     STRING       NOT NULL,
  start_ts     TIMESTAMP_TZ NOT NULL,
  end_ts       TIMESTAMP_TZ NOT NULL,
  is_planned   BOOLEAN      NOT NULL,
  reason_code  STRING,
  failure_mode STRING,
  minutes      FLOAT        NOT NULL,
  CONSTRAINT pk_downtime_event PRIMARY KEY (event_id)
);

-- -------------------------------------------------------
-- CORE.MAINTENANCE_HISTORY
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.MAINTENANCE_HISTORY (
  wo_hist_id      STRING       NOT NULL,
  asset_id        STRING       NOT NULL,
  completed_ts    TIMESTAMP_TZ NOT NULL,
  failure_code    STRING,
  finding         STRING,
  action_taken    STRING,
  parts_used      STRING,
  labor_hours     FLOAT,
  technician_note STRING,
  CONSTRAINT pk_maintenance_history PRIMARY KEY (wo_hist_id)
);

-- -------------------------------------------------------
-- CORE.SHIFT_CALENDAR
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.SHIFT_CALENDAR (
  shift_date              DATE         NOT NULL,
  shift_code              STRING       NOT NULL,
  start_ts                TIMESTAMP_TZ NOT NULL,
  end_ts                  TIMESTAMP_TZ NOT NULL,
  planned_minutes         NUMBER(10)   NOT NULL DEFAULT 480,
  planned_downtime_minutes NUMBER(10)  NOT NULL DEFAULT 0,
  CONSTRAINT pk_shift_calendar PRIMARY KEY (shift_date, shift_code)
);

-- -------------------------------------------------------
-- CORE.PARTS_INVENTORY
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.PARTS_INVENTORY (
  part_id         STRING    NOT NULL,
  part_name       STRING    NOT NULL,
  category        STRING,
  on_hand_qty     NUMBER(10) NOT NULL DEFAULT 0,
  reserved_qty    NUMBER(10) NOT NULL DEFAULT 0,
  reorder_point   NUMBER(10) NOT NULL DEFAULT 0,
  unit_cost       FLOAT     NOT NULL,
  supplier_name   STRING,
  lead_time_days  NUMBER(5)  NOT NULL DEFAULT 7,
  bin_location    STRING,
  CONSTRAINT pk_parts_inventory PRIMARY KEY (part_id)
);

-- -------------------------------------------------------
-- CORE.FAILURE_MODE_PARTS
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.FAILURE_MODE_PARTS (
  failure_mode  STRING NOT NULL,
  asset_type    STRING NOT NULL,
  part_id       STRING NOT NULL,
  qty_required  NUMBER(10) NOT NULL DEFAULT 1
);

-- -------------------------------------------------------
-- TEST.GROUND_TRUTH_FAILURES
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS TEST.GROUND_TRUTH_FAILURES (
  failure_id          STRING       NOT NULL,
  asset_id            STRING       NOT NULL,
  failure_mode        STRING       NOT NULL,
  degradation_start_ts TIMESTAMP_TZ NOT NULL,
  failure_ts          TIMESTAMP_TZ NOT NULL,
  severity            STRING,
  CONSTRAINT pk_ground_truth_failures PRIMARY KEY (failure_id)
);

-- -------------------------------------------------------
-- TEST.VALIDATION_RESULTS
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS TEST.VALIDATION_RESULTS (
  check_name  STRING    NOT NULL,
  status      STRING    NOT NULL,
  detail      STRING,
  checked_at  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- -------------------------------------------------------
-- ACTION.ALERT
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACTION.ALERT (
  alert_id            STRING       NOT NULL,
  asset_id            STRING       NOT NULL,
  onset_ts            TIMESTAMP_TZ NOT NULL,
  severity            STRING       NOT NULL,
  confidence          FLOAT,
  failure_probability FLOAT,
  predicted_mode      STRING,
  oee_impact_est      FLOAT,
  status              STRING       NOT NULL DEFAULT 'NEW',
  evidence            VARIANT,
  CONSTRAINT pk_alert PRIMARY KEY (alert_id)
);

-- -------------------------------------------------------
-- ACTION.WORK_ORDER
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACTION.WORK_ORDER (
  wo_id            STRING       NOT NULL,
  alert_id         STRING,
  asset_id         STRING       NOT NULL,
  priority         STRING,
  state            STRING       NOT NULL DEFAULT 'DRAFT',
  title            STRING,
  description      STRING,
  evidence         VARIANT,
  github_issue_url STRING,
  approved_by      STRING,
  approved_ts      TIMESTAMP_TZ,
  close_reason     STRING,
  closed_at        TIMESTAMP_TZ,
  CONSTRAINT pk_work_order PRIMARY KEY (wo_id)
);

-- -------------------------------------------------------
-- ACTION.WORK_ORDER_OUTBOX
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACTION.WORK_ORDER_OUTBOX (
  outbox_id  STRING       NOT NULL,
  wo_id      STRING       NOT NULL,
  target     STRING       NOT NULL,
  payload    VARIANT,
  attempts   NUMBER(5)    DEFAULT 0,
  last_error STRING,
  status     STRING       NOT NULL DEFAULT 'PENDING'
);

-- -------------------------------------------------------
-- ACTION.ACTION_AUDIT
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACTION.ACTION_AUDIT (
  audit_id   STRING       NOT NULL,
  ts         TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  actor      STRING       NOT NULL,
  action     STRING       NOT NULL,
  object_ref STRING,
  detail     VARIANT
);

-- -------------------------------------------------------
-- ACTION.PURCHASE_REQUISITION
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACTION.PURCHASE_REQUISITION (
  req_id          STRING       NOT NULL,
  wo_id           STRING,
  part_id         STRING       NOT NULL,
  qty             NUMBER(10)   NOT NULL,
  est_unit_cost   FLOAT,
  est_total       FLOAT,
  supplier_name   STRING,
  lead_time_days  NUMBER(5),
  rfq_text        STRING,
  status          STRING       NOT NULL DEFAULT 'PENDING_QUOTE',
  created_ts      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_purchase_requisition PRIMARY KEY (req_id)
);

-- -------------------------------------------------------
-- ML.ANOMALY_EVENTS
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS ML.ANOMALY_EVENTS (
  asset_id   STRING       NOT NULL,
  ts         TIMESTAMP_TZ NOT NULL,
  series_name STRING      NOT NULL,
  is_anomaly BOOLEAN,
  distance   FLOAT,
  percentile FLOAT,
  forecast   FLOAT,
  lower      FLOAT,
  upper      FLOAT
);
