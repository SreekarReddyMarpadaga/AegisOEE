# Mission 04 — Semantic Layer, Search, and the RCA Agent

Read `AGENTS.md`. Use `$oee-analytics` for metric definitions and the bundled `$agent-studio` and `$search-optimization` skills. Non-interactive: print `MISSION 04 FAILED: <reason>` on unrecoverable errors.

## Objective

Natural-language layer: semantic view for Cortex Analyst, Cortex Search over maintenance docs, and the governed RCA Orchestrator agent.

## Deliverables

1. `sql/07_semantic_view.sql` + `semantic/manufacturing_operations.yaml` — semantic view `SEMANTIC.MANUFACTURING_OPERATIONS`:
   - Entities/relationships: Site → Line → Asset; Product → Production Order; Asset → Alert → Work Order.
   - Dimensions: shift, asset type, line, product, failure mode, alert severity, WO state.
   - Facts: downtime minutes, produced/good/reject units, anomaly distance, failure probability.
   - Metrics: availability, performance, quality, OEE (derived from sums per `$oee-analytics`), MTBF, MTTR, alert count, estimated OEE loss.
   - Rich descriptions + synonyms; **15 verified queries** saved to `semantic/verified_queries.yaml` covering the demo questions.
2. `sql/08_search_service.sql` — Cortex Search service `SEMANTIC.MAINTENANCE_SEARCH` over parsed DOC_STAGE files + `CORE.MAINTENANCE_HISTORY.technician_note` (chunked), attribute-filtered by asset_id, executed.
3. Agent tools in `sql/09_agent_tools.sql`:
   - `ACTION.GET_ASSET_EVIDENCE(asset_id)` — returns the evidence bundle JSON per `$maintenance-triage`.
   - `ACTION.PROPOSE_WORK_ORDER(alert_id)` — returns draft JSON only, zero side effects, audit row 'PROPOSED'.
4. Cortex Agent `AEGIS_RCA_AGENT` (via agent-studio): tools = Cortex Analyst (semantic view), Cortex Search (MAINTENANCE_SEARCH), GET_ASSET_EVIDENCE, PROPOSE_WORK_ORDER. Instructions enforce the response structure (Assessment/Evidence/Impact/Alternatives/Recommendation/Safety/Trace), the confidence gate, "most likely cause" phrasing, and NEVER approving work. Deploy so it is visible in Snowflake Intelligence (multi-surface evidence).
5. `tests/analyst_eval.md` — 25 evaluation questions (factual, causal, tool-routing, refusal, missing-data) each with expected grounding; run them, score pass/fail, persist to `TEST.AGENT_EVAL_RESULTS`.
6. Append run record + eval scores to `docs/coco-evidence.md` ("Development" + "Testing").

## Acceptance criteria

- All 15 verified queries return numbers matching direct SQL within tolerance.
- Agent eval ≥ 80% pass; every causal answer cites asset-specific telemetry or maintenance evidence (Evidence Grounding rule); refusal cases actually refuse.
- "Why is CNC_01_SPINDLE at risk?" returns bearing-wear assessment citing vibration slope + prior bearing maintenance.

Print `MISSION 04 COMPLETE` when done.
