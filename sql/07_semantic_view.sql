-- =============================================================================
-- 07_semantic_view.sql — Semantic View for Cortex Analyst
-- Mission 04, Deliverable 1
-- Creates SEMANTIC.MANUFACTURING_OPERATIONS from the YAML in semantic/
-- =============================================================================

USE DATABASE AEGIS_OEE;
USE WAREHOUSE AEGIS_WH;

-- Deploy semantic view from YAML.
-- Primary method: cortex agent-studio sv-deploy
-- Fallback: CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(...)
--
-- To deploy:
--   cd <repo_root>
--   cortex agent-studio sv-write --yaml-content "$(cat semantic/manufacturing_operations.yaml)" --source-object AEGIS_OEE.SEMANTIC.MANUFACTURING_OPERATIONS
--   cortex agent-studio sv-deploy --file-path MANUFACTURING_OPERATIONS.sv.yaml --fqn AEGIS_OEE.SEMANTIC.MANUFACTURING_OPERATIONS
--
-- The semantic view MANUFACTURING_OPERATIONS includes:
--   - 8 logical tables: DT_SHIFT_OEE, ASSET, DOWNTIME_EVENT, PRODUCTION_ORDER, ALERT, WORK_ORDER, DT_ASSET_HEALTH, V_MTBF_MTTR
--   - 7 relationships (asset-centric star schema)
--   - 10+ metrics: OEE, Availability, Performance, Quality, MTBF, MTTR, alert count, etc.
--   - 15 verified queries covering all demo question types
--   - Custom instructions for OEE math and plant context

-- Create MCP server for agent tool procedures (stored procedures as tools)
CREATE OR REPLACE MCP SERVER AEGIS_OEE.ACTION.AEGIS_TOOLS_MCP
  FROM SPECIFICATION $$
    tools:
      - title: "Get Asset Evidence"
        identifier: "AEGIS_OEE.ACTION.GET_ASSET_EVIDENCE"
        name: "get_asset_evidence"
        type: "GENERIC"
        description: "Retrieve the full evidence bundle for a specific asset including health score, sensor signals, anomaly detections, maintenance history, downtime events, OEE trend, and open alerts."
        config:
          type: "procedure"
          warehouse: "AEGIS_APP_WH"
          input_schema:
            type: "object"
            properties:
              P_ASSET_ID:
                description: "The asset identifier, e.g. CNC_01_SPINDLE"
                type: "string"
      - title: "Propose Work Order"
        identifier: "AEGIS_OEE.ACTION.PROPOSE_WORK_ORDER"
        name: "propose_work_order"
        type: "GENERIC"
        description: "Generate a draft work order for an alert ID. Returns draft JSON with recommended action, parts kit, and safety statement. Does NOT create or approve the work order."
        config:
          type: "procedure"
          warehouse: "AEGIS_APP_WH"
          input_schema:
            type: "object"
            properties:
              P_ALERT_ID:
                description: "The alert identifier to propose a work order for"
                type: "string"
  $$;
