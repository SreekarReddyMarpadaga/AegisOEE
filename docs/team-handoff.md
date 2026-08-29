# AegisOEE — Team Handoff & AI-Session Bootstrap

**For teammates joining the build.** This file turns any fresh AI coding session (CoCo CLI, CoCo Desktop, or CoCo in Snowsight) into a fully briefed collaborator. It complements (never replaces) the three canonical files: `docs/plan.md` (status + runbook), `AGENTS.md` (data model + conventions + guardrails), `docs/coco-evidence.md` (reviewer evidence guide).

---

## How to onboard (5 minutes)

1. Clone the repo, open it in VS Code (WSL users: work via your distro; see Environment facts below).
2. Start a CoCo session and paste the **Bootstrap Prompt** below.
3. Set up your own credentials (never commit any): Snowflake connection alias `aegis` in `~/.snowflake/connections.toml`, plus `GITHUB_PAT` / `SLACK_WEBHOOK_URL` env vars if you work on the action loop.
4. Run `bash scripts/preflight_probes.sh` before touching Snowflake.

## Bootstrap Prompt (paste into your CoCo session)

```text
You are joining the AegisOEE project mid-build. Before anything else, read these
files in order and treat them as your memory: docs/plan.md (single source of truth for
status + runbook), AGENTS.md (canonical data model, naming, physics, guardrails),
docs/coco-evidence.md (evidence ledger), docs/team-handoff.md (this workflow + environment
gotchas). Then:
1. Report the current status table from docs/plan.md and identify the next open step.
2. Follow the Working Agreements and Locked Decisions in docs/team-handoff.md exactly.
3. Never invent new object/database names — AGENTS.md is authoritative (DB AEGIS_OEE).
4. When you complete work: update the docs/plan.md status table, append evidence rows to
   docs/coco-evidence.md, and commit with the mission/step and CoCo thread ID in the message.
Confirm you have read all four files and state the next open step before doing any work.
```

## Locked decisions (change only by team agreement — record changes in docs/plan.md)

- DB `AEGIS_OEE`; schemas RAW/CORE/FEATURES/ML/SEMANTIC/ACTION/APP/TEST; connection alias `aegis` (override `$COCO_CONN`); seed 42; timezone Asia/Kolkata; golden path = `CNC_01_SPINDLE` BEARING_WEAR.
- Ticketing = GitHub Issues via MCP + Slack webhook, OUTBOX fallback. Agent proposes, human approves (`CREATE_WORK_ORDER` guarded, DRY_RUN default, append-only audit).
- Missions are the build system: `cortex exec --file prompts/NN_*.md -c aegis --bypass`, must end `MISSION NN COMPLETE`, artifacts written to repo before execution.
- Repo artifacts use mission/step numbering only — no day-based names or schedule language.

## Working agreements

1. **One Snowflake writer at a time.** All missions mutate the shared `AEGIS_OEE` database — coordinate in chat before running any mission (00–06) or task/alert changes. Prompt/skill/app-code work is parallel-safe on branches.
2. Branch per member; PR back to main; the best variant wins on evidence (test results, eval scores), recorded in plan.md Key decisions.
3. After every mission run: verify completion line, review generated files, update plan.md status, append to coco-evidence.md, commit with thread ID (`cortex conversations list`).
4. Never commit secrets (PATs, webhooks, connections.toml). The sql-guard hook (.cortex/hooks/) stays enabled — its log is part of the project record.
5. Improvements welcome anywhere EXCEPT: golden-path reliability, OEE reconciliation invariants, approval guardrail, agent evaluation, 3 skills, evidence records. Those are core to the solution and only get *strengthened*.

## Environment facts (hard-won — trust these)

| Fact | Detail |
|---|---|
| Headless tool gate | `cortex -p` / `cortex exec` block tool calls by default → always add `--bypass` (sql-guard hook remains the safety net). All repo scripts already do this. |
| Connection rename trap | CoCo caches `cortexAgentConnectionName` + `sqlConnectionName` in `~/.snowflake/cortex/settings.json`. If your connection alias differs, fix those two keys or you get "Cannot create dedicated connection". |
| Automations | Account-gated. Local opt-in works via `scripts/with_automations.sh` (sets `CORTEX_CODE_EXPERIMENTAL_FEATURES`). Server-side create still unverified; fallback = native Tasks + cron `cortex exec`. |
| Cortex models | `SNOWFLAKE.CORTEX.COMPLETE` works; use valid model names (e.g. `llama3.1-8b`) — `snowflake-arctic` is NOT valid. `/model` in a session lists what your account has. |
| Verified grants | `EXECUTE AGENT TASK` on PUBLIC; `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY` readable (powers the Built-with-CoCo panel). |
| Python | Use a **3.12** venv (`uv venv ~/.venvs/aegis --python 3.12; uv pip install snowflake-snowpark-python pandas numpy`) — Snowpark does not support 3.14. Activate it in the same shell before `cortex exec`. Keep venvs OUT of /mnt/c. |
| WSL specifics | `sed -i 's/\r$//' scripts/*.sh .cortex/hooks/sql-guard.sh` once after checkout; `git config core.autocrlf input`; `export BROWSER="powershell.exe /c start"` for SSO (or use a PAT); quote spaced paths; pause OneDrive sync while missions run if repo is on /mnt/c. |
| `which: no cocobox` noise | Harmless — CoCo's optional sandbox binary is absent; commands run unsandboxed. |

## Repo map (30 seconds)

`prompts/00–06` missions build everything (foundation → data → pipelines → ML → semantics/agent → action loop → app); `prompts/triage-automation.md` + `daily-oee-digest.md` are unattended automation prompts; `.cortex/` holds the 3 reusable skills, 4 subagents, sql-guard hook; `scripts/` is the harness (`preflight_probes`, `build_all`, `inject_anomaly`, `demo_reset`, `capture_evidence`, `with_automations`); generated artifacts land in `sql/`, `data_gen/`, `ml/`, `semantic/`, `app/`, `tests/` and are committed for review + re-run.

## Merge protocol (end-state)

Individual experiments → PR with evidence (validation report, ML metrics, eval scores, screenshots) → team picks best per component → merged main must pass: full `scripts/build_all.sh` on clean state, OEE reconciliation, ML recall ≥ 0.8 with ≥ 24h lead, agent eval ≥ 80%, guardrail tests, golden-path replay. Submission before **Sept 1, 2026**.
