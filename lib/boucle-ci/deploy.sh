#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# deploy stage — build + deploy to Cloudflare Pages (on push to default branch)
# Extracted from .gitlab-ci.yml deploy job

boucle_ci_deploy() {
    set +o pipefail

    # Build
    eval "$BOUCLE_BUILD_CMD"

    # Deploy to production (configurable via BOUCLE_DEPLOY_CMD, force default branch)
    BRANCH="$BOUCLE_DEFAULT_BRANCH"
    DEPLOY_LOG=$(mktemp)
    (eval "$BOUCLE_DEPLOY_CMD") > "$DEPLOY_LOG" 2>&1
    DEPLOY_RC=$?
    DEPLOY_URL=$(grep -oE "$BOUCLE_DEPLOY_URL_REGEX" "$DEPLOY_LOG" | head -1)
    if [ "$DEPLOY_RC" -ne 0 ] && [ -n "$DEPLOY_URL" ]; then
        echo "WARN: deploy exited non-zero ($DEPLOY_RC) but emitted a URL — proceeding (may be a partial deploy)" >&2
    fi
    if [ "$DEPLOY_RC" -ne 0 ] && [ -z "$DEPLOY_URL" ]; then
        echo "FAIL: deploy exited $DEPLOY_RC with no URL" >&2
        cat "$DEPLOY_LOG" >&2
        rm -f "$DEPLOY_LOG"
        exit 1
    fi
    rm -f "$DEPLOY_LOG"

    # Assert: deployment URL returns 200 (production domain may not have DNS yet).
    if [ -z "$DEPLOY_URL" ]; then
        echo "FAIL: no deployment URL from deploy command" >&2
        exit 1
    fi
    # Retry with exponential backoff — CDN edge propagation can lag.
    DEPLOY_OK=false
    attempt=0
    delay=5
    while [ "$attempt" -lt 6 ]; do
        attempt=$((attempt + 1))
        HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "$DEPLOY_URL" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            echo "Deployment URL 200 OK (attempt $attempt/6)"
            DEPLOY_OK=true
            break
        fi
        if [ "$attempt" -lt 6 ]; then
            echo "Deployment URL returned $HTTP_CODE (attempt $attempt/6) — retrying in ${delay}s..." >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    if [ "$DEPLOY_OK" != "true" ]; then
        echo "FAIL: deployment URL $DEPLOY_URL not 200 after $attempt attempts (last code: $HTTP_CODE)" >&2
        exit 1
    fi
    echo "Deployed to $DEPLOY_URL (200 OK)"

    # Chain to e2e with the deployment URL
    chain_to_role "" "e2e" BOUCLE_LIVE_URL="$DEPLOY_URL"
}
