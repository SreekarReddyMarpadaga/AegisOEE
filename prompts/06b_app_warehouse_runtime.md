# Mission 06B — Redeploy the app on the warehouse runtime (with page 7)

Read `AGENTS.md`. Non-interactive: print `MISSION 06B FAILED: <reason>` on unrecoverable errors. Do not change app logic; only fix deployment.

## Problem (verified by the reviewer)

`DESCRIBE STREAMLIT AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER` currently reports `runtime_name = SYSTEM$ST_CONTAINER_RUNTIME_PY3_11` and `compute_pool = SYSTEM_COMPUTE_POOL_CPU`, even though `app/snowflake.yml` has no runtime/compute_pool and earlier logs claimed "warehouse runtime". The container runtime bills a compute pool while the app is open and is not portable for replication. The new `app/pages/7_Shift_Plan.py` may also not be deployed.

## Deliverables

1. `DROP STREAMLIT IF EXISTS AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER`, then redeploy with `snow streamlit deploy --replace` from `app/` (copy to a path without spaces first if needed; remove `__pycache__`). Re-run `DESCRIBE STREAMLIT` and **prove** `compute_pool` is empty and `runtime_name` is not a container runtime.
2. If the CLI still produces a container-runtime app, create the app the stage-based way instead (upload the files to `@AEGIS_OEE.APP.APP_STAGE/<dir>` incl. `environment.yml` and all 7 pages, then `CREATE OR REPLACE STREAMLIT ... ROOT_LOCATION/FROM ... MAIN_FILE = 'Home.py' QUERY_WAREHOUSE = AEGIS_APP_WH`), and re-prove with `DESCRIBE`. Record the exact working deploy commands in `deploy/sql/09_app.sh` and `prompts/06_app.md` so a fresh rebuild reproduces it.
3. List the deployed app files and prove all of these are present: `Home.py`, `utils.py`, `environment.yml`, `pages/1_...` through `pages/7_Shift_Plan.py`.
4. Confirm `SYSTEM_COMPUTE_POOL_CPU` is not running (`SHOW COMPUTE POOLS`); do not create or alter any compute pool.
5. Grant usage as before. Leave all tasks suspended.
6. Append an honest run record to `docs/run-records.md` (what was found, what was changed).

## Acceptance criteria

- `DESCRIBE STREAMLIT` shows no compute pool and no container runtime; the app files list includes `7_Shift_Plan.py` and `environment.yml`.
- Deploy instructions in the repo reproduce the same result.

Print `MISSION 06B COMPLETE` when done.
