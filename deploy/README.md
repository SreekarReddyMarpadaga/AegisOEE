# AegisOEE — Deploy Guide

Two methods to build the full AegisOEE system from scratch.

## Method A — Agent Rebuild (CoCo CLI)

Uses CoCo CLI to execute numbered mission prompts. Each mission generates and runs its own SQL/code.

```bash
# Prerequisites: CoCo CLI installed, snow CLI, Python 3.12 venv, connection named 'aegis'
bash scripts/build_all.sh
```

This runs missions 00→06 headlessly (see main README "Build everything" section for details). Each mission is idempotent and logs to `docs/runs/`.

## Method B — Direct Deploy (No LLM Required)

Replays the exact Snowflake objects from a known-good build. Data regenerates deterministically (seed 42); ML models retrain from scratch.

### Prerequisites

- **Snowflake CLI** (`snow`) installed and authenticated
- **Python 3.12** virtual environment with: `snowflake-snowpark-python pandas numpy`
- **Snowflake privileges**: CREATE DATABASE, CREATE WAREHOUSE, plus CREATE on TABLE, DYNAMIC TABLE, TASK, STREAM, STAGE, STREAMLIT, PROCEDURE, CORTEX SEARCH SERVICE, SEMANTIC VIEW
- **Optional** (for outbound ticketing/notifications): `GITHUB_PAT` (fine-grained, Issues RW), `SLACK_WEBHOOK_URL`, `gh` CLI authenticated

### Run

```bash
cd deploy
chmod +x deploy_all.sh load_data.sh sql/09_app.sh
./deploy_all.sh <connection_name>
```

### What each step does

| Step | File | What it creates | Time |
|------|------|-----------------|------|
| 01 | `sql/01_database_warehouses.sql` | `AEGIS_OEE` DB, 8 schemas, 2 warehouses, 3 stages | ~5s |
| 02 | `sql/02_tables.sql` | 23 tables across CORE/RAW/ACTION/ML/TEST/SEMANTIC | ~5s |
| 03 | `load_data.sh` | Runs `data_gen/backfill.py` (seed 42) → 10 tables loaded, docs uploaded to DOC_STAGE | ~3-5 min |
| 04 | `sql/04_streams_dynamic_tables.sql` | 2 streams, 7 Dynamic Tables, 7 views + 120s DT init wait | ~3 min |
| 05 | `sql/05_ml_models.sql` | 3 anomaly detection + 2 forecast models, scoring procs, backfill, DT_ASSET_HEALTH | **15-30 min** |
| 06 | `sql/06_semantic_search.sql` | Semantic view (MANUFACTURING_OPERATIONS), Cortex Search (MAINTENANCE_SEARCH) | ~1 min |
| 07 | `sql/07_agent.sql` | GET_ASSET_EVIDENCE, PROPOSE_WORK_ORDER procs, MCP server, agent deploy | ~1 min |
| 08 | `sql/08_action_loop.sql` | SCORE_ALERTS, CHECK_PARTS, CREATE_WORK_ORDER, outbox procs, 3 tasks (suspended) | ~10s |
| 09 | `sql/09_app.sh` | Streamlit app: AEGIS_OEE_COMMAND_CENTER (6 pages) | ~30s |
| 10 | `sql/10_verify.sql` | Row counts, DT refresh, model presence, OEE sanity — prints PASS/FAIL | ~10s |

**Expected total runtime: ~25-40 minutes** (dominated by ML model training in step 05).

### ML training step

Step 05 trains 5 Snowflake ML models (3 anomaly detection, 2 forecast) on the backfilled data, then runs historical scoring across ~260K anomaly events. This is the slowest step. The models use healthy-only training data (first 30 days, excluding ground-truth degradation windows) and score the full 75-day dataset.

### Outbox dispatcher (local)

Tasks create OUTBOX rows for GitHub Issues and Slack notifications. Actual HTTP dispatch runs locally:

```bash
export GITHUB_PAT="..."
export SLACK_WEBHOOK_URL="..."
python scripts/outbox_dispatcher.py
```

The dispatcher:
1. Polls `ACTION.WORK_ORDER_OUTBOX` for PENDING items
2. Creates GitHub Issues with full evidence (parts table, requisition quotes, safety statement)
3. Sends Slack notifications with asset/priority/mode details
4. Closes GitHub Issues when work orders reach CLOSED/REJECTED state
5. Syncs inbound: GitHub issue closures → WO state transitions (RESOLVED/CANCELLED)

For accounts with External Access Integrations (EAI), `sql/11_integrations.sql` in the main repo has the native Snowflake versions of these procs (commented, requires EAI setup).

### What's NOT replicable without an agent

- **External Access Integrations (EAI)**: Account-level feature requiring ACCOUNTADMIN. The outbox dispatcher handles this locally instead.
- **Agent deployment**: The `AEGIS_RCA_AGENT` Cortex Agent is deployed via `cortex project deploy`. If `cortex` CLI is unavailable, deploy manually through Snowsight.
- **CoCo automations** (hourly triage, daily digest): Require CoCo CLI. Use cron + `cortex exec` as fallback.
