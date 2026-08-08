#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# post-merge stage — deploy-wait + e2e trigger (unlocked, runs after merger)
# Extracted from .gitlab-ci.yml post-merge job
# Runs WITHOUT the boucle-merge concurrency lock so the next approved MR can
# start merging immediately instead of waiting for deploy to finish.

boucle_ci_post_merge() {
    set +o pipefail
    export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

    # The merge pushed to the default branch → triggers deploy → deploy triggers e2e.
    # BUT deploy-triggered e2e has no BOUCLE_ISSUE context, so
    # maybe_close_parent never runs. Fix: trigger e2e directly WITH
    # BOUCLE_ISSUE set, so the issue gets boucle:done + closed + parent cascade.
    # Wait for the deploy pipeline to finish first (production must be live
    # before e2e can test it). Poll for the deploy pipeline to complete.
    echo "Waiting for deploy pipeline to complete before triggering e2e..."
    for i in $(seq 1 60); do
        # Find the latest deploy pipeline for the default branch
        DEPLOY_STATUS=$(forge_pipeline_status_for_ref "$BOUCLE_DEFAULT_BRANCH" "push") || DEPLOY_STATUS="unknown"
        if [ "$DEPLOY_STATUS" = "success" ] || [ "$DEPLOY_STATUS" = "failed" ] || [ "$DEPLOY_STATUS" = "canceled" ]; then
            echo "Deploy pipeline status: $DEPLOY_STATUS"
            break
        fi
        sleep 15
    done

    # Get the production URL (from the deploy's e2e trigger or fallback)
    LIVE_URL="${BOUCLE_PRODUCTION_URL:-}"
    if [ -z "$LIVE_URL" ]; then
        # Fallback: construct the default Cloudflare Pages URL
        LIVE_URL="https://${BOUCLE_DEPLOY_PROJECT}.pages.dev"
    fi

    # Trigger e2e WITH BOUCLE_ISSUE set → enables maybe_close_parent
    chain_to_role "$BOUCLE_ISSUE" "e2e" BOUCLE_LIVE_URL="$LIVE_URL"
    echo "Triggered e2e for issue #$BOUCLE_ISSUE with LIVE_URL=$LIVE_URL"
}
