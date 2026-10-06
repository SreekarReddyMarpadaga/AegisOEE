import streamlit as st
import pandas as pd
from utils import apply_theme, render_header, render_sidebar, run_query, info_tooltip, risk_badge

apply_theme()
render_sidebar()
render_header("Asset Map", "ISA-95 plant hierarchy — area, line, asset health overview")

asset_df = run_query("""
    SELECT A.ASSET_ID, A.LINE_ID, A.SITE_ID, A.ASSET_TYPE, A.CRITICALITY,
           H.HEALTH_SCORE, H.RISK_LEVEL, H.FAILURE_PROBABILITY_24H, H.PREDICTED_MODE,
           COALESCE(OEE.AVG_OEE, 0) AS AVG_OEE,
           COALESCE(ALT.ALERT_COUNT, 0) AS OPEN_ALERTS
    FROM AEGIS_OEE.CORE.ASSET A
    LEFT JOIN AEGIS_OEE.FEATURES.DT_ASSET_HEALTH H ON A.ASSET_ID = H.ASSET_ID
    LEFT JOIN (
        SELECT ASSET_ID, AVG(OEE) AS AVG_OEE
        FROM AEGIS_OEE.SEMANTIC.DT_SHIFT_OEE
        WHERE SHIFT_DATE >= DATEADD('day', -7, CURRENT_DATE)
        GROUP BY ASSET_ID
    ) OEE ON A.ASSET_ID = OEE.ASSET_ID
    LEFT JOIN (
        SELECT ASSET_ID, COUNT(*) AS ALERT_COUNT
        FROM AEGIS_OEE.ACTION.ALERT
        WHERE STATUS NOT IN ('CLOSED', 'SUPPRESSED')
        GROUP BY ASSET_ID
    ) ALT ON A.ASSET_ID = ALT.ASSET_ID
    ORDER BY A.LINE_ID, A.ASSET_ID
""")

if asset_df.empty:
    st.warning("No asset data available.")
    st.stop()

# Plant hierarchy as HTML bar chart
st.markdown(f"### Plant Hierarchy {info_tooltip('ISA-95 hierarchy: Site > Line > Asset. Tile color = health score (green=healthy, amber=warning, red=critical). Health is real-time (latest from DT_ASSET_HEALTH). OEE is 7-day rolling average. Source: CORE.ASSET, FEATURES.DT_ASSET_HEALTH, SEMANTIC.DT_SHIFT_OEE.')}", unsafe_allow_html=True)
st.caption("Health: real-time · OEE: 7-day average")

tree_df = asset_df.copy()
tree_df["HEALTH_SCORE"] = tree_df["HEALTH_SCORE"].fillna(50).astype(float)
tree_df["CRITICALITY"] = tree_df["CRITICALITY"].fillna(1).astype(int)

def health_bg(score):
    if score >= 70:
        return "rgba(15,155,142,0.25)"
    elif score >= 40:
        return "rgba(240,165,0,0.25)"
    return "rgba(231,76,60,0.25)"

def health_border(score):
    if score >= 70:
        return "#0f9b8e"
    elif score >= 40:
        return "#f0a500"
    return "#e74c3c"

site = tree_df["SITE_ID"].iloc[0] if not tree_df.empty else "HYD_PRECISION"
html = f'<div style="margin-bottom:1rem;">'
html += f'<div style="font-weight:700;color:#f0a500;font-size:1.1rem;margin-bottom:0.8rem;">Site: {site}</div>'

for line_id in sorted(tree_df["LINE_ID"].unique()):
    line_assets = tree_df[tree_df["LINE_ID"] == line_id]
    html += f'<div style="margin-bottom:1rem;">'
    html += f'<div style="font-weight:600;color:#ccd6f6;font-size:0.95rem;margin-bottom:0.5rem;margin-left:0.2rem;">{line_id}</div>'
    html += '<div style="display:flex;flex-wrap:wrap;gap:0.6rem;">'
    for _, a in line_assets.iterrows():
        h = float(a["HEALTH_SCORE"])
        oee = float(a["AVG_OEE"]) * 100
        alerts = int(a["OPEN_ALERTS"])
        bg = health_bg(h)
        border = health_border(h)
        alert_html = f'<div style="margin-top:4px;"><span style="background:#e74c3c;color:white;padding:1px 6px;border-radius:8px;font-size:0.7rem;">⚠ {alerts}</span></div>' if alerts > 0 else ""
        crit_dots = '<span style="color:#f0a500;">●</span>' * int(a["CRITICALITY"])

        html += (
            f'<div style="background:{bg};border:2px solid {border};border-radius:10px;'
            f'padding:0.7rem 0.9rem;min-width:140px;flex:1;max-width:180px;">'
            f'<div style="font-weight:700;color:#ccd6f6;font-size:0.85rem;margin-bottom:2px;">{a["ASSET_ID"]}</div>'
            f'<div style="color:#8892b0;font-size:0.7rem;margin-bottom:6px;">{a["ASSET_TYPE"]} {crit_dots}</div>'
            f'<div style="display:flex;justify-content:space-between;font-size:0.8rem;">'
            f'<span style="color:{border};font-weight:600;">H: {h:.0f}</span>'
            f'<span style="color:#ccd6f6;">OEE: {oee:.0f}%</span>'
            f'</div>'
            f'{alert_html}'
            f'</div>'
        )
    html += '</div></div>'

html += '</div>'
st.markdown(html, unsafe_allow_html=True)

st.divider()

# Asset grid grouped by line
st.markdown(f"### Asset Grid {info_tooltip('One card per asset grouped by production line. Color indicates risk level. Shows 7-day average OEE, health score, and open alert count. Source: CORE.ASSET, FEATURES.DT_ASSET_HEALTH, SEMANTIC.DT_SHIFT_OEE.')}", unsafe_allow_html=True)

for line_id in sorted(asset_df["LINE_ID"].unique()):
    st.markdown(f"**{line_id}**")
    line_assets = asset_df[asset_df["LINE_ID"] == line_id]
    cols = st.columns(min(len(line_assets), 5))
    for i, (_, asset) in enumerate(line_assets.iterrows()):
        with cols[i % 5]:
            health = asset["HEALTH_SCORE"] or 50
            risk = (asset["RISK_LEVEL"] or "LOW").upper()
            oee = asset["AVG_OEE"] or 0
            alerts = int(asset["OPEN_ALERTS"] or 0)

            border_color = {"CRITICAL": "#e74c3c", "HIGH": "#f0a500", "MEDIUM": "#f39c12", "LOW": "#0f9b8e"}.get(risk, "#2a2a4a")
            alert_badge = f' <span style="background:#e74c3c;color:white;padding:1px 6px;border-radius:8px;font-size:0.75rem;">{alerts}</span>' if alerts > 0 else ""

            st.markdown(
                f'<div style="background:linear-gradient(135deg,#1a1a2e,#16213e);border:2px solid {border_color};'
                f'border-radius:10px;padding:0.8rem;text-align:center;margin-bottom:0.5rem;">'
                f'<div style="font-weight:700;color:#f0a500;font-size:0.9rem;">{asset["ASSET_ID"]}{alert_badge}</div>'
                f'<div style="color:#8892b0;font-size:0.75rem;">{asset["ASSET_TYPE"]}</div>'
                f'<div style="margin-top:0.4rem;">'
                f'<span style="color:#ccd6f6;font-size:0.85rem;">OEE {oee*100:.0f}%</span> · '
                f'<span style="color:#ccd6f6;font-size:0.85rem;">Health {health:.0f}</span>'
                f'</div>'
                f'<div style="margin-top:0.2rem;">{risk_badge(risk)}</div>'
                f'</div>',
                unsafe_allow_html=True,
            )

st.divider()

# Asset selector to navigate to Digital Twin
st.markdown("### Investigate Asset")
selected = st.selectbox("Select an asset to view its Digital Twin", asset_df["ASSET_ID"].tolist())
if st.button("Go to Digital Twin"):
    st.session_state["twin_asset"] = selected
    st.info(f"Navigate to the Asset Digital Twin page — {selected} is pre-selected.")
