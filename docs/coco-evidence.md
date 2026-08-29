# CoCo Usage — Verification Notes

AegisOEE is planned, developed, executed, and tested through CoCo. This page lists where that activity is recorded and how to check it — either by inspecting this repo or by replicating the build in your own Snowflake environment (see the README's "Replicate" section; a full rebuild regenerates all of these records under your own account).

## Quick checks

1. **Account-level usage** (after any rebuild, in your account):
   ```sql
   SELECT interface, COUNT(*) AS requests, SUM(token_credits) AS credits
   FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
   GROUP BY interface;
   ```
   The same panel renders live in the Streamlit app sidebar.
2. **Mission transcripts**: raw headless run logs in `docs/evidence/raw/mission_NN_*.log` — each ends with `MISSION NN COMPLETE`. Session IDs are listed by `cortex conversations list`; full transcripts via `cortex conversations transcript <id>`.
3. **Guardrail activity**: `.cortex/hooks/tool-log.jsonl` records every tool call the sql-guard hook inspected, including blocked destructive statements.
4. **Snapshots**: `bash scripts/capture_evidence.sh` regenerates CLI/usage snapshots into `docs/evidence/raw/`.

## Phase-by-phase

| Phase | Evidence | Where |
|---|---|---|
| Planning | Architecture ADRs, risk register, acceptance tests from a `cortex --plan` session | `docs/adr/`, `docs/risk-register.md`, `docs/acceptance-tests.md` + session transcript |
| Development | Mission prompts (input) and generated artifacts (output) side by side | `prompts/00–06` → `sql/`, `data_gen/`, `semantic/`, `ml/`, `app/` + mission logs |
| Execution | Scheduled triage + daily digest agent runs; live demo levers | `prompts/triage-automation.md`, `prompts/daily-oee-digest.md`, `cortex automation list/describe` (or cron logs), `scripts/inject_anomaly.sh` |
| Testing | Data validation, ML recall vs labeled ground truth, agent eval, guardrail tests — all CoCo-run and persisted | `tests/`, `AEGIS_OEE.TEST` schema (`VALIDATION_RESULTS`, `ML_METRICS`, `AGENT_EVAL_RESULTS`, `ACTION_GUARDRAIL_RESULTS`) |

## Extensibility used

Project skills (`.cortex/skills/` — also shareable via `snow://skill_catalog/...` links), specialist subagents (`.cortex/agents/`), PreToolUse guardrail hook, GitHub MCP server for work-order ticketing, hosted automations (with cron fallback where account-gated).

## Session log

| Date | Activity | Session/Thread ID |
|---|---|---|
| | Planning session (`prompts/planning_session.md`) | |
| | Missions 00–06 (see `docs/evidence/raw/`) | |
| | Automations / live triage runs | |
