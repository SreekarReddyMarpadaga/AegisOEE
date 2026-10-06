# AegisOEE — Deploy Guide

Two methods to build the full AegisOEE system from scratch.

## Method A — Agent Rebuild (CoCo CLI)

Uses CoCo CLI to execute numbered mission prompts. Each mission generates and runs its own SQL/code.

```bash
# Prerequisites: CoCo CLI installed, snow CLI, Python 3.12 venv, connection named 'aegis'
bash scripts/build_all.sh
```

This runs missions 00→07 headlessly (see main README "Build everything" section for details). Each mission is idempotent and logs to `docs/runs/`.

## Method B — Direct Deploy (No LLM Required)

Replays the exact Snowflake objects from a known-good build. Data regenerates deterministically (seed 42); ML models retrain from scratch. No CoCo/`cortex` CLI calls anywhere in the deploy pipeline.

### Prerequisites

- **Snowflake CLI** (`snow`) installed and authenticated
- **Python 3.12** virtual environment with: `snowflake-snowpark-python pandas numpy pyarrow`
- **Snowflake privileges**: CREATE DATABASE, CREATE WAREHOUSE, plus CREATE on TABLE, DYNAMIC TABLE, TASK, STREAM, STAGE, STREAMLIT, PROCEDURE, CORTEX SEARCH SERVICE, SEMANTIC VIEW, AGENT
- **Optional** (for outbound ticketing/notifications): `GITHUB_PAT` (fine-grained, Issues RW), `SLACK_WEBHOOK_URL`, `gh` CLI authenticated

### Run

```bash
cd deploy
chmod +x deploy_all.sh load_data.sh sql/09_app.sh
./deploy_all.sh <connection_name>
```

### Resume / partial run

```bash
# Resume from a specific step (e.g., after a failure at step 05):
./deploy_all.sh <connection_name> --from 05

# Run only one step:
./deploy_all.sh <connection_name> --only 07
```

### What each step does

| Step | File | What it creates | Time |
|------|------|-----------------|------|
| 01 | `sql/01_database_warehouses.sql` | `AEGIS_OEE` DB, 8 schemas, 2 warehouses, 4 stages | ~5s |
| 02 | `sql/02_tables.sql` | 26 tables across CORE/RAW/ACTION/ML/TEST/SEMANTIC | ~5s |
| 03 | `load_data.sh` | Runs `data_gen/backfill.py` (seed 42) → 10 tables loaded, docs → DOC_STAGE | ~3-5 min |
| 04 | `sql/04_streams_dynamic_tables.sql` | 2 streams, 7 Dynamic Tables, 7 views + DT polling | ~3 min |
| 05 | `sql/05_ml_models.sql` | 3 anomaly detection + 2 forecast models, scoring procs, backfill, DT_ASSET_HEALTH | **15-30 min** |
| 06 | `sql/06_semantic_search.sql` | Semantic view (MANUFACTURING_OPERATIONS), Cortex Search (MAINTENANCE_SEARCH) | ~1 min |
| 07 | `sql/07_agent.sql` | GET_ASSET_EVIDENCE, PROPOSE_WORK_ORDER procs, MCP server, **Cortex Agent via SQL** | ~1 min |
| 08 | `sql/08_action_loop.sql` | SCORE_ALERTS, CHECK_PARTS, CREATE_WORK_ORDER, WO lifecycle procs, 2 tasks (suspended) | ~10s |
| 11 | `sql/11_cmms_planning.sql` + `cmms_plan.py` | CMMS scheduling procs, maintenance windows, 1 task (suspended) | ~30s |
| 09 | `sql/09_app.sh` | Streamlit app: AEGIS_OEE_COMMAND_CENTER (warehouse runtime) | ~30s |
| 10 | `sql/10_verify.sql` | Row counts, DT refresh, ML models, agent, OEE sanity — prints PASS/FAIL | ~10s |

**Expected total runtime: ~25-40 minutes** (dominated by ML model training in step 05).

### Agent deployment

The Cortex Agent (`AEGIS_RCA_AGENT`) is deployed via `CREATE AGENT ... FROM SPECIFICATION` SQL in step 07. No `cortex project deploy` or `cortex` CLI is needed. The agent spec was extracted from the live account.

### ML training step

Step 05 trains 5 Snowflake ML models (3 anomaly detection, 2 forecast) on the backfilled data, then runs historical scoring across ~260K anomaly events. This is the slowest step. The models use healthy-only training data (first 30 days, excluding ground-truth degradation windows) and score the full 75-day dataset.

### Outbox dispatcher (local)

Tasks create OUTBOX rows for GitHub Issues and Slack notifications. Actual HTTP dispatch runs locally:

```bash
export GITHUB_PAT="..."
export SLACK_WEBHOOK_URL="..."
python scripts/outbox_dispatcher.py
```

For accounts with External Access Integrations (EAI), see `deploy/optional/github_slack_eai.sql`.

### Verification

Step 10 runs comprehensive checks: row counts, Dynamic Table refresh state, semantic view, Cortex Search, ML models, agent, task state, Streamlit app, procedure existence, OEE sanity range. Any FAIL result is printed clearly.

### End-to-end golden-path check

After deployment, run the E2E check to verify the full work-order lifecycle:

```bash
COCO_CONN=<connection_name> bash scripts/demo_e2e_check.sh
```

### What's NOT deployed without Cortex

- **CHECK_PARTS** RFQ text uses `SNOWFLAKE.CORTEX.COMPLETE` — gracefully degrades to empty text in non-Cortex regions.
- **Cortex Search** and **Agent** require Cortex availability. All other objects deploy successfully without it.

### Optional integrations

- `deploy/optional/github_slack_eai.sql` — External Access Integration for GitHub/Slack (requires ACCOUNTADMIN)
- `scripts/outbox_dispatcher.py` — Local HTTP dispatcher for GitHub Issues and Slack
