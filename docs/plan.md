# AegisOEE — Build Plan & Status (single source of truth)

> **For AI assistants (CoCo) resuming work**: read this file, `AGENTS.md` (conventions/data model/guardrails), `docs/run-records.md` (logs + usage reference), and `docs/team-handoff.md` (team workflow + environment gotchas), then continue from **Current Status** below. Update the status table as work completes — this file replaces any chat-session memory.

## Product

Closed-loop predictive maintenance + OEE Command Center, 100% Snowflake, built AND operated via CoCo CLI.
Golden path: `CNC_01_SPINDLE` bearing wear → P1 alert → evidence-backed RCA → human approval → governed work order → GitHub Issue (MCP) + Slack → audit.
Target: working prototype by **Sept 1, 2026**. CoCo is used across planning, development, execution, and testing. Extensibility in scope: 3 shared skills, MCP integration, automations, subagents, hooks, multi-surface usage.

## Current Status

| # | Work item | Status | Notes |
|---|---|---|---|
| 0.1 | Workbench scaffold (AGENTS.md, skills ×3, subagents ×4, sql-guard hook, missions 00–06, scripts, evidence guide) | ✅ DONE | committed |
| 0.2 | Toolchain on Linux (cortex, snow, python venv) | ✅ DONE | Fedora 44 WSL + uv, venv py3.12 |
| 0.3 | Connection `aegis` + model check | ✅ DONE | renamed conn broke CoCo's cached `cortexAgentConnectionName`/`sqlConnectionName` in `~/.snowflake/cortex/settings.json` — patched to `aegis` (backup kept) |
| 0.4 | GitHub PAT + MCP + Slack webhook + permissions.json | ⬜ TODO | Runbook §3 |
| 0.5 | `scripts/preflight_probes.sh` all green | ✅ DONE | CORTEX_COMPLETE PASS (llama3.1-8b; 'snowflake-arctic' invalid name), COCO_USAGE_HISTORY PASS (8 rows → Built-with-CoCo panel viable), EXECUTE_AGENT_TASK PASS (PUBLIC); automations account-gated → opt-in wrapper `scripts/with_automations.sh` accepted; headless runs use `--bypass` + sql-guard hook |
| 0.6 | Planning session (`cortex --plan` + prompts/planning_session.md) → ADRs, risks, acceptance tests + thread ID logged | ⬜ TODO | planning artifacts |
| 1 | Mission 00 foundation (`MISSION 00 COMPLETE`) | ⬜ TODO | |
| 2 | Mission 01 synthetic data + validation report | ⬜ TODO | long run (~1M rows) |
| 3 | Mission 02 pipelines (DTs INCREMENTAL, OEE reconciles, freshness <120s) | ⬜ TODO | after step 2 |
| 4 | Mission 03 ML (recall ≥0.8, lead ≥24h vs ground truth) | ⬜ TODO | after step 3 |
| 5 | Mission 04 semantics + RCA agent (eval ≥80%) | ⬜ TODO | after step 4 |
| 6 | Mission 05 action loop (guardrail tests pass) | ⬜ TODO | after step 5 |
| 7 | Mission 06 Streamlit Command Center + CoCo panel | ⬜ TODO | after step 6 |
| 8 | Automations pm_triage + oee_digest (or Tasks fallback) | ⬜ TODO | with step 7 |
| 9 | Publish + share 3 skills (snow:// links), request certification | ⬜ TODO | after core build |
| 10 | QA swarm, fresh-clone rebuild, edge cases, evidence compile | ⬜ TODO | after step 9 |
| 11 | Demo video (≤5 min) + backup recording + submit | ⬜ TODO | final step, before Sept 1 |

## Runbook — environment (Fedora 44 WSL, repo on /mnt/c, Python via uv)

```bash
# §1 toolchain
sudo dnf install -y git jq
uv tool install snowflake-cli                                          # 'snow' CLI
curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh   # installs ~/.local/bin/cortex
# venv pinned to 3.12 (Snowpark/connector wheels don't support 3.14); keep venv in ~ not /mnt/c
uv python install 3.12
uv venv ~/.venvs/aegis --python 3.12 && source ~/.venvs/aegis/bin/activate
uv pip install snowflake-snowpark-python pandas numpy
# one-time repo prep on the /mnt/c mount:
#   sed -i 's/\r$//' scripts/*.sh .cortex/hooks/sql-guard.sh ; git config core.autocrlf input
#   export BROWSER="powershell.exe /c start"   # WSL→Windows browser for SSO (or use PAT)

# §2 connection (~/.snowflake/connections.toml, chmod 600): [aegis] account/user/authenticator=externalbrowser (or password=<PAT>)
cortex -c aegis -p "Reply with exactly OK"        # then interactive /model → auto

# §3 integrations
export GITHUB_PAT=... SLACK_WEBHOOK_URL=...        # persist in ~/.bashrc
cortex mcp add github https://api.githubcopilot.com/mcp/ --type http -H "Authorization: Bearer ${GITHUB_PAT}"
# permissions.json: allow create/list/get/update issues; deny deletes/merges

# §4 execute
bash scripts/preflight_probes.sh
cortex --plan -c aegis                             # run prompts/planning_session.md → log thread ID
cortex exec --file prompts/00_foundation.md -c aegis --bypass 2>&1 | tee docs/runs/mission_00.log
cortex exec --file prompts/01_synthetic_data.md -c aegis --bypass 2>&1 | tee docs/runs/mission_01.log
# ... then missions 02–06 in order (or scripts/build_all.sh once 00–01 verified)
```

After every mission: verify `MISSION NN COMPLETE`, review generated files, `git add -A && git commit -m "mission NN: <summary> (thread <ID>)" && git push`, update this status table.

## Key decisions (locked)

- DB `AEGIS_OEE`; connection alias `aegis` ($COCO_CONN); seed 42; timezone Asia/Kolkata.
- Ticketing = GitHub Issues via MCP + Slack webhook; OUTBOX fallback (no Jira license).
- Agent proposes, human approves (`CREATE_WORK_ORDER` guarded, DRY_RUN default, append-only audit).
- Hosted automations hourly (no local MCP in sandbox → GitHub leg runs via CLI); native 5-min task does alert scoring.
- Streamlit container runtime preferred, warehouse+proc-wrapper fallback (probe decides).
- ML: Cortex ANOMALY_DETECTION + FORECAST, XGBoost stretch; z-score fallback if probes fail.
- Probe-verified: CORTEX.COMPLETE works (use valid model names, e.g. llama3.1-8b — NOT 'snowflake-arctic'); SNOWFLAKE_COCO_USAGE_HISTORY accessible; EXECUTE AGENT TASK on PUBLIC; automations need `scripts/with_automations.sh` wrapper (account gate, local opt-in works).

## Cut order if behind

XGBoost classifier → Snowsight Intelligence agent → 2nd automation → twin visuals polish.
**Never cut**: golden path reliability, OEE reconciliation, recall stat, approval guardrail, agent eval, 3 skills, evidence ledger, backup recording.
