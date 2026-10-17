#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/automerge.sh — automerge stage: merge bot "chore" PRs.
#
# Chained by the doctor sweep (boucle_bot_pr_sweep in lib/boucle.sh) with
# BOUCLE_AUTOMERGE_MR=<comma-separated PR iids>. Runs under the boucle-merge
# lock on both forges: re-verifies each PR (the sweep may be minutes old),
# squash-merges via forge_mr_merge (which refuses unstable/dirty — lesson
# #42), posts an audit comment, deploys in self mode and chains a smoke e2e.
#
# NEVER touches loop labels and NEVER merges a boucle/* worker branch: a bot
# PR has no issue (BOUCLE_ISSUE=0), and LESSONS #85 (a bot verdict is not a
# human approval) must hold even if the sweep regresses. post-merge is NOT
# chained (it is issue-bound, post-merge.sh:15): self mode deploys inline.

boucle_ci_automerge() {
  set +o pipefail
  local mrs="${BOUCLE_AUTOMERGE_MR:-}"
  [ -n "$mrs" ] || {
    echo "automerge: BOUCLE_AUTOMERGE_MR empty — nothing to do"
    return 0
  }
  command -v jq > /dev/null 2>&1 || {
    echo "automerge: jq unavailable — skipping (fail-open)"
    return 0
  }
  local iid=0 merged_count=0 data branch status head_sha suites sha
  for iid in ${mrs//,/ }; do
    [ -n "$iid" ] || continue
    data=$(forge_mr_get "$iid" 2> /dev/null || echo "")
    if [ -z "$data" ]; then
      echo "automerge: PR #$iid vanished (forge error?) — skipping"
      continue
    fi
    if [ "$(printf '%s' "$data" | jq -r 'if .merged == true or .state == "closed" then "true" else "false" end' 2> /dev/null || echo true)" = "true" ]; then
      echo "automerge: PR #$iid already merged or closed — skipping"
      continue
    fi
    branch=$(printf '%s' "$data" | jq -r '.source_branch // .head.ref // empty' 2> /dev/null || echo "")
    case "$branch" in
      boucle/*)
        echo "automerge: PR #$iid is a boucle worker branch — refusing (LESSONS #85)" >&2
        continue
        ;;
    esac
    status=$(forge_mr_merge_status "$iid" 2> /dev/null || echo "unknown")
    if [ "$status" != "mergeable" ]; then
      echo "automerge: PR #$iid not mergeable (status: $status) — left for the next sweep"
      continue
    fi
    head_sha=$(printf '%s' "$data" | jq -r '.head_sha // .sha // .head.sha // empty' 2> /dev/null || echo "")
    suites=$(forge_mr_check_suites "$iid" "$head_sha" 2> /dev/null || echo "[]")
    if ! boucle_checks_green "$suites"; then
      echo "automerge: PR #$iid checks not yet settled or not green — left for the next sweep"
      continue
    fi
    sha=$(forge_mr_merge "$iid" 2> /dev/null || true)
    if [ -z "$sha" ]; then
      echo "automerge: PR #$iid merge refused or failed — left for the next sweep"
      continue
    fi
    forge_mr_note "$iid" "🤖 boucle auto-merged this bot PR (merge \`$sha\`, checks green, branch \`$branch\`, policy: dependency chore — patch/minor or security).$(job_link)" || true
    echo "automerge: merged PR #$iid (merge_commit $sha)"
    merged_count=$((merged_count + 1))
  done
  echo "automerge: merged $merged_count bot PR(s)"
  # Merged bot code must still reach production when the consumer runs
  # boucle's own deploy (self mode): deploy inline here (post-merge is
  # issue-bound), on the FRESHLY MERGED default-branch head — the job's
  # checkout predates the merges. Fail-open: a failed deploy warns and
  # exits 0; the merged code is already on the default branch and the next
  # loop deploy (or the consumer's CI) reconciles production.
  if [ "$merged_count" -gt 0 ]; then
    if boucle_is_external_deploy; then
      echo "automerge: external deploy mode — the consumer's own CI deploys the merge."
    else
      if git fetch -q origin "$BOUCLE_DEFAULT_BRANCH" 2> /dev/null \
        && git checkout -f -q "origin/$BOUCLE_DEFAULT_BRANCH" 2> /dev/null; then
        if deploy_url=$(boucle_do_deploy 2> /dev/null); then
          live_url="${deploy_url:-$(boucle_resolve_live_url "")}"
          chain_to_role "" "e2e" "BOUCLE_LIVE_URL=$live_url" || true
          echo "automerge: deployed $live_url — chained smoke e2e."
        else
          echo "automerge: WARN: deploy failed after the merges — production reconciles on the next loop deploy." >&2
        fi
      else
        echo "automerge: WARN: could not fetch the merged default branch — deploy skipped." >&2
      fi
    fi
  fi
  return 0
}
