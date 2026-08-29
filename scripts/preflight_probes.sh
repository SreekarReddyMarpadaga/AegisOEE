#!/usr/bin/env bash
# Preflight readiness report: CoCo, connection, models, MCP, automations, grants.
set -u
CONN="${COCO_CONN:-aegis}"
PASS=0; FAIL=0
say() { printf '%s\n' "$*"; }
check() { # check <name> <cmd...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then say "PASS  $name"; PASS=$((PASS+1)); else say "FAIL  $name  ($*)"; FAIL=$((FAIL+1)); fi
}

say "== AegisOEE preflight probes ($(date -Iseconds)) =="

check "cortex installed"            cortex --version
check "snow CLI installed"          snow --version
check "connection '$CONN' works"    cortex -c "$CONN" -p "Reply with exactly OK"
check "automations (via opt-in)"    bash scripts/with_automations.sh automation list
check "mcp subcommand available"    cortex mcp list

say ""
say "-- GitHub MCP --"
if [ -z "${GITHUB_PAT:-}" ]; then
  say "WARN  GITHUB_PAT not set — export it, then run:"
  say '      cortex mcp add github https://api.githubcopilot.com/mcp/ --type http -H "Authorization: Bearer ${GITHUB_PAT}"'
else
  check "github MCP configured" bash -c "cortex mcp list 2>/dev/null | grep -qi github"
fi
[ -z "${SLACK_WEBHOOK_URL:-}" ] && say "WARN  SLACK_WEBHOOK_URL not set (needed by Mission 05)"

say ""
say "-- Snowflake capability probes (also persisted by Mission 00) --"
cortex -c "$CONN" --bypass -p "Run these checks with SQL and reply one line each as 'PROBE <name>: PASS|FAIL <detail>': 1) SELECT SNOWFLAKE.CORTEX.COMPLETE with a trivial prompt. 2) SELECT COUNT(*) FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY. 3) SHOW GRANTS TO ROLE PUBLIC and state whether EXECUTE AGENT TASK appears. Do not create any objects." 2>&1 | tail -20

say ""
say "hint: if 'automations CLI' FAILed, run 'cortex update' once and re-check; fallback (native Tasks + cron) is already planned"

say ""
say "== Summary: $PASS pass, $FAIL fail =="
say "Evidence tip: run 'cortex conversations list' and record today's thread IDs in docs/coco-evidence.md"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
