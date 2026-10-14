import streamlit as st
import pandas as pd
from utils import (refresh_page, flash, 
    apply_theme, render_header, render_sidebar, run_query,
    severity_badge, time_ago, get_session, write_audit, info_tooltip,
    format_failure_eta, FAILURE_ETA_HELP, render_kpi_card,
    FAILURE_PROB_HELP, OEE_IMPACT_HELP, ALERT_STATUS_HELP, SEVERITY_HELP,
    CONFIDENCE_HELP, PREDICTED_MODE_HELP,
)

apply_theme()
render_sidebar()
render_header("Alert Triage", "Ranked open alerts \u2014 acknowledge, investigate, or suppress")

with st.spinner("Loading alerts..."):
    alerts_df = run_query("""
        SELECT ALERT_ID, ASSET_ID, ONSET_TS, SEVERITY, CONFIDENCE,
               FAILURE_PROBABILITY, PREDICTED_MODE, OEE_IMPACT_EST, STATUS, EVIDENCE, PREDICTED_FAILURE_TS
        FROM AEGIS_OEE.ACTION.ALERT
        WHERE STATUS NOT IN ('CLOSED', 'SUPPRESSED')
        ORDER BY
            CASE SEVERITY WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
            FAILURE_PROBABILITY DESC
    """, ttl=30)

if alerts_df.empty:
    st.success("No open alerts \u2014 plant healthy \u2713")
    st.stop()

st.markdown(f"**{len(alerts_df)}** open alert(s)")
st.markdown(f"Alerts ranked by severity (P1 > P2 > P3) then failure probability. {info_tooltip('Each alert represents a predicted failure mode detected by the ML anomaly detection and z-score persistence models. Confidence combines model confidence, data quality, and evidence agreement. Actions: Acknowledge to mark for work order creation, Investigate to view sensor data, Suppress to dismiss with a reason. All actions are logged to ACTION.ACTION_AUDIT.')}", unsafe_allow_html=True)

for idx, row in alerts_df.iterrows():
    alert_id = row["ALERT_ID"]
    key_id = f"{idx}_{alert_id}"
    sev = row["SEVERITY"]
    asset = row["ASSET_ID"]
    mode = row["PREDICTED_MODE"]
    conf = float(row["CONFIDENCE"]) * 100 if row["CONFIDENCE"] else 0
    fp = float(row["FAILURE_PROBABILITY"]) * 100 if row["FAILURE_PROBABILITY"] else 0
    impact = float(row["OEE_IMPACT_EST"]) * 100 if row["OEE_IMPACT_EST"] else 0
    onset = time_ago(row["ONSET_TS"])
    status = row["STATUS"]

    with st.expander(f"{sev} | {asset} \u2014 {mode} (conf {conf:.0f}%) \u2014 {onset}", expanded=(sev == "P1")):
        c1, c2, c3, c4 = st.columns(4)
        c1.markdown(f"**Severity:** {severity_badge(sev)} {info_tooltip(SEVERITY_HELP)}", unsafe_allow_html=True)
        with c2:
            render_kpi_card("Failure Prob.", fp / 100, fmt="pct", help=FAILURE_PROB_HELP)
        with c3:
            render_kpi_card("OEE Impact", impact / 100, fmt="pct", help=OEE_IMPACT_HELP)
        with c4:
            render_kpi_card("Status", status, fmt="text", help=ALERT_STATUS_HELP)

        st.markdown(
            f"**Asset:** {asset} | **Mode:** {mode} {info_tooltip(PREDICTED_MODE_HELP)} | "
            f"**Confidence:** {conf:.0f}% {info_tooltip(CONFIDENCE_HELP)} | **Onset:** {onset}",
            unsafe_allow_html=True,
        )
        st.markdown(f"**Predicted failure by:** {format_failure_eta(row['PREDICTED_FAILURE_TS'])} {info_tooltip(FAILURE_ETA_HELP)}", unsafe_allow_html=True)

        # Evidence (shown inline, not nested expander)
        if row["EVIDENCE"]:
            show_ev = st.checkbox("Show evidence", key=f"ev_{key_id}")
            if show_ev:
                st.json(row["EVIDENCE"])

        # Actions
        act_cols = st.columns(3)
        with act_cols[0]:
            if status in ("NEW", "TRIAGED"):
                if st.button("Acknowledge", key=f"ack_{key_id}"):
                    try:
                        session = get_session()
                        session.sql(f"""
                            UPDATE AEGIS_OEE.ACTION.ALERT
                            SET STATUS = 'ACKED'
                            WHERE ALERT_ID = '{alert_id}' AND STATUS IN ('NEW', 'TRIAGED')
                        """).collect()
                        write_audit(session, "APP_USER", "ALERT_ACKED", alert_id)
                        flash(f"Alert {alert_id} acknowledged. Open Work Order Review to approve it.")
                    except Exception as e:
                        st.error(f"Error: {e}")
                    else:
                        refresh_page()
            elif status == "ACKED":
                st.success("Acknowledged — proceed to Work Order Review")
            else:
                st.info(f"Status: {status}")

        with act_cols[1]:
            if st.button("Investigate", key=f"inv_{key_id}"):
                st.session_state["twin_asset"] = asset
                st.info(f"Navigate to Asset Digital Twin page and select {asset}.")

        with act_cols[2]:
            with st.form(f"form_sup_{key_id}"):
                reason = st.text_input("Suppress reason", key=f"sup_reason_{key_id}")
                confirm = st.checkbox("Confirm", key=f"sup_confirm_{key_id}")
                if st.form_submit_button("Suppress"):
                    if not confirm:
                        st.warning("Check the confirmation box first.")
                    elif not reason.strip():
                        st.warning("Provide a reason.")
                    else:
                        try:
                            session = get_session()
                            safe_reason = reason.replace("'", "''")
                            session.sql(f"""
                                UPDATE AEGIS_OEE.ACTION.ALERT
                                SET STATUS = 'SUPPRESSED'
                                WHERE ALERT_ID = '{alert_id}' AND STATUS NOT IN ('CLOSED', 'SUPPRESSED')
                            """).collect()
                            write_audit(
                                session, "APP_USER", "ALERT_SUPPRESSED", alert_id,
                                '{"reason":"' + safe_reason + '"}'
                            )
                            flash(f"Alert {alert_id} suppressed.")
                        except Exception as e:
                            st.error(f"Error: {e}")
                        else:
                            refresh_page()
