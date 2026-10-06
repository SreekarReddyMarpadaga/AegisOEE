#!/usr/bin/env bash
# =============================================================================
# 09_app.sh — Deploy AegisOEE Streamlit app (stage-based, warehouse runtime)
#
# Uses PUT + CREATE STREAMLIT ... FROM ... RUNTIME_NAME = 'SYSTEM$WAREHOUSE_RUNTIME'
# instead of `snow streamlit deploy`, which defaults to container runtime
# after BCR-2342 (2026_06 bundle).
#
# Requires: snow CLI authenticated with the target connection.
# =============================================================================
set -euo pipefail
CONN="${1:-aegis}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../../app" && pwd)"

STAGE="@AEGIS_OEE.APP.APP_STAGE/aegis_app"

echo "==> Deploying Streamlit app from $APP_DIR..."

# Clean up artifacts that shouldn't be uploaded
rm -rf "$APP_DIR/output" "$APP_DIR/__pycache__" "$APP_DIR/pages/__pycache__" "$APP_DIR/.streamlit" 2>/dev/null || true

# Copy to a temp dir without spaces (PUT may fail with spaces in paths)
TMP_APP=$(mktemp -d)
trap 'rm -rf "$TMP_APP"' EXIT
cp "$APP_DIR/Home.py" "$APP_DIR/utils.py" "$APP_DIR/environment.yml" "$TMP_APP/"
mkdir -p "$TMP_APP/pages"
cp "$APP_DIR/pages/"*.py "$TMP_APP/pages/"

echo "==> Clearing old stage files..."
snow sql -q "REMOVE ${STAGE}/" --connection "$CONN" || true

echo "==> Uploading root files..."
snow sql -q "PUT file://${TMP_APP}/Home.py ${STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE" --connection "$CONN"
snow sql -q "PUT file://${TMP_APP}/utils.py ${STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE" --connection "$CONN"
snow sql -q "PUT file://${TMP_APP}/environment.yml ${STAGE}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE" --connection "$CONN"

echo "==> Uploading page files..."
for f in "$TMP_APP/pages/"*.py; do
  snow sql -q "PUT file://${f} ${STAGE}/pages/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE" --connection "$CONN"
done

echo "==> Creating Streamlit app (warehouse runtime)..."
snow sql -q "
CREATE OR REPLACE STREAMLIT AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER
  FROM '${STAGE}'
  MAIN_FILE = 'Home.py'
  QUERY_WAREHOUSE = AEGIS_APP_WH
  RUNTIME_NAME = 'SYSTEM\$WAREHOUSE_RUNTIME'
  TITLE = 'AegisOEE Command Center';
" --connection "$CONN"

echo "==> Making app live..."
snow sql -q "ALTER STREAMLIT AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER ADD LIVE VERSION FROM LAST" --connection "$CONN"

echo "==> Granting usage..."
snow sql -q "GRANT USAGE ON STREAMLIT AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER TO ROLE PUBLIC" --connection "$CONN"

echo "==> Verifying deployment..."
snow sql -q "DESCRIBE STREAMLIT AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER" --connection "$CONN"

echo "==> Streamlit app deployed: AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER (warehouse runtime)"
