#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# merger stage — serial merge after author approval
# Extracted from .gitlab-ci.yml merger job
# Concurrency: MUST be serialized (boucle-merge group) — lesson #8/#10/#42

boucle_ci_merger() {
  set +o pipefail
  export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

  # Set merging label
  set_boucle_label "$BOUCLE_ISSUE" "boucle:merging" "boucle::status::bot"

  # Find the MR for this issue (prefix match on the protocol key
  # boucle/<iid> — the actual branch may be boucle/<iid> or
  # boucle/<iid>-<slug>). Use the forge layer (forge_mr_lookup_by_branch)
  # which works on both GitLab (glab) and GitHub (gh api) — the old glab
  # call only worked on GitLab and caused "glab: command not found" on
  # GitHub consumers.
  MR_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "open")
  if [ -z "$MR_IID" ]; then
    # Before escalating, check if the MR was already merged manually
    # (human merged via GitLab UI before merger job ran). If so,
    # transition to boucle:done instead of boucle:human — prevents
    # the race condition where a manual merge triggers a false
    # "no open MR" escalation + webhook storm.
    local MERGED_IID MERGED_DATA MERGED_SHA
    MERGED_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "merged")
    if [ -n "$MERGED_IID" ]; then
      MERGED_DATA=$(forge_mr_get "$MERGED_IID" 2>/dev/null || echo "")
      MERGED_SHA=$(echo "$MERGED_DATA" | jq -r '.merge_commit_sha // .merge_commit_sha // empty' 2>/dev/null)
      echo "Found merged MR !$MERGED_IID for issue #$BOUCLE_ISSUE (merge_commit=${MERGED_SHA:0:12}) — already merged, transitioning to boucle:done."
      forge_issue_note "$BOUCLE_ISSUE" "✅ MR already merged (merge_commit ${MERGED_SHA:0:12}) — issue resolved.$(job_link)" || true
      set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::bot"
      exit 0
    fi
    echo "FAIL: no open or merged MR found for issue #$BOUCLE_ISSUE (branch boucle/$BOUCLE_ISSUE)" >&2
    # Note BEFORE the terminal label — never a muted boucle:human.
    if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Merger could not find an open MR for branch boucle/$BOUCLE_ISSUE. Human intervention needed.$(job_link)"; then
      echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
      exit 1
    fi
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    exit 1
  fi
  MR_DATA=$(forge_mr_get "$MR_IID")
  BRANCH=$(echo "$MR_DATA" | jq -r '.source_branch // .head.ref // empty')

  # Refresh default branch so we rebase onto the latest (another MR may have
  # just merged — the concurrency group guarantees we're the only merger running,
  # but the default branch may have advanced since this MR was created).
  # Also fetch the MR branch itself — CI clones with --depth=1 and only the
  # ref that triggered the pipeline, so the MR branch ref is NOT present by default.
  git fetch origin "$BOUCLE_DEFAULT_BRANCH" "$BRANCH"
  boucle_deepen_rebase_fetch

  # Set git identity BEFORE the rebase — git rebase rewrites commits and
  # needs a committer identity.
  git config user.email "${BOUCLE_BOT_EMAIL:-boucle-bot@boucle.local}"
  git config user.name "${BOUCLE_BOT_USERNAME:-up-bot}"
  git remote set-url origin "https://${BOUCLE_BOT_USERNAME:-up-bot}:${BOUCLE_TOKEN}@${BOUCLE_FORGE_HOST}/${BOUCLE_PROJECT_PATH}.git"

  # Rebase the MR branch onto latest default branch. This is the key conflict-
  # avoidance mechanism: because merges are serialized, each rebase is
  # against a default branch that already includes all previously-merged MRs.
  git checkout "$BRANCH" 2> /dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
  local REBASE_OUTPUT=""
  if ! REBASE_OUTPUT=$(git rebase "origin/$BOUCLE_DEFAULT_BRANCH" 2>&1); then
    echo "FAIL: rebase onto origin/$BOUCLE_DEFAULT_BRANCH conflicted — even after serial merge." >&2
    git rebase --abort 2> /dev/null || true
    # S4: classify the conflict, then hand it to the human IMMEDIATELY with
    # structured options — never re-trigger the worker blindly (a fresh run
    # would reproduce the same semantic conflict; observed on framagit with a
    # modify/delete on MobilisationBlock.astro, 2026-08).
    boucle_escalate_merge_conflict "$BOUCLE_ISSUE" "$MR_IID" "$BOUCLE_DEFAULT_BRANCH" "$REBASE_OUTPUT"
    exit 1
  fi

  # Push the rebased branch
  # Use --force: the merger rebased onto the default branch, so the local branch
  # has diverged from the remote. --force-with-lease fails if the remote-tracking
  # ref is stale. We always want to overwrite with the rebased branch.
  git push --force origin "$BRANCH"

  # Wait for the forge to recompute mergeability after the force-push (poll).
  # If the project has "Pipelines must succeed" enabled, the force-push triggers
  # a new pipeline on the MR branch and the forge refuses to merge until it
  # completes. Poll up to ~10 min to accommodate a full CI run, tolerating
  # transient API failures (set +e around the poll). — lesson #42
  sleep 5
  MERGE_STATUS="unknown"
  MWPS=false
  for i in $(seq 1 60); do
    MERGE_STATUS=$(forge_mr_merge_status "$MR_IID") || MERGE_STATUS="unknown"
    case "$MERGE_STATUS" in
      mergeable) break ;;
      checking | pipeline_status_must_pass | pipeline_blocked)
        # Pipeline still running or forge recomputing — keep polling.
        ;;
      *)
        # Hard block (conflict, broken, etc.) — no point waiting.
        echo "MR !${MR_IID} merge status: $MERGE_STATUS — hard block, not waiting." >&2
        break
        ;;
    esac
    echo "MR !${MR_IID} merge status: $MERGE_STATUS — waiting 10s... (attempt $i/60)"
    sleep 10
  done

  # If the pipeline is still running after the poll window, use
  # merge-when-pipeline-succeeds (MWPS) instead of failing. The forge will
  # merge automatically once the pipeline passes. — lesson #42
  if [ "$MERGE_STATUS" = "checking" ] || [ "$MERGE_STATUS" = "pipeline_status_must_pass" ] || [ "$MERGE_STATUS" = "pipeline_blocked" ]; then
    echo "MR !${MR_IID} pipeline still running (status: $MERGE_STATUS) — using merge-when-pipeline-succeeds."
    MWPS=true
  elif [ "$MERGE_STATUS" != "mergeable" ]; then
    echo "FAIL: MR !${MR_IID} not mergeable after rebase (status: $MERGE_STATUS)" >&2
    # Note BEFORE the terminal label — never a muted boucle:human.
    if ! forge_issue_note "$BOUCLE_ISSUE" "$(boucle_escalation_diagnostic "$BOUCLE_ISSUE" "not-mergeable")$(job_link)"; then
      echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
      boucle_health_outcome "$BOUCLE_ISSUE" "merger" "not-mergeable" "MR !${MR_IID} status $MERGE_STATUS (note FAILED)" || true
      exit 1
    fi
    boucle_health_outcome "$BOUCLE_ISSUE" "merger" "not-mergeable" "MR !${MR_IID} status $MERGE_STATUS" || true
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    exit 1
  fi

  # Merge the MR.
  # When MWPS=true, the merge is deferred until the pipeline succeeds —
  # the forge returns merge_commit_sha=null immediately, so skip the SHA check
  # and let the deploy (triggered by the eventual merge) handle e2e.
  if [ "$MWPS" = true ]; then
    forge_mr_merge "$MR_IID" --mwps
    echo "MWPS enabled for MR !${MR_IID} — the forge will merge when the pipeline succeeds."
    forge_issue_note "$BOUCLE_ISSUE" "⏳ MR !${MR_IID} merge scheduled (merge-when-pipeline-succeeds). The forge will merge automatically once the CI pipeline passes."
    # MWPS merge: no merge_commit_sha yet. The deploy triggered by the
    # eventual merge will run e2e with BOUCLE_ISSUE unset (no issue
    # context). The doctor's staleness check will close the loop if the
    # MWPS merge lands but no issue-context e2e runs.
    exit 0
  fi

  MERGE_SHA=$(forge_mr_merge "$MR_IID")

  if [ -z "$MERGE_SHA" ]; then
    echo "FAIL: merge API call failed" >&2
    # Note BEFORE the terminal label — never a muted boucle:human.
    if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Merger: the merge API call failed for MR !${MR_IID}. Human intervention needed.$(job_link)"; then
      echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
      exit 1
    fi
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    exit 1
  fi

  echo "Merged MR !${MR_IID} (merge_commit $MERGE_SHA) for issue #$BOUCLE_ISSUE"

  # Post-merge branch cleanup: delete the worker branch. Best-effort — a
  # failed deletion logs a warning but does not fail the job (the branch is
  # stale but harmless). lesson #68.
  if ! forge_branch_delete "$BRANCH"; then
    echo "WARN: could not delete branch $BRANCH after merge (stale but harmless)" >&2
  else
    echo "Deleted worker branch $BRANCH after merge"
  fi

  # The deploy-wait + e2e-trigger has been moved to the post-merge stage
  # which runs WITHOUT the boucle-merge concurrency lock.
  # This releases the merge lock immediately after the merge API call succeeds
  # so the next approved MR can start merging instead of waiting 2+ min
  # for the deploy to finish.
  #
  # Chain to post-merge so it builds + deploys + triggers e2e. Without this,
  # the merged code never deploys (the merge commit has [skip ci], so the
  # push trigger doesn't fire, and the post-merge job only runs on
  # workflow_dispatch BOUCLE_ROLE=post-merge).
  chain_to_role "$BOUCLE_ISSUE" "post-merge"
}
