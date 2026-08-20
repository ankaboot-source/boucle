#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/cmd-status.sh — /boucle status (#61).
#
# Shells out to `bin/health <issue>` (exists, read-only, exits 0) and posts
# the output as a stamped comment with a header. bin/health reads
# .boucle-state/<issue>/health.jsonl + cost.json and prints a text table:
# iterations, outcomes by role, cost total, last verdict, failure class.

boucle_ci_cmd_status() {
  local iid="${BOUCLE_ISSUE:-}"
  if [ -z "$iid" ]; then
    echo "cmd-status: BOUCLE_ISSUE is unset — nothing to do" >&2
    exit 0
  fi

  local health
  health=$("$BOUCLE_HOME/bin/health" "$iid" 2> /dev/null || true)
  if [ -z "$health" ]; then
    health="No loop-health record found for issue #$iid — nothing measured yet."
  fi

  local body
  body="### 🩺 loop health — issue #$iid

\`\`\`
$health
\`\`\`"
  forge_issue_note "$iid" "$body" 2> /dev/null || true
  exit 0
}
