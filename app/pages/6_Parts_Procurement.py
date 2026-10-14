import streamlit as st
import pandas as pd
import json
from utils import (refresh_page, flash, 
    apply_theme, render_header, render_sidebar, render_kpi_card, run_query,
    get_session, write_audit, info_tooltip, tab_switch, remember_open, is_open,
)

apply_theme()
render_sidebar()
render_header("Parts Procurement", "Requisitions, inventory, and supplier tracking")

TAB_NAMES = ["Requisitions", "Inventory", "Suppliers"]
active_tab = tab_switch(TAB_NAMES, "parts_tab")

# ---- TAB 1: Requisitions ----
if active_tab == TAB_NAMES[0]:
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
            render_kpi_card("Open Requisitions", open_reqs, fmt="int", help="Requisitions in PENDING_QUOTE, QUOTED or ORDERED status for the current filters.")
        with k2:
            render_kpi_card("Pending Value", pending_value, fmt="dollar", help="Estimated total cost of requisitions still PENDING_QUOTE or QUOTED (not yet ordered).")
        with k3:
            render_kpi_card("Max Lead Time", max_lead, fmt="int", help="Longest supplier lead time, in days, among the listed requisitions.")

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
                    with st.expander(f"Update status for {pr['REQ_ID']}", expanded=is_open(f"upd_{pr['REQ_ID']}")):
                        with st.form(f"form_upd_{pr['REQ_ID']}"):
                            ac1, ac2 = st.columns(2)
                            with ac1:
                                new_status = st.selectbox("New status", options, key=f"ns_{pr['REQ_ID']}")
                            with ac2:
                                actor = st.text_input("Your name", key=f"act_{pr['REQ_ID']}", placeholder="e.g. STORES_KUMAR")
                            note = st.text_input("Note (optional)", key=f"note_{pr['REQ_ID']}")
                            confirm = st.checkbox("I confirm this status change", key=f"conf_{pr['REQ_ID']}")
                            bc1, bc2 = st.columns(2)
                            with bc1:
                                if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=(f"upd_{pr['REQ_ID']}",)):
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
                                if st.form_submit_button("Confirm", type="primary"):
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
                                            should_rerun = False
                                            if result:
                                                try:
                                                    parsed = json.loads(result[0][0]) if isinstance(result[0][0], str) else result[0][0]
                                                    if parsed.get("status") == "OK":
                                                        flash(f"Requisition {pr['REQ_ID']} updated to {new_status}.")
                                                        should_rerun = True
                                                    else:
                                                        st.warning(f"Result: {parsed.get('reason', parsed.get('status'))}")
                                                except Exception:
                                                    st.write(result)
                                        except Exception as e:
                                            st.error(f"Error: {e}")
                                        else:
                                            if should_rerun:
                                                refresh_page()

                # Manual acquisition: skips the supplier flow (local purchase, transfer, emergency vendor)
                with st.expander(f"Acquire manually (outside supplier flow) for {pr['REQ_ID']}", expanded=is_open(f"man_{pr['REQ_ID']}")):
                    st.caption("Use when the parts are sourced directly: this marks the requisition as RECEIVED, adds the stock and reserves it for the linked work order.")
                    with st.form(f"form_man_{pr['REQ_ID']}"):
                        mc1, mc2 = st.columns(2)
                        with mc1:
                            m_source = st.selectbox(
                                "Source", ["LOCAL_PURCHASE", "INTER_PLANT_TRANSFER", "EMERGENCY_VENDOR", "OTHER"],
                                key=f"msrc_{pr['REQ_ID']}",
                            )
                        with mc2:
                            m_actor = st.text_input("Your name", key=f"mact_{pr['REQ_ID']}", placeholder="e.g. STORES_KUMAR")
                        m_note = st.text_input("Reference / note (PO no., transfer no., vendor)", key=f"mnote_{pr['REQ_ID']}")
                        m_confirm = st.checkbox("I confirm the parts are physically in stock", key=f"mconf_{pr['REQ_ID']}")
                        mb1, mb2 = st.columns(2)
                        with mb1:
                            if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=(f"man_{pr['REQ_ID']}",)):
                                if not m_actor.strip():
                                    st.warning("Enter your name.")
                                else:
                                    try:
                                        session = get_session()
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.ACQUIRE_REQUISITION_MANUAL('{pr['REQ_ID']}', '{m_source}', "
                                            f"'{m_actor.strip().replace(chr(39), chr(39) * 2)}', '{m_note.strip().replace(chr(39), chr(39) * 2)}', TRUE)"
                                        ).collect()
                                        if result:
                                            st.json(result[0][0])
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                        with mb2:
                            if st.form_submit_button("Acquire & receive", type="primary"):
                                if not m_actor.strip():
                                    st.warning("Enter your name.")
                                elif not m_confirm:
                                    st.warning("Check the confirmation box.")
                                else:
                                    try:
                                        session = get_session()
                                        result = session.sql(
                                            f"CALL AEGIS_OEE.ACTION.ACQUIRE_REQUISITION_MANUAL('{pr['REQ_ID']}', '{m_source}', "
                                            f"'{m_actor.strip().replace(chr(39), chr(39) * 2)}', '{m_note.strip().replace(chr(39), chr(39) * 2)}', FALSE)"
                                        ).collect()
                                        parsed = json.loads(result[0][0]) if result and isinstance(result[0][0], str) else (result[0][0] if result else {})
                                        if parsed.get("status") != "OK":
                                            st.warning(f"Result: {parsed.get('reason', parsed.get('status'))}")
                                    except Exception as e:
                                        st.error(f"Error: {e}")
                                    else:
                                        if parsed.get("status") == "OK":
                                            flash(f"Requisition {pr['REQ_ID']} received manually ({m_source}); stock added and reserved for the work order.")
                                            refresh_page()

# ---- TAB 2: Inventory ----
if active_tab == TAB_NAMES[1]:
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
            render_kpi_card("Below Reorder", below, fmt="int", help="Parts whose on-hand quantity is at or below the reorder point.")
        with k2:
            render_kpi_card("Inventory Value", total_value, fmt="dollar", help="On-hand quantity x unit cost across all parts.")
        with k3:
            render_kpi_card("Total Reserved", total_reserved, fmt="int", help="Units held for approved work orders. Reserved stock is not available for new work orders.")

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
            st.markdown(f"#### Shortages vs Open Work Orders {info_tooltip('Parts required by open work orders that exceed available stock (on hand minus reserved). These need a requisition or a manual stock addition.')}", unsafe_allow_html=True)
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

        st.markdown(f"#### Full Inventory {info_tooltip('Every part with on-hand, reserved and available quantity, reorder point, unit cost and supplier. Source: CORE.PARTS_INVENTORY.')}", unsafe_allow_html=True)
        display_df = inv_df[["PART_ID", "PART_NAME", "CATEGORY", "ON_HAND_QTY", "RESERVED_QTY",
                             "AVAILABLE", "REORDER_POINT", "BELOW_REORDER", "UNIT_COST",
                             "SUPPLIER_NAME", "LEAD_TIME_DAYS", "BIN_LOCATION"]].copy()
        display_df["UNIT_COST"] = display_df["UNIT_COST"].apply(lambda x: f"${x:,.2f}")
        display_df["BELOW_REORDER"] = display_df["BELOW_REORDER"].map({True: "YES", False: ""})
        st.dataframe(display_df.reset_index(drop=True), use_container_width=True)

        # Manual stock receipt without a requisition
        with st.expander("Add stock manually (no requisition)", expanded=is_open("stock_form")):
            st.caption("For parts obtained outside the supplier flow. If an open requisition already covers the shortage, use the Requisitions tab instead to avoid double-counting.")
            open_wos = run_query("""
                SELECT WO_ID FROM AEGIS_OEE.ACTION.WORK_ORDER
                WHERE STATE NOT IN ('CLOSED', 'REJECTED', 'CANCELLED') ORDER BY APPROVED_TS DESC
            """, ttl=30)
            wo_options = ["(none)"] + (open_wos["WO_ID"].tolist() if not open_wos.empty else [])
            with st.form("form_stock"):
                sc1, sc2, sc3 = st.columns(3)
                with sc1:
                    s_part = st.selectbox("Part", inv_df["PART_ID"].tolist(), key="stk_part")
                with sc2:
                    s_qty = st.number_input("Quantity", min_value=1, value=1, step=1, key="stk_qty")
                with sc3:
                    s_source = st.selectbox(
                        "Source", ["LOCAL_PURCHASE", "INTER_PLANT_TRANSFER", "EMERGENCY_VENDOR", "RETURNED_STOCK", "OTHER"],
                        key="stk_source",
                    )
                sd1, sd2 = st.columns(2)
                with sd1:
                    s_actor = st.text_input("Your name", key="stk_actor", placeholder="e.g. STORES_KUMAR")
                with sd2:
                    s_wo = st.selectbox("Reserve for work order (optional)", wo_options, key="stk_wo")
                s_note = st.text_input("Reference / note (PO no., transfer no., vendor)", key="stk_note")
                s_confirm = st.checkbox("I confirm the parts are physically in stock", key="stk_confirm")

                def _stock_call(dry_run):
                    q = lambda v: v.strip().replace("'", "''")
                    wo_arg = "NULL" if s_wo == "(none)" else f"'{q(s_wo)}'"
                    return get_session().sql(
                        f"CALL AEGIS_OEE.ACTION.ADD_STOCK_MANUAL('{q(s_part)}', {int(s_qty)}, '{s_source}', "
                        f"'{q(s_actor)}', '{q(s_note)}', {wo_arg}, {'TRUE' if dry_run else 'FALSE'})"
                    ).collect()

                sb1, sb2 = st.columns(2)
                with sb1:
                    if st.form_submit_button("Preview (dry run)", on_click=remember_open, args=("stock_form",)):
                        if not s_actor.strip():
                            st.warning("Enter your name.")
                        else:
                            try:
                                res = _stock_call(True)
                                if res:
                                    st.json(res[0][0])
                            except Exception as e:
                                st.error(f"Error: {e}")
                with sb2:
                    if st.form_submit_button("Add stock", type="primary"):
                        if not s_actor.strip():
                            st.warning("Enter your name.")
                        elif not s_confirm:
                            st.warning("Check the confirmation box.")
                        else:
                            parsed = {}
                            try:
                                res = _stock_call(False)
                                parsed = json.loads(res[0][0]) if res and isinstance(res[0][0], str) else (res[0][0] if res else {})
                                if parsed.get("status") != "OK":
                                    st.warning(f"Result: {parsed.get('reason', parsed.get('status'))}")
                            except Exception as e:
                                st.error(f"Error: {e}")
                            else:
                                if parsed.get("status") == "OK":
                                    flash(f"Added {int(s_qty)} x {s_part} to stock ({s_source}).")
                                    refresh_page()

# ---- TAB 3: Suppliers ----
if active_tab == TAB_NAMES[2]:
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
