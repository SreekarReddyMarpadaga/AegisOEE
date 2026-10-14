import streamlit as st
import pandas as pd
import json
from utils import (refresh_page, flash, 
    apply_theme, render_header, render_sidebar, render_kpi_card, run_query,
    severity_badge, time_ago, get_session, write_audit, info_tooltip,
    format_failure_eta, FAILURE_ETA_HELP,
    FAILURE_PROB_HELP, OEE_IMPACT_HELP, SEVERITY_HELP,
    tab_switch, remember_open, is_open,
)

apply_theme()
render_sidebar()
render_header("Work Order Review", "Approve/reject drafts, execute maintenance jobs, and review past work orders")

TAB_NAMES = ["Pending Drafts", "Active Work Orders", "Past Work Orders"]
active_tab = tab_switch(TAB_NAMES, "wo_tab")


def override_sql(on, reason):
    """SQL literal for the emergency-override reason argument (NULL when not overriding)."""
    return "'" + reason.strip().replace("'", "''") + "'" if on and reason.strip() else "NULL"

# ---- TAB 1: Pending Drafts ----
if active_tab == TAB_NAMES[0]:
    st.markdown(f"### Alerts Ready for Work Order {info_tooltip('Alerts in ACKED status that are eligible for work order creation. Approve creates a real work order (reserves parts, queues GitHub/Slack sync). Source: ACTION.ALERT, CORE.FAILURE_MODE_PARTS, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)
    st.caption("Work orders manage maintenance execution. For detailed requisitions and inventory, see Parts Procurement.")
    acked_df = run_query("""
        SELECT A.ALERT_ID, A.ASSET_ID, A.SEVERITY, A.PREDICTED_MODE,
               A.CONFIDENCE, A.FAILURE_PROBABILITY, A.OEE_IMPACT_EST,
               A.ONSET_TS, A.EVIDENCE, A.PREDICTED_FAILURE_TS,
               ASSET.ASSET_TYPE
        FROM AEGIS_OEE.ACTION.ALERT A
        JOIN AEGIS_OEE.CORE.ASSET ASSET ON A.ASSET_ID = ASSET.ASSET_ID
        WHERE A.STATUS = 'ACKED'
        ORDER BY
            CASE A.SEVERITY WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
            A.FAILURE_PROBABILITY DESC
    """, ttl=30)

    if acked_df.empty:
        st.info("No acknowledged alerts pending work order creation.")
    else:
        for idx, row in acked_df.iterrows():
            alert_id = row["ALERT_ID"]
            key_id = f"{idx}_{alert_id}"
            sev = row["SEVERITY"]
            asset = row["ASSET_ID"]
            mode = row["PREDICTED_MODE"]
            asset_type = row["ASSET_TYPE"]
            conf = float(row["CONFIDENCE"]) * 100 if row["CONFIDENCE"] else 0
            fp = float(row["FAILURE_PROBABILITY"]) * 100 if row["FAILURE_PROBABILITY"] else 0
            impact = float(row["OEE_IMPACT_EST"]) * 100 if row["OEE_IMPACT_EST"] else 0

            with st.expander(
                f"{sev} | {asset} — {mode} (failure prob {fp:.0f}%)",
                expanded=(sev == "P1"),
            ):
                c1, c2, c3 = st.columns(3)
                c1.markdown(f"**Severity:** {severity_badge(sev)} {info_tooltip(SEVERITY_HELP)}", unsafe_allow_html=True)
                with c2:
                    render_kpi_card("Failure Prob.", fp / 100, fmt="pct", help=FAILURE_PROB_HELP)
                with c3:
                    render_kpi_card("OEE Impact", impact / 100, fmt="pct", help=OEE_IMPACT_HELP)
                st.markdown(f"**Predicted failure by:** {format_failure_eta(row['PREDICTED_FAILURE_TS'])} {info_tooltip(FAILURE_ETA_HELP)}", unsafe_allow_html=True)

                if row["EVIDENCE"]:
                    if st.checkbox("Show evidence", key=f"ev_{key_id}"):
                        st.json(row["EVIDENCE"])

                st.divider()

                st.markdown(f"#### Parts Readiness {info_tooltip('Parts kit for this failure mode and asset type (CORE.FAILURE_MODE_PARTS) against available stock = on hand minus reserved. Short means a requisition is needed; an open requisition and its lead time are shown when one exists.')}", unsafe_allow_html=True)
                parts_df = run_query(f"""
                    SELECT FMP.PART_ID, PI.PART_NAME,
                           FMP.QTY_REQUIRED,
                           (PI.ON_HAND_QTY - PI.RESERVED_QTY) AS AVAILABLE,
                           GREATEST(FMP.QTY_REQUIRED - (PI.ON_HAND_QTY - PI.RESERVED_QTY), 0) AS SHORTAGE,
                           PR.STATUS AS REQ_STATUS, PR.LEAD_TIME_DAYS AS REQ_LEAD
                    FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS FMP
                    JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON FMP.PART_ID = PI.PART_ID
                    LEFT JOIN AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
                        ON FMP.PART_ID = PR.PART_ID AND PR.STATUS NOT IN ('CANCELLED','RECEIVED')
                    WHERE FMP.FAILURE_MODE = '{mode}'
                      AND FMP.ASSET_TYPE = '{asset_type}'
                    ORDER BY FMP.PART_ID
                """, ttl=60)

                if not parts_df.empty:
                    shortage_count = int((parts_df["SHORTAGE"] > 0).sum())
                    for _, p in parts_df.iterrows():
                        avail = int(p["AVAILABLE"])
                        need = int(p["QTY_REQUIRED"])
                        short = int(p["SHORTAGE"])
                        req_info = ""
                        if pd.notna(p.get("REQ_STATUS")) and p["REQ_STATUS"]:
                            req_info = f" | Req: {p['REQ_STATUS']} ({int(p['REQ_LEAD'])}d)"
                        color = "#e74c3c" if short > 0 else "#0f9b8e"
                        st.markdown(
                            f'<div style="font-size:0.85rem;margin:2px 0;">'
                            f'<span style="color:{color};font-weight:600;">{p["PART_ID"]}</span> '
                            f'{p["PART_NAME"]} — Need: {need}, Avail: {avail}'
                            f'{", <strong>Short: " + str(short) + "</strong>" if short > 0 else ""}'
                            f'{req_info}</div>',
                            unsafe_allow_html=True,
                        )
                    if shortage_count > 0:
                        st.info("📦 Navigate to **Parts Procurement** page to view requisitions & inventory.")
                else:
                    st.info("No parts mapping found for this failure mode.")

                st.divider()

                st.markdown(f"#### Actions {info_tooltip('Approve creates the work order with your estimated repair time, reserves parts, auto-schedules a maintenance window that fits that time and queues the GitHub/Slack sync. Reject suppresses the alert with a recorded reason. Both are audited.')}", unsafe_allow_html=True)
                act_c1, act_c2 = st.columns(2)

                with act_c1:
                    st.markdown("**Approve Work Order**")
                    hist_df = run_query(f"""
                        SELECT AEGIS_OEE.ACTION.GET_EST_DURATION_MIN('{mode}', '{asset_type}') AS SUGGESTED, COUNT(*) AS JOBS
                        FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY MH
                        JOIN AEGIS_OEE.CORE.ASSET A ON MH.ASSET_ID = A.ASSET_ID
                        WHERE MH.FAILURE_CODE = '{mode}' AND A.ASSET_TYPE = '{asset_type}'
                    """, ttl=60)
                    suggested = int(hist_df["SUGGESTED"].iloc[0]) if not hist_df.empty else 120
                    past_jobs = int(hist_df["JOBS"].iloc[0]) if not hist_df.empty else 0
                    st.markdown(
                        f"Estimated repair time {info_tooltip('How long the job will occupy a maintenance window. Scheduling picks a window with at least this much free capacity. Default is the historical average labour time for this failure mode and asset type (120 min when there is no history); change it to your own estimate.')}"
                        f" &mdash; history suggests **{suggested} min** ({past_jobs} past job(s))",
                        unsafe_allow_html=True,
                    )
                    with st.form(f"form_approve_{key_id}"):
                        approver = st.text_input("Approver name", key=f"approver_{key_id}", placeholder="e.g. MAINT_SUPERVISOR_RAJ")
                        est_min = st.number_input("Estimated repair time (minutes)", min_value=15, max_value=1440, value=min(max(suggested, 15), 1440), step=15, key=f"est_{key_id}")
                        confirm_approve = st.checkbox("I confirm this work order should be created", key=f"confirm_approve_{key_id}")
                        if st.form_submit_button("Approve", type="primary"):
                            if not approver.strip():
                                st.warning("Enter approver name.")
                            elif not confirm_approve:
                                st.warning("Check the confirmation box.")
                            else:
                                try:
                                    session = get_session()
                                    safe_approver = approver.strip().replace("'", "''")
                                    result = session.sql(
                                        f"CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('{alert_id}', '{safe_approver}', FALSE, {int(est_min)})"
                                    ).collect()
                                    parsed = json.loads(result[0][0]) if result and isinstance(result[0][0], str) else (result[0][0] if result else {})
                                    created = parsed.get("status") == "APPROVED"
                                    if created:
                                        flash(f"Work order created for alert {alert_id} — see the Active Work Orders tab.")
                                    else:
                                        st.warning(f"Not created: {parsed.get('reason', parsed.get('status'))}")
                                except Exception as e:
                                    st.error(f"Error creating work order: {e}")
                                else:
                                    if created:
                                        refresh_page()

                with act_c2:
                    st.markdown("**Reject / Suppress**")
                    with st.form(f"form_reject_{key_id}"):
                        reject_reason = st.text_input("Rejection reason", key=f"reject_reason_{key_id}")
                        confirm_reject = st.checkbox("I confirm this alert should be suppressed", key=f"confirm_reject_{key_id}")
                        if st.form_submit_button("Reject"):
                            if not reject_reason.strip():
                                st.warning("Provide a rejection reason.")
                            elif not confirm_reject:
                                st.warning("Check the confirmation box.")
                            else:
                                try:
                                    session = get_session()
                                    safe_reason = reject_reason.strip().replace("'", "''")
                                    session.sql(f"""
                                        UPDATE AEGIS_OEE.ACTION.ALERT
                                        SET STATUS = 'SUPPRESSED'
                                        WHERE ALERT_ID = '{alert_id}' AND STATUS = 'ACKED'
                                    """).collect()
                                    write_audit(session, "APP_USER", "ALERT_REJECTED", alert_id, '{"reason":"' + safe_reason + '"}')
                                    flash(f"Alert {alert_id} rejected and suppressed.")
                                except Exception as e:
                                    st.error(f"Error: {e}")
                                else:
                                    refresh_page()

# ---- TAB 2: Active Work Orders (execution lifecycle) ----
if active_tab == TAB_NAMES[1]:
    st.markdown(f"### Active Work Orders {info_tooltip('Work orders in APPROVED, SYNCED, IN_PROGRESS, or RESOLVED state. Manage the full execution lifecycle: Start work, Complete, and Close with verification. Source: ACTION.WORK_ORDER, ACTION.WO_SCHEDULE, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)

    wo_df = run_query("""
        SELECT WO.WO_ID, WO.ALERT_ID, WO.ASSET_ID, WO.PRIORITY, WO.STATE,
               WO.TITLE, WO.DESCRIPTION, WO.APPROVED_BY, WO.APPROVED_TS,
               WO.GITHUB_ISSUE_URL, WO.CLOSE_REASON,
               AL.PREDICTED_MODE, AL.PREDICTED_FAILURE_TS, A.ASSET_TYPE
        FROM AEGIS_OEE.ACTION.WORK_ORDER WO
        JOIN AEGIS_OEE.ACTION.ALERT AL ON WO.ALERT_ID = AL.ALERT_ID
        JOIN AEGIS_OEE.CORE.ASSET A ON WO.ASSET_ID = A.ASSET_ID
        WHERE WO.STATE NOT IN ('CLOSED', 'REJECTED', 'CANCELLED')
        ORDER BY
            CASE WO.PRIORITY WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
            WO.APPROVED_TS DESC
    """, ttl=15)

    if wo_df.empty:
        st.info("No active work orders.")
    else:
        for _, wo in wo_df.iterrows():
            wo_id = wo["WO_ID"]
            wo_state = wo["STATE"]
            predicted_mode = wo["PREDICTED_MODE"]
            asset_type = wo["ASSET_TYPE"]

            # Lifecycle stepper
            steps = ["Approved", "Parts Ready", "In Progress", "Resolved", "Closed"]
            state_step = {"DRAFT": 0, "APPROVED": 0, "SYNCED": 0, "IN_PROGRESS": 2, "RESOLVED": 3}
            current_step = state_step.get(wo_state, 0)

            # Check parts readiness for the step indicator
            parts_ready = True
            parts_check_df = run_query(f"""
                SELECT FMP.PART_ID, PI.PART_NAME,
                       FMP.QTY_REQUIRED, PI.RESERVED_QTY,
                       GREATEST(0, FMP.QTY_REQUIRED - PI.RESERVED_QTY) AS SHORTAGE
                FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS FMP
                JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON FMP.PART_ID = PI.PART_ID
                WHERE FMP.FAILURE_MODE = '{predicted_mode}'
                  AND FMP.ASSET_TYPE = '{asset_type}'
                ORDER BY FMP.PART_ID
            """, ttl=15)
            if not parts_check_df.empty:
                has_shortage = int((parts_check_df["SHORTAGE"] > 0).sum()) > 0
                if has_shortage and wo_state in ("APPROVED", "SYNCED"):
                    parts_ready = False
                elif not has_shortage and wo_state in ("APPROVED", "SYNCED"):
                    current_step = 1

            with st.expander(f"{wo['PRIORITY']} | {wo_id} — {wo['TITLE']} [{wo_state}]", expanded=(wo_state == "IN_PROGRESS" or is_open(wo_id))):
                # Lifecycle stepper visual
                stepper_html = '<div style="display:flex;align-items:center;gap:4px;margin-bottom:12px;">'
                for si, label in enumerate(steps):
                    if si < current_step:
                        bg = "#0f9b8e"
                        fg = "white"
                    elif si == current_step:
                        bg = "#3498db"
                        fg = "white"
                    else:
                        bg = "#2a2a4a"
                        fg = "#8892b0"
                    stepper_html += (
                        f'<div style="background:{bg};color:{fg};padding:6px 12px;'
                        f'border-radius:8px;font-size:0.8rem;font-weight:600;">'
                        f'{si+1}. {label}</div>'
                    )
                    if si < len(steps) - 1:
                        stepper_html += '<div style="color:#8892b0;">→</div>'
                stepper_html += '</div>'
                st.markdown(stepper_html, unsafe_allow_html=True)

                # WO summary
                w1, w2, w3 = st.columns(3)
                w1.markdown(f"**Priority:** {severity_badge(wo['PRIORITY'])}", unsafe_allow_html=True)
                w2.markdown(f"**Asset:** {wo['ASSET_ID']}")
                w3.markdown(f"**Approved by:** {wo['APPROVED_BY'] or 'N/A'}")
                st.markdown(f"**Description:** {wo['DESCRIPTION']}")
                st.markdown(f"**Predicted failure by:** {format_failure_eta(wo['PREDICTED_FAILURE_TS'])} {info_tooltip(FAILURE_ETA_HELP)}", unsafe_allow_html=True)

                if wo["GITHUB_ISSUE_URL"]:
                    st.markdown(f"**GitHub Issue:** {wo['GITHUB_ISSUE_URL']}")

                # Schedule info
                sched_df = run_query(f"""
                    SELECT SCHEDULE_ID, WINDOW_ID,
                           TO_VARCHAR(SCHEDULED_START_TS, 'YYYY-MM-DD HH24:MI') AS SCHED_START,
                           TO_VARCHAR(SCHEDULED_END_TS, 'YYYY-MM-DD HH24:MI') AS SCHED_END,
                           EST_DURATION_MIN, PARTS_READY_DATE, ORDER_BY_DATE, STATUS
                    FROM AEGIS_OEE.ACTION.WO_SCHEDULE
                    WHERE WO_ID = '{wo_id}' AND STATUS NOT IN ('CANCELLED')
                    ORDER BY CREATED_TS DESC LIMIT 1
                """, ttl=15)
                if not sched_df.empty:
                    s = sched_df.iloc[0]
                    sched_status_color = {"TENTATIVE": "#f0a500", "CONFIRMED": "#0f9b8e", "EXPEDITE": "#e74c3c", "IN_PROGRESS": "#3498db", "COMPLETED": "#0f9b8e"}.get(s["STATUS"], "#8892b0")
                    st.markdown(
                        f'<div style="background:#16213e;padding:8px 12px;border-radius:8px;margin:8px 0;font-size:0.85rem;">'
                        f'<strong>Schedule:</strong> {s["SCHED_START"]} to {s["SCHED_END"]} '
                        f'({int(s["EST_DURATION_MIN"])} min est) — '
                        f'<span style="color:{sched_status_color};font-weight:600;">{s["STATUS"]}</span> — '
                        f'Parts ready: {str(s["PARTS_READY_DATE"])[:10] if pd.notna(s["PARTS_READY_DATE"]) else "N/A"} — '
                        f'Order by: {str(s["ORDER_BY_DATE"])[:10] if pd.notna(s["ORDER_BY_DATE"]) else "N/A"}'
                        f'</div>',
                        unsafe_allow_html=True,
                    )

                # Parts readiness panel
                st.markdown("**Parts Readiness:**")
                if not parts_check_df.empty:
                    for _, p in parts_check_df.iterrows():
                        need = int(p["QTY_REQUIRED"])
                        reserved = int(p["RESERVED_QTY"])
                        short = int(p["SHORTAGE"])
                        color = "#e74c3c" if short > 0 else "#0f9b8e"
                        st.markdown(
                            f'<div style="font-size:0.85rem;margin:2px 0;">'
                            f'<span style="color:{color};font-weight:600;">{p["PART_ID"]}</span> '
                            f'{p["PART_NAME"]} — Need: {need}, Reserved: {reserved}'
                            f'{", <strong>Short: " + str(short) + "</strong>" if short > 0 else " ✓"}'
                            f'</div>',
                            unsafe_allow_html=True,
                        )
                    if not parts_ready:
                        st.warning("Parts not ready — cannot start work. Receive outstanding requisitions first.")
                        st.info("📦 Navigate to **Parts Procurement** page to manage parts.")
                else:
                    st.info("No parts mapping found.")

                st.divider()

                # === ACTION FORMS per state ===

                # APPROVED / SYNCED → Start Work
                if wo_state in ("APPROVED", "SYNCED"):
                    st.markdown(f"#### Start Work {info_tooltip('Records the technician and moves the work order to IN_PROGRESS. Rejected if the required parts are not available, or if the current time is outside the booked shift-plan maintenance window (15 min early start allowed). In an emergency, tick the override and give a reason (10+ characters); overrides are audited.')}", unsafe_allow_html=True)
                    with st.form(f"form_start_{wo_id}"):
                        tech = st.text_input("Technician name", key=f"tech_start_{wo_id}", placeholder="e.g. TECH_KUMAR")
                        note = st.text_input("Note (optional)", key=f"note_start_{wo_id}")
                        override = st.checkbox("Emergency override: start outside the booked shift-plan window", key=f"ovr_start_{wo_id}")
                        override_reason = st.text_input("Override reason (at least 10 characters, audited)", key=f"ovr_reason_{wo_id}", placeholder="e.g. Spindle seizing, line stopped")
                        bc1, bc2 = st.columns(2)
                        with bc1:
                            if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=(wo_id,)):
                                if not tech.strip():
                                    st.warning("Enter technician name.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_tech = tech.strip().replace("'", "''")
                                        safe_note = note.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.START_WORK_ORDER('{wo_id}', '{safe_tech}', '{safe_note}', TRUE, {override_sql(override, override_reason)})"
                                        ).collect()
                                        if result:
                                            parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                            if parsed.get("status") == "REJECTED":
                                                st.error(f"Cannot start: {parsed.get('reason', 'Unknown')}")
                                                if parsed.get("schedule_violation"):
                                                    st.info(f"Booked window: {parsed.get('window_start') or 'none'} to {parsed.get('window_end') or 'none'}. " + ("Enter an override reason of at least 10 characters." if override else "In an emergency, tick the override box and enter a reason."))
                                                if parsed.get("blocking_parts"):
                                                    st.json(parsed["blocking_parts"])
                                                    st.info("📦 Navigate to **Parts Procurement** page to manage parts.")
                                            else:
                                                st.json(parsed)
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                        with bc2:
                            confirm = st.checkbox("I confirm starting this work order", key=f"conf_start_{wo_id}")
                            if st.form_submit_button("Start Work", type="primary"):
                                if not tech.strip():
                                    st.warning("Enter technician name.")
                                elif not confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_tech = tech.strip().replace("'", "''")
                                        safe_note = note.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.START_WORK_ORDER('{wo_id}', '{safe_tech}', '{safe_note}', FALSE, {override_sql(override, override_reason)})"
                                        ).collect()
                                        should_rerun = True
                                        if result:
                                            parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                            if parsed.get("status") == "OK":
                                                flash(f"Work started on {wo_id}." + (" Emergency override recorded in the audit trail." if "OVERRIDDEN" in str(parsed.get("schedule_check", "")) else ""))
                                            elif parsed.get("status") == "REJECTED":
                                                st.error(f"Cannot start: {parsed.get('reason')}")
                                                if parsed.get("schedule_violation"):
                                                    st.info(f"Booked window: {parsed.get('window_start') or 'none'} to {parsed.get('window_end') or 'none'}. " + ("Enter an override reason of at least 10 characters." if override else "In an emergency, tick the override box and enter a reason."))
                                                should_rerun = False
                                                if parsed.get("blocking_parts"):
                                                    st.json(parsed["blocking_parts"])
                                                    st.info("📦 Navigate to **Parts Procurement** page to manage parts.")
                                            else:
                                                st.json(parsed)
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        if should_rerun:
                                            refresh_page()

                # IN_PROGRESS → Complete Work
                elif wo_state == "IN_PROGRESS":
                    st.markdown(f"#### Complete Work {info_tooltip('Records finding, action taken, parts used and labour hours. Writes a CORE.MAINTENANCE_HISTORY row, consumes the reserved parts and moves the work order to RESOLVED.')}", unsafe_allow_html=True)
                    with st.form(f"form_comp_{wo_id}"):
                        tech = st.text_input("Technician name", key=f"tech_comp_{wo_id}", placeholder="e.g. TECH_KUMAR")
                        finding = st.text_area("Finding", key=f"finding_{wo_id}", placeholder="Describe what was found during inspection")
                        action_taken = st.text_area("Action taken", key=f"action_{wo_id}", placeholder="Describe the repair performed")
                        cc1, cc2 = st.columns(2)
                        with cc1:
                            labor_hours = st.number_input("Labor hours", min_value=0.0, step=0.5, value=1.0, key=f"labor_{wo_id}")
                        with cc2:
                            outcome = st.selectbox("Outcome", ["FIXED", "PARTIAL"], key=f"outcome_{wo_id}")

                        bc1, bc2 = st.columns(2)
                        with bc1:
                            if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=(wo_id,)):
                                if not tech.strip():
                                    st.warning("Enter technician name.")
                                elif not finding.strip():
                                    st.warning("Enter finding.")
                                elif not action_taken.strip():
                                    st.warning("Enter action taken.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_tech = tech.strip().replace("'", "''")
                                        safe_finding = finding.strip().replace("'", "''")
                                        safe_action = action_taken.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER('{wo_id}', '{safe_tech}', "
                                            f"'{safe_finding}', '{safe_action}', {labor_hours}, NULL, '{outcome}', TRUE)"
                                        ).collect()
                                        if result:
                                            st.json(result[0][0])
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                        with bc2:
                            confirm = st.checkbox("I confirm completion of this work order", key=f"conf_comp_{wo_id}")
                            if st.form_submit_button("Complete Work", type="primary"):
                                if not tech.strip():
                                    st.warning("Enter technician name.")
                                elif not finding.strip():
                                    st.warning("Enter finding.")
                                elif not action_taken.strip():
                                    st.warning("Enter action taken.")
                                elif not confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_tech = tech.strip().replace("'", "''")
                                        safe_finding = finding.strip().replace("'", "''")
                                        safe_action = action_taken.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.COMPLETE_WORK_ORDER('{wo_id}', '{safe_tech}', "
                                            f"'{safe_finding}', '{safe_action}', {labor_hours}, NULL, '{outcome}', FALSE)"
                                        ).collect()
                                        should_rerun = False
                                        if result:
                                            parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                            if parsed.get("status") == "OK":
                                                flash(f"Work order {wo_id} completed — {outcome}.")
                                                should_rerun = True
                                            else:
                                                st.warning(f"Result: {parsed.get('reason', parsed.get('status'))}")
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        if should_rerun:
                                            refresh_page()

                # RESOLVED → Close (verification)
                elif wo_state == "RESOLVED":
                    st.markdown(f"#### Close Work Order (Verification) {info_tooltip('Four-eyes check: a different person than the technician verifies the repair. Closing records the reason, queues the GitHub issue close and starts a 24 h cooldown during which the same asset and failure mode is not re-alerted.')}", unsafe_allow_html=True)
                    st.caption("Approver must differ from the technician who started the work.")
                    with st.form(f"form_close_{wo_id}"):
                        approver = st.text_input("Approver name", key=f"approver_close_{wo_id}", placeholder="e.g. MAINT_SUPERVISOR_RAJ")
                        verification = st.text_area("Verification note", key=f"verify_{wo_id}", placeholder="Describe verification performed")

                        bc1, bc2 = st.columns(2)
                        with bc1:
                            if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=(wo_id,)):
                                if not approver.strip():
                                    st.warning("Enter approver name.")
                                elif not verification.strip():
                                    st.warning("Enter verification note.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_approver = approver.strip().replace("'", "''")
                                        safe_verify = verification.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.CLOSE_WORK_ORDER('{wo_id}', '{safe_approver}', '{safe_verify}', TRUE)"
                                        ).collect()
                                        if result:
                                            parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                            if parsed.get("status") == "REJECTED":
                                                st.error(f"Cannot close: {parsed.get('reason')}")
                                            else:
                                                st.json(parsed)
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                        with bc2:
                            confirm = st.checkbox("I confirm closure of this work order", key=f"conf_close_{wo_id}")
                            if st.form_submit_button("Close Work Order", type="primary"):
                                if not approver.strip():
                                    st.warning("Enter approver name.")
                                elif not verification.strip():
                                    st.warning("Enter verification note.")
                                elif not confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_approver = approver.strip().replace("'", "''")
                                        safe_verify = verification.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.CLOSE_WORK_ORDER('{wo_id}', '{safe_approver}', '{safe_verify}', FALSE)"
                                        ).collect()
                                        should_rerun = True
                                        if result:
                                            parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                            if parsed.get("status") == "OK":
                                                flash(f"Work order {wo_id} closed and verified.")
                                            elif parsed.get("status") == "REJECTED":
                                                st.error(f"Cannot close: {parsed.get('reason')}")
                                                should_rerun = False
                                            else:
                                                st.json(parsed)
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        if should_rerun:
                                            refresh_page()

                # Outbox status
                try:
                    outbox_df = run_query(f"""
                        SELECT TARGET, STATUS, ATTEMPTS, LAST_ERROR
                        FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
                        WHERE WO_ID = '{wo_id}'
                        ORDER BY TARGET
                    """, ttl=30)
                    if not outbox_df.empty:
                        st.markdown("**Sync Status:**")
                        for _, ob in outbox_df.iterrows():
                            target = ob["TARGET"]
                            status = ob["STATUS"]
                            attempts = int(ob["ATTEMPTS"])
                            if status == "SENT":
                                badge = '<span style="color:#0f9b8e;">Sent</span>'
                            elif status == "PENDING" and attempts == 0:
                                badge = '<span style="color:#8892b0;">Queued (not configured)</span>'
                            elif status == "PENDING":
                                badge = f'<span style="color:#f0a500;">Pending (attempt {attempts})</span>'
                            elif status == "DEAD":
                                badge = '<span style="color:#8892b0;">Not configured</span>'
                            else:
                                badge = f'<span style="color:#8892b0;">{status}</span>'
                            st.markdown(
                                f'<div style="font-size:0.85rem; margin-bottom:4px;">'
                                f'<strong>{target}:</strong> {badge}'
                                f'</div>',
                                unsafe_allow_html=True,
                            )
                except Exception:
                    pass

# ---- TAB 3: Past Work Orders ----
if active_tab == TAB_NAMES[2]:
    st.markdown(f"### Past Work Orders {info_tooltip('Work orders that have been completed (CLOSED/RESOLVED), cancelled (CANCELLED), or rejected (REJECTED). Source: ACTION.WORK_ORDER.')}", unsafe_allow_html=True)
    past_df = run_query("""
        SELECT WO.WO_ID, WO.ALERT_ID, WO.ASSET_ID, WO.PRIORITY, WO.STATE,
               WO.TITLE, WO.DESCRIPTION, WO.APPROVED_BY, WO.APPROVED_TS,
               WO.GITHUB_ISSUE_URL, WO.CLOSE_REASON, WO.CLOSED_AT
        FROM AEGIS_OEE.ACTION.WORK_ORDER WO
        WHERE WO.STATE IN ('CLOSED', 'REJECTED', 'RESOLVED', 'CANCELLED')
        ORDER BY COALESCE(WO.CLOSED_AT, WO.APPROVED_TS) DESC
    """, ttl=30)

    if past_df.empty:
        st.info("No past work orders yet.")
    else:
        for _, wo in past_df.iterrows():
            state = wo["STATE"]
            state_map = {
                "CLOSED": ("#0f9b8e", "Completed"),
                "RESOLVED": ("#0f9b8e", "Resolved"),
                "CANCELLED": ("#e74c3c", "Cancelled"),
                "REJECTED": ("#e74c3c", "Rejected"),
            }
            state_color, state_label = state_map.get(state, ("#8892b0", state))
            close_reason = wo.get("CLOSE_REASON", "") or ""
            closed_at = wo.get("CLOSED_AT", "")
            reason_suffix = f" ({close_reason})" if close_reason else ""

            with st.expander(f"{wo['PRIORITY']} | {wo['WO_ID']} — {state_label}{reason_suffix}"):
                w1, w2, w3 = st.columns(3)
                w1.markdown(f"**Priority:** {severity_badge(wo['PRIORITY'])}", unsafe_allow_html=True)
                w2.markdown(f'**Status:** <span style="color:{state_color}; font-weight:700;">{state_label}</span>', unsafe_allow_html=True)
                w3.markdown(f"**Approved by:** {wo['APPROVED_BY'] or 'N/A'}")
                st.markdown(f"**Description:** {wo['DESCRIPTION']}")
                st.markdown(f"**Asset:** {wo['ASSET_ID']} | **Alert:** {wo['ALERT_ID']}")
                if close_reason:
                    st.markdown(f"**Close Reason:** {close_reason}")
                if closed_at and str(closed_at) != "None":
                    st.markdown(f"**Closed At:** {str(closed_at)[:19]}")
                if wo["GITHUB_ISSUE_URL"]:
                    st.markdown(f"**GitHub Issue:** {wo['GITHUB_ISSUE_URL']}")
