import streamlit as st
import pandas as pd
import altair as alt
from datetime import date, timedelta
from utils import apply_theme, render_header, render_kpi_card, render_sidebar, run_query, info_tooltip

apply_theme()
render_sidebar()
render_header("Executive OEE", "Plant-wide OEE trends and loss analysis")

# Date range selector
col_d1, col_d2 = st.columns(2)
with col_d1:
    start_date = st.date_input("Start Date", value=date.today() - timedelta(days=7))
with col_d2:
    end_date = st.date_input("End Date", value=date.today())

start_str = start_date.strftime("%Y-%m-%d")
end_str = end_date.strftime("%Y-%m-%d")

# Fetch current period OEE
with st.spinner("Loading OEE data..."):
    oee_df = run_query(f"""
        SELECT LINE_ID, ASSET_ID, SHIFT_DATE, SHIFT_CODE,
               AVAILABILITY, PERFORMANCE, QUALITY, OEE,
               PLANNED_MIN, DOWNTIME_MIN, RUN_MIN,
               TOTAL_COUNT, GOOD_COUNT, REJECT_COUNT
        FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
        WHERE SHIFT_DATE >= '{start_str}' AND SHIFT_DATE <= '{end_str}'
        ORDER BY SHIFT_DATE, SHIFT_CODE, LINE_ID
    """)

if oee_df.empty:
    st.warning("No OEE data for the selected period.")
    st.stop()

# Prior period for delta calculation
days_span = (end_date - start_date).days + 1
prior_start = (start_date - timedelta(days=days_span)).strftime("%Y-%m-%d")
prior_end = (start_date - timedelta(days=1)).strftime("%Y-%m-%d")

prior_df = run_query(f"""
    SELECT AVG(OEE) AS AVG_OEE, AVG(AVAILABILITY) AS AVG_A,
           AVG(PERFORMANCE) AS AVG_P, AVG(QUALITY) AS AVG_Q
    FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
    WHERE SHIFT_DATE >= '{prior_start}' AND SHIFT_DATE <= '{prior_end}'
""")

curr_oee = float(oee_df["OEE"].mean())
curr_a = float(oee_df["AVAILABILITY"].mean())
curr_p = float(oee_df["PERFORMANCE"].mean())
curr_q = float(oee_df["QUALITY"].mean())

delta_oee = delta_a = delta_p = delta_q = None
if not prior_df.empty and prior_df["AVG_OEE"].iloc[0] is not None:
    delta_oee = curr_oee - float(prior_df["AVG_OEE"].iloc[0])
    delta_a = curr_a - float(prior_df["AVG_A"].iloc[0])
    delta_p = curr_p - float(prior_df["AVG_P"].iloc[0])
    delta_q = curr_q - float(prior_df["AVG_Q"].iloc[0])

# KPI cards
st.markdown(f"#### KPI Summary {info_tooltip('Average OEE and its components (Availability, Performance, Quality) for the selected period. Delta shows change vs the same-length prior period. OEE = A x P x Q. Source: SEMANTIC.DT_SHIFT_OEE')}", unsafe_allow_html=True)
k1, k2, k3, k4 = st.columns(4)
with k1:
    render_kpi_card("Overall OEE", curr_oee, delta=delta_oee, fmt="pct")
with k2:
    render_kpi_card("Availability", curr_a, delta=delta_a, fmt="pct")
with k3:
    render_kpi_card("Performance", curr_p, delta=delta_p, fmt="pct")
with k4:
    render_kpi_card("Quality", curr_q, delta=delta_q, fmt="pct")

st.divider()

# Line comparison
st.markdown(f"### OEE by Production Line {info_tooltip('Grouped bar chart comparing average OEE, Availability, Performance, and Quality per production line for the selected date range. Source: SEMANTIC.DT_SHIFT_OEE aggregated by LINE_ID.')}", unsafe_allow_html=True)
line_oee = oee_df.groupby("LINE_ID").agg({"OEE": "mean", "AVAILABILITY": "mean", "PERFORMANCE": "mean", "QUALITY": "mean"}).reset_index()

bar_data = line_oee.melt(id_vars=["LINE_ID"], value_vars=["OEE", "AVAILABILITY", "PERFORMANCE", "QUALITY"], var_name="Metric", value_name="Value")

bar_chart = (
    alt.Chart(bar_data)
    .mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4)
    .encode(
        x=alt.X("Metric:N", title=None, axis=alt.Axis(labelAngle=0)),
        y=alt.Y("Value:Q", title="Value", scale=alt.Scale(domain=[0, 1])),
        color=alt.Color(
            "Metric:N",
            scale=alt.Scale(
                domain=["OEE", "AVAILABILITY", "PERFORMANCE", "QUALITY"],
                range=["#f0a500", "#0f9b8e", "#29B5E8", "#8892b0"],
            ),
            legend=None,
        ),
        column=alt.Column("LINE_ID:N", title="Production Line"),
        tooltip=["LINE_ID", "Metric", alt.Tooltip("Value:Q", format=".1%")],
    )
    .properties(height=300, width=200)
)
st.altair_chart(bar_chart)

st.divider()

# OEE trend chart
st.markdown(f"### OEE Trend (A / P / Q) {info_tooltip('Daily average of OEE and its three components over the selected period. Helps identify degradation patterns. Source: SEMANTIC.DT_SHIFT_OEE aggregated by SHIFT_DATE.')}", unsafe_allow_html=True)
daily_trend = (
    oee_df.groupby("SHIFT_DATE")
    .agg({"OEE": "mean", "AVAILABILITY": "mean", "PERFORMANCE": "mean", "QUALITY": "mean"})
    .reset_index()
)
daily_trend["SHIFT_DATE"] = pd.to_datetime(daily_trend["SHIFT_DATE"])

trend_data = daily_trend.melt(
    id_vars=["SHIFT_DATE"],
    value_vars=["OEE", "AVAILABILITY", "PERFORMANCE", "QUALITY"],
    var_name="Metric",
    value_name="Value",
)

trend_chart = (
    alt.Chart(trend_data)
    .mark_line(point=True, strokeWidth=2)
    .encode(
        x=alt.X("SHIFT_DATE:T", title="Date"),
        y=alt.Y("Value:Q", title="Value", scale=alt.Scale(domain=[0, 1])),
        color=alt.Color(
            "Metric:N",
            scale=alt.Scale(
                domain=["OEE", "AVAILABILITY", "PERFORMANCE", "QUALITY"],
                range=["#f0a500", "#0f9b8e", "#29B5E8", "#8892b0"],
            ),
        ),
        tooltip=["SHIFT_DATE:T", "Metric", alt.Tooltip("Value:Q", format=".1%")],
    )
    .properties(height=350)
)
st.altair_chart(trend_chart, use_container_width=True)

st.divider()

# Six big losses waterfall
st.markdown(f"### Six Big Losses {info_tooltip('Total minutes lost to each loss category: Breakdown (unplanned downtime), Speed (reduced cycle time), Quality (rejects). Based on the ISA-95 six big losses framework. Source: SEMANTIC.V_SIX_BIG_LOSSES.')}", unsafe_allow_html=True)
try:
    loss_df = run_query(f"""
        SELECT LINE_ID, ASSET_ID, SHIFT_DATE,
               BREAKDOWN_LOSS_MIN, SPEED_LOSS_MIN, QUALITY_LOSS_MIN,
               FULLY_PRODUCTIVE_MIN, RUN_MIN
        FROM AEGIS_OEE.SEMANTIC.V_SIX_BIG_LOSSES
        WHERE SHIFT_DATE >= '{start_str}' AND SHIFT_DATE <= '{end_str}'
    """)
    if not loss_df.empty:
        loss_agg = pd.DataFrame({
            "Loss Type": ["Breakdown Loss", "Speed Loss", "Quality Loss"],
            "Minutes": [
                float(loss_df["BREAKDOWN_LOSS_MIN"].sum()),
                float(loss_df["SPEED_LOSS_MIN"].sum()),
                float(loss_df["QUALITY_LOSS_MIN"].sum()),
            ],
        })

        loss_chart = (
            alt.Chart(loss_agg)
            .mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4)
            .encode(
                x=alt.X("Loss Type:N", sort=["Breakdown Loss", "Speed Loss", "Quality Loss"], title="Loss Category"),
                y=alt.Y("Minutes:Q", title="Total Minutes Lost"),
                color=alt.Color(
                    "Loss Type:N",
                    scale=alt.Scale(
                        domain=["Breakdown Loss", "Speed Loss", "Quality Loss"],
                        range=["#e74c3c", "#f0a500", "#29B5E8"],
                    ),
                    legend=None,
                ),
                tooltip=["Loss Type", alt.Tooltip("Minutes:Q", format=",.0f")],
            )
            .properties(height=300)
        )
        st.altair_chart(loss_chart, use_container_width=True)
    else:
        st.info("No loss data available for the selected period.")
except Exception as e:
    st.warning(f"Could not load six-big-losses: {e}")

st.divider()

# OEE at risk
st.markdown(f"### OEE at Risk {info_tooltip('Estimated OEE impact if all currently active alert predictions materialize. Calculated as the sum of OEE_IMPACT_EST across open alerts. Source: ACTION.ALERT.')}", unsafe_allow_html=True)
try:
    risk_df = run_query("""
        SELECT SUM(OEE_IMPACT_EST) AS TOTAL_RISK
        FROM AEGIS_OEE.ACTION.ALERT
        WHERE STATUS NOT IN ('CLOSED', 'SUPPRESSED')
    """)
    if not risk_df.empty and risk_df["TOTAL_RISK"].iloc[0] is not None:
        risk_val = float(risk_df["TOTAL_RISK"].iloc[0])
        st.markdown(
            f'<div class="info-card">'
            f'<span style="color:#e74c3c; font-size:1.5rem; font-weight:700;">{risk_val * 100:.1f}%</span> '
            f'<span style="color:#8892b0;"> estimated OEE impact from active alerts</span>'
            f'</div>',
            unsafe_allow_html=True,
        )
        st.caption("Sum of OEE_IMPACT_EST across all open alerts. If predicted failures materialize, "
                    f"plant OEE could drop from {curr_oee * 100:.1f}% to {max(0, (curr_oee - risk_val)) * 100:.1f}%.")
    else:
        st.success("No OEE at risk \u2014 no active alerts.")
except Exception as e:
    st.warning(f"Could not load OEE-at-risk: {e}")
