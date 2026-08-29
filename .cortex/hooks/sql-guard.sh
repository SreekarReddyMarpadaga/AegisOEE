#!/usr/bin/env bash
# PreToolUse guardrail: blocks destructive SQL/shell outside the AEGIS_OEE sandbox and logs every tool call.
set -u

INPUT="$(cat)"
LOG_FILE="${CORTEX_PROJECT_DIR:-.}/.cortex/hooks/tool-log.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
printf '%s\n' "$INPUT" >> "$LOG_FILE" 2>/dev/null || true

# Normalize: uppercase, collapse whitespace
UPPER="$(printf '%s' "$INPUT" | tr '[:lower:]' '[:upper:]' | tr '\n' ' ')"

block() {
  printf '{"decision":"block","reason":"sql-guard: %s"}\n' "$1"
  exit 2
}

# Absolute blocks — never allowed regardless of target
echo "$UPPER" | grep -Eq 'ALTER[[:space:]]+ACCOUNT' && block "ALTER ACCOUNT is not allowed"
echo "$UPPER" | grep -Eq 'DROP[[:space:]]+(USER|ROLE|WAREHOUSE|INTEGRATION)' && block "dropping users/roles/warehouses/integrations is not allowed"
echo "$UPPER" | grep -Eq 'GRANT[[:space:]]+.*(ACCOUNTADMIN|SECURITYADMIN)' && block "granting admin roles is not allowed"
echo "$UPPER" | grep -Eq 'RM[[:space:]]+-RF[[:space:]]+(/|~|\$HOME)([[:space:]]|$)' && block "recursive delete of home or root is not allowed"

# Destructive SQL allowed only when scoped to AEGIS_OEE
if echo "$UPPER" | grep -Eq '(DROP[[:space:]]+(DATABASE|SCHEMA|TABLE|DYNAMIC[[:space:]]+TABLE|VIEW|TASK|STREAM|STAGE|FUNCTION|PROCEDURE)|TRUNCATE[[:space:]]+TABLE|DELETE[[:space:]]+FROM)'; then
  if ! echo "$UPPER" | grep -q 'AEGIS_OEE'; then
    block "destructive statement without AEGIS_OEE qualifier — fully qualify object names"
  fi
fi

# DELETE must carry a WHERE clause (TEST/demo resets use qualified TRUNCATE instead)
if echo "$UPPER" | grep -Eq 'DELETE[[:space:]]+FROM' && ! echo "$UPPER" | grep -Eq 'WHERE'; then
  block "DELETE without WHERE — add a predicate or use a scoped TRUNCATE"
fi

exit 0
