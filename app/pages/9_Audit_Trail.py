import json
import streamlit as st
from utils import apply_theme, render_header, render_sidebar, run_query, info_tooltip, time_ago

apply_theme()
render_sidebar()
render_header("Audit Trail", "Append-only log of every action in the system: alerts, work orders, parts, scheduling and the dispatcher")

st.markdown(
    f"### System Audit Log {info_tooltip('Every governed action, including rejected attempts, previews (dry runs), stock changes, schedule changes and dispatcher activity. Source: ACTION.ACTION_AUDIT.')}",
    unsafe_allow_html=True,
)

facets = run_query("""
    SELECT DISTINCT ACTION, ACTOR FROM AEGIS_OEE.ACTION.ACTION_AUDIT
""", ttl=60)
actions = ["All"] + sorted(facets["ACTION"].dropna().unique().tolist()) if not facets.empty else ["All"]
actors = ["All"] + sorted(facets["ACTOR"].dropna().unique().tolist()) if not facets.empty else ["All"]

f1, f2, f3, f4 = st.columns(4)
with f1:
    action_filter = st.selectbox("Action", actions, key="aud_action")
with f2:
    actor_filter = st.selectbox("Actor", actors, key="aud_actor")
with f3:
    object_filter = st.text_input("Object contains", key="aud_object", placeholder="e.g. WO_CNC_01 or P001")
with f4:
    limit = st.selectbox("Rows", [50, 100, 250, 500], key="aud_limit")

where = []
if action_filter != "All":
    where.append(f"ACTION = '{action_filter.replace(chr(39), chr(39) * 2)}'")
if actor_filter != "All":
    where.append(f"ACTOR = '{actor_filter.replace(chr(39), chr(39) * 2)}'")
if object_filter.strip():
    safe_obj = object_filter.strip().replace("'", "''").upper()
    where.append(f"UPPER(OBJECT_REF) LIKE '%{safe_obj}%'")
where_clause = ("WHERE " + " AND ".join(where)) if where else ""

audit_df = run_query(f"""
    SELECT AUDIT_ID, TS, ACTOR, ACTION, OBJECT_REF, DETAIL
    FROM AEGIS_OEE.ACTION.ACTION_AUDIT
    {where_clause}
    ORDER BY TS DESC
    LIMIT {int(limit)}
""", ttl=30)

if audit_df.empty:
    st.info("No audit records match the filters.")
else:
    st.caption(f"Showing {len(audit_df)} most recent record(s).")
    for _, au in audit_df.iterrows():
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
            f'by {au["ACTOR"]} ({time_ago(au["TS"])}){detail_str}'
            f'</div>',
            unsafe_allow_html=True,
        )
