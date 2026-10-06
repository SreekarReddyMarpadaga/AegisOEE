-- =============================================================================
-- github_slack_eai.sql — Optional External Access Integration for outbox dispatch
--
-- Requires ACCOUNTADMIN role and External Access Integrations enabled.
-- This replaces the local scripts/outbox_dispatcher.py for accounts that support EAI.
--
-- Before running:
--   1. Create secrets for GITHUB_PAT and SLACK_WEBHOOK_URL:
--        CREATE OR REPLACE SECRET AEGIS_OEE.ACTION.GITHUB_PAT_SECRET
--          TYPE = GENERIC_STRING SECRET_STRING = '<your-github-pat>';
--        CREATE OR REPLACE SECRET AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET
--          TYPE = GENERIC_STRING SECRET_STRING = '<your-slack-webhook-url>';
--   2. Run this file as ACCOUNTADMIN.
-- =============================================================================

/*
-- UNCOMMENT the entire block below after creating the secrets above.

USE ROLE ACCOUNTADMIN;
USE DATABASE AEGIS_OEE;

-- ── Network rules ──

CREATE OR REPLACE NETWORK RULE AEGIS_OEE.ACTION.GITHUB_API_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.github.com:443');

CREATE OR REPLACE NETWORK RULE AEGIS_OEE.ACTION.SLACK_WEBHOOK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hooks.slack.com:443');

-- ── External Access Integrations ──

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION AEGIS_GITHUB_EAI
  ALLOWED_NETWORK_RULES = (AEGIS_OEE.ACTION.GITHUB_API_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (AEGIS_OEE.ACTION.GITHUB_PAT_SECRET)
  ENABLED = TRUE
  COMMENT = 'AegisOEE GitHub Issues integration';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION AEGIS_SLACK_EAI
  ALLOWED_NETWORK_RULES = (AEGIS_OEE.ACTION.SLACK_WEBHOOK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET)
  ENABLED = TRUE
  COMMENT = 'AegisOEE Slack notifications integration';

-- ── Grant to ACCOUNTADMIN (if using a different role for procedures) ──

-- GRANT USAGE ON INTEGRATION AEGIS_GITHUB_EAI TO ROLE ACCOUNTADMIN;
-- GRANT USAGE ON INTEGRATION AEGIS_SLACK_EAI TO ROLE ACCOUNTADMIN;

-- ── Native GitHub dispatch procedure (replaces outbox_dispatcher.py for GitHub) ──
-- See sql/11_integrations.sql in the main repo for the full procedure implementations.
-- Those procedures use EXTERNAL_ACCESS_INTEGRATIONS to call the GitHub and Slack APIs
-- directly from Snowflake stored procedures, eliminating the need for the local dispatcher.

-- Usage after setup:
--   ALTER TASK AEGIS_OEE.ACTION.TASK_OUTBOX_RETRY RESUME;
-- The task will call RETRY_OUTBOX() every 10 minutes, which processes pending outbox items.
-- With EAI procedures, RETRY_OUTBOX can dispatch directly instead of requiring the local script.

*/
