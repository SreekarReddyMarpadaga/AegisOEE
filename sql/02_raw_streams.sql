-- =============================================================
-- Mission 02 — Raw Streams
-- Idempotent: safe to re-run at any time.
-- =============================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

CREATE OR REPLACE STREAM RAW.STR_SENSOR_TELEMETRY
  ON TABLE RAW.SENSOR_TELEMETRY
  APPEND_ONLY = TRUE;

CREATE OR REPLACE STREAM RAW.STR_PRODUCTION_EVENT
  ON TABLE RAW.PRODUCTION_EVENT
  APPEND_ONLY = TRUE;
