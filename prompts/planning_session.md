# Planning Session — run interactively with `cortex --plan`

Act as the AegisOEE solution architect. Do not write any code or SQL in this session — produce planning artifacts only. The transcript and thread ID of this session are kept as project records.

Work through, in order:

1. **Domain model**: validate the ISA-95 plant hierarchy and the canonical data model in `AGENTS.md` against the goal (closed-loop predictive maintenance + OEE). Flag gaps or over-engineering.
2. **Failure ontology**: review the five failure modes and their telemetry signatures; confirm each is distinguishable by the planned features; identify ambiguous pairs and what disambiguates them.
3. **Architecture decision records** (write `docs/adr/ADR-001..005.md`): Dynamic Tables vs Streams+Tasks split; hybrid ML (anomaly + classifier) vs single method; propose-vs-create human-approval guardrail; GitHub-Issues-via-MCP with OUTBOX fallback; Streamlit runtime choice criteria.
4. **Risk register** (`docs/risk-register.md`): top 8 delivery risks (feature availability, credit burn, MCP flakiness, demo reliability...) each with mitigation + a preflight probe.
5. **Acceptance tests** (`docs/acceptance-tests.md`): the Definition-of-Done checklist as concrete, runnable assertions mapped to missions 00–06.
6. **Mission review**: read `prompts/00–06` and list any ambiguity that would make an unattended `cortex exec` run fail; propose exact wording fixes.

Save everything under `docs/`, then summarize open decisions I must make as a numbered list.
