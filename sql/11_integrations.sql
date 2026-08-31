/*  ================================================================
    AegisOEE — External Integrations (GitHub Issues + Slack Webhook)
    File : sql/11_integrations.sql
    Idempotent — safe to re-run.
    ================================================================

    NOTE: This account is a Snowflake trial which does NOT support
    EXTERNAL ACCESS INTEGRATIONS.  The procedures below use the
    outbox pattern: queue payloads to WORK_ORDER_OUTBOX, then a CLI
    script (scripts/retry_outbox.py) drains them via HTTP.

    When upgrading to a non-trial account, uncomment the EAI block
    below and replace the SQL procedures with the Python EAI versions
    in the "EAI-READY" section at the bottom of this file.
    ================================================================ */

USE DATABASE AEGIS_OEE;
USE SCHEMA ACTION;
USE WAREHOUSE AEGIS_WH;

-- ----------------------------------------------------------------
-- 1. Snowflake Secrets (work on all editions)
-- ----------------------------------------------------------------
-- Secrets store credentials referenced by EAI procedures.
-- On trial accounts they serve as documentation; the CLI script
-- reads credentials from cortex secrets instead.
CREATE OR REPLACE SECRET AEGIS_OEE.ACTION.GITHUB_PAT_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<GITHUB_PAT>';  -- inject via: cortex secret get github_pat

CREATE OR REPLACE SECRET AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<SLACK_WEBHOOK_URL>';  -- inject via: cortex secret get slack_webhook_url

-- ----------------------------------------------------------------
-- 2. Network Rule + External Access Integration
--    (BLOCKED on trial accounts — uncomment on Enterprise+)
-- ----------------------------------------------------------------
/*
CREATE OR REPLACE NETWORK RULE AEGIS_OEE.ACTION.AEGIS_EGRESS_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.github.com', 'hooks.slack.com');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION AEGIS_EGRESS_EAI
  ALLOWED_NETWORK_RULES   = (AEGIS_OEE.ACTION.AEGIS_EGRESS_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (AEGIS_OEE.ACTION.GITHUB_PAT_SECRET,
                                     AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET)
  ENABLED = TRUE;
*/

-- ----------------------------------------------------------------
-- 3. QUEUE_GITHUB_SYNC — queues GitHub issue payload to outbox
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.QUEUE_GITHUB_SYNC(P_WO_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
'
DECLARE
  v_wo VARIANT;
  v_alert VARIANT;
  v_parts VARIANT;
  v_reqs VARIANT;
  v_asset_type VARCHAR;
  v_predicted_mode VARCHAR;
  v_existing_outbox VARCHAR;
BEGIN
  SELECT OBJECT_CONSTRUCT(
    ''wo_id'', wo.WO_ID, ''alert_id'', wo.ALERT_ID, ''asset_id'', wo.ASSET_ID,
    ''priority'', wo.PRIORITY, ''state'', wo.STATE, ''title'', wo.TITLE,
    ''description'', wo.DESCRIPTION, ''approved_by'', wo.APPROVED_BY,
    ''approved_ts'', wo.APPROVED_TS::STRING
  ) INTO :v_wo
  FROM AEGIS_OEE.ACTION.WORK_ORDER wo WHERE wo.WO_ID = :P_WO_ID;

  IF (:v_wo IS NULL) THEN
    RETURN ''WO not found: '' || :P_WO_ID;
  END IF;

  SELECT OBJECT_CONSTRUCT(
    ''alert_id'', al.ALERT_ID, ''severity'', al.SEVERITY, ''predicted_mode'', al.PREDICTED_MODE,
    ''confidence'', al.CONFIDENCE, ''failure_probability'', al.FAILURE_PROBABILITY,
    ''oee_impact_est'', al.OEE_IMPACT_EST, ''onset_ts'', al.ONSET_TS::STRING
  ) INTO :v_alert
  FROM AEGIS_OEE.ACTION.ALERT al WHERE al.ALERT_ID = :v_wo:alert_id::STRING;

  v_predicted_mode := :v_alert:predicted_mode::STRING;

  SELECT ASSET_TYPE INTO :v_asset_type
  FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = :v_wo:asset_id::STRING;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    ''part_id'', fmp.PART_ID, ''part_name'', pi.PART_NAME,
    ''qty_required'', fmp.QTY_REQUIRED,
    ''available'', pi.ON_HAND_QTY - pi.RESERVED_QTY,
    ''shortage'', GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)),
    ''unit_cost'', pi.UNIT_COST, ''lead_time_days'', pi.LEAD_TIME_DAYS
  )) INTO :v_parts
  FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
  JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
  WHERE fmp.FAILURE_MODE = :v_predicted_mode AND fmp.ASSET_TYPE = :v_asset_type;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
    ''req_id'', pr.REQ_ID, ''part_id'', pr.PART_ID, ''qty'', pr.QTY,
    ''est_total'', pr.EST_TOTAL, ''supplier'', pr.SUPPLIER_NAME,
    ''lead_time_days'', pr.LEAD_TIME_DAYS, ''status'', pr.STATUS
  )) INTO :v_reqs
  FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION pr WHERE pr.WO_ID = :P_WO_ID;

  -- Upsert outbox entry
  SELECT OUTBOX_ID INTO :v_existing_outbox
  FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  WHERE WO_ID = :P_WO_ID AND TARGET = ''GITHUB'' LIMIT 1;

  IF (:v_existing_outbox IS NOT NULL) THEN
    UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
    SET PAYLOAD = OBJECT_CONSTRUCT(
           ''title'', :v_wo:title::STRING,
           ''labels'', ARRAY_CONSTRUCT(:v_alert:severity::STRING, :v_predicted_mode, ''maintenance''),
           ''body_data'', OBJECT_CONSTRUCT(
             ''work_order'', :v_wo, ''alert'', :v_alert,
             ''parts_availability'', :v_parts, ''purchase_requisitions'', :v_reqs,
             ''safety_statement'', ''This work order requires on-site human verification before execution.'',
             ''generated_by'', ''AegisOEE Governed Action Loop''
           )
         ),
        STATUS = ''PENDING'', ATTEMPTS = 0, LAST_ERROR = NULL
    WHERE WO_ID = :P_WO_ID AND TARGET = ''GITHUB'';
  ELSE
    INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, ATTEMPTS, STATUS)
    SELECT ''OB_GH_'' || TO_VARCHAR(CURRENT_TIMESTAMP(), ''YYYYMMDD_HH24MISSFF3''),
           :P_WO_ID, ''GITHUB'',
           OBJECT_CONSTRUCT(
             ''title'', :v_wo:title::STRING,
             ''labels'', ARRAY_CONSTRUCT(:v_alert:severity::STRING, :v_predicted_mode, ''maintenance''),
             ''body_data'', OBJECT_CONSTRUCT(
               ''work_order'', :v_wo, ''alert'', :v_alert,
               ''parts_availability'', :v_parts, ''purchase_requisitions'', :v_reqs,
               ''safety_statement'', ''This work order requires on-site human verification before execution.'',
               ''generated_by'', ''AegisOEE Governed Action Loop''
             )
           ), 0, ''PENDING'';
  END IF;

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT ''AUD_GH_'' || TO_VARCHAR(CURRENT_TIMESTAMP(), ''YYYYMMDD_HH24MISSFF3''),
         CURRENT_TIMESTAMP(), ''SYSTEM'', ''GITHUB_QUEUED'', :P_WO_ID,
         OBJECT_CONSTRUCT(''outbox_target'', ''GITHUB'');

  RETURN ''GitHub sync queued for WO: '' || :P_WO_ID;
END;
';

-- ----------------------------------------------------------------
-- 4. NOTIFY_SLACK — queues Slack payload to outbox
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.NOTIFY_SLACK(P_PAYLOAD VARIANT)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
'
DECLARE
  v_wo_id VARCHAR;
  v_existing_outbox VARCHAR;
BEGIN
  v_wo_id := COALESCE(:P_PAYLOAD:wo_id::STRING, ''UNKNOWN'');

  SELECT OUTBOX_ID INTO :v_existing_outbox
  FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  WHERE WO_ID = :v_wo_id AND TARGET = ''SLACK'' LIMIT 1;

  IF (:v_existing_outbox IS NOT NULL) THEN
    UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
    SET PAYLOAD = :P_PAYLOAD, STATUS = ''PENDING'', ATTEMPTS = 0, LAST_ERROR = NULL
    WHERE WO_ID = :v_wo_id AND TARGET = ''SLACK'';
  ELSE
    INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, ATTEMPTS, STATUS)
    SELECT ''OB_SLACK_'' || TO_VARCHAR(CURRENT_TIMESTAMP(), ''YYYYMMDD_HH24MISSFF3''),
           :v_wo_id, ''SLACK'', :P_PAYLOAD, 0, ''PENDING'';
  END IF;

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT ''AUD_SLACK_'' || TO_VARCHAR(CURRENT_TIMESTAMP(), ''YYYYMMDD_HH24MISSFF3''),
         CURRENT_TIMESTAMP(), ''SYSTEM'', ''SLACK_QUEUED'', :v_wo_id, :P_PAYLOAD;

  RETURN ''Slack notification queued for WO: '' || :v_wo_id;
END;
';

-- ----------------------------------------------------------------
-- 5. RETRY_OUTBOX — reports pending items for CLI dispatch
-- ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.RETRY_OUTBOX()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
'
DECLARE
  v_pending_gh INTEGER;
  v_pending_sl INTEGER;
  v_dead INTEGER;
BEGIN
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  SET STATUS = ''DEAD'', LAST_ERROR = ''Max attempts (10) reached''
  WHERE STATUS = ''PENDING'' AND ATTEMPTS >= 10;

  SELECT COUNT(*) INTO :v_pending_gh
  FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET = ''GITHUB'' AND STATUS IN (''PENDING'', ''DEAD'');
  SELECT COUNT(*) INTO :v_pending_sl
  FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET = ''SLACK'' AND STATUS IN (''PENDING'', ''DEAD'');
  SELECT COUNT(*) INTO :v_dead
  FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE STATUS = ''DEAD'';

  INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
  SELECT ''AUD_RETRY_'' || TO_VARCHAR(CURRENT_TIMESTAMP(), ''YYYYMMDD_HH24MISSFF3''),
         CURRENT_TIMESTAMP(), ''SYSTEM'', ''OUTBOX_RETRY_CHECK'', ''OUTBOX'',
         OBJECT_CONSTRUCT(
           ''pending_github'', :v_pending_gh, ''pending_slack'', :v_pending_sl,
           ''dead'', :v_dead,
           ''note'', ''Use CLI retry script for HTTP dispatch on trial accounts''
         );

  RETURN ''Outbox: '' || :v_pending_gh || '' GitHub, '' || :v_pending_sl || '' Slack pending, '' || :v_dead || '' dead.'';
END;
';

-- ================================================================
-- EAI-READY VERSIONS (for non-trial accounts)
-- Uncomment the EAI block above (lines 39-50), then uncomment
-- these Python procedures to replace the SQL outbox-only versions.
-- Features: real HTTP calls, rich Slack Block Kit messages,
-- parts table in GitHub issues, GitHub issue closing on WO
-- close/reject.
-- ================================================================

/*
-- 3-EAI. QUEUE_GITHUB_SYNC — creates real GitHub issues
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.QUEUE_GITHUB_SYNC(P_WO_ID VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (AEGIS_EGRESS_EAI)
SECRETS = ('github_pat' = AEGIS_OEE.ACTION.GITHUB_PAT_SECRET)
EXECUTE AS CALLER
AS
$$
import _snowflake
import requests
import json

REPO = "SreekarReddyMarpadaga/AegisOEE"
API_URL = f"https://api.github.com/repos/{REPO}/issues"

def run(session, p_wo_id: str) -> str:
    pat = _snowflake.get_generic_secret_string('github_pat')
    headers = {"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}

    wo = session.sql(f"SELECT * FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '{p_wo_id}'").collect()
    if not wo:
        return f"WO not found: {p_wo_id}"
    wo = wo[0].as_dict()

    alert = {}
    if wo.get("ALERT_ID"):
        ar = session.sql(f"SELECT * FROM AEGIS_OEE.ACTION.ALERT WHERE ALERT_ID = '{wo['ALERT_ID']}'").collect()
        if ar:
            alert = ar[0].as_dict()

    mode = alert.get("PREDICTED_MODE", "UNKNOWN")
    asset_type_r = session.sql(f"SELECT ASSET_TYPE FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = '{wo['ASSET_ID']}'").collect()
    asset_type = asset_type_r[0]["ASSET_TYPE"] if asset_type_r else "UNKNOWN"

    parts = session.sql(f"""
        SELECT fmp.PART_ID, pi.PART_NAME, fmp.QTY_REQUIRED,
               pi.ON_HAND_QTY - pi.RESERVED_QTY AS AVAILABLE,
               GREATEST(0, fmp.QTY_REQUIRED - (pi.ON_HAND_QTY - pi.RESERVED_QTY)) AS SHORTAGE,
               pi.UNIT_COST, pi.LEAD_TIME_DAYS
        FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS fmp
        JOIN AEGIS_OEE.CORE.PARTS_INVENTORY pi ON fmp.PART_ID = pi.PART_ID
        WHERE fmp.FAILURE_MODE = '{mode}' AND fmp.ASSET_TYPE = '{asset_type}'
    """).collect()

    reqs = session.sql(f"""
        SELECT REQ_ID, PART_ID, QTY, EST_TOTAL, SUPPLIER_NAME, LEAD_TIME_DAYS, STATUS
        FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE WO_ID = '{p_wo_id}'
    """).collect()

    parts_table = "| Part | Name | Req | Avail | Short | Cost | Lead |\\n|---|---|---|---|---|---|---|\\n"
    for p in parts:
        d = p.as_dict()
        flag = " :warning:" if d.get("SHORTAGE", 0) > 0 else ""
        parts_table += f"| {d['PART_ID']} | {d['PART_NAME']} | {d['QTY_REQUIRED']} | {d['AVAILABLE']} | {d['SHORTAGE']}{flag} | ${d['UNIT_COST']} | {d['LEAD_TIME_DAYS']}d |\\n"

    reqs_section = ""
    if reqs:
        reqs_section = "\\n### Purchase Requisitions\\n\\n"
        for r in reqs:
            rd = r.as_dict()
            reqs_section += f"- **{rd['REQ_ID']}**: {rd['PART_ID']} x{rd['QTY']} — ${rd['EST_TOTAL']} — {rd['SUPPLIER_NAME']} ({rd['LEAD_TIME_DAYS']}d) — {rd['STATUS']}\\n"

    body_md = f"""## Work Order: `{wo['WO_ID']}`

**Asset:** `{wo['ASSET_ID']}` ({asset_type}) | **Priority:** {wo['PRIORITY']} | **Approved by:** {wo.get('APPROVED_BY','N/A')}

> {wo.get('DESCRIPTION','')}

---

### Alert Details

| Field | Value |
|---|---|
| Severity | **{alert.get('SEVERITY','N/A')}** |
| Predicted Mode | `{mode}` |
| Confidence | {alert.get('CONFIDENCE','N/A')} |
| Failure Prob | {alert.get('FAILURE_PROBABILITY','N/A')} |
| OEE Impact | {alert.get('OEE_IMPACT_EST','N/A')} |

---

### Parts Required

{parts_table}
{reqs_section}
---

### :rotating_light: Safety
> This work order requires on-site human verification before execution.

---
*Generated by AegisOEE Governed Action Loop*
"""
    labels = [str(alert.get("SEVERITY","P3")), mode, "maintenance"]

    # Upsert outbox entry
    existing = session.sql(f"SELECT OUTBOX_ID FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE WO_ID = '{p_wo_id}' AND TARGET = 'GITHUB' LIMIT 1").collect()

    try:
        resp = requests.post(API_URL, headers=headers, json={"title": wo["TITLE"], "body": body_md, "labels": labels}, timeout=30)
        resp.raise_for_status()
        issue_url = resp.json().get("html_url", "")
        session.sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER SET GITHUB_ISSUE_URL = '{issue_url}' WHERE WO_ID = '{p_wo_id}'").collect()
        if existing:
            session.sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='SENT', ATTEMPTS=ATTEMPTS+1, LAST_ERROR=NULL WHERE WO_ID='{p_wo_id}' AND TARGET='GITHUB'").collect()
        else:
            session.sql(f"INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX(OUTBOX_ID,WO_ID,TARGET,PAYLOAD,ATTEMPTS,STATUS) SELECT 'OB_GH_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),'{p_wo_id}','GITHUB',PARSE_JSON('{{}}'),1,'SENT'").collect()
        detail = json.dumps({"issue_url": issue_url}).replace("'","''")
        session.sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_GH_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP(),'SYSTEM','GITHUB_ISSUE_CREATED','{p_wo_id}',PARSE_JSON('{detail}')").collect()
        return f"GitHub issue created: {issue_url}"
    except Exception as e:
        err = str(e).replace("'","''")[:500]
        if existing:
            session.sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET ATTEMPTS=ATTEMPTS+1, LAST_ERROR='{err}', STATUS=CASE WHEN ATTEMPTS+1>=5 THEN 'DEAD' ELSE 'PENDING' END WHERE WO_ID='{p_wo_id}' AND TARGET='GITHUB'").collect()
        else:
            session.sql(f"INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX(OUTBOX_ID,WO_ID,TARGET,PAYLOAD,ATTEMPTS,LAST_ERROR,STATUS) SELECT 'OB_GH_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),'{p_wo_id}','GITHUB',PARSE_JSON('{{}}'),1,'{err}','PENDING'").collect()
        return f"GitHub sync failed (queued to outbox): {err}"
$$;


-- 4-EAI. NOTIFY_SLACK — sends rich Block Kit messages
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.NOTIFY_SLACK(P_PAYLOAD VARIANT)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (AEGIS_EGRESS_EAI)
SECRETS = ('slack_webhook' = AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET)
EXECUTE AS CALLER
AS
$$
import _snowflake
import requests
import json

def run(session, p_payload) -> str:
    webhook_url = _snowflake.get_generic_secret_string('slack_webhook')
    payload = json.loads(p_payload) if isinstance(p_payload, str) else p_payload
    wo_id = payload.get("wo_id", "UNKNOWN")
    asset = payload.get("asset_id", "")
    mode = payload.get("predicted_mode", "")
    approver = payload.get("approver", "")
    title = payload.get("text", "Work Order Update")

    # Fetch GitHub URL if available
    gh_url = ""
    try:
        gh_r = session.sql(f"SELECT GITHUB_ISSUE_URL FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '{wo_id}'").collect()
        if gh_r and gh_r[0]["GITHUB_ISSUE_URL"]:
            gh_url = gh_r[0]["GITHUB_ISSUE_URL"]
    except Exception:
        pass
    gh_link = f"\n<{gh_url}|View GitHub Issue>" if gh_url else ""

    slack_msg = {"blocks": [
        {"type": "header", "text": {"type": "plain_text", "text": ":rotating_light: AegisOEE Work Order Approved", "emoji": True}},
        {"type": "section", "fields": [
            {"type": "mrkdwn", "text": f"*Work Order:*\n`{wo_id}`"},
            {"type": "mrkdwn", "text": f"*Asset:*\n`{asset}`"},
            {"type": "mrkdwn", "text": f"*Failure Mode:*\n`{mode}`"},
            {"type": "mrkdwn", "text": f"*Approved by:*\n{approver}"},
        ]},
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*{title}*{gh_link}"}},
        {"type": "context", "elements": [{"type": "mrkdwn", "text": "Generated by AegisOEE Governed Action Loop"}]},
    ]}

    # Upsert outbox
    existing = session.sql(f"SELECT OUTBOX_ID FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE WO_ID = '{wo_id}' AND TARGET = 'SLACK' LIMIT 1").collect()

    try:
        resp = requests.post(webhook_url, json=slack_msg, timeout=30)
        resp.raise_for_status()
        if existing:
            session.sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='SENT', ATTEMPTS=ATTEMPTS+1, LAST_ERROR=NULL WHERE WO_ID='{wo_id}' AND TARGET='SLACK'").collect()
        else:
            session.sql(f"INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX(OUTBOX_ID,WO_ID,TARGET,PAYLOAD,ATTEMPTS,STATUS) SELECT 'OB_SL_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),'{wo_id}','SLACK',PARSE_JSON('{json.dumps(payload).replace(chr(39),chr(39)+chr(39))}'),1,'SENT'").collect()
        session.sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_SL_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP(),'SYSTEM','SLACK_SENT','{wo_id}',PARSE_JSON('{{\"status\":\"sent\"}}')")
        return f"Slack sent ({resp.status_code})"
    except Exception as e:
        err = str(e).replace("'","''")[:500]
        if existing:
            session.sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET ATTEMPTS=ATTEMPTS+1, LAST_ERROR='{err}', STATUS=CASE WHEN ATTEMPTS+1>=5 THEN 'DEAD' ELSE 'PENDING' END WHERE WO_ID='{wo_id}' AND TARGET='SLACK'").collect()
        else:
            session.sql(f"INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX(OUTBOX_ID,WO_ID,TARGET,PAYLOAD,ATTEMPTS,LAST_ERROR,STATUS) SELECT 'OB_SL_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),'{wo_id}','SLACK',PARSE_JSON('{json.dumps(payload).replace(chr(39),chr(39)+chr(39))}'),1,'{err}','PENDING'").collect()
        return f"Slack failed (queued to outbox): {err}"
$$;


-- 5-EAI. CLOSE_GITHUB_ISSUE — closes GitHub issue when WO is CLOSED/REJECTED
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.CLOSE_GITHUB_ISSUE(P_WO_ID VARCHAR)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (AEGIS_EGRESS_EAI)
SECRETS = ('github_pat' = AEGIS_OEE.ACTION.GITHUB_PAT_SECRET,
           'slack_webhook' = AEGIS_OEE.ACTION.SLACK_WEBHOOK_SECRET)
EXECUTE AS CALLER
AS
$$
import _snowflake
import requests
import json
import re

REPO = "SreekarReddyMarpadaga/AegisOEE"

def run(session, p_wo_id: str) -> str:
    pat = _snowflake.get_generic_secret_string('github_pat')
    webhook_url = _snowflake.get_generic_secret_string('slack_webhook')
    headers = {"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json"}

    wo_r = session.sql(f"SELECT WO_ID, STATE, GITHUB_ISSUE_URL FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '{p_wo_id}'").collect()
    if not wo_r:
        return f"WO not found: {p_wo_id}"
    wo = wo_r[0].as_dict()

    if wo["STATE"] not in ("CLOSED", "REJECTED"):
        return f"WO state is {wo['STATE']}, not CLOSED/REJECTED — skipping"

    issue_url = wo.get("GITHUB_ISSUE_URL", "")
    if not issue_url:
        return "No GitHub issue URL on this WO"

    match = re.search(r'/issues/(\d+)$', issue_url)
    if not match:
        return f"Cannot parse issue number from {issue_url}"
    issue_num = match.group(1)
    api_url = f"https://api.github.com/repos/{REPO}/issues/{issue_num}"

    # Already closed?
    already = session.sql(f"SELECT 1 FROM AEGIS_OEE.ACTION.ACTION_AUDIT WHERE ACTION='GITHUB_ISSUE_CLOSED' AND OBJECT_REF='{p_wo_id}'").collect()
    if already:
        return "Already closed"

    state = wo["STATE"]
    comment = f"Work order `{p_wo_id}` has been **{state}**. Closing this issue."
    if state == "REJECTED":
        comment += "\n\n> This work order was rejected and no maintenance action was taken."

    try:
        requests.post(f"{api_url}/comments", headers=headers, json={"body": comment}, timeout=30)
        resp = requests.patch(api_url, headers=headers,
                              json={"state": "closed", "state_reason": "completed" if state == "CLOSED" else "not_planned"},
                              timeout=30)
        resp.raise_for_status()

        detail = json.dumps({"issue_url": issue_url, "issue_number": issue_num, "wo_state": state}).replace("'","''")
        session.sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_GH_CLOSE_'||TO_VARCHAR(CURRENT_TIMESTAMP(),'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP(),'SYSTEM','GITHUB_ISSUE_CLOSED','{p_wo_id}',PARSE_JSON('{detail}')").collect()

        # Slack notification
        if webhook_url:
            requests.post(webhook_url, json={
                "text": f"GitHub Issue #{issue_num} closed — WO {p_wo_id} {state}",
                "blocks": [
                    {"type": "section", "text": {"type": "mrkdwn", "text": f":white_check_mark: *Work Order {state}*\n`{p_wo_id}` — <{issue_url}|GitHub Issue #{issue_num}> closed."}},
                    {"type": "context", "elements": [{"type": "mrkdwn", "text": "AegisOEE Governed Action Loop"}]},
                ]
            }, timeout=30)

        return f"GitHub issue #{issue_num} closed ({state})"
    except Exception as e:
        return f"Failed to close: {e}"
$$;


-- 6-EAI. RETRY_OUTBOX — retries pending, marks dead after 10 attempts
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.RETRY_OUTBOX()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
'
DECLARE
  v_pending_gh INTEGER;
  v_pending_sl INTEGER;
BEGIN
  UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
  SET STATUS = ''DEAD'', LAST_ERROR = ''Max attempts (10) reached''
  WHERE STATUS = ''PENDING'' AND ATTEMPTS >= 10;

  -- Retry GitHub
  FOR rec IN (SELECT WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET = ''GITHUB'' AND STATUS = ''PENDING'') DO
    CALL AEGIS_OEE.ACTION.QUEUE_GITHUB_SYNC(rec.WO_ID);
  END FOR;

  -- Retry Slack
  FOR rec IN (SELECT WO_ID, PAYLOAD FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX WHERE TARGET = ''SLACK'' AND STATUS = ''PENDING'') DO
    CALL AEGIS_OEE.ACTION.NOTIFY_SLACK(rec.PAYLOAD);
  END FOR;

  -- Close GitHub issues for finished WOs
  FOR rec IN (SELECT WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER
              WHERE STATE IN (''CLOSED'', ''REJECTED'') AND GITHUB_ISSUE_URL IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM AEGIS_OEE.ACTION.ACTION_AUDIT WHERE ACTION = ''GITHUB_ISSUE_CLOSED'' AND OBJECT_REF = WO_ID)) DO
    CALL AEGIS_OEE.ACTION.CLOSE_GITHUB_ISSUE(rec.WO_ID);
  END FOR;

  RETURN ''Outbox retry + issue close complete'';
END;
';
*/

-- ============================================================
-- EAI-READY: Inbound GitHub Sync (polls linked issues, syncs
-- state transitions back to Snowflake WO)
-- Requires AEGIS_OEE.ACTION.AEGIS_GITHUB_EAI to be active.
-- ============================================================
/*
CREATE OR REPLACE PROCEDURE AEGIS_OEE.ACTION.SYNC_GITHUB_INBOUND()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (AEGIS_OEE.ACTION.AEGIS_GITHUB_EAI)
EXECUTE AS CALLER
AS '
import json, requests, _snowflake

def run(session):
    pat = _snowflake.get_generic_secret_string("github_pat_secret")
    repo = "SreekarReddyMarpadaga/AegisOEE"
    headers = {"Authorization": f"token {pat}", "Accept": "application/vnd.github.v3+json"}

    rows = session.sql("""
        SELECT WO_ID, STATE, GITHUB_ISSUE_URL
        FROM AEGIS_OEE.ACTION.WORK_ORDER
        WHERE GITHUB_ISSUE_URL IS NOT NULL
          AND GITHUB_ISSUE_URL != ''''
          AND STATE NOT IN (''RESOLVED'',''CANCELLED'',''CLOSED'',''REJECTED'')
    """).collect()

    transitions = 0
    for r in rows:
        wo_id = r["WO_ID"]
        current_state = r["STATE"]
        issue_url = r["GITHUB_ISSUE_URL"]
        import re
        m = re.search(r"/issues/(\d+)$", issue_url)
        if not m:
            continue
        issue_num = m.group(1)

        resp = requests.get(f"https://api.github.com/repos/{repo}/issues/{issue_num}", headers=headers, timeout=30)
        if resp.status_code != 200:
            continue
        issue = resp.json()
        if issue.get("state") != "closed":
            continue

        gh_reason = issue.get("state_reason", "")
        gh_closed = issue.get("closed_at", "")
        new_state = "CANCELLED" if gh_reason == "not_planned" else "RESOLVED"
        audit_action = "WO_CANCELLED" if new_state == "CANCELLED" else "WO_RESOLVED"
        if current_state == new_state:
            continue

        closed_at_sql = f"TRY_TO_TIMESTAMP_TZ(''{gh_closed}'')" if gh_closed else "CURRENT_TIMESTAMP"
        session.sql(f"""
            UPDATE AEGIS_OEE.ACTION.WORK_ORDER
            SET STATE = ''{new_state}'', CLOSE_REASON = ''{gh_reason or "completed"}'', CLOSED_AT = {closed_at_sql}
            WHERE WO_ID = ''{wo_id}''
        """).collect()

        detail = json.dumps({"source":"github_sync","issue_url":issue_url,"issue_number":issue_num,"gh_state_reason":gh_reason,"previous_state":current_state}).replace("''","''''")
        session.sql(f"""
            INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL)
            SELECT ''AUD_GHSYNC_''||TO_VARCHAR(CURRENT_TIMESTAMP,''YYYYMMDD_HH24MISSFF3''),CURRENT_TIMESTAMP,
                   ''GITHUB_SYNC'',''{audit_action}'',''{wo_id}'',PARSE_JSON(''{detail}'')
        """).collect()

        if new_state == "CANCELLED":
            session.sql(f"""
                UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY PI
                SET PI.QTY_RESERVED = PI.QTY_RESERVED - PR.QTY_REQUESTED
                FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
                WHERE PR.WO_ID = ''{wo_id}'' AND PR.PART_ID = PI.PART_ID AND PI.QTY_RESERVED >= PR.QTY_REQUESTED
            """).collect()

        # Queue Slack notification
        session.sql(f"""
            INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX(OUTBOX_ID,WO_ID,TARGET,PAYLOAD,STATUS)
            SELECT ''OB_GHSYNC_''||TO_VARCHAR(CURRENT_TIMESTAMP,''YYYYMMDD_HH24MISSFF3''),
                   ''{wo_id}'',''SLACK'',
                   OBJECT_CONSTRUCT(''text'',''GitHub #{issue_num} closed -> {new_state}''),
                   ''PENDING''
        """).collect()
        transitions += 1

    return f"Synced {transitions} transition(s)"
';
*/
