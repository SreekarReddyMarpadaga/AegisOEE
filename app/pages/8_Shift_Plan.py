import streamlit as st
import pandas as pd
import json
from datetime import datetime, timedelta
from utils import (refresh_page, flash, 
    apply_theme, render_header, render_sidebar, render_kpi_card, run_query,
    severity_badge, time_ago, get_session, write_audit, info_tooltip,
    format_failure_eta, FAILURE_ETA_HELP, tab_switch,
)

apply_theme()
render_sidebar()
render_header("Shift Plan & Maintenance Windows", "14-day forward plan: production schedule, maintenance windows, and WO scheduling")

# Keep the rolling 14-day plan ahead of today (idempotent) so the page is never empty.
if not st.session_state.get("_cmms_extended"):
    try:
        get_session().sql("CALL AEGIS_OEE.CORE.EXTEND_CMMS_HORIZON()").collect()
        st.cache_data.clear()
    except Exception:
        pass
    st.session_state["_cmms_extended"] = True

TAB_NAMES = ["Production & Maintenance Gantt", "WO Schedule", "Rebook"]
active_tab = tab_switch(TAB_NAMES, "shift_tab")

# ---- TAB 1: Gantt ----
if active_tab == TAB_NAMES[0]:
    st.markdown(f"### 14-Day Forward Plan {info_tooltip('Gantt view of production shifts (blue), maintenance windows (green/orange), and booked work orders (red). Source: CORE.SHIFT_PLAN, CORE.MAINTENANCE_WINDOW, ACTION.WO_SCHEDULE.')}", unsafe_allow_html=True)

    line_filter = st.selectbox("Line", ["All", "LINE_1", "LINE_2"], key="gantt_line")
    line_clause = f"AND sp.LINE_ID = '{line_filter}'" if line_filter != "All" else ""
    mw_clause = f"AND mw.LINE_ID = '{line_filter}'" if line_filter != "All" else ""

    shift_df = run_query(f"""
        SELECT PLAN_ID, PLAN_DATE, SHIFT_CODE, LINE_ID, ORDER_ID,
               PLANNED_QTY, PLANNED_START_TS, PLANNED_END_TS, PLANNED_RUN_MIN, STATUS
        FROM AEGIS_OEE.CORE.SHIFT_PLAN sp
        WHERE sp.PLAN_DATE >= CURRENT_DATE() {line_clause}
        ORDER BY sp.PLAN_DATE, sp.LINE_ID, sp.SHIFT_CODE
    """, ttl=60)

    window_df = run_query(f"""
        SELECT mw.WINDOW_ID, mw.LINE_ID, mw.ASSET_ID, mw.WINDOW_TYPE,
               mw.WINDOW_START_TS, mw.WINDOW_END_TS,
               mw.CAPACITY_MIN, mw.BOOKED_MIN, mw.STATUS,
               ws.WO_ID, ws.SCHEDULE_ID, ws.STATUS AS SCHED_STATUS
        FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw
        LEFT JOIN AEGIS_OEE.ACTION.WO_SCHEDULE ws
            ON mw.WINDOW_ID = ws.WINDOW_ID AND ws.STATUS NOT IN ('CANCELLED')
        WHERE mw.WINDOW_END_TS > CURRENT_TIMESTAMP() {mw_clause}
        ORDER BY mw.WINDOW_START_TS
    """, ttl=60)

    fail_df = run_query(f"""
        SELECT al.ALERT_ID, al.ASSET_ID, al.PREDICTED_MODE, al.PREDICTED_FAILURE_TS, a.LINE_ID
        FROM AEGIS_OEE.ACTION.ALERT al
        JOIN AEGIS_OEE.CORE.ASSET a ON al.ASSET_ID = a.ASSET_ID
        WHERE al.STATUS NOT IN ('CLOSED', 'SUPPRESSED') AND al.PREDICTED_FAILURE_TS IS NOT NULL {line_clause.replace('sp.LINE_ID', 'a.LINE_ID')}
    """, ttl=60)

    # KPIs
    k1, k2, k3, k4 = st.columns(4)
    with k1:
        total_prod_shifts = len(shift_df) if not shift_df.empty else 0
        render_kpi_card("Planned Shifts", total_prod_shifts, fmt="int", help="Production shifts planned from today onward. Source: CORE.SHIFT_PLAN.")
    with k2:
        total_windows = len(window_df["WINDOW_ID"].unique()) if not window_df.empty else 0
        render_kpi_card("Maint Windows", total_windows, fmt="int", help="Upcoming time slots reserved for maintenance. Source: CORE.MAINTENANCE_WINDOW.")
    with k3:
        booked = window_df[window_df["WO_ID"].notna()]["WINDOW_ID"].nunique() if not window_df.empty else 0
        render_kpi_card("Booked Windows", booked, fmt="int", help="Maintenance windows that already have a work order scheduled.")
    with k4:
        total_cap = int(window_df["CAPACITY_MIN"].sum()) if not window_df.empty else 0
        total_booked_min = int(window_df["BOOKED_MIN"].sum()) if not window_df.empty else 0
        render_kpi_card("Available Min", total_cap - total_booked_min, fmt="int", help="Unbooked maintenance capacity in minutes (window capacity minus booked minutes).")

    st.divider()

    # Build Gantt-like display using HTML
    if not shift_df.empty or not window_df.empty:
        gantt_rows = []

        # Production shifts
        for _, row in shift_df.iterrows():
            gantt_rows.append({
                "Type": "Production",
                "Line": row["LINE_ID"],
                "Label": f"{row['SHIFT_CODE']} - {row['ORDER_ID']}",
                "Start": str(row["PLANNED_START_TS"])[:16],
                "End": str(row["PLANNED_END_TS"])[:16],
                "Status": row["STATUS"],
                "Detail": f"Qty: {int(row['PLANNED_QTY'])}, Run: {int(row['PLANNED_RUN_MIN'])}min",
            })

        # Maintenance windows
        for _, row in window_df.drop_duplicates(subset="WINDOW_ID").iterrows():
            avail = int(row["CAPACITY_MIN"]) - int(row["BOOKED_MIN"])
            wo_label = f" [{row['WO_ID']}]" if pd.notna(row.get("WO_ID")) else ""
            gantt_rows.append({
                "Type": row["WINDOW_TYPE"],
                "Line": row["LINE_ID"],
                "Label": f"{row['WINDOW_TYPE']}{wo_label}",
                "Start": str(row["WINDOW_START_TS"])[:16],
                "End": str(row["WINDOW_END_TS"])[:16],
                "Status": row["STATUS"],
                "Detail": f"Cap: {int(row['CAPACITY_MIN'])}min, Avail: {avail}min",
            })

        # Predicted failure deadlines of open alerts (shown in the plant's IST timeline)
        for _, row in fail_df.iterrows():
            fts = pd.Timestamp(row["PREDICTED_FAILURE_TS"])
            fts = fts.tz_convert("Asia/Kolkata") if fts.tzinfo else fts
            gantt_rows.append({
                "Type": "Predicted failure",
                "Line": row["LINE_ID"],
                "Label": f"\u26a0 PREDICTED FAILURE \u2014 {row['ASSET_ID']} ({row['PREDICTED_MODE']})",
                "Start": fts.strftime("%Y-%m-%d %H:%M"),
                "End": fts.strftime("%Y-%m-%d %H:%M"),
                "Status": "ALERT",
                "Detail": "maintenance should finish before this time",
            })

        gantt_df = pd.DataFrame(gantt_rows)

        # Color-code by type
        type_colors = {
            "Production": "#3498db",
            "DAILY_PM": "#2ecc71",
            "CHANGEOVER": "#f39c12",
            "NON_PRODUCTION": "#27ae60",
            "SHUTDOWN": "#e67e22",
            "Predicted failure": "#e74c3c",
        }

        for line_id in sorted(gantt_df["Line"].unique()):
            st.markdown(f"#### {line_id}")
            line_data = gantt_df[gantt_df["Line"] == line_id].sort_values("Start")
            for _, r in line_data.iterrows():
                color = type_colors.get(r["Type"], "#95a5a6")
                st.markdown(
                    f'<div style="background:{color}22; border-left:4px solid {color}; '
                    f'padding:6px 12px; margin:3px 0; border-radius:6px; font-size:0.85rem;">'
                    f'<strong>{r["Label"]}</strong> '
                    f'<span style="color:#8892b0;">| {r["Start"]} \u2192 {r["End"]}</span> '
                    f'<span style="color:#ccd6f6;">| {r["Detail"]}</span>'
                    f'</div>',
                    unsafe_allow_html=True,
                )
    else:
        st.info("No shift plan or maintenance window data found.")

# ---- TAB 2: WO Schedule ----
if active_tab == TAB_NAMES[1]:
    st.markdown(f"### Work Order Schedule {info_tooltip('All scheduled work orders with parts ready dates, order-by deadlines, and EXPEDITE flags. Source: ACTION.WO_SCHEDULE, ACTION.WORK_ORDER, ACTION.PURCHASE_REQUISITION.')}", unsafe_allow_html=True)

    sched_df = run_query("""
        SELECT ws.SCHEDULE_ID, ws.WO_ID, ws.WINDOW_ID,
               ws.SCHEDULED_START_TS, ws.SCHEDULED_END_TS,
               ws.EST_DURATION_MIN, ws.PARTS_READY_DATE, ws.ORDER_BY_DATE,
               ws.STATUS AS SCHED_STATUS, ws.RATIONALE,
               wo.ASSET_ID, wo.TITLE, wo.PRIORITY, wo.STATE AS WO_STATE,
               mw.WINDOW_TYPE, mw.LINE_ID, al.PREDICTED_FAILURE_TS
        FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
        JOIN AEGIS_OEE.ACTION.WORK_ORDER wo ON ws.WO_ID = wo.WO_ID
        LEFT JOIN AEGIS_OEE.ACTION.ALERT al ON wo.ALERT_ID = al.ALERT_ID
        JOIN AEGIS_OEE.CORE.MAINTENANCE_WINDOW mw ON ws.WINDOW_ID = mw.WINDOW_ID
        WHERE ws.STATUS NOT IN ('CANCELLED')
        ORDER BY ws.SCHEDULED_START_TS
    """, ttl=30)

    unsched_df = run_query("""
        SELECT wo.WO_ID, wo.ASSET_ID, wo.TITLE, wo.PRIORITY, wo.STATE,
               a.LINE_ID, al.PREDICTED_FAILURE_TS
        FROM AEGIS_OEE.ACTION.WORK_ORDER wo
        JOIN AEGIS_OEE.CORE.ASSET a ON wo.ASSET_ID = a.ASSET_ID
        LEFT JOIN AEGIS_OEE.ACTION.ALERT al ON wo.ALERT_ID = al.ALERT_ID
        WHERE wo.STATE IN ('APPROVED', 'SYNCED', 'IN_PROGRESS')
          AND NOT EXISTS (
              SELECT 1 FROM AEGIS_OEE.ACTION.WO_SCHEDULE ws
              WHERE ws.WO_ID = wo.WO_ID AND ws.STATUS NOT IN ('CANCELLED')
          )
        ORDER BY wo.PRIORITY, wo.WO_ID
    """, ttl=30)

    if not unsched_df.empty:
        st.markdown(f"#### Unscheduled Work Orders {info_tooltip('Approved work orders without a maintenance window, for example because the plan had no free slot before the predicted failure time.')}", unsafe_allow_html=True)
        st.caption("These approved work orders have no maintenance window assigned yet. Use the **Rebook** tab to schedule them.")
        for _, u in unsched_df.iterrows():
            st.markdown(
                f'<div style="background:#16213e; border-left:4px solid #e74c3c; '
                f'padding:12px; margin:8px 0; border-radius:8px;">'
                f'<span style="background:#e74c3c;color:white;padding:2px 8px;border-radius:8px;font-weight:700;">UNSCHEDULED</span> '
                f'{severity_badge(u["PRIORITY"])} '
                f'<strong>{u["WO_ID"]}</strong> — {u["TITLE"]}<br/>'
                f'<span style="color:#8892b0;">Asset: {u["ASSET_ID"]} | Line: {u["LINE_ID"]} | State: {u["STATE"]}</span><br/>'
                f'<span style="color:#f0a500;">Predicted failure by: {format_failure_eta(u["PREDICTED_FAILURE_TS"])}</span><br/>'
                f'<span style="color:#ccd6f6;">No maintenance window assigned — go to Rebook tab to schedule.</span>'
                f'</div>',
                unsafe_allow_html=True,
            )
        st.divider()

    if sched_df.empty and unsched_df.empty:
        st.info("No work orders currently scheduled or pending. Approve a work order to see it here.")
    elif not sched_df.empty:
        st.markdown(f"#### Scheduled Work Orders {info_tooltip('Work orders booked into a maintenance window, with parts-ready and order-by dates. Windows starting before the predicted failure time are preferred.')}", unsafe_allow_html=True)
        for _, s in sched_df.iterrows():
            sched_status = s["SCHED_STATUS"]
            if sched_status == "EXPEDITE":
                border_color = "#e74c3c"
                status_html = '<span style="background:#e74c3c;color:white;padding:2px 8px;border-radius:8px;font-weight:700;">EXPEDITE</span>'
            elif sched_status == "CONFIRMED":
                border_color = "#0f9b8e"
                status_html = '<span style="background:#0f9b8e;color:white;padding:2px 8px;border-radius:8px;font-weight:700;">CONFIRMED</span>'
            else:
                border_color = "#f0a500"
                status_html = f'<span style="background:#f0a500;color:#1a1a2e;padding:2px 8px;border-radius:8px;font-weight:700;">{sched_status}</span>'

            parts_ready = str(s["PARTS_READY_DATE"])[:10] if s["PARTS_READY_DATE"] else "N/A"
            order_by = str(s["ORDER_BY_DATE"])[:10] if s["ORDER_BY_DATE"] else "N/A"
            sched_start = str(s["SCHEDULED_START_TS"])[:16]
            sched_end = str(s["SCHEDULED_END_TS"])[:16]

            timing_html = ""
            try:
                pft = pd.Timestamp(s["PREDICTED_FAILURE_TS"])
                margin_h = (pft - pd.Timestamp(s["SCHEDULED_START_TS"])).total_seconds() / 3600
                if margin_h >= 0:
                    verdict = f'<span style="color:#0f9b8e;font-weight:600;">window starts {margin_h:.0f} h before the predicted failure</span>'
                else:
                    verdict = (f'<span style="color:#e74c3c;font-weight:600;">window starts {abs(margin_h):.0f} h AFTER the predicted failure '
                               f'\u2014 expedite parts or approve a production stop</span>')
                timing_html = (f'<br/><span style="color:#ccd6f6;">Predicted failure by: {format_failure_eta(s["PREDICTED_FAILURE_TS"])} | {verdict}</span>')
            except Exception:
                pass

            st.markdown(
                f'<div style="background:#16213e; border-left:4px solid {border_color}; '
                f'padding:12px; margin:8px 0; border-radius:8px;">'
                f'{status_html} {severity_badge(s["PRIORITY"])} '
                f'<strong>{s["WO_ID"]}</strong> \u2014 {s["TITLE"]}<br/>'
                f'<span style="color:#8892b0;">Asset: {s["ASSET_ID"]} | Line: {s["LINE_ID"]} | '
                f'Window: {s["WINDOW_TYPE"]} ({s["WINDOW_ID"]})</span><br/>'
                f'<span style="color:#ccd6f6;">'
                f'Scheduled: {sched_start} \u2192 {sched_end} ({int(s["EST_DURATION_MIN"])} min) | '
                f'Parts ready: {parts_ready} | Order by: {order_by}</span>{timing_html}'
                f'</div>',
                unsafe_allow_html=True,
            )

            if s.get("RATIONALE") and pd.notna(s["RATIONALE"]):
                with st.expander("Rationale", expanded=False):
                    st.write(s["RATIONALE"])

# ---- TAB 3: Rebook ----
if active_tab == TAB_NAMES[2]:
    st.markdown(f"### Rebook Work Order {info_tooltip('Select a work order and a new maintenance window to reschedule. Dry-run preview first, then confirm with your approver name. Source: ACTION.SCHEDULE_WORK_ORDER proc.')}", unsafe_allow_html=True)

    # Get approved WOs
    wo_list = run_query("""
        SELECT WO_ID, ASSET_ID, TITLE, PRIORITY, STATE
        FROM AEGIS_OEE.ACTION.WORK_ORDER
        WHERE STATE IN ('APPROVED', 'SYNCED', 'IN_PROGRESS')
        ORDER BY PRIORITY, WO_ID
    """, ttl=30)

    if wo_list.empty:
        st.info("No approved work orders available for scheduling.")
    else:
        wo_options = [f"{r['WO_ID']} | {r['PRIORITY']} | {r['ASSET_ID']} - {r['TITLE']}" for _, r in wo_list.iterrows()]
        selected_wo = st.selectbox("Select Work Order", wo_options, key="rebook_wo")
        wo_id = selected_wo.split(" | ")[0] if selected_wo else None

        if wo_id:
            # Get available windows for this WO's line
            asset_line = run_query(f"""
                SELECT a.LINE_ID FROM AEGIS_OEE.ACTION.WORK_ORDER wo
                JOIN AEGIS_OEE.CORE.ASSET a ON wo.ASSET_ID = a.ASSET_ID
                WHERE wo.WO_ID = '{wo_id}'
            """, ttl=60)

            if not asset_line.empty:
                line_id = asset_line.iloc[0]["LINE_ID"]
                avail_windows = run_query(f"""
                    SELECT WINDOW_ID, WINDOW_TYPE, WINDOW_START_TS, WINDOW_END_TS,
                           CAPACITY_MIN, BOOKED_MIN,
                           (CAPACITY_MIN - BOOKED_MIN) AS AVAILABLE_MIN
                    FROM AEGIS_OEE.CORE.MAINTENANCE_WINDOW
                    WHERE LINE_ID = '{line_id}' AND STATUS = 'OPEN'
                      AND WINDOW_END_TS > CURRENT_TIMESTAMP()
                      AND (CAPACITY_MIN - BOOKED_MIN) > 0
                    ORDER BY WINDOW_START_TS
                """, ttl=30)

                if avail_windows.empty:
                    st.warning(f"No available windows for {line_id}.")
                else:
                    win_options = [
                        f"{r['WINDOW_ID']} | {r['WINDOW_TYPE']} | {str(r['WINDOW_START_TS'])[:16]} ({int(r['AVAILABLE_MIN'])}min avail)"
                        for _, r in avail_windows.iterrows()
                    ]
                    with st.form("form_rebook"):
                        selected_win = st.selectbox("Select Window", win_options, key="rebook_win")
                        window_id = selected_win.split(" | ")[0] if selected_win else None

                        approver = st.text_input("Approver name", key="rebook_approver", placeholder="e.g. MAINT_SUPERVISOR_RAJ")

                        col_dry, col_confirm = st.columns(2)

                        with col_dry:
                            if st.form_submit_button("Preview (dry run)"):
                                if not approver.strip():
                                    st.warning("Enter approver name.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_approver = approver.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER('{wo_id}', '{window_id}', '{safe_approver}', TRUE)"
                                        ).collect()
                                        if result:
                                            st.json(result[0][0])
                                    except Exception as e:
                                        st.error(f"Error: {e}")

                        with col_confirm:
                            confirm = st.checkbox("I confirm this rebook", key="rebook_confirm")
                            if st.form_submit_button("Confirm Rebook", type="primary"):
                                if not approver.strip():
                                    st.warning("Enter approver name.")
                                elif not confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_approver = approver.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.SCHEDULE_WORK_ORDER('{wo_id}', '{window_id}', '{safe_approver}', FALSE)"
                                        ).collect()
                                        should_rerun = False
                                        if result:
                                            res_json = result[0][0]
                                            st.json(res_json)
                                            try:
                                                parsed = json.loads(res_json) if isinstance(res_json, str) else res_json
                                                if parsed.get("status") == "CONFIRMED":
                                                    flash("Work order rebooked successfully.")
                                                    should_rerun = True
                                                else:
                                                    st.warning(f"Result: {parsed.get('status', 'unknown')}")
                                            except Exception:
                                                pass
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        if should_rerun:
                                            refresh_page()
