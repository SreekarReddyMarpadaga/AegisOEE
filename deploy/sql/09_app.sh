#!/usr/bin/env bash
# =============================================================================
# 09_app.sh — Deploy AegisOEE Streamlit app via snow CLI
# Requires: snow CLI authenticated with the target connection.
# =============================================================================
set -euo pipefail
CONN="${1:-aegis}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../../app" && pwd)"

echo "==> Deploying Streamlit app from $APP_DIR..."

cd "$APP_DIR"

# Clean up artifacts that shouldn't be uploaded
rm -rf output __pycache__ pages/__pycache__ .streamlit 2>/dev/null || true

# Deploy using snow CLI (snowflake.yml defines the app config)
snow streamlit deploy --replace --prune --connection "$CONN"

echo "==> Streamlit app deployed: AEGIS_OEE.APP.AEGIS_OEE_COMMAND_CENTER"
