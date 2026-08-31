import streamlit as st
import pandas as pd
import altair as alt
from utils import (
    apply_theme, render_header, render_sidebar, render_kpi_card,
    run_query, risk_badge, time_ago, info_tooltip,
)

apply_theme()
render_sidebar()
render_header("Asset Digital Twin", "Sensor trends, anomalies, forecasts, and health per asset")

# Asset selector with filters
all_assets = run_query("SELECT ASSET_ID, LINE_ID, SITE_ID, ASSET_TYPE FROM AEGIS_OEE.CORE.ASSET ORDER BY LINE_ID, ASSET_ID")

fc1, fc2, fc3 = st.columns(3)
with fc1:
    lines = ["All"] + sorted(all_assets["LINE_ID"].unique().tolist())
    sel_line = st.selectbox("Line", lines, key="twin_line_filter")
with fc2:
    sites = ["All"] + sorted(all_assets["SITE_ID"].unique().tolist())
    sel_site = st.selectbox("Area", sites, key="twin_site_filter")
with fc3:
    types = ["All"] + sorted(all_assets["ASSET_TYPE"].unique().tolist())
    sel_type = st.selectbox("Asset Type", types, key="twin_type_filter")

filtered = all_assets.copy()
if sel_line != "All":
    filtered = filtered[filtered["LINE_ID"] == sel_line]
if sel_site != "All":
    filtered = filtered[filtered["SITE_ID"] == sel_site]
if sel_type != "All":
    filtered = filtered[filtered["ASSET_TYPE"] == sel_type]

asset_list = filtered["ASSET_ID"].tolist()

assets_df = run_query("SELECT ASSET_ID, LINE_ID, ASSET_TYPE, CRITICALITY, VIB_ALERT_MM_S, VIB_DANGER_MM_S, TEMP_LIMIT_C FROM AEGIS_OEE.CORE.ASSET ORDER BY CRITICALITY DESC, ASSET_ID")

default_asset = "CNC_01_SPINDLE"
if "twin_asset" in st.session_state and st.session_state["twin_asset"] in asset_list:
    default_asset = st.session_state["twin_asset"]

default_idx = asset_list.index(default_asset) if default_asset in asset_list else 0
selected_asset = st.selectbox("Select Asset", asset_list, index=default_idx)
asset_info = assets_df[assets_df["ASSET_ID"] == selected_asset].iloc[0]

# Health gauge
with st.spinner("Loading asset health..."):
    health_df = run_query(f"""
        SELECT HEALTH_SCORE, ANOMALY_DISTANCE, FAILURE_PROBABILITY_24H,
               PREDICTED_MODE, RISK_LEVEL, LAST_READING_TS
        FROM AEGIS_OEE.FEATURES.DT_ASSET_HEALTH
        WHERE ASSET_ID = '{selected_asset}'
    """, ttl=60)

h1, h2, h3, h4 = st.columns(4)
if not health_df.empty:
    hr = health_df.iloc[0]
    hs = float(hr["HEALTH_SCORE"]) if hr["HEALTH_SCORE"] is not None else 100
    fp = float(hr["FAILURE_PROBABILITY_24H"]) if hr["FAILURE_PROBABILITY_24H"] is not None else 0
    pred_mode = hr["PREDICTED_MODE"] if hr["PREDICTED_MODE"] else "None"
    rl = hr["RISK_LEVEL"] if hr["RISK_LEVEL"] else "LOW"
    with h1:
        render_kpi_card("Health Score", hs, fmt="score")
    with h2:
        render_kpi_card("Failure Prob (24h)", fp, fmt="pct")
    with h3:
        st.markdown(f'**Risk Level:** {risk_badge(rl)}', unsafe_allow_html=True)
        st.markdown(f"**Predicted Mode:** {pred_mode}")
    with h4:
        st.markdown(f"**Line:** {asset_info['LINE_ID']}")
        st.markdown(f"**Type:** {asset_info['ASSET_TYPE']}")
        st.markdown(f"**Criticality:** {int(asset_info['CRITICALITY'])}/5")
else:
    with h1:
        render_kpi_card("Health Score", 100, fmt="score")
    with h2:
        render_kpi_card("Failure Prob (24h)", 0, fmt="pct")
    with h3:
        st.markdown(f'**Risk Level:** {risk_badge("LOW")}', unsafe_allow_html=True)
    with h4:
        st.markdown(f"**Line:** {asset_info['LINE_ID']}")

st.divider()

# Sensor trends (last 24h)
st.markdown("### Sensor Trends (Last 24h)")
sensor_df = run_query(f"""
    SELECT WINDOW_TS, VIB_RMS_MEAN, TEMP_C_MEAN, RPM_MEAN,
           VIB_RMS_ZSCORE, TEMP_C_ZSCORE, RPM_ZSCORE
    FROM AEGIS_OEE.FEATURES.DT_SENSOR_FEATURES_15MIN
    WHERE ASSET_ID = '{selected_asset}'
      AND WINDOW_TS >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
    ORDER BY WINDOW_TS
""", ttl=60)

# Anomaly markers
anomaly_df = run_query(f"""
    SELECT TS, SERIES_NAME, DISTANCE, IS_ANOMALY
    FROM AEGIS_OEE.ML.ANOMALY_EVENTS
    WHERE ASSET_ID = '{selected_asset}'
      AND IS_ANOMALY = TRUE
      AND TS >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
    ORDER BY TS
""", ttl=60)

# Forecast bands
forecast_df = run_query(f"""
    SELECT TS, SERIES_TYPE, FORECAST, LOWER_BOUND, UPPER_BOUND
    FROM AEGIS_OEE.ML.SIGNAL_FORECASTS
    WHERE SERIES_ID = '{selected_asset}'
      AND TS >= DATEADD('hour', -24, CURRENT_TIMESTAMP)
    ORDER BY TS
""", ttl=60)

vib_alert = float(asset_info["VIB_ALERT_MM_S"]) if asset_info["VIB_ALERT_MM_S"] else None
vib_danger = float(asset_info["VIB_DANGER_MM_S"]) if asset_info["VIB_DANGER_MM_S"] else None
temp_limit = float(asset_info["TEMP_LIMIT_C"]) if asset_info["TEMP_LIMIT_C"] else None

if not sensor_df.empty:
    sensor_df["WINDOW_TS"] = pd.to_datetime(sensor_df["WINDOW_TS"].astype(str).str.slice(0, 19))

    # Vibration chart
    st.markdown(f"#### Vibration RMS (mm/s) {info_tooltip('15-minute rolling mean vibration (mm/s). Orange dashed line = alert threshold (ISO 10816), red dashed = danger threshold. Red dots = anomalies detected by ML models. Shaded band = 24h forecast with confidence interval. Source: FEATURES.DT_SENSOR_FEATURES_15MIN, ML.ANOMALY_EVENTS, ML.SIGNAL_FORECASTS.')}", unsafe_allow_html=True)
    vib_line = (
        alt.Chart(sensor_df)
        .mark_line(color="#f0a500", strokeWidth=2)
        .encode(
            x=alt.X("WINDOW_TS:T", title="Time"),
            y=alt.Y("VIB_RMS_MEAN:Q", title="Vibration RMS (mm/s)"),
            tooltip=["WINDOW_TS:T", alt.Tooltip("VIB_RMS_MEAN:Q", format=".2f")],
        )
    )
    layers = [vib_line]

    # Threshold lines
    if vib_alert:
        alert_rule = alt.Chart(pd.DataFrame({"y": [vib_alert]})).mark_rule(color="#f0a500", strokeDash=[5, 5], strokeWidth=1).encode(y="y:Q")
        layers.append(alert_rule)
    if vib_danger:
        danger_rule = alt.Chart(pd.DataFrame({"y": [vib_danger]})).mark_rule(color="#e74c3c", strokeDash=[5, 5], strokeWidth=1).encode(y="y:Q")
        layers.append(danger_rule)

    # Anomaly points on vibration
    vib_anomalies = anomaly_df[anomaly_df["SERIES_NAME"] == "vibration_rms"] if not anomaly_df.empty else pd.DataFrame()
    if not vib_anomalies.empty:
        vib_anomalies = vib_anomalies.copy()
        vib_anomalies["TS"] = pd.to_datetime(vib_anomalies["TS"].astype(str).str.slice(0, 19))
        vib_anomalies = vib_anomalies.merge(
            sensor_df[["WINDOW_TS", "VIB_RMS_MEAN"]],
            left_on="TS", right_on="WINDOW_TS", how="inner",
        )
        if not vib_anomalies.empty:
            anomaly_pts = (
                alt.Chart(vib_anomalies)
                .mark_circle(size=80, color="#e74c3c")
                .encode(x="TS:T", y="VIB_RMS_MEAN:Q", tooltip=["TS:T", alt.Tooltip("DISTANCE:Q", format=".2f")])
            )
            layers.append(anomaly_pts)

    # Forecast band
    vib_fc = forecast_df[forecast_df["SERIES_TYPE"] == "vibration_rms"] if not forecast_df.empty else pd.DataFrame()
    if not vib_fc.empty:
        vib_fc = vib_fc.copy()
        vib_fc["TS"] = pd.to_datetime(vib_fc["TS"].astype(str).str.slice(0, 19))
        fc_area = (
            alt.Chart(vib_fc)
            .mark_area(opacity=0.15, color="#f0a500")
            .encode(x="TS:T", y="LOWER_BOUND:Q", y2="UPPER_BOUND:Q")
        )
        fc_line = (
            alt.Chart(vib_fc)
            .mark_line(color="#f0a500", strokeDash=[4, 4], strokeWidth=1)
            .encode(x="TS:T", y="FORECAST:Q")
        )
        layers.extend([fc_area, fc_line])

    st.altair_chart(alt.layer(*layers).properties(height=280), use_container_width=True)

    # Temperature chart
    st.markdown(f"#### Temperature (\u00b0C) {info_tooltip('15-minute rolling mean temperature. Red dashed line = asset thermal limit. Red dots = detected anomalies. Shaded band = forecast. Source: FEATURES.DT_SENSOR_FEATURES_15MIN.')}", unsafe_allow_html=True)
    temp_line = (
        alt.Chart(sensor_df)
        .mark_line(color="#0f9b8e", strokeWidth=2)
        .encode(
            x=alt.X("WINDOW_TS:T", title="Time"),
            y=alt.Y("TEMP_C_MEAN:Q", title="Temperature (\u00b0C)"),
            tooltip=["WINDOW_TS:T", alt.Tooltip("TEMP_C_MEAN:Q", format=".1f")],
        )
    )
    temp_layers = [temp_line]
    if temp_limit:
        temp_rule = alt.Chart(pd.DataFrame({"y": [temp_limit]})).mark_rule(color="#e74c3c", strokeDash=[5, 5], strokeWidth=1).encode(y="y:Q")
        temp_layers.append(temp_rule)

    temp_anomalies = anomaly_df[anomaly_df["SERIES_NAME"] == "temp_c"] if not anomaly_df.empty else pd.DataFrame()
    if not temp_anomalies.empty:
        temp_anomalies = temp_anomalies.copy()
        temp_anomalies["TS"] = pd.to_datetime(temp_anomalies["TS"].astype(str).str.slice(0, 19))
        temp_anomalies = temp_anomalies.merge(
            sensor_df[["WINDOW_TS", "TEMP_C_MEAN"]],
            left_on="TS", right_on="WINDOW_TS", how="inner",
        )
        if not temp_anomalies.empty:
            ta_pts = alt.Chart(temp_anomalies).mark_circle(size=80, color="#e74c3c").encode(x="TS:T", y="TEMP_C_MEAN:Q")
            temp_layers.append(ta_pts)

    temp_fc = forecast_df[forecast_df["SERIES_TYPE"] == "temp_c"] if not forecast_df.empty else pd.DataFrame()
    if not temp_fc.empty:
        temp_fc = temp_fc.copy()
        temp_fc["TS"] = pd.to_datetime(temp_fc["TS"].astype(str).str.slice(0, 19))
        temp_layers.append(alt.Chart(temp_fc).mark_area(opacity=0.15, color="#0f9b8e").encode(x="TS:T", y="LOWER_BOUND:Q", y2="UPPER_BOUND:Q"))
        temp_layers.append(alt.Chart(temp_fc).mark_line(color="#0f9b8e", strokeDash=[4, 4], strokeWidth=1).encode(x="TS:T", y="FORECAST:Q"))

    st.altair_chart(alt.layer(*temp_layers).properties(height=280), use_container_width=True)

    # RPM chart
    st.markdown(f"#### RPM {info_tooltip('15-minute rolling mean RPM. Instability (oscillation) may indicate drive or belt issues. Source: FEATURES.DT_SENSOR_FEATURES_15MIN.')}", unsafe_allow_html=True)
    rpm_line = (
        alt.Chart(sensor_df)
        .mark_line(color="#29B5E8", strokeWidth=2)
        .encode(
            x=alt.X("WINDOW_TS:T", title="Time"),
            y=alt.Y("RPM_MEAN:Q", title="RPM"),
            tooltip=["WINDOW_TS:T", alt.Tooltip("RPM_MEAN:Q", format=".0f")],
        )
    )
    st.altair_chart(rpm_line.properties(height=280), use_container_width=True)
else:
    st.info("No sensor data available for the last 24 hours.")

st.divider()

# Maintenance history
st.markdown(f"### Maintenance History {info_tooltip('Past maintenance work orders for this asset showing completion date, failure code, findings, and actions taken. Source: CORE.MAINTENANCE_HISTORY.')}", unsafe_allow_html=True)
maint_df = run_query(f"""
    SELECT WO_HIST_ID, COMPLETED_TS, FAILURE_CODE, FINDING, ACTION_TAKEN, PARTS_USED, LABOR_HOURS
    FROM AEGIS_OEE.CORE.MAINTENANCE_HISTORY
    WHERE ASSET_ID = '{selected_asset}'
    ORDER BY COMPLETED_TS DESC
    LIMIT 10
""")
if not maint_df.empty:
    st.dataframe(maint_df, use_container_width=True)
else:
    st.info("No maintenance history for this asset.")

# Open work orders
st.markdown(f"### Open Work Orders {info_tooltip('Currently active (non-closed, non-rejected) work orders for this asset. Source: ACTION.WORK_ORDER.')}", unsafe_allow_html=True)
wo_df = run_query(f"""
    SELECT WO_ID, PRIORITY, STATE, TITLE, APPROVED_BY, APPROVED_TS
    FROM AEGIS_OEE.ACTION.WORK_ORDER
    WHERE ASSET_ID = '{selected_asset}' AND STATE NOT IN ('CLOSED', 'REJECTED')
    ORDER BY APPROVED_TS DESC
""")
if not wo_df.empty:
    st.dataframe(wo_df, use_container_width=True)
else:
    st.info("No open work orders for this asset.")

# Top anomaly drivers
st.markdown(f"### Top Anomaly Drivers (Last 7 Days) {info_tooltip('Which signal series (vibration, temperature, RPM) has the most anomaly detections in the last 7 days for this asset. Helps identify the dominant degradation signature. Source: ML.ANOMALY_EVENTS.')}", unsafe_allow_html=True)
drivers_df = run_query(f"""
    SELECT SERIES_NAME, COUNT(*) AS ANOMALY_COUNT, AVG(ABS(DISTANCE)) AS AVG_DISTANCE
    FROM AEGIS_OEE.ML.ANOMALY_EVENTS
    WHERE ASSET_ID = '{selected_asset}' AND IS_ANOMALY = TRUE
      AND TS >= DATEADD('day', -7, CURRENT_TIMESTAMP)
    GROUP BY SERIES_NAME
    ORDER BY ANOMALY_COUNT DESC
""")
if not drivers_df.empty:
    for _, dr in drivers_df.iterrows():
        st.markdown(
            f'<div class="info-card">'
            f'<strong>{dr["SERIES_NAME"]}</strong>: {int(dr["ANOMALY_COUNT"])} anomalies '
            f'(avg distance {float(dr["AVG_DISTANCE"]):.2f})'
            f'</div>',
            unsafe_allow_html=True,
        )
else:
    st.success("No anomalies detected in the last 7 days.")
