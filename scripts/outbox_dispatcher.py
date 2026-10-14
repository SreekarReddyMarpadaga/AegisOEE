#!/usr/bin/env python3
"""AegisOEE Outbox Dispatcher — polls WORK_ORDER_OUTBOX for PENDING items,
dispatches via GitHub API / Slack webhook, and closes GitHub issues for
CLOSED/REJECTED work orders."""

import json, os, subprocess, sys, re, time

CONN = os.environ.get("COCO_CONN", "aegis")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "")  # owner/repo that receives the issues
_close_retry_after = {}  # wo_id -> epoch seconds before which a failed close is not retried

def snow_sql(sql, retries=3):
    """Run a statement; returns True on success. Retries so a DNS blip after an
    external send does not leave the row unmarked."""
    for i in range(retries):
        r = subprocess.run(["snow", "sql", "--connection", CONN, "-q", sql],
                           capture_output=True, text=True)
        if r.returncode == 0:
            return True
        time.sleep(2 * (i + 1))
    print(f"  WARN: SQL failed after {retries} tries: {sql[:80]!r}")
    return False

def claim(outbox_id):
    """Atomically flip PENDING -> SENDING; only the caller that wins may send."""
    rows = query_json(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='SENDING' "
                      f"WHERE OUTBOX_ID='{outbox_id}' AND STATUS='PENDING'")
    try:
        return int(list(rows[0].values())[0]) == 1
    except Exception:
        return False

def mark_sent(outbox_id):
    snow_sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='SENT', ATTEMPTS=ATTEMPTS+1, LAST_ERROR=NULL "
             f"WHERE OUTBOX_ID='{outbox_id}'")

def release(outbox_id, err):
    err = err[:200].replace("'", "''")
    snow_sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='PENDING', ATTEMPTS=ATTEMPTS+1, "
             f"LAST_ERROR='{err}' WHERE OUTBOX_ID='{outbox_id}'")

def find_existing_issue(github_pat, wo_id):
    """Recover from a lost DB update: an issue for this WO may already exist."""
    import requests
    resp = requests.get(
        f"https://api.github.com/repos/{GITHUB_REPO}/issues",
        headers={"Authorization": f"token {github_pat}", "Accept": "application/vnd.github.v3+json"},
        params={"state": "all", "labels": "maintenance", "per_page": 100},
        timeout=30,
    )
    if resp.status_code != 200:
        return ""
    for issue in resp.json():
        if "pull_request" not in issue and f"`{wo_id}`" in (issue.get("body") or ""):
            return issue.get("html_url", "")
    return ""

def query_json(sql):
    r = subprocess.run(["snow", "sql", "--connection", CONN, "--format", "json", "-q", sql],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return []
    try:
        return json.loads(r.stdout)
    except Exception:
        return []


def dispatch_pending(github_pat, slack_url, only=None):
    items = query_json("""
        SELECT OB.OUTBOX_ID, OB.WO_ID, OB.TARGET, OB.ATTEMPTS, OB.PAYLOAD,
               WO.TITLE, WO.DESCRIPTION, WO.ASSET_ID, WO.PRIORITY, WO.APPROVED_BY,
               WO.ALERT_ID, WO.GITHUB_ISSUE_URL,
               AL.SEVERITY, AL.PREDICTED_MODE, AL.FAILURE_PROBABILITY,
               AL.CONFIDENCE, AL.OEE_IMPACT_EST
        FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX OB
        JOIN AEGIS_OEE.ACTION.WORK_ORDER WO ON OB.WO_ID = WO.WO_ID
        LEFT JOIN AEGIS_OEE.ACTION.ALERT AL ON WO.ALERT_ID = AL.ALERT_ID
        WHERE OB.STATUS = 'PENDING'
        ORDER BY OB.TARGET
    """)
    if only:
        items = [i for i in items if i["TARGET"] in only]
    if not items:
        return

    import requests
    print(f"[DISPATCHER] {len(items)} pending item(s)")

    for item in items:
        outbox_id = item["OUTBOX_ID"]
        wo_id = item["WO_ID"]
        target = item["TARGET"]
        title = item.get("TITLE") or "Work Order"
        desc = item.get("DESCRIPTION") or ""
        asset = item.get("ASSET_ID") or ""
        priority = item.get("PRIORITY") or "P3"
        approver = item.get("APPROVED_BY") or ""
        severity = item.get("SEVERITY") or priority
        mode = item.get("PREDICTED_MODE") or ""
        fp = item.get("FAILURE_PROBABILITY") or 0
        conf = item.get("CONFIDENCE") or 0
        oee_impact = item.get("OEE_IMPACT_EST") or 0
        alert_id = item.get("ALERT_ID") or ""
        existing_url = item.get("GITHUB_ISSUE_URL") or ""
        payload = item.get("PAYLOAD") or {}
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception:
                payload = {}

        if target == "GITHUB" and not github_pat:
            print(f"  SKIP: {target} for {wo_id} (no credential)")
            continue
        if target == "SLACK" and not slack_url:
            print(f"  SKIP: {target} for {wo_id} (no credential)")
            continue
        if target == "SLACK" and not existing_url and os.environ.get("GITHUB_PAT"):
            # Hold the Slack message until the issue exists so it can carry the link (gives up after 3 GitHub attempts).
            waiting = query_json(
                f"SELECT COUNT(*) AS N FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX "
                f"WHERE WO_ID = '{wo_id}' AND TARGET = 'GITHUB' AND STATUS IN ('PENDING', 'SENDING') "
                f"AND ATTEMPTS < 3 AND COALESCE(PAYLOAD:action::STRING, '') != 'close'"
            )
            if waiting and int(list(waiting[0].values())[0]) > 0:
                print(f"  WAIT: Slack for {wo_id} until the GitHub issue link exists")
                continue
        if not claim(outbox_id):
            continue  # another dispatcher (or retry task) already took it

        try:
            if target == "GITHUB" and payload.get("action") == "close":
                # Close requests never create an issue; close_github_issues() performs the close.
                mark_sent(outbox_id)
                print(f"  GITHUB CLOSE REQUEST deferred to closer: {wo_id}")

            elif target == "GITHUB" and existing_url:
                mark_sent(outbox_id)
                print(f"  GITHUB SKIP (issue already linked): {wo_id} -> {existing_url}")

            elif target == "GITHUB":
                recovered = find_existing_issue(github_pat, wo_id)
                if recovered:
                    safe_url = recovered.replace("'", "''")
                    snow_sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER SET GITHUB_ISSUE_URL='{safe_url}' WHERE WO_ID='{wo_id}' AND GITHUB_ISSUE_URL IS NULL")
                    mark_sent(outbox_id)
                    print(f"  GITHUB ADOPTED existing issue: {wo_id} -> {recovered}")
                    continue
                # Fetch parts data for the issue body
                parts_rows = query_json(f"""
                    SELECT FMP.PART_ID, PI.PART_NAME, FMP.QTY_REQUIRED,
                           PI.ON_HAND_QTY - PI.RESERVED_QTY AS AVAILABLE,
                           GREATEST(0, FMP.QTY_REQUIRED - (PI.ON_HAND_QTY - PI.RESERVED_QTY)) AS SHORTAGE,
                           PI.UNIT_COST, PI.LEAD_TIME_DAYS
                    FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS FMP
                    JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON FMP.PART_ID = PI.PART_ID
                    WHERE FMP.FAILURE_MODE = '{mode}'
                      AND FMP.ASSET_TYPE = (SELECT ASSET_TYPE FROM AEGIS_OEE.CORE.ASSET WHERE ASSET_ID = '{asset}')
                """)
                reqs = query_json(f"""
                    SELECT REQ_ID, PART_ID, QTY, EST_TOTAL, SUPPLIER_NAME, LEAD_TIME_DAYS, STATUS
                    FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION WHERE WO_ID = '{wo_id}'
                """)

                parts_table = "| Part | Name | Req | Avail | Short | Cost | Lead |\n|---|---|---|---|---|---|---|\n"
                for p in parts_rows:
                    shortage_flag = " :warning:" if p.get("SHORTAGE", 0) > 0 else ""
                    parts_table += f"| {p['PART_ID']} | {p['PART_NAME']} | {p['QTY_REQUIRED']} | {p['AVAILABLE']} | {p['SHORTAGE']}{shortage_flag} | ${p['UNIT_COST']} | {p['LEAD_TIME_DAYS']}d |\n"

                reqs_section = ""
                if reqs:
                    reqs_section = "\n### Purchase Requisitions\n\n"
                    for r in reqs:
                        reqs_section += f"- **{r['REQ_ID']}**: {r['PART_ID']} x{r['QTY']} — ${r['EST_TOTAL']} — {r['SUPPLIER_NAME']} ({r['LEAD_TIME_DAYS']}d) — {r['STATUS']}\n"

                body_md = f"""## Work Order: `{wo_id}`

**Asset:** `{asset}` | **Priority:** {priority} | **Approved by:** {approver}

> {desc}

---

### Alert Details

| Field | Value |
|---|---|
| Severity | **{severity}** |
| Predicted Mode | `{mode}` |
| Confidence | {conf} |
| Failure Probability | {fp} |
| OEE Impact | {oee_impact} |
| Alert ID | `{alert_id}` |

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
                labels = [s for s in [severity, mode, "maintenance"] if s]
                resp = requests.post(
                    f"https://api.github.com/repos/{GITHUB_REPO}/issues",
                    headers={"Authorization": f"token {github_pat}", "Accept": "application/vnd.github.v3+json"},
                    json={"title": title, "body": body_md, "labels": labels},
                    timeout=30,
                )
                if resp.status_code in (200, 201):
                    issue_url = resp.json().get("html_url", "")
                    safe_url = issue_url.replace("'", "''")
                    mark_sent(outbox_id)
                    if issue_url:
                        snow_sql(f"UPDATE AEGIS_OEE.ACTION.WORK_ORDER SET GITHUB_ISSUE_URL='{safe_url}' WHERE WO_ID='{wo_id}' AND GITHUB_ISSUE_URL IS NULL")
                    audit_detail = json.dumps({"issue_url": issue_url}).replace("'", "''")
                    snow_sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_GH_'||TO_VARCHAR(CURRENT_TIMESTAMP,'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP,'OUTBOX_DISPATCHER','GITHUB_SENT','{wo_id}',PARSE_JSON('{audit_detail}')")
                    print(f"  GITHUB SENT: {wo_id} -> {issue_url}")
                else:
                    release(outbox_id, resp.text)
                    print(f"  GITHUB FAILED ({resp.status_code}): {wo_id} - {resp.json().get('message', resp.text[:120]) if resp.headers.get('content-type', '').startswith('application/json') else resp.text[:120]}")
                    if resp.status_code == 404:
                        print(f"    404 means GITHUB_REPO='{GITHUB_REPO}' does not exist or the token cannot access it (fine-grained tokens must be granted this repo with Issues: read/write).")

            elif target == "SLACK":
                github_url_rows = query_json(f"SELECT GITHUB_ISSUE_URL FROM AEGIS_OEE.ACTION.WORK_ORDER WHERE WO_ID = '{wo_id}'")
                gh_url = github_url_rows[0].get("GITHUB_ISSUE_URL", "") if github_url_rows else ""
                gh_link = f"\n<{gh_url}|View GitHub Issue>" if gh_url else ""
                slack_text = payload.get("text") or f"{severity} Work Order Approved: {title}"
                header = "AegisOEE Work Order Closed" if "Closed" in slack_text else "AegisOEE Work Order Approved"

                msg = payload if payload.get("blocks") else {
                    "text": slack_text,
                    "blocks": [
                        {"type": "header", "text": {"type": "plain_text", "text": f":rotating_light: {header}", "emoji": True}},
                        {"type": "section", "fields": [
                            {"type": "mrkdwn", "text": f"*Work Order:*\n`{wo_id}`"},
                            {"type": "mrkdwn", "text": f"*Asset:*\n`{asset}`"},
                            {"type": "mrkdwn", "text": f"*Failure Mode:*\n`{mode}`"},
                            {"type": "mrkdwn", "text": f"*Approved by:*\n{approver}"},
                        ]},
                        {"type": "section", "text": {"type": "mrkdwn", "text": f"*{title}*\n{desc}{gh_link}"}},
                        {"type": "context", "elements": [{"type": "mrkdwn", "text": "Generated by AegisOEE Governed Action Loop"}]},
                    ]
                }
                resp = requests.post(slack_url, json=msg, timeout=30)
                if resp.status_code == 200:
                    mark_sent(outbox_id)
                    snow_sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_SL_'||TO_VARCHAR(CURRENT_TIMESTAMP,'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP,'OUTBOX_DISPATCHER','SLACK_SENT','{wo_id}',PARSE_JSON('{{\"status\":\"sent\"}}')")
                    print(f"  SLACK SENT: {wo_id}")
                else:
                    release(outbox_id, resp.text)
                    print(f"  SLACK FAILED ({resp.status_code}): {wo_id}")
        except Exception as e:
            release(outbox_id, str(e))
            print(f"  ERROR: {target} {wo_id} -> {e}")


def close_github_issues(github_pat):
    """Close GitHub issues for work orders that are CLOSED or REJECTED."""
    if not github_pat:
        return

    wo_to_close = query_json("""
        SELECT WO.WO_ID, WO.STATE, WO.GITHUB_ISSUE_URL
        FROM AEGIS_OEE.ACTION.WORK_ORDER WO
        WHERE WO.STATE IN ('CLOSED', 'REJECTED')
          AND WO.GITHUB_ISSUE_URL IS NOT NULL
          AND WO.GITHUB_ISSUE_URL != ''
          AND NOT EXISTS (
            SELECT 1 FROM AEGIS_OEE.ACTION.ACTION_AUDIT AA
            WHERE AA.ACTION = 'GITHUB_ISSUE_CLOSED'
              AND AA.OBJECT_REF = WO.WO_ID
          )
    """)
    if not wo_to_close:
        return
    wo_to_close = [w for w in wo_to_close if _close_retry_after.get(w["WO_ID"], 0) <= time.time()]
    if not wo_to_close:
        return

    import requests
    print(f"[DISPATCHER] {len(wo_to_close)} GitHub issue(s) to close")

    for wo in wo_to_close:
        wo_id = wo["WO_ID"]
        state = wo["STATE"]
        issue_url = wo["GITHUB_ISSUE_URL"]
        # Extract issue number from URL like .../issues/1
        match = re.search(r'/issues/(\d+)$', issue_url)
        if not match:
            print(f"  SKIP CLOSE: {wo_id} — can't parse issue number from {issue_url}")
            continue
        issue_number = match.group(1)

        try:
            api_url = f"https://api.github.com/repos/{GITHUB_REPO}/issues/{issue_number}"
            headers = {"Authorization": f"token {github_pat}", "Accept": "application/vnd.github.v3+json"}
            close_comment = f"Work order `{wo_id}` has been **{state}**. Closing this issue."
            if state == "REJECTED":
                close_comment += "\n\n> This work order was rejected and no maintenance action was taken."

            resp = requests.patch(
                api_url, headers=headers,
                json={"state": "closed", "state_reason": "completed" if state == "CLOSED" else "not_planned"},
                timeout=30,
            )
            if resp.status_code == 200:
                # Best effort: the issue is already closed, so a failed comment must not trigger a retry.
                requests.post(f"{api_url}/comments", headers=headers, json={"body": close_comment}, timeout=30)
                audit_detail = json.dumps({"issue_url": issue_url, "issue_number": issue_number, "wo_state": state}).replace("'", "''")
                snow_sql(f"INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT(AUDIT_ID,TS,ACTOR,ACTION,OBJECT_REF,DETAIL) SELECT 'AUD_GH_CLOSE_'||TO_VARCHAR(CURRENT_TIMESTAMP,'YYYYMMDD_HH24MISSFF3'),CURRENT_TIMESTAMP,'OUTBOX_DISPATCHER','GITHUB_ISSUE_CLOSED','{wo_id}',PARSE_JSON('{audit_detail}')")
                # The Slack 'Work Order Closed' message is queued by CLOSE_WORK_ORDER; none is sent here.
                print(f"  GITHUB CLOSED: {wo_id} issue #{issue_number} ({state})")
            else:
                wait = int(resp.headers.get("Retry-After", 300))
                _close_retry_after[wo_id] = time.time() + max(wait, 60)
                needed = resp.headers.get("X-Accepted-GitHub-Permissions", "")
                print(f"  GITHUB CLOSE FAILED ({resp.status_code}): {wo_id} | {resp.text[:300]!r}"
                      + (f" | token needs: {needed}" if needed else "")
                      + f" | retry in {max(wait, 60)}s")
        except Exception as e:
            _close_retry_after[wo_id] = time.time() + 300
            print(f"  ERROR closing issue: {wo_id} -> {e}")


def sync_github_status(github_pat):
    """Inbound sync: poll linked GitHub issues for WOs not yet in terminal state.
    On state transition → update WO, audit, release parts if cancelled, queue Slack."""
    if not github_pat:
        return
    wo_rows = query_json("""
        SELECT WO_ID, STATE, GITHUB_ISSUE_URL
        FROM AEGIS_OEE.ACTION.WORK_ORDER
        WHERE GITHUB_ISSUE_URL IS NOT NULL
          AND GITHUB_ISSUE_URL != ''
          AND STATE NOT IN ('RESOLVED','CANCELLED','CLOSED','REJECTED')
    """)
    if not wo_rows:
        return

    import requests
    print(f"[SYNC] Checking {len(wo_rows)} linked GitHub issue(s) for inbound state changes")

    for wo in wo_rows:
        wo_id = wo["WO_ID"]
        current_state = wo["STATE"]
        issue_url = wo["GITHUB_ISSUE_URL"]
        match = re.search(r'/issues/(\d+)$', issue_url)
        if not match:
            continue
        issue_number = match.group(1)

        try:
            api_url = f"https://api.github.com/repos/{GITHUB_REPO}/issues/{issue_number}"
            resp = requests.get(api_url, headers={
                "Authorization": f"token {github_pat}",
                "Accept": "application/vnd.github.v3+json",
            }, timeout=30)
            if resp.status_code != 200:
                print(f"  SKIP {wo_id}: GitHub API {resp.status_code}")
                continue

            issue = resp.json()
            gh_state = issue.get("state", "open")
            gh_reason = issue.get("state_reason", "")
            gh_closed_at = issue.get("closed_at", "")

            if gh_state != "closed":
                continue

            # Map GitHub close reason to WO state
            if gh_reason == "not_planned":
                new_state = "CANCELLED"
                audit_action = "WO_CANCELLED"
            else:
                new_state = "RESOLVED"
                audit_action = "WO_RESOLVED"

            # Idempotency: skip if already in this state
            if current_state == new_state:
                continue

            print(f"  TRANSITION: {wo_id} {current_state} -> {new_state} (GitHub #{issue_number} {gh_reason or 'completed'})")

            # 2a. Update WO state + close_reason + closed_at
            closed_at_sql = f"'{gh_closed_at}'" if gh_closed_at else "CURRENT_TIMESTAMP"
            reason_escaped = (gh_reason or 'completed').replace("'", "''")
            snow_sql(f"""
                UPDATE AEGIS_OEE.ACTION.WORK_ORDER
                SET STATE = '{new_state}',
                    CLOSE_REASON = '{reason_escaped}',
                    CLOSED_AT = TRY_TO_TIMESTAMP_TZ({closed_at_sql})
                WHERE WO_ID = '{wo_id}'
            """)

            # 2b. Audit row
            audit_detail = json.dumps({
                "source": "github_sync",
                "issue_url": issue_url,
                "issue_number": issue_number,
                "gh_state_reason": gh_reason,
                "previous_state": current_state,
            }).replace("'", "''")
            snow_sql(f"""
                INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT
                    (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
                SELECT
                    'AUD_GHSYNC_'||TO_VARCHAR(CURRENT_TIMESTAMP,'YYYYMMDD_HH24MISSFF3'),
                    CURRENT_TIMESTAMP,
                    'GITHUB_SYNC',
                    '{audit_action}',
                    '{wo_id}',
                    PARSE_JSON('{audit_detail}')
            """)

            # 2c. On CANCELLED: release reserved parts
            if new_state == "CANCELLED":
                snow_sql(f"""
                    UPDATE AEGIS_OEE.CORE.PARTS_INVENTORY PI
                    SET PI.RESERVED_QTY = PI.RESERVED_QTY - PR.QTY
                    FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
                    WHERE PR.WO_ID = '{wo_id}'
                      AND PR.PART_ID = PI.PART_ID
                      AND PI.RESERVED_QTY >= PR.QTY
                """)
                print(f"    Released reserved parts for {wo_id}")

            # 2d. Queue Slack notification
            slack_text = f"GitHub Issue #{issue_number} was closed ({gh_reason or 'completed'}) — WO `{wo_id}` → **{new_state}**"
            slack_escaped = slack_text.replace("'", "''")
            snow_sql(f"""
                INSERT INTO AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
                    (OUTBOX_ID, WO_ID, TARGET, PAYLOAD, STATUS)
                SELECT
                    'OB_GHSYNC_'||TO_VARCHAR(CURRENT_TIMESTAMP,'YYYYMMDD_HH24MISSFF3'),
                    '{wo_id}',
                    'SLACK',
                    OBJECT_CONSTRUCT('text', '{slack_escaped}', 'blocks', ARRAY_CONSTRUCT(
                        OBJECT_CONSTRUCT('type','section','text',OBJECT_CONSTRUCT('type','mrkdwn','text',
                            ':arrows_counterclockwise: *{new_state}* via GitHub close\\n`{wo_id}` — <{issue_url}|Issue #{issue_number}> ({gh_reason or "completed"})'
                        )),
                        OBJECT_CONSTRUCT('type','context','elements',ARRAY_CONSTRUCT(
                            OBJECT_CONSTRUCT('type','mrkdwn','text','AegisOEE Governed Action Loop — Inbound Sync')
                        ))
                    )),
                    'PENDING'
            """)
            print(f"    Queued Slack notification for {wo_id}")

        except Exception as e:
            print(f"  ERROR syncing {wo_id}: {e}")


def main():
    github_pat = os.environ.get("GITHUB_PAT", "")
    slack_url = os.environ.get("SLACK_WEBHOOK_URL", "")
    if github_pat and not GITHUB_REPO:
        sys.exit("GITHUB_PAT is set but GITHUB_REPO (owner/repo) is not.")

    dispatch_pending(github_pat, slack_url)
    close_github_issues(github_pat)
    sync_github_status(github_pat)
    # Dispatch any Slack items queued by the sync above
    dispatch_pending("", slack_url, only=("SLACK",))

if __name__ == "__main__":
    # A crash mid-send leaves SENDING rows; requeue them once at startup (GitHub recovery search prevents duplicate issues).
    snow_sql("UPDATE AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX SET STATUS='PENDING' WHERE STATUS='SENDING'")
    interval = int(os.environ.get("DISPATCH_INTERVAL_S", "0"))  # 0 = run once
    while True:
        main()
        if interval <= 0:
            break
        time.sleep(interval)
