#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# deploy stage — build + deploy to Cloudflare Pages (on push to default branch)
# Extracted from .gitlab-ci.yml deploy job

boucle_ci_deploy() {
  set +o pipefail

  # Thin wrapper over boucle_do_deploy (lib/boucle.sh): build + deploy and
  # get the URL. The push-triggered deploy job has no BOUCLE_ISSUE, so it
  # chains to e2e with an empty issue. For declarative Pages / external
  # providers boucle_do_deploy returns an empty URL and there is nothing to
  # chain — the post-merge job resolves the URL and chains instead.
  local deploy_url
  deploy_url=$(boucle_do_deploy) || return 1
  if [ -n "$deploy_url" ]; then
    chain_to_role "" "e2e" BOUCLE_LIVE_URL="$deploy_url"
  fi
  return 0
}
