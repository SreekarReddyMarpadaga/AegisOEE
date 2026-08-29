-- =============================================================================
-- 08_search_service.sql — Cortex Search Service for Maintenance Docs
-- Mission 04, Deliverable 2
-- Creates SEMANTIC.MAINTENANCE_SEARCH over DOC_STAGE files + technician notes
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE SCHEMA SEMANTIC;
USE WAREHOUSE AEGIS_WH;

-- Step 1: Create a table to hold parsed documents and chunked technician notes
CREATE OR REPLACE TABLE AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS (
    DOC_ID       VARCHAR NOT NULL,
    ASSET_ID     VARCHAR,
    DOC_TYPE     VARCHAR,       -- 'manual' or 'tech_note' or 'maintenance_history'
    TITLE        VARCHAR,
    CONTENT      VARCHAR(16777216),
    SOURCE       VARCHAR,
    CREATED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Step 2: Ensure directory metadata is registered
ALTER STAGE AEGIS_OEE.RAW.DOC_STAGE REFRESH;

-- Step 3: Create file format for raw text ingestion
CREATE OR REPLACE FILE FORMAT AEGIS_OEE.RAW.FF_RAW_TEXT
  TYPE = CSV
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE;

-- Step 4: Load manuals and tech notes from DOC_STAGE as raw text
INSERT INTO AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS (DOC_ID, ASSET_ID, DOC_TYPE, TITLE, CONTENT, SOURCE)
SELECT
    'DOC_' || ROW_NUMBER() OVER (ORDER BY METADATA$FILENAME) AS DOC_ID,
    NULL AS ASSET_ID,
    CASE WHEN METADATA$FILENAME ILIKE '%manual%' THEN 'manual' ELSE 'tech_note' END AS DOC_TYPE,
    REPLACE(REPLACE(SPLIT_PART(METADATA$FILENAME, '/', -1), '.md', ''), '_', ' ') AS TITLE,
    $1 AS CONTENT,
    METADATA$FILENAME AS SOURCE
FROM @AEGIS_OEE.RAW.DOC_STAGE (FILE_FORMAT => 'AEGIS_OEE.RAW.FF_RAW_TEXT', PATTERN => '.*\\.md');

-- Step 5: Extract asset_id from doc content where identifiable
UPDATE AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS
SET ASSET_ID = 
    CASE
        WHEN CONTENT ILIKE '%CNC_01_SPINDLE%' THEN 'CNC_01_SPINDLE'
        WHEN CONTENT ILIKE '%CNC_02_SPINDLE%' THEN 'CNC_02_SPINDLE'
        WHEN CONTENT ILIKE '%CNC_03_SPINDLE%' THEN 'CNC_03_SPINDLE'
        WHEN CONTENT ILIKE '%CNC_04_SPINDLE%' THEN 'CNC_04_SPINDLE'
        WHEN CONTENT ILIKE '%COOLANT_PUMP_01%' THEN 'COOLANT_PUMP_01'
        WHEN CONTENT ILIKE '%COOLANT_PUMP_02%' THEN 'COOLANT_PUMP_02'
        WHEN CONTENT ILIKE '%SERVO_MOTOR_01%' THEN 'SERVO_MOTOR_01'
        WHEN CONTENT ILIKE '%CONVEYOR_GBX_01%' THEN 'CONVEYOR_GBX_01'
        WHEN CONTENT ILIKE '%CONVEYOR_GBX_02%' THEN 'CONVEYOR_GBX_02'
        WHEN CONTENT ILIKE '%AIR_COMP_01%' THEN 'AIR_COMP_01'
    END
WHERE ASSET_ID IS NULL;

-- Step 6: Load chunked technician notes from MAINTENANCE_HISTORY
INSERT INTO AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS (DOC_ID, ASSET_ID, DOC_TYPE, TITLE, CONTENT, SOURCE)
SELECT
    'MH_' || WO_HIST_ID AS DOC_ID,
    ASSET_ID,
    'maintenance_history' AS DOC_TYPE,
    'Maintenance: ' || ASSET_ID || ' - ' || FAILURE_CODE || ' (' || TO_VARCHAR(COMPLETED_TS, 'YYYY-MM-DD') || ')' AS TITLE,
    'Asset: ' || ASSET_ID || CHR(10) ||
    'Failure Code: ' || FAILURE_CODE || CHR(10) ||
    'Finding: ' || COALESCE(FINDING, 'N/A') || CHR(10) ||
    'Action Taken: ' || COALESCE(ACTION_TAKEN, 'N/A') || CHR(10) ||
    'Parts Used: ' || COALESCE(PARTS_USED, 'N/A') || CHR(10) ||
    'Labor Hours: ' || TO_VARCHAR(LABOR_HOURS) || CHR(10) ||
    'Technician Note: ' || COALESCE(TECHNICIAN_NOTE, 'N/A') || CHR(10) ||
    'Completed: ' || TO_VARCHAR(COMPLETED_TS) AS CONTENT,
    'CORE.MAINTENANCE_HISTORY.' || WO_HIST_ID AS SOURCE
FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY;

-- Step 7: Create Cortex Search Service
CREATE OR REPLACE CORTEX SEARCH SERVICE AEGIS_OEE.SEMANTIC.MAINTENANCE_SEARCH
    ON CONTENT
    ATTRIBUTES ASSET_ID, DOC_TYPE
    WAREHOUSE = AEGIS_WH
    TARGET_LAG = '1 hour'
    AS (
        SELECT
            DOC_ID,
            ASSET_ID,
            DOC_TYPE,
            TITLE,
            CONTENT,
            SOURCE
        FROM AEGIS_OEE.SEMANTIC.MAINTENANCE_DOCS
    );
