import streamlit as st
import pandas as pd
from datetime import datetime, timedelta
from snowflake.snowpark.context import get_active_session

AEGIS_CSS = """
<style>
    .stApp { background-color: #0e1117; }

    /* Reduce Streamlit's large default top padding on the main content block */
    .block-container {
        padding-top: 1.5rem !important;
    }

    /* Compact top bar (plant selector), rendered in main content */
    .top-bar-row {
        padding-top: 0 !important;
        margin-top: 0;
        margin-bottom: 0.3rem;
    }
    .top-bar-row .stSelectbox { margin-bottom: 0 !important; }

    /* CoCo usage badge floating at the bottom-right of the viewport */
    .coco-badge {
        position: fixed;
        bottom: 0.75rem;
        right: 1rem;
        color: #8892b0;
        font-size: 0.7rem;
        background: rgba(22, 33, 62, 0.85);
        border: 1px solid #2a2a4a;
        border-radius: 8px;
        padding: 0.35rem 0.7rem;
        z-index: 999;
    }

    /* KPI metric cards */
    .kpi-card {
        background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
        border: 1px solid #2a2a4a;
        border-radius: 12px;
        padding: 1.2rem;
        text-align: center;
        box-shadow: 0 4px 6px rgba(0,0,0,0.3);
    }
    .kpi-card .kpi-value {
        font-size: 2.2rem;
        font-weight: 700;
        margin: 0.3rem 0;
    }
    .kpi-card .kpi-label {
        font-size: 0.85rem;
        color: #8892b0;
        text-transform: uppercase;
        letter-spacing: 1px;
    }
    .kpi-card .kpi-delta {
        font-size: 0.9rem;
        margin-top: 0.3rem;
    }
    .kpi-green { color: #0f9b8e; }
    .kpi-amber { color: #f0a500; }
    .kpi-red { color: #e74c3c; }
    .severity-p1 { background: #e74c3c; color: white; padding: 2px 10px; border-radius: 12px; font-weight: 700; display: inline-block; }
    .severity-p2 { background: #f0a500; color: #1a1a2e; padding: 2px 10px; border-radius: 12px; font-weight: 700; display: inline-block; }
    .severity-p3 { background: #0f9b8e; color: white; padding: 2px 10px; border-radius: 12px; font-weight: 700; display: inline-block; }
    .risk-critical { background: #e74c3c; color: white; padding: 4px 12px; border-radius: 8px; display: inline-block; }
    .risk-high { background: #f0a500; color: #1a1a2e; padding: 4px 12px; border-radius: 8px; display: inline-block; }
    .risk-medium { background: #f39c12; color: #1a1a2e; padding: 4px 12px; border-radius: 8px; display: inline-block; }
    .risk-low { background: #0f9b8e; color: white; padding: 4px 12px; border-radius: 8px; display: inline-block; }
    .aegis-header {
        background: linear-gradient(90deg, #1a1a2e 0%, #16213e 50%, #0a0a1a 100%);
        padding: 1.5rem 2rem;
        border-radius: 12px;
        border-left: 4px solid #f0a500;
        margin-bottom: 1.5rem;
    }
    .aegis-header h1 {
        color: #f0a500;
        margin: 0;
        font-size: 1.8rem;
    }
    .aegis-header p {
        color: #8892b0;
        margin: 0.3rem 0 0 0;
        font-size: 0.95rem;
    }
    .info-card {
        background: #16213e;
        border: 1px solid #2a2a4a;
        border-radius: 10px;
        padding: 1rem 1.2rem;
        margin-bottom: 0.8rem;
    }
    .shortage-warning {
        background: rgba(231, 76, 60, 0.15);
        border: 1px solid #e74c3c;
        border-radius: 8px;
        padding: 0.8rem;
        color: #e74c3c;
    }
    .stDataFrame { border-radius: 8px; overflow: hidden; }
    div[data-testid="stMetric"] {
        background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
        border: 1px solid #2a2a4a;
        border-radius: 12px;
        padding: 1rem;
    }

    /* Info tooltip on hover */
    .info-tip {
        display: inline-block;
        vertical-align: middle;
        margin-left: 6px;
        cursor: help;
        position: relative;
    }
    .info-tip:hover::after {
        content: attr(title);
        position: absolute;
        left: 0;
        top: 24px;
        background: #1a1a2e;
        color: #ccd6f6;
        border: 1px solid #2a2a4a;
        border-radius: 8px;
        padding: 8px 12px;
        font-size: 0.78rem;
        line-height: 1.4;
        white-space: normal;
        width: 280px;
        z-index: 1000;
        box-shadow: 0 4px 12px rgba(0,0,0,0.4);
    }
    .info-tip:hover::before {
        content: '';
        position: absolute;
        left: 6px;
        top: 18px;
        border: 6px solid transparent;
        border-bottom-color: #2a2a4a;
        z-index: 1001;
    }

    /* Nav cards — CSS grid forces equal row height automatically */
    .nav-grid {
        display: grid;
        grid-template-columns: repeat(5, 1fr);
        gap: 1rem;
    }
    .nav-card {
        background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
        border: 1px solid #2a2a4a;
        border-radius: 12px;
        padding: 1.5rem 1rem;
        text-align: center;
        transition: border-color 0.3s;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: flex-start;
    }
    .nav-card:hover { border-color: #f0a500; }
    .nav-card h3 { color: #f0a500; margin: 0 0 0.5rem 0; font-size: 1.05rem; line-height: 1.3; }
    .nav-card p { color: #8892b0; margin: 0; font-size: 0.82rem; line-height: 1.4; }
    .nav-card .nav-icon { font-size: 2rem; margin-bottom: 0.5rem; flex-shrink: 0; }
</style>
"""


def get_session():
    return get_active_session()


def run_query(sql, ttl=300):
    session = get_active_session()
    return session.sql(sql).to_pandas()


def apply_theme():
    st.markdown(AEGIS_CSS, unsafe_allow_html=True)


def render_header(title, subtitle=None):
    sub = f"<p>{subtitle}</p>" if subtitle else ""
    st.markdown(
        f'<div class="aegis-header"><h1>{title}</h1>{sub}</div>',
        unsafe_allow_html=True,
    )


def render_kpi_card(label, value, delta=None, fmt="pct"):
    if fmt == "pct":
        display_val = f"{value * 100:.1f}%"
    elif fmt == "int":
        display_val = f"{int(value):,}"
    elif fmt == "score":
        display_val = f"{value:.0f}"
    elif fmt == "dollar":
        display_val = f"${value:,.2f}"
    else:
        display_val = str(value)

    color_class = "kpi-green"
    if fmt == "pct" and value < 0.65:
        color_class = "kpi-red"
    elif fmt == "pct" and value < 0.85:
        color_class = "kpi-amber"
    elif fmt == "score" and value < 50:
        color_class = "kpi-red"
    elif fmt == "score" and value < 75:
        color_class = "kpi-amber"

    delta_html = ""
    if delta is not None:
        delta_sign = "+" if delta >= 0 else ""
        delta_color = "kpi-green" if delta >= 0 else "kpi-red"
        if fmt == "pct":
            delta_html = f'<div class="kpi-delta {delta_color}">{delta_sign}{delta * 100:.1f}pp</div>'
        else:
            delta_html = f'<div class="kpi-delta {delta_color}">{delta_sign}{delta:.1f}</div>'

    st.markdown(
        f"""
    <div class="kpi-card">
        <div class="kpi-label">{label}</div>
        <div class="kpi-value {color_class}">{display_val}</div>
        {delta_html}
    </div>
    """,
        unsafe_allow_html=True,
    )


def severity_badge(sev):
    cls = {"P1": "severity-p1", "P2": "severity-p2", "P3": "severity-p3"}.get(
        sev, "severity-p3"
    )
    return f'<span class="{cls}">{sev}</span>'


def risk_badge(level):
    if level is None:
        level = "LOW"
    level_upper = str(level).upper()
    cls = {
        "CRITICAL": "risk-critical",
        "HIGH": "risk-high",
        "MEDIUM": "risk-medium",
        "LOW": "risk-low",
    }.get(level_upper, "risk-low")
    return f'<span class="{cls}">{level_upper}</span>'


def info_tooltip(text):
    """Return HTML for an info icon with hover tooltip. Use inline with section headings."""
    escaped = text.replace('"', '&quot;').replace("'", "&#39;")
    return (
        f'<span class="info-tip" title="{escaped}">'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" '
        f'fill="none" stroke="#8892b0" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        f'<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/>'
        f'<line x1="12" y1="8" x2="12.01" y2="8"/></svg></span>'
    )


def time_ago(ts):
    if ts is None or (isinstance(ts, float) and pd.isna(ts)):
        return "\u2014"
    if pd.isna(ts):
        return "\u2014"
    now = datetime.now()
    if isinstance(ts, str):
        ts = pd.to_datetime(ts)
    try:
        if hasattr(ts, "tz") and ts.tz is not None:
            ts = ts.tz_localize(None)
        elif hasattr(ts, "tzinfo") and ts.tzinfo is not None:
            ts = ts.replace(tzinfo=None)
    except Exception:
        pass
    diff = now - ts
    total_seconds = diff.total_seconds()
    if total_seconds < 0:
        return "just now"
    if total_seconds < 3600:
        return f"{int(total_seconds / 60)} min ago"
    elif total_seconds < 86400:
        return f"{int(total_seconds / 3600)} hours ago"
    else:
        return f"{int(diff.days)} days ago"


def render_sidebar():
    """Renders the plant selector (right-aligned) as a compact top-bar widget
    in the main content area, and floats the CoCo usage line as a small
    badge fixed to the bottom-right of the viewport. Nothing is added to
    the Streamlit sidebar itself, which stays nav-only."""
    coco_text = "Built with CoCo"
    try:
        coco_df = run_query(
            """
            SELECT INTERFACE, COUNT(*) AS CALLS
            FROM SNOWFLAKE.LOCAL.SNOWFLAKE_COCO_USAGE_HISTORY
            GROUP BY INTERFACE ORDER BY CALLS DESC LIMIT 5
        """,
            ttl=600,
        )
        if not coco_df.empty:
            parts = [f"{row['INTERFACE']}: {int(row['CALLS'])}" for _, row in coco_df.iterrows()]
            coco_text += " &middot; " + ", ".join(parts)
    except Exception:
        pass
    st.markdown(f'<div class="coco-badge">{coco_text}</div>', unsafe_allow_html=True)

    st.markdown('<div class="top-bar-row">', unsafe_allow_html=True)
    col_spacer, col_plant = st.columns([3, 1])
    with col_plant:
        st.selectbox("Plant", ["HYD_PRECISION"], key="plant_selector", label_visibility="collapsed")
    st.markdown('</div>', unsafe_allow_html=True)


def write_audit(session, actor, action, object_ref, detail_json="{}"):
    session.sql(
        f"""
        INSERT INTO AEGIS_OEE.ACTION.ACTION_AUDIT (AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL)
        SELECT
            'AUD_' || TO_VARCHAR(CURRENT_TIMESTAMP, 'YYYYMMDD_HH24MISS_FF3') || '_' || UNIFORM(1000,9999, RANDOM()),
            CURRENT_TIMESTAMP,
            '{actor}',
            '{action}',
            '{object_ref}',
            PARSE_JSON('{detail_json}')
    """
    ).collect()
