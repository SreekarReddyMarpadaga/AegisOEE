#!/usr/bin/env bash
# Wrapper: run any cortex command with the automations experimental opt-in enabled.
# Usage: bash scripts/with_automations.sh automation list
set -u
export CORTEX_CODE_EXPERIMENTAL_FEATURES='{"automations":true}'
exec cortex "$@"
