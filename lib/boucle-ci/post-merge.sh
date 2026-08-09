#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# post-merge stage — deploy-wait + e2e trigger (unlocked, runs after merger)
# Extracted from .gitlab-ci.yml post-merge job
# Runs WITHOUT the boucle-merge concurrency lock so the next approved MR can
# start merging immediately instead of waiting for deploy to finish.
#
# Modes:
#   self (default) — run BOUCLE_DEPLOY_CMD, wait for deploy pipeline, extract URL
#   external       — skip deploy, wait for consumer's own CI on merged commit

boucle_ci_post_merge() {
  set +o pipefail
  export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"
  local live_url=""

  if boucle_is_external_deploy; then
    # ── External mode: wait for consumer's own CI ─────────────────
    echo "External deploy mode — waiting for consumer's own CI on merged commit..."

    # BOUCLE_LIVE_URL is required in external mode
    if [ -z "${BOUCLE_LIVE_URL:-}" ]; then
      echo "FAIL: BOUCLE_LIVE_URL must be set in external deploy mode" >&2
      exit 1
    fi
    live_url="$BOUCLE_LIVE_URL"

    # Wait for check suites on the merged commit
    local head_sha wait_sec attempt max_attempts
    head_sha=$(git rev-parse HEAD)
    wait_sec="${BOUCLE_EXTERNAL_DEPLOY_WAIT:-600}"
    max_attempts=$((wait_sec / 10))
    attempt=0
    local all_done=true
    while [ "$attempt" -lt "$max_attempts" ]; do
      attempt=$((attempt + 1))
      local check_data all_concluded pending_count
      check_data=$(forge_commit_check_suites "$head_sha")
      all_concluded=$(echo "$check_data" | jq -r '[.[] | select(.conclusion == null or .status == "queued" or .status == "in_progress")] | length' 2> /dev/null || echo 1)
      if [ "$all_concluded" -eq 0 ]; then
        echo "All check suites concluded for commit ${head_sha:0:12} (after ~$((attempt * 10))s)"
        all_done=true
        break
      fi
      if [ "$attempt" -ge "$max_attempts" ]; then
        all_done=false
        break
      fi
      echo "Waiting for check suites on ${head_sha:0:12} — $all_concluded still pending (attempt $attempt/$max_attempts)"
      sleep 10
    done

    if [ "$all_done" != "true" ]; then
      echo "FAIL: external deploy wait timed out after ${wait_sec}s — check suites on ${head_sha:0:12} did not conclude" >&2
      forge_issue_note "$BOUCLE_ISSUE" \
        "⚠️ External deploy wait timed out after ${wait_sec}s. The consumer's own CI/CD did not complete for commit ${head_sha:0:12}. Check the repo's CI/CD status manually.\n\nBOUCLE_LIVE_URL=$live_url"
      exit 1
    fi

    echo "External deploy complete. Target URL: $live_url"
  else
    # ── Self mode: wait for deploy pipeline ─────────────────────
    echo "Self deploy mode — waiting for deploy pipeline to complete..."
    local deploy_log
    for i in $(seq 1 60); do
      DEPLOY_STATUS=$(forge_pipeline_status_for_ref "$BOUCLE_DEFAULT_BRANCH" "push") || DEPLOY_STATUS="unknown"
      if [ "$DEPLOY_STATUS" = "success" ] || [ "$DEPLOY_STATUS" = "failed" ] || [ "$DEPLOY_STATUS" = "canceled" ]; then
        echo "Deploy pipeline status: $DEPLOY_STATUS"
        break
      fi
      sleep 15
    done

    # Resolve live URL: BOUCLE_LIVE_URL → BOUCLE_PRODUCTION_URL → regex → pages.dev fallback
    # In self mode there's no deploy_log to regex-extract from in post-merge (the deploy
    # pipeline ran separately), so boucle_resolve_live_url with empty log falls through
    # to BOUCLE_LIVE_URL → BOUCLE_PRODUCTION_URL → pages.dev fallback
    live_url=$(boucle_resolve_live_url "")
  fi

  # Trigger e2e WITH BOUCLE_ISSUE set → enables maybe_close_parent
  chain_to_role "$BOUCLE_ISSUE" "e2e" BOUCLE_LIVE_URL="$live_url"
  echo "Triggered e2e for issue #$BOUCLE_ISSUE with LIVE_URL=$live_url"
}
