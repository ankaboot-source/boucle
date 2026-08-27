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

    # BOUCLE_LIVE_URL is required in external mode UNLESS command-mode e2e is
    # active (BOUCLE_E2E_COMMAND set) — the verify command doesn't need a URL.
    if [ -z "${BOUCLE_LIVE_URL:-}" ] && [ -z "${BOUCLE_E2E_COMMAND:-}" ]; then
      echo "FAIL: BOUCLE_LIVE_URL must be set in external deploy mode (or set BOUCLE_E2E_COMMAND for command-mode e2e)" >&2
      exit 1
    fi
    live_url="${BOUCLE_LIVE_URL:-}"

    # Wait for check suites on the merged commit
    local head_sha wait_sec attempt max_attempts
    head_sha=$(git rev-parse HEAD)
    wait_sec="${BOUCLE_EXTERNAL_DEPLOY_WAIT:-600}"
    wait_sec=$(echo "$wait_sec" | tr -cd '0-9')
    [ -z "$wait_sec" ] || [ "$wait_sec" -eq 0 ] 2> /dev/null && wait_sec=600
    max_attempts=$((wait_sec / 10))
    [ "$max_attempts" -lt 1 ] && max_attempts=1
    attempt=0
    local all_done=true
    while [ "$attempt" -lt "$max_attempts" ]; do
      attempt=$((attempt + 1))
      local check_data all_concluded pending_count
      check_data=$(forge_commit_check_suites "$head_sha")
      # Vocabulary-agnostic pending detection: treat as pending when
      # .conclusion is null OR .status/pending in {queued,in_progress,pending,running}
      pending_count=$(echo "$check_data" | jq -r '
        def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
        [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))]
        | length' 2> /dev/null || echo 1)
      if [ "$pending_count" -eq 0 ]; then
        echo "All check suites concluded for commit ${head_sha:0:12} (after ~$((attempt * 10))s)"
        all_done=true
        break
      fi
      if [ "$attempt" -ge "$max_attempts" ]; then
        all_done=false
        break
      fi
      echo "Waiting for check suites on ${head_sha:0:12} — $pending_count still pending (attempt $attempt/$max_attempts)"
      sleep 10
    done

    if [ "$all_done" != "true" ]; then
      echo "FAIL: external deploy wait timed out after ${wait_sec}s — check suites on ${head_sha:0:12} did not conclude" >&2
      forge_issue_note "$BOUCLE_ISSUE" \
        "⚠️ External deploy wait timed out after ${wait_sec}s. The consumer's own CI/CD did not complete for commit ${head_sha:0:12}. Check the repo's CI/CD status manually.\n\nBOUCLE_LIVE_URL=$live_url"
      exit 1
    fi

    # Check for any suite that concluded with failure/cancelled/timed_out/action_required
    local failed_count
    failed_count=$(echo "$check_data" | jq -r '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length' 2> /dev/null || echo 0)
    if [ "$failed_count" -gt 0 ]; then
      echo "FAIL: $failed_count check suite(s) failed for commit ${head_sha:0:12}" >&2
      forge_issue_note "$BOUCLE_ISSUE" \
        "⚠️ External deploy CI failed: $failed_count check suite(s) concluded with failure for commit ${head_sha:0:12}. The consumer's own CI/CD reported errors.\n\nBOUCLE_LIVE_URL=$live_url"
      exit 1
    fi

    echo "External deploy complete. Target URL: $live_url"
  else
    # ── Self mode: build + deploy directly ─────────────────────────
    # The merge commit carries [skip ci] (inherited from the worker commits),
    # so the push-triggered deploy job never fires. Post-merge performs the
    # deploy itself via boucle_do_deploy instead of polling for a pipeline
    # that can never be observed.
    echo "Self deploy mode — building and deploying..."
    local deploy_url
    deploy_url=$(boucle_do_deploy) || {
      echo "FAIL: deploy failed in post-merge self mode" >&2
      exit 1
    }

    # Resolve live URL: use the deploy URL if boucle_do_deploy returned one,
    # otherwise fall through to boucle_resolve_live_url (handles $CI_PAGES_URL
    # for gitlab-pages, boucle_github_pages_url for github-pages, and
    # BOUCLE_LIVE_URL / BOUCLE_PRODUCTION_URL overrides).
    if [ -n "$deploy_url" ]; then
      live_url="$deploy_url"
    else
      live_url=$(boucle_resolve_live_url "")
    fi
  fi

  # Trigger e2e WITH BOUCLE_ISSUE set → enables maybe_close_parent
  chain_to_role "$BOUCLE_ISSUE" "e2e" BOUCLE_LIVE_URL="$live_url"
  echo "Triggered e2e for issue #$BOUCLE_ISSUE with LIVE_URL=$live_url"
}
