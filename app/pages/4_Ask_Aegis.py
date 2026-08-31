import streamlit as st
import json
from utils import apply_theme, render_header, render_sidebar, get_session, info_tooltip

apply_theme()
render_sidebar()
render_header("Ask Aegis", "Chat with the RCA agent for root cause analysis and recommendations")

if "aegis_messages" not in st.session_state:
    st.session_state.aegis_messages = []
if "aegis_input_counter" not in st.session_state:
    st.session_state.aegis_input_counter = 0

st.markdown(
    '<div class="info-card">'
    f'<strong>Try asking:</strong> "What is causing elevated vibration on CNC_01_SPINDLE '
    f'and what maintenance action do you recommend?" '
    f'{info_tooltip("Aegis uses the AEGIS_RCA_AGENT Cortex Agent which orchestrates across Cortex Analyst (structured OEE/production data via MANUFACTURING_OPERATIONS semantic view), Cortex Search (maintenance manuals and technician notes), and MCP tools (GET_ASSET_EVIDENCE, PROPOSE_WORK_ORDER). Responses follow a 7-part RCA structure: Assessment, Evidence, Operational Impact, Alternatives, Recommended Action, Safety Statement, Trace.")}'
    '</div>',
    unsafe_allow_html=True,
)

# Display chat history
for msg in st.session_state.aegis_messages:
    role_label = "**You:**" if msg["role"] == "user" else "**Aegis:**"
    st.markdown(f'{role_label} {msg["content"]}')
    if msg.get("trace"):
        with st.expander("Evidence / Trace"):
            st.markdown(msg["trace"])

st.divider()

# Chat input — key changes on each send to clear the box
col_input, col_btn = st.columns([5, 1])
with col_input:
    prompt = st.text_input(
        "Ask Aegis",
        key=f"aegis_input_{st.session_state.aegis_input_counter}",
        label_visibility="collapsed",
        placeholder="Ask about asset health, alerts, RCA, or maintenance...",
    )
with col_btn:
    send = st.button("Send")

if send and prompt and prompt.strip():
    st.session_state.aegis_messages.append({"role": "user", "content": prompt})
    st.session_state.aegis_input_counter += 1  # clear the input on rerun

    with st.spinner("Aegis is thinking..."):
        session = get_session()
        response_text = None
        trace_text = None
        # Escape for JSON string embedding
        safe_prompt = prompt.replace("\\", "\\\\").replace('"', '\\"')

        # Call agent via DATA_AGENT_RUN (correct SQL syntax)
        try:
            request_body = '{"messages": [{"role": "user", "content": [{"type": "text", "text": "' + safe_prompt + '"}]}]}'
            result = session.sql(
                f"""SELECT TRY_PARSE_JSON(
                    SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
                        'AEGIS_OEE.ACTION.AEGIS_RCA_AGENT',
                        $${request_body}$$,
                        TRUE
                    )
                ) AS RESP"""
            ).collect()
            if result and result[0]["RESP"]:
                resp = result[0]["RESP"]
                if isinstance(resp, str):
                    resp = json.loads(resp)
                # Extract text from the agent response content array
                content = resp.get("content", []) if isinstance(resp, dict) else []
                text_parts = []
                trace_parts = []
                for item in content:
                    if isinstance(item, dict):
                        if item.get("type") == "text":
                            text_parts.append(item.get("text", ""))
                        elif item.get("type") == "thinking":
                            thinking = item.get("thinking", {})
                            if isinstance(thinking, dict):
                                trace_parts.append(f"**Thinking:** {thinking.get('text', '')[:500]}")
                        elif item.get("type") == "tool_use":
                            tool_info = item.get("tool_use", {})
                            if isinstance(tool_info, dict):
                                trace_parts.append(f"**Tool:** {tool_info.get('name', 'unknown')}")
                        elif item.get("type") == "tool_result":
                            trace_parts.append("**Tool result received**")
                if text_parts:
                    response_text = "\n\n".join(text_parts)
                if trace_parts:
                    trace_text = "\n\n".join(trace_parts)
        except Exception as agent_err:
            trace_text = f"**Agent error:** {agent_err}"

        # Fallback: CORTEX.COMPLETE with asset evidence context
        if not response_text:
            try:
                evidence_result = session.sql(
                    "CALL AEGIS_OEE.ACTION.GET_ASSET_EVIDENCE('CNC_01_SPINDLE')"
                ).collect()
                evidence_ctx = str(evidence_result[0][0])[:3000] if evidence_result else "No evidence."
            except Exception:
                evidence_ctx = "No evidence available."

            system_msg = (
                "You are Aegis, an expert predictive maintenance AI for manufacturing equipment. "
                "Answer using the Assessment / Evidence / Operational impact / Alternatives / "
                "Recommended action / Safety statement structure. "
                f"Context from asset evidence: {evidence_ctx}"
            ).replace("'", "''")

            try:
                fb_result = session.sql(
                    f"""SELECT SNOWFLAKE.CORTEX.COMPLETE(
                        'llama3.1-70b',
                        ARRAY_CONSTRUCT(
                            OBJECT_CONSTRUCT('role', 'system', 'content', '{system_msg}'),
                            OBJECT_CONSTRUCT('role', 'user', 'content', '{safe_prompt}')
                        ),
                        OBJECT_CONSTRUCT('temperature', 0.3, 'max_tokens', 2000)
                    )::STRING AS RESPONSE"""
                ).collect()
                if fb_result and fb_result[0]["RESPONSE"]:
                    raw_fb = fb_result[0]["RESPONSE"]
                    try:
                        parsed_fb = json.loads(raw_fb)
                        if isinstance(parsed_fb, dict) and "choices" in parsed_fb:
                            response_text = parsed_fb["choices"][0].get("messages", str(parsed_fb))
                        elif isinstance(parsed_fb, dict) and "message" in parsed_fb:
                            response_text = parsed_fb["message"]
                        else:
                            response_text = str(parsed_fb)
                    except (json.JSONDecodeError, TypeError):
                        response_text = raw_fb
                    trace_text = "**Note:** Used CORTEX.COMPLETE with asset evidence context (agent not available)."
            except Exception as fb_err:
                response_text = f"Unable to process your request. Error: {fb_err}"
                trace_text = f"**Fallback error:** {fb_err}"

        st.session_state.aegis_messages.append({
            "role": "assistant",
            "content": response_text or "No response received. Please try again.",
            "trace": trace_text,
        })

    st.rerun()

# Clear chat
if st.session_state.aegis_messages:
    if st.button("Clear Chat"):
        st.session_state.aegis_messages = []
        st.session_state.aegis_input_counter += 1
        st.rerun()
