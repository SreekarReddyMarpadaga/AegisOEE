import streamlit as st
from utils import apply_theme, render_header, render_kpi_card, render_sidebar, run_query, info_tooltip

st.set_page_config(
    page_title="Home",
    layout="wide",
    initial_sidebar_state="expanded",
)

apply_theme()
render_sidebar()
render_header(
    "AegisOEE Command Center",
    "HYD_PRECISION \u2014 Precision Components",
)

# Quick KPI overview
with st.spinner("Loading plant overview..."):
    try:
        oee_df = run_query("""
            SELECT AVG(OEE) AS AVG_OEE,
                   AVG(AVAILABILITY) AS AVG_A,
                   AVG(PERFORMANCE) AS AVG_P,
                   AVG(QUALITY) AS AVG_Q
            FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
            WHERE SHIFT_DATE = (SELECT MAX(SHIFT_DATE) FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE)
        """)
        alert_df = run_query("""
            SELECT COUNT(*) AS CNT
            FROM AEGIS_OEE.ACTION.ALERT
            WHERE STATUS NOT IN ('CLOSED', 'SUPPRESSED')
        """)
        wo_df = run_query("""
            SELECT COUNT(*) AS CNT
            FROM AEGIS_OEE.ACTION.WORK_ORDER
            WHERE STATE NOT IN ('CLOSED', 'REJECTED')
        """)

        c1, c2, c3, c4 = st.columns(4)
        with c1:
            val = float(oee_df["AVG_OEE"].iloc[0]) if not oee_df.empty else 0
            render_kpi_card("Plant OEE (Latest Day)", val, fmt="pct")
        with c2:
            val = int(alert_df["CNT"].iloc[0]) if not alert_df.empty else 0
            render_kpi_card("Active Alerts", val, fmt="int")
        with c3:
            val = int(wo_df["CNT"].iloc[0]) if not wo_df.empty else 0
            render_kpi_card("Open Work Orders", val, fmt="int")
        with c4:
            a_val = float(oee_df["AVG_A"].iloc[0]) if not oee_df.empty else 0
            render_kpi_card("Availability", a_val, fmt="pct")
    except Exception as e:
        st.error(f"Error loading KPIs: {e}")

st.divider()

# Recent alerts summary
st.markdown(f"### Recent Alerts {info_tooltip('Open alerts ranked by severity and failure probability. Source: ACTION.ALERT table, filtered to exclude CLOSED and SUPPRESSED statuses.')}", unsafe_allow_html=True)
try:
    recent_alerts = run_query("""
        SELECT ALERT_ID, ASSET_ID, SEVERITY, PREDICTED_MODE, CONFIDENCE, STATUS, ONSET_TS
        FROM AEGIS_OEE.ACTION.ALERT
        WHERE STATUS NOT IN ('CLOSED', 'SUPPRESSED')
        ORDER BY
            CASE SEVERITY WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 3 END,
            FAILURE_PROBABILITY DESC
        LIMIT 5
    """)
    if recent_alerts.empty:
        st.success("No open alerts \u2014 plant healthy \u2713")
    else:
        for _, row in recent_alerts.iterrows():
            sev = row["SEVERITY"]
            sev_cls = {"P1": "severity-p1", "P2": "severity-p2", "P3": "severity-p3"}.get(sev, "severity-p3")
            conf = float(row["CONFIDENCE"]) * 100 if row["CONFIDENCE"] else 0
            st.markdown(
                f'<div class="info-card">'
                f'<span class="{sev_cls}">{sev}</span> '
                f'<strong>{row["ASSET_ID"]}</strong> \u2014 {row["PREDICTED_MODE"]} '
                f'(confidence {conf:.0f}%) \u2014 status: {row["STATUS"]}'
                f'</div>',
                unsafe_allow_html=True,
            )
except Exception as e:
    st.warning(f"Could not load alerts: {e}")
