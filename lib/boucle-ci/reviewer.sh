#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle-ci/reviewer.sh — reviewer stage: adversarial review of the MR
# against the preview URL.
#
# Extracted from the .gitlab-ci.yml reviewer job (script block only).
# Sourced by lib/boucle-ci.sh, which provides the forge_* layer
# (bin/forge/common.sh contract) and the lib/boucle.sh helpers
# (set_boucle_label, resolve_reporter_id, close_issue, chain_to_role, ...).
#
# Environment (see lib/boucle-ci.sh):
#   BOUCLE_ISSUE          — required; the issue IID under review
#   BOUCLE_PROJECT_ID     — forge project identifier
#   BOUCLE_FORGE_HOST     — forge API host
#   BOUCLE_DEFAULT_BRANCH — default branch (approval message + triggers)
#   BOUCLE_WORKSPACE      — checkout directory (agent-output.log lives under it)
#   BOUCLE_HOME           — boucle installation root
#   BOUCLE_PREVIEW_URL    — exported for the agent (set here from MR description)
#
# Verdict contract: the agent posts `<!-- boucle:verdict v=1 role=reviewer
# sha=<short-sha> -->` + a `VERDICT: PASS|FAIL|UNCERTAIN` line on the MR.
# CI parses it SHA-anchored, then falls back to SHA-unanchored + log-scraping
# (AGENTS.md lessons #27, #41, #43, #47).

boucle_ci_reviewer() {
    # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script
    # under set -eo pipefail. Without pipefail, the var is just empty (which
    # we handle).
    set +o pipefail
    export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

    # Label helper: preserve non-boucle labels when writing a boucle label.
    # The jq filter uses startswith("boucle:") which catches BOTH the detail
    # axis (boucle:triage) AND the gross axis (boucle::status::bot, also
    # starts with "boucle:"), so we strip all boucle-managed labels when
    # writing a new pair. Caller passes detail as $2 and gross as $3.
    # set_boucle_label is provided by lib/boucle.sh (sourced in before_script).
    # Find the MR for this issue.
    # TODO: forge_* — no find-by-source-branch MR lookup in the forge contract
    # yet (forge_mr_get needs the MR IID). Kept as a direct glab call.
    MR_IID=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests?state=opened" |
        jq -r '.[] | select(.source_branch == "boucle/'"$BOUCLE_ISSUE"'") | .iid' | head -1)

    if [ -z "$MR_IID" ]; then
        echo "FAIL: no open MR found for issue #$BOUCLE_ISSUE (branch boucle/$BOUCLE_ISSUE)" >&2
        # The MR was likely closed or merged while the issue is at
        # boucle:review. A bare `exit 1` would leave the issue pinned at
        # boucle:review forever, and the doctor would re-trigger the
        # reviewer every 5min — infinite loop (issue #34). Inspect the
        # MR state and transition the issue instead.
        # TODO: forge_* — no find-by-branch MR lookup in the forge contract.
        CLOSED_MR_STATE=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests?source_branch=boucle/$BOUCLE_ISSUE&state=closed" 2>/dev/null | jq -r '.[0].state // empty' 2>/dev/null || true)
        MERGED_MR_STATE=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests?source_branch=boucle/$BOUCLE_ISSUE&state=merged" 2>/dev/null | jq -r '.[0].state // empty' 2>/dev/null || true)
        if [ -n "$MERGED_MR_STATE" ] || [ -n "$CLOSED_MR_STATE" ]; then
            echo "boucle: a $MERGED_MR_STATE$CLOSED_MR_STATE MR exists for issue #$BOUCLE_ISSUE — transitioning to boucle:done"
            set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
            close_issue "$BOUCLE_ISSUE"
            forge_issue_note "$BOUCLE_ISSUE" "✅ Reviewer: no open MR found, but a $MERGED_MR_STATE$CLOSED_MR_STATE MR exists for this issue. Marked boucle:done and closed."
        else
            echo "boucle: no MR at all for issue #$BOUCLE_ISSUE — escalating to boucle:human"
            set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
            forge_issue_note "$BOUCLE_ISSUE" "⚠️ Reviewer: no MR found for branch boucle/$BOUCLE_ISSUE (no opened, closed, or merged MR). Escalated to **boucle:human**."
        fi
        exit 1
    fi

    MR_DATA=$(forge_mr_get "$MR_IID")
    PREVIEW_URL=$(echo "$MR_DATA" | jq -r '.description' | grep -oE 'https://[a-z0-9.-]+\.pages\.dev' | head -1)
    MR_URL=$(echo "$MR_DATA" | jq -r '.web_url // .html_url // empty')

    # ── Feedback channel: inject human MR comments into the reviewer ──
    # state.md acceptance criteria are seeded ONCE from the triage comment
    # and never refreshed — they freeze the spec at triage time. Humans
    # amend the spec via MR comments mid-loop, and the worker sees those
    # comments (BOUCLE_REVIEWER_FEEDBACK in the worker job). Without the
    # same channel here, the reviewer grades against the frozen triage
    # spec and FAILs implementations that correctly follow the human's
    # amended spec — directly contradicting the human. Fetch ALL non-system
    # MR notes (same query as the worker job) so the reviewer can weigh
    # human amendments over the frozen criteria.
    export BOUCLE_REVIEWER_FEEDBACK
    BOUCLE_REVIEWER_FEEDBACK=$(forge_mr_notes "$MR_IID" |
        jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | .[]' 2>/dev/null || echo "")

    # Detect empty MR (worker shipped zero commits — base_sha == head_sha).
    # Re-trigger the worker instead of running the reviewer uselessly.
    # (.diff_refs.* is GitLab; .base.sha/.head.sha is GitHub — accept both.)
    MR_BASE=$(echo "$MR_DATA" | jq -r '.diff_refs.base_sha // .base.sha // empty')
    MR_HEAD=$(echo "$MR_DATA" | jq -r '.diff_refs.head_sha // .head.sha // empty')
    if [ -n "$MR_BASE" ] && [ "$MR_BASE" = "$MR_HEAD" ]; then
        ITERATION="${BOUCLE_ITERATION:-1}"
        MAX_ITER="${BOUCLE_MAX_ITERATIONS:-3}"
        echo "FAIL: worker shipped zero commits (MR !${MR_IID} empty — base_sha == head_sha). Re-triggering worker (iteration $((ITERATION + 1))/$MAX_ITER)." >&2
        set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
        forge_issue_note "$BOUCLE_ISSUE" "🔄 Worker shipped zero commits (MR !${MR_IID} has empty diff). Re-running the worker (iteration $((ITERATION + 1))/$MAX_ITER)."
        if [ "$ITERATION" -lt "$MAX_ITER" ]; then
            chain_to_role "$BOUCLE_ISSUE" "worker" BOUCLE_ITERATION=$((ITERATION + 1))
        else
            set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
            forge_issue_note "$BOUCLE_ISSUE" "⚠️ Worker shipped zero commits after $MAX_ITER attempts. Human intervention needed."
        fi
        exit 1
    fi

    # Download attachments uploaded to the issue (images, PDFs, archives).
    "$BOUCLE_HOME"/bin/fetch-issue-attachments || echo "[boucle] WARN: attachment fetch failed — continuing without attachments"

    # Download attachments uploaded to MR comments (reviewer screenshots,
    # human mockups). Mirrors bin/fetch-issue-attachments but for MR notes.
    export BOUCLE_MR_IID="$MR_IID"
    "$BOUCLE_HOME"/bin/fetch-mr-attachments || echo "[boucle] WARN: MR attachment fetch failed — continuing without MR attachments"

    # Describe image attachments using a vision model so the reviewer gets
    # visual context as text without swapping its model.
    # Forge controls: BOUCLE_VISION_ROUTING, BOUCLE_VISION_MODEL, BOUCLE_VISION_ROLES.
    "$BOUCLE_HOME"/bin/describe-images reviewer || echo "[boucle] WARN: image description failed — continuing without descriptions"

    export BOUCLE_PREVIEW_URL="$PREVIEW_URL"

    # Fetch the issue body and export it so the reviewer agent can verify
    # that the MR content (texts, video URLs, citations) matches what the
    # issue actually instructed. Without this, the reviewer only sees the
    # MR diff + the human amendments and cannot detect content regressions
    # vs. the original issue (issue #42 on a consumer repo: reviewer
    # posted "Leaning PASS" on an iteration that had Rickroll placeholder
    # videos and rewritten citations, because it had no issue body to
    # compare against). Mirrors the triage and worker jobs.
    export BOUCLE_ISSUE_BODY
    BOUCLE_ISSUE_BODY=$(forge_issue_get "$BOUCLE_ISSUE" 2>/dev/null | jq -r '.description // empty' 2>/dev/null || echo "")
    if [ -z "$BOUCLE_ISSUE_BODY" ]; then
        echo "[boucle] WARN: could not fetch issue #$BOUCLE_ISSUE body — reviewer will grade without the original spec."
    fi

    # Download attachments from MR comments (reviewer screenshots, human
    # mockups) so the reviewer can see what the human pointed at.
    # Gated on MR_IID being non-empty (it is set above from the MR lookup).
    if [ -n "${MR_IID:-}" ]; then
        export BOUCLE_MR_IID="$MR_IID"
        "$BOUCLE_HOME"/bin/fetch-mr-attachments || echo "[boucle] WARN: MR attachment fetch failed — continuing without MR attachments"
    fi
    "$BOUCLE_HOME"/bin/fetch-issue-attachments || echo "[boucle] WARN: attachment fetch failed — continuing without attachments"

    # Detect image attachments (issue + MR comments) and route to a
    # vision-capable model if needed.
    # Forge controls: BOUCLE_VISION_ROUTING, BOUCLE_VISION_MODEL, BOUCLE_VISION_ROLES.
    eval "$("$BOUCLE_HOME"/bin/detect-vision-need reviewer)"

    # Run the agent against the preview.
    # Use `|| rc=$?` to suppress set -e so the script continues to
    # verdict parsing even if the agent exits non-zero (step limit,
    # crash, etc.). The missing-verdict recovery below handles the
    # case where the agent didn't post a verdict.
    # Capture the highest reviewer verdict note ID that existed BEFORE this
    # run, so we can collapse duplicate v2 verdicts below.
    PRE_RUN_VERDICT_ID=$(forge_mr_notes "$MR_IID" |
        jq -r '[.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=reviewer")) | .id] | max // 0' 2>/dev/null || echo 0)
    echo "PRE_RUN_VERDICT_ID=$PRE_RUN_VERDICT_ID"

    rc=0
    "$BOUCLE_HOME"/bin/jc reviewer || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "WARN: $BOUCLE_HOME/bin/jc reviewer exited $rc — checking if a verdict was posted anyway."
    fi

    # Parse verdict — agent posts on the MR, not the issue.
    # Filter by the current MR head SHA (the verdict marker includes sha=<head>)
    # so we only pick up a verdict for THIS version of the code, not a stale
    # one from a previous worker iteration. Use `last` (newest) in case the
    # agent posts multiple notes.
    # Use the short (8-char) SHA for matching: the agent posts
    # sha=<short-sha> (git rev-parse --short output), not the full
    # 40-char SHA. contains("sha=f8e4a30") matches both short and
    # full SHA postings, so this is strictly more permissive.
    # Use 7 chars (Git's minimum short SHA length) so it matches
    # sha=6675f9e (7), sha=6675f9e1 (8), and the full 40-char SHA.
    MR_HEAD_SHORT="${MR_HEAD:0:7}"
    COMMENT=$(forge_mr_notes "$MR_IID" |
        jq -r --arg sha "$MR_HEAD_SHORT" '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer") and contains("sha=\($sha)"))] | first | .body // empty')
    VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
    # Track whether the verdict we found matches the current MR head SHA.
    # The SHA-anchored parse above filters on sha=$MR_HEAD_SHORT, so if VERDICT is
    # non-empty here, the verdict is fresh (matches the current head).
    VERDICT_SHA_MATCHED=true

    # SHA-filter fallback: if the SHA-anchored parse found nothing, accept
    # the newest reviewer verdict regardless of SHA. Better to act on a
    # verdict for a slightly-stale SHA than to strand the issue at human.
    if [ -z "$VERDICT" ]; then
        COMMENT=$(forge_mr_notes "$MR_IID" |
            jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer"))] | first | .body // empty')
        VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
        # SHA-unanchored fallback → the verdict may be stale (different SHA).
        # Flag it so the log-scraping fallback below gets a chance to find the
        # current run's drafted verdict in stdout, which is fresher.
        VERDICT_SHA_MATCHED=false
        if [ -n "$VERDICT" ]; then
            echo "[boucle] WARN: SHA-anchored verdict parse empty — accepted newest reviewer verdict (SHA-unanchored fallback, may be stale)."
        fi
    fi

    # ── Log-scraping fallback (step-limit recovery) ──────────────────
    # If the agent drafted a verdict but ran out of steps before posting it
    # (VERDICT empty), scrape the drafted verdict from the agent's stdout log
    # and post it ourselves. The agent's post-early prompt rule should
    # prevent this, but this catches the residual case.
    # The reviewer may post a first-pass draft with the `boucle:draft` marker
    # (no CI action) before the final `boucle:verdict` marker. If the agent
    # exhausted its steps after the draft, we promote the draft to a verdict
    # (replace the marker) so the loop has a parsable verdict to act on.
    #
    # Run the log-scraping if VERDICT is empty OR if the verdict we found is
    # SHA-stale (VERDICT_SHA_MATCHED=false). A stale verdict from a previous
    # iteration is worse than the current run's drafted verdict in stdout.
    # (issue #35 on a consumer repo: reviewer posted FAIL in stdout
    # but exhausted steps before posting via glab; SHA-unanchored fallback
    # found an old UNCERTAIN verdict with a different SHA, set
    # VERDICT=UNCERTAIN, and the log-scraping was skipped — the FAIL verdict
    # was lost and the issue was wrongly escalated to human.)
    if [ -z "$VERDICT" ] || [ "$VERDICT_SHA_MATCHED" = false ]; then
        AGENT_LOG="$BOUCLE_WORKSPACE/.boucle/$BOUCLE_ISSUE/agent-output.log"
        if [ -f "$AGENT_LOG" ]; then
            # Extract the drafted verdict comment: from the boucle:verdict marker
            # to the VERDICT line. Try SHA-anchored first, then SHA-unanchored
            # (tolerates agent omitting/malforming the SHA in the drafted marker).
            # Match on short SHA prefix (no " -->" suffix) so it works whether
            # the agent used short or full SHA in the marker.
            # All marker patterns are anchored to start-of-line (AGENTS.md lesson
            # #47) so prose that merely quotes the marker is never matched.
            DRAFTED_VERDICT=$(awk -v sha="$MR_HEAD_SHORT" '
                $0 ~ "^<!-- boucle:verdict v=1 role=reviewer sha=" sha { found=1 }
                found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
            ' "$AGENT_LOG" 2>/dev/null || echo "")
            if [ -z "$DRAFTED_VERDICT" ]; then
                DRAFTED_VERDICT=$(awk '
                    /^<!-- boucle:verdict v=1 role=reviewer/ { found=1 }
                    found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
                ' "$AGENT_LOG" 2>/dev/null || echo "")
                if [ -n "$DRAFTED_VERDICT" ]; then
                    echo "[boucle] WARN: SHA-anchored log scrape empty — used SHA-unanchored scrape."
                fi
            fi
            # If no boucle:verdict found, try the boucle:draft marker (first-pass
            # draft posted early per the post-early rule). Promote it to a verdict
            # by replacing the draft marker with the verdict marker.
            if [ -z "$DRAFTED_VERDICT" ]; then
                DRAFTED_VERDICT=$(awk -v sha="$MR_HEAD" '
                    /^<!-- boucle:draft role=reviewer -->/ { found=1 }
                    found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
                ' "$AGENT_LOG" 2>/dev/null || echo "")
                if [ -n "$DRAFTED_VERDICT" ]; then
                    echo "[boucle] WARN: no boucle:verdict in log — promoting boucle:draft to verdict (step-limit fallback)."
                    # Promote the draft marker to a verdict marker so the CI parser
                    # recognizes it when we re-fetch after posting.
                    DRAFTED_VERDICT=$(printf '%s' "$DRAFTED_VERDICT" | sed "s|<!-- boucle:draft role=reviewer -->|<!-- boucle:verdict v=1 role=reviewer sha=$MR_HEAD -->|")
                    # If the promoted draft has no VERDICT line, default to UNCERTAIN
                    # (the agent posted a draft but ran out of steps before posting
                    # a final verdict with a VERDICT: line).
                    if ! echo "$DRAFTED_VERDICT" | grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'; then
                        DRAFTED_VERDICT="$(printf '%s\n\nVERDICT: UNCERTAIN\n' "$DRAFTED_VERDICT")"
                        echo "[boucle] WARN: promoted reviewer draft had no VERDICT line — defaulting to UNCERTAIN."
                    fi
                fi
            fi
            if [ -n "$DRAFTED_VERDICT" ] && echo "$DRAFTED_VERDICT" | grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'; then
                echo "[boucle] Recovering drafted reviewer verdict from agent log (step-limit fallback)."
                # Strip leading/trailing ``` fences if the agent wrapped the comment.
                DRAFTED_VERDICT=$(echo "$DRAFTED_VERDICT" | sed '/^```$/d')
                forge_mr_note "$MR_IID" "$DRAFTED_VERDICT"
                # Re-fetch and re-parse the now-posted verdict (SHA-anchored, then
                # SHA-unanchored fallback — same logic as the primary parse above).
                NEW_COMMENT=$(forge_mr_notes "$MR_IID" |
                    jq -r --arg sha "$MR_HEAD" '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer") and contains("sha=\($sha)"))] | first | .body // empty')
                NEW_VERDICT=$(echo "$NEW_COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
                if [ -z "$NEW_VERDICT" ]; then
                    NEW_COMMENT=$(forge_mr_notes "$MR_IID" |
                        jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer"))] | first | .body // empty')
                    NEW_VERDICT=$(echo "$NEW_COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
                fi
                if [ -n "$NEW_VERDICT" ]; then
                    # The log-scraping found a fresher verdict — override the stale one.
                    COMMENT="$NEW_COMMENT"
                    VERDICT="$NEW_VERDICT"
                    VERDICT_SHA_MATCHED=true
                    echo "[boucle] Step-limit fallback succeeded: recovered verdict=$VERDICT (overrode stale verdict)."
                else
                    echo "[boucle] Step-limit fallback failed: drafted verdict had no parsable VERDICT line — keeping previous verdict=$VERDICT."
                fi
            else
                echo "[boucle] Step-limit fallback: no drafted verdict in log — keeping previous verdict=$VERDICT."
            fi
        fi
    fi

    # Collapse duplicate reviewer verdicts (agent may post a v2; CI replaces the first).
    "$BOUCLE_HOME"/bin/collapse-duplicate-notes reviewer "$BOUCLE_PROJECT_ID" "$MR_IID" "$PRE_RUN_VERDICT_ID" "$BOUCLE_FORGE_HOST" "$MR_HEAD"

    # Resolve the reporter id once, before the verdict case, so every branch
    # (PASS, FAIL, UNCERTAIN) can assign the MR to the author when their
    # action is required. Handles sub-issues: uses the parent issue's author.
    # resolve_reporter_id is provided by lib/boucle.sh (forge-aware).
    AUTHOR_ID=$(resolve_reporter_id "$BOUCLE_ISSUE")
    assign_mr_to_author() {
        # Assign the MR to the issue author.
        # TODO: forge_* — no forge_mr_assign in the forge contract yet; GitLab
        # needs assignee_ids[] via curl (glab array-param is broken).
        if [ -n "$AUTHOR_ID" ] && [ "$AUTHOR_ID" != "null" ] && [ -n "$MR_IID" ]; then
            curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$BOUCLE_PROJECT_ID/merge_requests/$MR_IID" \
                --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
                --data-urlencode "assignee_ids[]=$AUTHOR_ID" 2>/dev/null || true
        fi
    }

    case "$VERDICT" in
    PASS)
        # Assign the MR to the original issue author so they're notified
        # that their approval is needed. The loop pauses here until the
        # author clicks "Approve" on the MR (forge-native approval). The
        # merge_request webhook (action=approved) triggers the merger job,
        # which merges serially to avoid conflicts.
        assign_mr_to_author
        # Set boucle:approval (waits for author to approve the MR natively)
        set_boucle_label "$BOUCLE_ISSUE" "boucle:approval" "boucle::status::human"
        # shellcheck disable=SC2016  # $BOUCLE_DEFAULT_BRANCH stays literal in the user-facing message (matches original $CI_DEFAULT_BRANCH text)
        APPROVAL_MSG=$(printf '✅ Reviewer verdict: **PASS**. MR !%s is ready to merge.\n\nThe MR has been assigned to you for approval. To approve and merge, click the **Approve** button on [MR !%s](%s). The merger will then rebase the MR onto $BOUCLE_DEFAULT_BRANCH and merge it serially (avoiding conflicts with other approved MRs).' "$MR_IID" "$MR_IID" "$MR_URL")
        forge_issue_note "$BOUCLE_ISSUE" "$APPROVAL_MSG"
        # Race condition recovery: the human may have approved the MR
        # BEFORE the reviewer finished (the dispatch `approved` handler
        # silently skips when the issue is at boucle:review, not
        # boucle:approval). Check if the MR is already approved natively
        # — if so, trigger the merger immediately instead of waiting for
        # an approval webhook that was already silently dropped.
        # TODO: forge_* — no MR approvals endpoint in the forge contract yet.
        MR_APPROVALS=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$MR_IID/approvals" 2>/dev/null)
        MR_APPROVED_COUNT=$(echo "$MR_APPROVALS" | jq -r '[.approved_by[].user.username] | length' 2>/dev/null || echo 0)
        if [ "${MR_APPROVED_COUNT:-0}" -gt 0 ]; then
            echo "MR !${MR_IID} was already approved ($MR_APPROVED_COUNT) before reviewer PASS — triggering merger (race condition recovery)"
            forge_trigger_role "$BOUCLE_ISSUE" "merger"
        fi
        ;;
    FAIL)
        ITERATION="${BOUCLE_ITERATION:-1}"
        MAX_ITER="${BOUCLE_MAX_ITERATIONS:-3}"
        # Closed-issue guard: if the issue was closed (e.g. by catchup after
        # a human merged the MR directly), do NOT re-trigger the worker —
        # it would run on a closed issue and create zombie MRs. The reviewer
        # FAIL is a dead end on a closed issue; just exit.
        REVIEW_FAIL_ISSUE_STATE=$(forge_issue_get "$BOUCLE_ISSUE" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
        if [ "$REVIEW_FAIL_ISSUE_STATE" = "closed" ]; then
            echo "boucle: issue #$BOUCLE_ISSUE is closed — not re-triggering worker after reviewer FAIL (no-op on closed issue)"
            exit 0
        fi
        if [ "$ITERATION" -lt "$MAX_ITER" ]; then
            set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
            # Chain back to worker with incremented iteration
            chain_to_role "$BOUCLE_ISSUE" "worker" BOUCLE_ITERATION=$((ITERATION + 1))
        else
            # Final reviewer FAIL after $MAX_ITER attempts: fused into boucle:human
            # (was boucle:blocked, deleted). Configurable via BOUCLE_MAX_ITERATIONS.
            set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
            # Assign the MR to the issue author so they're notified that human
            # intervention is required. Without this, the user never gets a
            # signal that the loop exhausted its iterations (issue #35 on
            # a consumer repo: MR stayed assigned to the bot after 3
            # reviewer FAILs, the user saw no notification).
            assign_mr_to_author
            ESCALATION_MSG=$(printf '⚠️ Reviewer verdict: **FAIL** after %s iterations. The loop could not satisfy the acceptance criteria automatically.\n\nThe MR has been assigned to you for manual review. Inspect [MR !%s](%s) and the reviewer verdicts, then either:\n- **Approve** the MR if the work is acceptable (the merger will rebase + merge), or\n- **Comment** with guidance and re-assign to the bot to re-trigger the worker.' "$MAX_ITER" "$MR_IID" "$MR_URL")
            forge_issue_note "$BOUCLE_ISSUE" "$ESCALATION_MSG"
        fi
        ;;
    UNCERTAIN)
        # Genuinely UNCERTAIN verdict (agent posted VERDICT: UNCERTAIN).
        # This branch is NOT a catch-all for empty VERDICT — empty VERDICT
        # (agent crashed / step-exhausted before posting a verdict) is
        # handled by the post-case assertion below, which re-triggers the
        # reviewer instead of prematurely escalating to human. Conflating
        # the two caused MR !40 on a consumer repo: the reviewer
        # posted only drafts on iterations 1-2 (no VERDICT line), the
        # catch-all fired, assigned the MR to the human and set
        # boucle:human BEFORE the re-triggered reviewer could finish —
        # creating the appearance of "assigned mid-review" and 3 duplicate
        # "unparsable" notes. See AGENTS.md lesson #43.
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
        # Assign the MR to the issue author on escalation (same rationale as
        # the FAIL-after-max branch above).
        assign_mr_to_author
        forge_issue_note "$BOUCLE_ISSUE" "Verdict unparsable or uncertain. Human review needed. The MR has been assigned to you."
        ;;
    esac

    # Assert: verdict comment exists and VERDICT: parsable.
    # If the agent ran but didn't post a verdict for this SHA (ran out of
    # steps, crashed, etc.), re-trigger the reviewer instead of leaving the
    # issue stuck at boucle:review for the doctor to pick up 15 min later.
    # This runs AFTER the case block — but the case block no longer has a
    # catch-all, so empty VERDICT falls through the case without side
    # effects and reaches this assertion. On iter < MAX_ITER we re-trigger
    # the reviewer; on iter == MAX_ITER we escalate to human (with MR
    # assignment + note, matching the FAIL-after-max behavior).
    if [ -z "$VERDICT" ]; then
        ITERATION="${BOUCLE_ITERATION:-1}"
        MAX_ITER="${BOUCLE_MAX_ITERATIONS:-3}"
        echo "FAIL: agent did not post a verdict for sha $MR_HEAD (iteration $ITERATION/$MAX_ITER)" >&2
        if [ "$ITERATION" -lt "$MAX_ITER" ]; then
            echo "Re-triggering reviewer (iteration $((ITERATION + 1))/$MAX_ITER)."
            chain_to_role "$BOUCLE_ISSUE" "reviewer" BOUCLE_ITERATION=$((ITERATION + 1))
        else
            echo "Max iterations reached — escalating to human."
            set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
            assign_mr_to_author
            forge_issue_note "$BOUCLE_ISSUE" "⚠️ Reviewer agent failed to post a verdict after $MAX_ITER attempts. Human review needed. The MR has been assigned to you."
        fi
        exit 1
    fi
}
