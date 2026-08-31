import streamlit as st
import pandas as pd
import json
from utils import (
    apply_theme, render_header, render_sidebar, render_kpi_card, run_query,
    severity_badge, time_ago, get_session, write_audit, info_tooltip,
)

apply_theme()
render_sidebar()
render_header("Work Order Review", "Approve/reject drafts, parts procurement, and audit trail")

tab1, tab2, tab3, tab4, tab5 = st.tabs(["Pending Drafts", "Active Work Orders", "Past Work Orders", "Procurement", "Audit History"])

# ---- TAB 1: Pending Drafts ----
with tab1:
    st.markdown(f"### Alerts Ready for Work Order {info_tooltip('Alerts in ACKED status that are eligible for work order creation. Approve creates a real work order (reserves parts, queues GitHub/Slack sync). Source: ACTION.ALERT, CORE.FAILURE_MODE_PARTS, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)
    st.caption("Work orders manage maintenance execution. See the Procurement tab for detailed parts and requisition tracking.")
    acked_df = run_query("""
        SELECT A.ALERT_ID, A.ASSET_ID, A.SEVERITY, A.PREDICTED_MODE,
               A.CONFIDENCE, A.FAILURE_PROBABILITY, A.OEE_IMPACT_EST,
               A.ONSET_TS, A.EVIDENCE,
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
            sev = row["SEVERITY"]
            asset = row["ASSET_ID"]
            mode = row["PREDICTED_MODE"]
            asset_type = row["ASSET_TYPE"]
            conf = float(row["CONFIDENCE"]) * 100 if row["CONFIDENCE"] else 0
            fp = float(row["FAILURE_PROBABILITY"]) * 100 if row["FAILURE_PROBABILITY"] else 0
            impact = float(row["OEE_IMPACT_EST"]) * 100 if row["OEE_IMPACT_EST"] else 0

            with st.expander(
                f"{sev} | {asset} \u2014 {mode} (failure prob {fp:.0f}%)",
                expanded=(sev == "P1"),
            ):
                # Alert summary
                c1, c2, c3 = st.columns(3)
                c1.markdown(f"**Severity:** {severity_badge(sev)}", unsafe_allow_html=True)
                c2.metric("Failure Prob.", f"{fp:.0f}%")
                c3.metric("OEE Impact", f"{impact:.1f}%")

                # Evidence
                if row["EVIDENCE"]:
                    if st.checkbox("Show evidence", key=f"ev_{alert_id}"):
                        st.json(row["EVIDENCE"])

                st.divider()

                # Parts panel
                st.markdown("#### Parts & Procurement")
                parts_df = run_query(f"""
                    SELECT FMP.FAILURE_MODE, FMP.PART_ID, PI.PART_NAME, PI.CATEGORY,
                           FMP.QTY_REQUIRED,
                           PI.ON_HAND_QTY,
                           PI.RESERVED_QTY,
                           (PI.ON_HAND_QTY - PI.RESERVED_QTY) AS AVAILABLE,
                           GREATEST(FMP.QTY_REQUIRED - (PI.ON_HAND_QTY - PI.RESERVED_QTY), 0) AS SHORTAGE,
                           PI.UNIT_COST,
                           PI.SUPPLIER_NAME,
                           PI.LEAD_TIME_DAYS,
                           PI.BIN_LOCATION
                    FROM AEGIS_OEE.CORE.FAILURE_MODE_PARTS FMP
                    JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON FMP.PART_ID = PI.PART_ID
                    WHERE FMP.FAILURE_MODE = '{mode}'
                      AND FMP.ASSET_TYPE = '{asset_type}'
                    ORDER BY FMP.PART_ID
                """, ttl=60)

                if not parts_df.empty:
                    total_parts = len(parts_df)
                    shortage_count = int((parts_df["SHORTAGE"] > 0).sum())
                    if shortage_count > 0:
                        st.markdown(
                            f'<div class="shortage-warning">'
                            f'Parts: {total_parts} required, <strong>{shortage_count} shortage(s)</strong> — '
                            f'see Procurement tab for details'
                            f'</div>',
                            unsafe_allow_html=True,
                        )
                    else:
                        st.markdown(
                            f'<div class="info-card">'
                            f'Parts: {total_parts} required, all in stock'
                            f'</div>',
                            unsafe_allow_html=True,
                        )
                else:
                    st.info("No parts mapping found for this failure mode.")

                st.divider()

                # Approve / Reject
                st.markdown("#### Actions")
                act_c1, act_c2 = st.columns(2)

                with act_c1:
                    st.markdown("**Approve Work Order**")
                    approver = st.text_input("Approver name", key=f"approver_{alert_id}", placeholder="e.g. MAINT_SUPERVISOR_RAJ")
                    confirm_approve = st.checkbox("I confirm this work order should be created", key=f"confirm_approve_{alert_id}")
                    if st.button("Approve", key=f"btn_approve_{alert_id}", type="primary"):
                        if not approver.strip():
                            st.warning("Enter approver name.")
                        elif not confirm_approve:
                            st.warning("Check the confirmation box.")
                        else:
                            try:
                                session = get_session()
                                safe_approver = approver.strip().replace("'", "''")
                                result = session.sql(
                                    f"CALL AEGIS_OEE.ACTION.CREATE_WORK_ORDER('{alert_id}', '{safe_approver}', FALSE)"
                                ).collect()
                                st.success(f"Work order created for alert {alert_id}.")
                                if result:
                                    try:
                                        st.json(result[0][0])
                                    except Exception:
                                        st.write(result)
                                st.rerun()
                            except Exception as e:
                                st.error(f"Error creating work order: {e}")

                with act_c2:
                    st.markdown("**Reject / Suppress**")
                    reject_reason = st.text_input("Rejection reason", key=f"reject_reason_{alert_id}")
                    confirm_reject = st.checkbox("I confirm this alert should be suppressed", key=f"confirm_reject_{alert_id}")
                    if st.button("Reject", key=f"btn_reject_{alert_id}"):
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
                                    WHERE ALERT_ID = '{alert_id}'
                                """).collect()
                                write_audit(session, "APP_USER", "ALERT_REJECTED", alert_id, '{"reason":"' + safe_reason + '"}')
                                st.success(f"Alert {alert_id} rejected and suppressed.")
                                st.rerun()
                            except Exception as e:
                                st.error(f"Error: {e}")

# ---- TAB 2: Active Work Orders ----
with tab2:
    st.markdown(f"### Active Work Orders {info_tooltip('Work orders in APPROVED, IN_PROGRESS, DRAFT, or SYNCED state. Shows outbox sync status for GitHub issue creation and Slack notifications. GitHub issue closure syncs back to RESOLVED/CANCELLED. Source: ACTION.WORK_ORDER, ACTION.WORK_ORDER_OUTBOX.')}", unsafe_allow_html=True)
    wo_df = run_query("""
        SELECT WO.WO_ID, WO.ALERT_ID, WO.ASSET_ID, WO.PRIORITY, WO.STATE,
               WO.TITLE, WO.DESCRIPTION, WO.APPROVED_BY, WO.APPROVED_TS,
               WO.GITHUB_ISSUE_URL
        FROM AEGIS_OEE.ACTION.WORK_ORDER WO
        WHERE WO.STATE NOT IN ('CLOSED', 'REJECTED', 'RESOLVED', 'CANCELLED')
        ORDER BY
            CASE WO.PRIORITY WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
            WO.APPROVED_TS DESC
    """, ttl=30)

    if wo_df.empty:
        st.info("No active work orders.")
    else:
        for _, wo in wo_df.iterrows():
            with st.expander(f"{wo['PRIORITY']} | {wo['WO_ID']} \u2014 {wo['TITLE']}"):
                w1, w2, w3 = st.columns(3)
                w1.markdown(f"**Priority:** {severity_badge(wo['PRIORITY'])}", unsafe_allow_html=True)
                wo_state = wo['STATE']
                wo_state_color = "#f0a500" if wo_state == "IN_PROGRESS" else "#8892b0"
                w2.markdown(f'**State:** <span style="color:{wo_state_color};font-weight:600;">{wo_state}</span>', unsafe_allow_html=True)
                w3.markdown(f"**Approved by:** {wo['APPROVED_BY'] or 'N/A'}")

                st.markdown(f"**Description:** {wo['DESCRIPTION']}")
                st.markdown(f"**Asset:** {wo['ASSET_ID']} | **Alert:** {wo['ALERT_ID']}")

                if wo["GITHUB_ISSUE_URL"]:
                    st.markdown(f"**GitHub Issue:** {wo['GITHUB_ISSUE_URL']}")

                # Outbox status
                try:
                    outbox_df = run_query(f"""
                        SELECT TARGET, STATUS, ATTEMPTS, LAST_ERROR
                        FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
                        WHERE WO_ID = '{wo['WO_ID']}'
                        ORDER BY TARGET
                    """, ttl=30)
                    if not outbox_df.empty:
                        st.markdown("**Sync Status:**")
                        for _, ob in outbox_df.iterrows():
                            target = ob["TARGET"]
                            status = ob["STATUS"]
                            attempts = int(ob["ATTEMPTS"])
                            err = ob["LAST_ERROR"]
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
with tab3:
    st.markdown(f"### Past Work Orders {info_tooltip('Work orders that have been completed (CLOSED/RESOLVED), cancelled (CANCELLED), or rejected (REJECTED). RESOLVED/CANCELLED are synced from GitHub issue closures. Source: ACTION.WORK_ORDER.')}", unsafe_allow_html=True)
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

                # Sync status for past WOs
                try:
                    ob_df = run_query(f"""
                        SELECT TARGET, STATUS, ATTEMPTS
                        FROM AEGIS_OEE.ACTION.WORK_ORDER_OUTBOX
                        WHERE WO_ID = '{wo['WO_ID']}'
                        ORDER BY TARGET
                    """, ttl=30)
                    if not ob_df.empty:
                        st.markdown("**Sync Status:**")
                        for _, ob in ob_df.iterrows():
                            s = ob["STATUS"]
                            if s == "SENT":
                                badge = '<span style="color:#0f9b8e;">Sent</span>'
                            else:
                                badge = f'<span style="color:#8892b0;">{s}</span>'
                            st.markdown(
                                f'<div style="font-size:0.85rem; margin-bottom:4px;">'
                                f'<strong>{ob["TARGET"]}:</strong> {badge}'
                                f'</div>',
                                unsafe_allow_html=True,
                            )
                except Exception:
                    pass

# ---- TAB 4: Procurement ----
with tab4:
    st.markdown(f"### Procurement Overview {info_tooltip('All purchase requisitions across assets. Shows pending quotes, costs, suppliers, and lead times. Source: ACTION.PURCHASE_REQUISITION, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)

    all_reqs = run_query("""
        SELECT PR.REQ_ID, PR.WO_ID, PR.PART_ID, PI.PART_NAME, PR.QTY,
               PR.EST_UNIT_COST, PR.EST_TOTAL, PR.SUPPLIER_NAME,
               PR.LEAD_TIME_DAYS, PR.RFQ_TEXT, PR.STATUS, PR.CREATED_TS,
               WO.ASSET_ID, WO.ALERT_ID, WO.TITLE AS WO_TITLE
        FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
        LEFT JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON PR.PART_ID = PI.PART_ID
        LEFT JOIN AEGIS_OEE.ACTION.WORK_ORDER WO ON PR.WO_ID = WO.WO_ID
        ORDER BY PR.CREATED_TS DESC
    """, ttl=30)

    if all_reqs.empty:
        st.info("No purchase requisitions.")
    else:
        open_reqs = len(all_reqs[all_reqs["STATUS"].isin(["PENDING_QUOTE", "QUOTED"])])
        pending_value = float(all_reqs[all_reqs["STATUS"].isin(["PENDING_QUOTE", "QUOTED"])]["EST_TOTAL"].sum())
        max_lead = int(all_reqs["LEAD_TIME_DAYS"].max()) if not all_reqs.empty else 0

        k1, k2, k3 = st.columns(3)
        with k1:
            render_kpi_card("Open Requisitions", open_reqs, fmt="int")
        with k2:
            render_kpi_card("Pending Value", pending_value, fmt="dollar")
        with k3:
            render_kpi_card("Max Lead Time", max_lead, fmt="int")

        st.divider()
        st.caption("Procurement manages parts acquisition. Work orders (Active/Past tabs) manage maintenance execution.")

        for _, pr in all_reqs.iterrows():
            status = pr["STATUS"]
            status_color = "#0f9b8e" if status in ("RECEIVED", "ORDERED") else "#f0a500" if status == "PENDING_QUOTE" else "#8892b0"
            asset = pr["ASSET_ID"] or "\u2014"

            st.markdown(
                f'<div class="info-card">'
                f'<strong>{pr["REQ_ID"]}</strong> \u2014 '
                f'{pr["PART_ID"]} ({pr["PART_NAME"] or "Unknown"}) \u2014 '
                f'Qty: {int(pr["QTY"])} \u2014 '
                f'${float(pr["EST_TOTAL"]):,.2f} \u2014 '
                f'{pr["SUPPLIER_NAME"]} \u2014 '
                f'{int(pr["LEAD_TIME_DAYS"])}d lead \u2014 '
                f'<span style="color:{status_color};font-weight:600;">{status}</span> \u2014 '
                f'Asset: {asset}'
                f'</div>',
                unsafe_allow_html=True,
            )
            if pr.get("RFQ_TEXT") and pd.notna(pr["RFQ_TEXT"]):
                if st.checkbox(f"Draft PR", key=f"proc_rfq_{pr['REQ_ID']}"):
                    st.text_area("Purchase Requisition", value=pr["RFQ_TEXT"], height=120, disabled=True, key=f"proc_rfq_text_{pr['REQ_ID']}")

# ---- TAB 5: Audit History ----
with tab5:
    st.markdown(f"### Action Audit Trail {info_tooltip('Append-only log of all actions taken in the system: alert acknowledgements, work order proposals, approvals, rejections, parts checks, and sync events. Every action is timestamped with the actor identity. Source: ACTION.ACTION_AUDIT.')}", unsafe_allow_html=True)
    audit_df = run_query("""
        SELECT AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL
        FROM AEGIS_OEE.ACTION.ACTION_AUDIT
        ORDER BY TS DESC
        LIMIT 50
    """, ttl=30)

    if audit_df.empty:
        st.info("No audit records yet.")
    else:
        for _, au in audit_df.iterrows():
            ts_display = time_ago(au["TS"])
            detail_str = ""
            if au["DETAIL"]:
                try:
                    d = json.loads(au["DETAIL"]) if isinstance(au["DETAIL"], str) else au["DETAIL"]
                    if isinstance(d, dict) and d:
                        detail_str = " \u2014 " + ", ".join(f"{k}: {v}" for k, v in d.items() if v)
                except Exception:
                    detail_str = f" \u2014 {au['DETAIL']}"
            st.markdown(
                f'<div class="info-card">'
                f'<strong>{au["ACTION"]}</strong> on {au["OBJECT_REF"]} '
                f'by {au["ACTOR"]} ({ts_display}){detail_str}'
                f'</div>',
                unsafe_allow_html=True,
            )
