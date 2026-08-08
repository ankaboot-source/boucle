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

    # Find the MR for this issue
    MR_IID=$(forge_mr_list_open | jq -r ".[] | select(.source_branch == \"boucle/$BOUCLE_ISSUE\") | .iid" | head -1)

    if [ -z "$MR_IID" ]; then
        echo "FAIL: no open MR found for issue #$BOUCLE_ISSUE (branch boucle/$BOUCLE_ISSUE)" >&2
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
        forge_issue_note "$BOUCLE_ISSUE" "⚠️ Merger could not find an open MR for branch boucle/$BOUCLE_ISSUE. Human intervention needed."
        exit 1
    fi

    # Refresh default branch so we rebase onto the latest (another MR may have
    # just merged — the concurrency group guarantees we're the only merger running,
    # but the default branch may have advanced since this MR was created).
    # Also fetch the MR branch itself — CI clones with --depth=1 and only the
    # ref that triggered the pipeline, so the MR branch ref is NOT present by default.
    BRANCH="boucle/$BOUCLE_ISSUE"
    git fetch origin "$BOUCLE_DEFAULT_BRANCH" "$BRANCH"

    # Set git identity BEFORE the rebase — git rebase rewrites commits and
    # needs a committer identity.
    git config user.email "bot@ankaboot.dev"
    git config user.name "${BOUCLE_BOT_USERNAME:-up-bot}"
    git remote set-url origin "https://${BOUCLE_BOT_USERNAME:-up-bot}:${BOUCLE_TOKEN}@${BOUCLE_FORGE_HOST}/${BOUCLE_PROJECT_PATH}.git"

    # Rebase the MR branch onto latest default branch. This is the key conflict-
    # avoidance mechanism: because merges are serialized, each rebase is
    # against a default branch that already includes all previously-merged MRs.
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
    if ! git rebase "origin/$BOUCLE_DEFAULT_BRANCH"; then
        echo "FAIL: rebase onto origin/$BOUCLE_DEFAULT_BRANCH conflicted — even after serial merge." >&2
        git rebase --abort 2>/dev/null || true
        echo "Re-triggering worker (iteration 1) — the MR will be regenerated on fresh $BOUCLE_DEFAULT_BRANCH, no rebase needed." >&2
        set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
        forge_issue_note "$BOUCLE_ISSUE" "🔄 Merger could not rebase MR !${MR_IID} onto $BOUCLE_DEFAULT_BRANCH (conflict). Re-running the worker on fresh $BOUCLE_DEFAULT_BRANCH to regenerate the MR."
        chain_to_role "$BOUCLE_ISSUE" "worker" BOUCLE_ITERATION=1
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
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
        forge_issue_note "$BOUCLE_ISSUE" "⚠️ MR !${MR_IID} is not mergeable after rebase (status: $MERGE_STATUS). Human intervention needed."
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
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
        exit 1
    fi

    echo "Merged MR !${MR_IID} (merge_commit $MERGE_SHA) for issue #$BOUCLE_ISSUE"

    # The deploy-wait + e2e-trigger has been moved to the post-merge stage
    # which runs WITHOUT the boucle-merge concurrency lock.
    # This releases the merge lock immediately after the merge API call succeeds
    # so the next approved MR can start merging instead of waiting 2+ min
    # for the deploy to finish.
}
