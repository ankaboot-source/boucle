#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# deploy stage — build + deploy to Cloudflare Pages (on push to default branch)
# Extracted from .gitlab-ci.yml deploy job

boucle_ci_deploy() {
  set +o pipefail

  # GitHub Pages declarative mode: the post-merge deploy re-pushes the
  # merged build to the gh-pages branch and hands e2e the canonical URL.
  # No CLOUDFLARE_* secrets needed — the bot PAT has contents:write.
  if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "github-pages" ]; then
    echo "deploy: GitHub Pages mode — building and pushing to gh-pages"
    if [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] \
      && [ -n "$(ls -A "$BOUCLE_BUILD_OUTPUT" 2> /dev/null)" ]; then
      echo "deploy: $BOUCLE_BUILD_OUTPUT already populated (build artifact) — skipping build"
    else
      eval "$BOUCLE_BUILD_CMD"
    fi
    DEPLOY_LOG=$(mktemp)
    boucle_worker_deploy "$DEPLOY_LOG" || {
      rm -f "$DEPLOY_LOG"
      echo "FAIL: GitHub Pages deploy failed" >&2
      exit 1
    }
    rm -f "$DEPLOY_LOG"
    DEPLOY_URL=$(boucle_github_pages_url)
    echo "Deployed to $DEPLOY_URL"
    chain_to_role "" "e2e" BOUCLE_LIVE_URL="$DEPLOY_URL"
    return 0
  fi

  # No deploy command (e.g. GitLab Pages mode / external): skip cleanly.
  # The site is served by the forge's own Pages (the pages job builds
  # and publishes it), so there is no URL to extract and no e2e chain
  # here — the post-merge job hands $CI_PAGES_URL to e2e instead.
  if [ -z "${BOUCLE_DEPLOY_CMD:-}" ]; then
    echo "deploy: BOUCLE_DEPLOY_CMD is empty (Pages/external mode) — skipping"
    return 0
  fi

  # Build — unless the build output is already populated. On GitLab the
  # build-site job hands this job `public/` as an artifact, and rebuilding
  # here OOMs WASM toolchains on shell executors (framagit, 2026-08). On
  # GitHub there is no build-site job, so the tree is empty and this builds
  # exactly as before.
  if [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] \
    && [ -n "$(ls -A "$BOUCLE_BUILD_OUTPUT" 2> /dev/null)" ]; then
    echo "deploy: $BOUCLE_BUILD_OUTPUT already populated (build artifact) — skipping build"
  else
    eval "$BOUCLE_BUILD_CMD"
  fi

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
    HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "$DEPLOY_URL" 2> /dev/null || echo "000")
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
