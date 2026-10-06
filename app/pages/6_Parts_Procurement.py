import streamlit as st
import pandas as pd
import json
from utils import (
    apply_theme, render_header, render_sidebar, render_kpi_card, run_query,
    get_session, write_audit, info_tooltip,
)

apply_theme()
render_sidebar()
render_header("Parts Procurement", "Requisitions, inventory, and supplier tracking")

tab1, tab2, tab3 = st.tabs(["Requisitions", "Inventory", "Suppliers"])

# ---- TAB 1: Requisitions ----
with tab1:
    st.markdown(f"### Purchase Requisitions {info_tooltip('All requisitions with status, supplier, quote, lead time, linked work order, and order-by date from WO_SCHEDULE. Source: ACTION.PURCHASE_REQUISITION, ACTION.WO_SCHEDULE, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)

    # Filters
    fc1, fc2, fc3 = st.columns(3)
    with fc1:
        status_filter = st.selectbox("Status", ["All", "PENDING_QUOTE", "QUOTED", "ORDERED", "RECEIVED", "CANCELLED"], key="req_status")
    with fc2:
        supplier_list = run_query("SELECT DISTINCT SUPPLIER_NAME FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION ORDER BY SUPPLIER_NAME", ttl=120)
        suppliers = ["All"] + (supplier_list["SUPPLIER_NAME"].tolist() if not supplier_list.empty else [])
        supplier_filter = st.selectbox("Supplier", suppliers, key="req_supplier")
    with fc3:
        asset_list = run_query("""
            SELECT DISTINCT WO.ASSET_ID
            FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
            JOIN AEGIS_OEE.ACTION.WORK_ORDER WO ON PR.WO_ID = WO.WO_ID
            ORDER BY WO.ASSET_ID
        """, ttl=120)
        assets = ["All"] + (asset_list["ASSET_ID"].tolist() if not asset_list.empty else [])
        asset_filter = st.selectbox("Asset", assets, key="req_asset")

    where_parts = []
    if status_filter != "All":
        where_parts.append(f"PR.STATUS = '{status_filter}'")
    if supplier_filter != "All":
        safe_sup = supplier_filter.replace("'", "''")
        where_parts.append(f"PR.SUPPLIER_NAME = '{safe_sup}'")
    if asset_filter != "All":
        where_parts.append(f"WO.ASSET_ID = '{asset_filter}'")
    where_clause = ("AND " + " AND ".join(where_parts)) if where_parts else ""

    all_reqs = run_query(f"""
        SELECT PR.REQ_ID, PR.WO_ID, PR.PART_ID, PI.PART_NAME, PR.QTY,
               PR.EST_UNIT_COST, PR.EST_TOTAL, PR.SUPPLIER_NAME,
               PR.LEAD_TIME_DAYS, PR.RFQ_TEXT, PR.STATUS, PR.CREATED_TS,
               WO.ASSET_ID, WO.TITLE AS WO_TITLE,
               WS.ORDER_BY_DATE, WS.PARTS_READY_DATE, WS.STATUS AS SCHED_STATUS
        FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
        LEFT JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON PR.PART_ID = PI.PART_ID
        LEFT JOIN AEGIS_OEE.ACTION.WORK_ORDER WO ON PR.WO_ID = WO.WO_ID
        LEFT JOIN AEGIS_OEE.ACTION.WO_SCHEDULE WS ON WO.WO_ID = WS.WO_ID AND WS.STATUS NOT IN ('CANCELLED')
        WHERE 1=1 {where_clause}
        ORDER BY PR.CREATED_TS DESC
    """, ttl=30)

    if all_reqs.empty:
        st.info("No purchase requisitions match the selected filters.")
    else:
        open_reqs = len(all_reqs[all_reqs["STATUS"].isin(["PENDING_QUOTE", "QUOTED", "ORDERED"])])
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

        for _, pr in all_reqs.iterrows():
            status = pr["STATUS"]
            status_color = {
                "RECEIVED": "#0f9b8e", "ORDERED": "#3498db",
                "QUOTED": "#f0a500", "PENDING_QUOTE": "#e67e22",
                "CANCELLED": "#e74c3c",
            }.get(status, "#8892b0")
            asset = pr["ASSET_ID"] or "\u2014"

            order_by = str(pr["ORDER_BY_DATE"])[:10] if pd.notna(pr.get("ORDER_BY_DATE")) else ""
            overdue_flag = ""
            if order_by and status in ("PENDING_QUOTE", "QUOTED"):
                try:
                    from datetime import date
                    obd = pd.to_datetime(order_by).date()
                    if obd <= date.today():
                        overdue_flag = ' <span style="background:#e74c3c;color:white;padding:1px 6px;border-radius:8px;font-size:0.7rem;font-weight:700;">OVERDUE</span>'
                    elif (obd - date.today()).days <= 3:
                        overdue_flag = ' <span style="background:#f0a500;color:#1a1a2e;padding:1px 6px;border-radius:8px;font-size:0.7rem;font-weight:700;">AT RISK</span>'
                except Exception:
                    pass
            order_by_html = f" | Order by: {order_by}{overdue_flag}" if order_by else ""

            st.markdown(
                f'<div class="info-card">'
                f'<strong>{pr["REQ_ID"]}</strong> \u2014 '
                f'{pr["PART_ID"]} ({pr["PART_NAME"] or "Unknown"}) \u2014 '
                f'Qty: {int(pr["QTY"])} \u2014 '
                f'${float(pr["EST_TOTAL"]):,.2f} \u2014 '
                f'{pr["SUPPLIER_NAME"]} \u2014 '
                f'{int(pr["LEAD_TIME_DAYS"])}d lead \u2014 '
                f'<span style="color:{status_color};font-weight:600;">{status}</span> \u2014 '
                f'Asset: {asset}{order_by_html}'
                f'</div>',
                unsafe_allow_html=True,
            )
            if pr.get("RFQ_TEXT") and pd.notna(pr["RFQ_TEXT"]):
                with st.expander("RFQ Draft", expanded=False):
                    st.text_area("Purchase Requisition", value=pr["RFQ_TEXT"], height=120, disabled=True, key=f"rfq_{pr['REQ_ID']}")

            # Status change action
            if status not in ("RECEIVED", "CANCELLED"):
                next_map = {
                    "PENDING_QUOTE": ["QUOTED", "CANCELLED"],
                    "QUOTED": ["ORDERED", "CANCELLED"],
                    "ORDERED": ["RECEIVED", "CANCELLED"],
                }
                options = next_map.get(status, [])
                if options:
                    with st.expander(f"Update status for {pr['REQ_ID']}", expanded=False):
                        ac1, ac2 = st.columns(2)
                        with ac1:
                            new_status = st.selectbox("New status", options, key=f"ns_{pr['REQ_ID']}")
                        with ac2:
                            actor = st.text_input("Your name", key=f"act_{pr['REQ_ID']}", placeholder="e.g. STORES_KUMAR")
                        note = st.text_input("Note (optional)", key=f"note_{pr['REQ_ID']}")
                        confirm = st.checkbox("I confirm this status change", key=f"conf_{pr['REQ_ID']}")
                        bc1, bc2 = st.columns(2)
                        with bc1:
                            if st.button("Preview (dry run)", key=f"dry_{pr['REQ_ID']}"):
                                if not actor.strip():
                                    st.warning("Enter your name.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_actor = actor.strip().replace("'", "''")
                                        safe_note = note.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('{pr['REQ_ID']}', '{new_status}', '{safe_actor}', '{safe_note}', TRUE)"
                                        ).collect()
                                        if result:
                                            st.json(result[0][0])
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                        with bc2:
                            if st.button("Confirm", key=f"exec_{pr['REQ_ID']}", type="primary"):
                                if not actor.strip():
                                    st.warning("Enter your name.")
                                elif not confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        safe_actor = actor.strip().replace("'", "''")
                                        safe_note = note.strip().replace("'", "''")
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.UPDATE_REQUISITION_STATUS('{pr['REQ_ID']}', '{new_status}', '{safe_actor}', '{safe_note}', FALSE)"
                                        ).collect()
                                        if result:
                                            try:
                                                parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                                if parsed.get("status") == "OK":
                                                    st.success(f"Requisition {pr['REQ_ID']} updated to {new_status}.")
                                                else:
                                                    st.warning(f"Result: {parsed.get('reason', parsed.get('status'))}")
                                            except Exception:
                                                st.write(result)
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        st.rerun()

# ---- TAB 2: Inventory ----
with tab2:
    st.markdown(f"### Parts Inventory {info_tooltip('Current stock levels, reserved quantities, reorder status, and shortage analysis against open work orders. Source: CORE.PARTS_INVENTORY, CORE.FAILURE_MODE_PARTS, ACTION.WORK_ORDER.')}", unsafe_allow_html=True)

    inv_df = run_query("""
        SELECT PI.PART_ID, PI.PART_NAME, PI.CATEGORY,
               PI.ON_HAND_QTY, PI.RESERVED_QTY,
               (PI.ON_HAND_QTY - PI.RESERVED_QTY) AS AVAILABLE,
               PI.REORDER_POINT,
               CASE WHEN (PI.ON_HAND_QTY - PI.RESERVED_QTY) < PI.REORDER_POINT THEN TRUE ELSE FALSE END AS BELOW_REORDER,
               PI.UNIT_COST, PI.SUPPLIER_NAME, PI.LEAD_TIME_DAYS, PI.BIN_LOCATION
        FROM AEGIS_OEE.CORE.PARTS_INVENTORY PI
        ORDER BY BELOW_REORDER DESC, PI.PART_ID
    """, ttl=30)

    if inv_df.empty:
        st.info("No inventory data.")
    else:
        below = int(inv_df["BELOW_REORDER"].sum())
        total_value = float((inv_df["ON_HAND_QTY"] * inv_df["UNIT_COST"]).sum())
        total_reserved = int(inv_df["RESERVED_QTY"].sum())

        k1, k2, k3 = st.columns(3)
        with k1:
            render_kpi_card("Below Reorder", below, fmt="int")
        with k2:
            render_kpi_card("Inventory Value", total_value, fmt="dollar")
        with k3:
            render_kpi_card("Total Reserved", total_reserved, fmt="int")

        st.divider()

        # Shortage vs open work orders
        shortage_df = run_query("""
            SELECT FMP.FAILURE_MODE, FMP.PART_ID, PI.PART_NAME,
                   FMP.QTY_REQUIRED,
                   (PI.ON_HAND_QTY - PI.RESERVED_QTY) AS AVAILABLE,
                   GREATEST(FMP.QTY_REQUIRED - (PI.ON_HAND_QTY - PI.RESERVED_QTY), 0) AS SHORTAGE,
                   WO.WO_ID, WO.ASSET_ID, WO.STATE AS WO_STATE
            FROM AEGIS_OEE.ACTION.WORK_ORDER WO
            JOIN AEGIS_OEE.ACTION.ALERT AL ON WO.ALERT_ID = AL.ALERT_ID
            JOIN AEGIS_OEE.CORE.ASSET A ON WO.ASSET_ID = A.ASSET_ID
            JOIN AEGIS_OEE.CORE.FAILURE_MODE_PARTS FMP
                ON AL.PREDICTED_MODE = FMP.FAILURE_MODE AND A.ASSET_TYPE = FMP.ASSET_TYPE
            JOIN AEGIS_OEE.CORE.PARTS_INVENTORY PI ON FMP.PART_ID = PI.PART_ID
            WHERE WO.STATE NOT IN ('CLOSED', 'REJECTED', 'CANCELLED')
              AND FMP.QTY_REQUIRED > (PI.ON_HAND_QTY - PI.RESERVED_QTY)
            ORDER BY SHORTAGE DESC
        """, ttl=30)

        if not shortage_df.empty:
            st.markdown("#### Shortages vs Open Work Orders")
            for _, s in shortage_df.iterrows():
                st.markdown(
                    f'<div class="shortage-warning">'
                    f'<strong>{s["PART_ID"]}</strong> ({s["PART_NAME"]}) \u2014 '
                    f'Need: {int(s["QTY_REQUIRED"])}, Available: {int(s["AVAILABLE"])}, '
                    f'<strong>Shortage: {int(s["SHORTAGE"])}</strong> \u2014 '
                    f'WO: {s["WO_ID"]} ({s["WO_STATE"]}) \u2014 {s["FAILURE_MODE"]}'
                    f'</div>',
                    unsafe_allow_html=True,
                )
            st.divider()

        st.markdown("#### Full Inventory")
        display_df = inv_df[["PART_ID", "PART_NAME", "CATEGORY", "ON_HAND_QTY", "RESERVED_QTY",
                             "AVAILABLE", "REORDER_POINT", "BELOW_REORDER", "UNIT_COST",
                             "SUPPLIER_NAME", "LEAD_TIME_DAYS", "BIN_LOCATION"]].copy()
        display_df["UNIT_COST"] = display_df["UNIT_COST"].apply(lambda x: f"${x:,.2f}")
        display_df["BELOW_REORDER"] = display_df["BELOW_REORDER"].map({True: "YES", False: ""})
        st.dataframe(display_df.reset_index(drop=True), use_container_width=True)

# ---- TAB 3: Suppliers ----
with tab3:
    st.markdown(f"### Supplier Overview {info_tooltip('Spend, open requisitions, and average lead time per supplier. Source: ACTION.PURCHASE_REQUISITION, CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)

    supplier_df = run_query("""
        SELECT PR.SUPPLIER_NAME,
               COUNT(*) AS TOTAL_REQS,
               SUM(CASE WHEN PR.STATUS IN ('PENDING_QUOTE','QUOTED','ORDERED') THEN 1 ELSE 0 END) AS OPEN_REQS,
               SUM(PR.EST_TOTAL) AS TOTAL_SPEND,
               SUM(CASE WHEN PR.STATUS IN ('PENDING_QUOTE','QUOTED','ORDERED') THEN PR.EST_TOTAL ELSE 0 END) AS OPEN_SPEND,
               ROUND(AVG(PR.LEAD_TIME_DAYS), 1) AS AVG_LEAD_DAYS
        FROM AEGIS_OEE.ACTION.PURCHASE_REQUISITION PR
        GROUP BY PR.SUPPLIER_NAME
        ORDER BY OPEN_SPEND DESC
    """, ttl=60)

    if supplier_df.empty:
        st.info("No supplier data from requisitions.")
    else:
        for _, sup in supplier_df.iterrows():
            open_spend = float(sup["OPEN_SPEND"])
            total_spend = float(sup["TOTAL_SPEND"])
            st.markdown(
                f'<div class="info-card">'
                f'<strong>{sup["SUPPLIER_NAME"]}</strong> \u2014 '
                f'Open: {int(sup["OPEN_REQS"])} reqs (${open_spend:,.2f}) \u2014 '
                f'Total: {int(sup["TOTAL_REQS"])} reqs (${total_spend:,.2f}) \u2014 '
                f'Avg lead: {sup["AVG_LEAD_DAYS"]}d'
                f'</div>',
                unsafe_allow_html=True,
            )
