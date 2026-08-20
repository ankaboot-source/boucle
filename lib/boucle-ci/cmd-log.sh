#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/cmd-log.sh — /boucle log <role> (#61).
#
# Fetches the agent-output.log artifact of the most recent run of <role>
# (default: the role currently in flight, else the last completed) on this
# issue and posts the tail (≤ comment-size limit) as a stamped comment.
#
# Backed by forge_job_artifact (bin/forge/{gitlab,github}.sh). On any failure
# (no pipeline, no job, no artifact) forge_job_artifact echoes empty and
# returns 1 — the cmd-log job posts a "no log found" reply, not a failure
# (fail-open: the data is observable in the CI UI anyway).

# Comment-size limit: GitLab ~1M chars, GitHub 65536. Truncate to the last
# 65536 chars to be safe across both forges.
BOUCLE_CMD_LOG_TAIL_LIMIT="${BOUCLE_CMD_LOG_TAIL_LIMIT:-65536}"

boucle_ci_cmd_log() {
  local iid="${BOUCLE_ISSUE:-}"
  local role="${BOUCLE_CMD_ARGS:-}"
  if [ -z "$iid" ]; then
    echo "cmd-log: BOUCLE_ISSUE is unset — nothing to do" >&2
    exit 0
  fi
  # Default role: the role currently in flight (BOUCLE_ROLE), else empty
  # (forge_job_artifact picks the most recent completed boucle role).
  if [ -z "$role" ]; then
    role="${BOUCLE_ROLE:-}"
    # Strip the cmd- prefix so we look for the underlying role's log.
    role="${role#cmd-}"
  fi

  local log
  log=$(forge_job_artifact "$iid" "$role" 2> /dev/null || true)
  if [ -z "$log" ]; then
    forge_issue_note "$iid" "### 📋 agent-output.log (role=${role:-any}, issue=#$iid) — tail

No agent-output.log artifact found for this issue. The log is only available after a role job has completed and uploaded its artifact." 2> /dev/null || true
    exit 0
  fi

  # Truncate to the last N chars (comment-size limit).
  local tail_log
  tail_log=$(printf '%s' "$log" | tail -c "$BOUCLE_CMD_LOG_TAIL_LIMIT")

  local body
  body="### 📋 agent-output.log (role=${role:-any}, issue=#$iid) — tail

\`\`\`
$tail_log
\`\`\`"
  forge_issue_note "$iid" "$body" 2> /dev/null || true
  exit 0
}
