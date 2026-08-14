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

  # Evidence pack: charter excerpts at base + diff brief, read by
  # bin/jc and injected into the reviewer prompt. Best-effort: never
  # fails the job.
  "${BOUCLE_HOME}"/bin/build-evidence-pack > /dev/null 2>&1 || true

  # ── Restore the triage's obligations.md into the workspace ──────
  # The triage job writes obligations.md (the `## Deliverables` obligations)
  # to the state cache. The reviewer's obligations gate reads it from
  # $BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/obligations.md, so restore it
  # here (mirrors the worker's state-cache restore). Best-effort: a missing
  # file simply disables the gate.
  BOUCLE_STATE_CACHE="${BOUCLE_STATE_CACHE:-${HOME}/.boucle-state-cache}"
  ISSUE_STATE_CACHE="${BOUCLE_STATE_CACHE}/${BOUCLE_ISSUE}"
  if [ -f "$ISSUE_STATE_CACHE/obligations.md" ]; then
    mkdir -p "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE"
    cp -a "$ISSUE_STATE_CACHE/obligations.md" "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/obligations.md" 2> /dev/null || true
  fi

  # Label helper: preserve non-boucle labels when writing a boucle label.
  # The jq filter uses startswith("boucle:") which catches BOTH the detail
  # axis (boucle:triage) AND the gross axis (boucle::status::bot, also
  # starts with "boucle:"), so we strip all boucle-managed labels when
  # writing a new pair. Caller passes detail as $2 and gross as $3.
  # set_boucle_label is provided by lib/boucle.sh (sourced in before_script).
  # Find the MR for this issue.
  MR_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "opened")

  if [ -z "$MR_IID" ]; then
    echo "FAIL: no open MR found for issue #$BOUCLE_ISSUE (branch boucle/$BOUCLE_ISSUE)" >&2
    # The MR was likely closed or merged while the issue is at
    # boucle:review. A bare `exit 1` would leave the issue pinned at
    # boucle:review forever, and the doctor would re-trigger the
    # reviewer every 5min — infinite loop (issue #34). Inspect the
    # MR state and transition the issue instead.
    CLOSED_MR_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "closed")
    MERGED_MR_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "merged")
    MERGED_MR_STATE=""
    CLOSED_MR_STATE=""
    CLOSED_MR_DATA=""
    if [ -n "$MERGED_MR_IID" ]; then
      MERGED_MR_STATE=$(forge_mr_get "$MERGED_MR_IID" | jq -r '.state // empty' 2> /dev/null || echo "")
    fi
    if [ -n "$CLOSED_MR_IID" ]; then
      # GitHub reports merged PRs as state=closed — distinguish a merge
      # from a plain close via .merged_at (GitLab uses a dedicated
      # "merged" state, so the merged lookup above covers it).
      CLOSED_MR_DATA=$(forge_mr_get "$CLOSED_MR_IID")
      if printf '%s' "$CLOSED_MR_DATA" | jq -e '.merged_at != null' > /dev/null 2>&1; then
        MERGED_MR_STATE="merged"
      else
        CLOSED_MR_STATE=$(printf '%s' "$CLOSED_MR_DATA" | jq -r '.state // empty' 2> /dev/null || echo "")
      fi
    fi
    if [ -n "$MERGED_MR_STATE" ]; then
      echo "boucle: a merged MR exists for issue #$BOUCLE_ISSUE — transitioning to boucle:done"
      set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
      close_issue "$BOUCLE_ISSUE"
      forge_issue_note "$BOUCLE_ISSUE" "✅ Reviewer: no open MR found, but a merged MR exists for this issue. Marked boucle:done and closed."
    elif [ -n "$CLOSED_MR_STATE" ]; then
      # Closed WITHOUT a merge is ambiguous: it may be (a) the human
      # closed the MR mid-review (issue pinned at boucle:review — closing
      # the issue breaks the reviewer re-trigger loop), or (b) a recovery
      # artifact — the human closed a zombie/empty MR while the issue is
      # queued for work (boucle:todo/boucle:working). In case (b),
      # boucle:done is WRONG: the work is not finished, and closing the
      # issue kills the loop (consumer MR !59: the human closed a
      # 0-commit zombie MR, the reviewer marked the issue boucle:done and
      # closed it 2 minutes after the recovery). Gate the done-transition
      # on the issue's current detail label.
      ISSUE_LABELS=$(forge_issue_labels_get "$BOUCLE_ISSUE" 2> /dev/null || echo "")
      case ",$ISSUE_LABELS," in
        *",boucle:review,"* | *",boucle:approval,"*)
          echo "boucle: a closed MR exists while issue #$BOUCLE_ISSUE is at review/approval — transitioning to boucle:done"
          set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
          close_issue "$BOUCLE_ISSUE"
          forge_issue_note "$BOUCLE_ISSUE" "✅ Reviewer: no open MR found, but a closed MR exists for this issue. Marked boucle:done and closed."
          ;;
        *)
          echo "boucle: closed MR for issue #$BOUCLE_ISSUE is stale (not merged, issue queued for work) — leaving the issue open"
          forge_issue_note "$BOUCLE_ISSUE" "ℹ️ Reviewer: the only MR on branch boucle/$BOUCLE_ISSUE is closed and NOT merged, while the issue is queued for work. Treating it as a stale MR — the issue stays open and a fresh MR will be created on the next worker run."
          exit 0
          ;;
      esac
    else
      echo "boucle: no MR at all for issue #$BOUCLE_ISSUE — escalating to boucle:human"
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Reviewer: no MR found for branch boucle/$BOUCLE_ISSUE (no opened, closed, or merged MR). Escalated to **boucle:human**.$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    fi
    exit 1
  fi

  MR_DATA=$(forge_mr_get "$MR_IID")
  PREVIEW_URL=$(echo "$MR_DATA" | jq -r '.description' | grep -oE "$BOUCLE_DEPLOY_URL_REGEX" | head -1)
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
  BOUCLE_REVIEWER_FEEDBACK=$(forge_mr_notes "$MR_IID" \
    | jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | .[]' 2> /dev/null || echo "")

  # Detect empty MR (worker shipped zero commits — base_sha == head_sha).
  # Re-trigger the worker instead of running the reviewer uselessly.
  # (.diff_refs.* is GitLab; .base.sha/.head.sha is GitHub — accept both.)
  MR_BASE=$(echo "$MR_DATA" | jq -r '.diff_refs.base_sha // .base.sha // empty')
  MR_HEAD=$(echo "$MR_DATA" | jq -r '.diff_refs.head_sha // .head.sha // empty')
  if [ -n "$MR_BASE" ] && [ "$MR_BASE" = "$MR_HEAD" ]; then
    ITERATION="${BOUCLE_ITERATION:-1}"
    MAX_ITER="${BOUCLE_MAX_ITERATIONS:-5}"
    echo "FAIL: worker shipped zero commits (MR !${MR_IID} empty — base_sha == head_sha). Re-triggering worker (iteration $((ITERATION + 1))/$MAX_ITER)." >&2
    set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
    forge_issue_note "$BOUCLE_ISSUE" "🔄 Worker shipped zero commits (PR #${MR_IID} has empty diff). Re-running the worker (iteration $((ITERATION + 1))/$MAX_ITER).$(job_link)" || true
    if [ "$ITERATION" -lt "$MAX_ITER" ]; then
      chain_to_role "$BOUCLE_ISSUE" "worker" BOUCLE_ITERATION=$((ITERATION + 1))
    else
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Worker shipped zero commits after $MAX_ITER attempts. Human intervention needed.$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
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
  # In screenshot review mode, use --criteria so the vision model answers
  # the acceptance criteria from state.md (not a generic description) —
  # the reviewer model can't read images, so the description must be
  # guided by what the reviewer actually needs to verify.
  if boucle_is_screenshot_review; then
    "$BOUCLE_HOME"/bin/describe-images reviewer --criteria || echo "[boucle] WARN: image description failed — continuing without descriptions"
  else
    "$BOUCLE_HOME"/bin/describe-images reviewer || echo "[boucle] WARN: image description failed — continuing without descriptions"
  fi

  export BOUCLE_PREVIEW_URL="$PREVIEW_URL"

  # ── Diff review mode ─────────────────────────────────────────────
  # When BOUCLE_REVIEW_MODE=diff (or no preview URL could be extracted
  # and we're not in screenshot mode), run code-review mode: review the
  # PR diff, wait for check suites. Screenshot mode has its own path below.
  export BOUCLE_MR_DIFF=""
  export BOUCLE_MR_CHECKS=""
  if boucle_is_diff_review || { [ -z "$PREVIEW_URL" ] && ! boucle_is_screenshot_review; }; then
    echo "[boucle] Diff review mode — gathering PR diff and check suites..."
    # Fetch the MR diff
    BOUCLE_MR_DIFF=$(forge_mr_diff "$MR_IID" | head -c 5000 || echo "")
    # Wait for check suites on the PR head
    local checks_wait checks_attempt checks_max check_data
    checks_wait="${BOUCLE_REVIEW_CHECKS_WAIT:-900}"
    checks_wait=$(echo "$checks_wait" | tr -cd '0-9')
    [ -z "$checks_wait" ] || [ "$checks_wait" -eq 0 ] 2> /dev/null && checks_wait=900
    checks_max=$((checks_wait / 10))
    [ "$checks_max" -lt 1 ] && checks_max=1
    checks_attempt=0
    check_data="[]"
    while [ "$checks_attempt" -lt "$checks_max" ]; do
      checks_attempt=$((checks_attempt + 1))
      check_data=$(forge_mr_check_suites "$MR_IID" "$MR_HEAD")
      # Vocabulary-agnostic pending detection: treat as pending when
      # .conclusion is null OR .status/pending in {queued,in_progress,pending,running}
      local pending_count
      pending_count=$(echo "$check_data" | jq -r '
        def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
        [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))]
        | length' 2> /dev/null || echo 1)
      if [ "$pending_count" -eq 0 ]; then
        echo "All PR check suites concluded for MR !${MR_IID} (after ~$((checks_attempt * 10))s)"
        break
      fi
      echo "PR check suites: $pending_count still pending (attempt $checks_attempt/$checks_max)"
      sleep 10
    done
    BOUCLE_MR_CHECKS=$(echo "$check_data" | jq -c '.' 2> /dev/null || echo "[]")
    # Warn on timeout but don't fail — the review can still proceed.
    # Report failed-conclusions count alongside the timeout warning.
    local failed_count
    failed_count=$(echo "$check_data" | jq -r '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length' 2> /dev/null || echo 0)
    if echo "$check_data" | jq -e '
      def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
      [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))] | length > 0' > /dev/null 2>&1; then
      echo "[boucle] WARN: PR check suites timed out after ${checks_wait}s (${failed_count} failed) — proceeding without full CI results"
    elif [ "$failed_count" -gt 0 ]; then
      echo "[boucle] INFO: ${failed_count} PR check suite(s) had failure conclusions — reviewer will judge"
    fi
    export BOUCLE_MR_DIFF BOUCLE_MR_CHECKS
    echo "[boucle] Diff review mode ready: diff=${#BOUCLE_MR_DIFF}chars, checks=$(echo "$BOUCLE_MR_CHECKS" | jq 'length')"
  fi

  # Fetch the issue body and export it so the reviewer agent can verify
  # that the MR content (texts, video URLs, citations) matches what the
  # issue actually instructed. Without this, the reviewer only sees the
  # MR diff + the human amendments and cannot detect content regressions
  # vs. the original issue (issue #42 on a consumer repo: reviewer
  # posted "Leaning PASS" on an iteration that had Rickroll placeholder
  # videos and rewritten citations, because it had no issue body to
  # compare against). Mirrors the triage and worker jobs.
  export BOUCLE_ISSUE_BODY
  BOUCLE_ISSUE_BODY=$(forge_issue_get "$BOUCLE_ISSUE" 2> /dev/null | jq -r '.description // empty' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_BODY" ]; then
    echo "[boucle] WARN: could not fetch issue #$BOUCLE_ISSUE body — reviewer will grade without the original spec."
  fi

  # Issue notes (human amendments posted as issue comments, not MR comments).
  # Without these, the reviewer grades against MR notes + issue body alone and
  # misses amendments the human posted on the ISSUE (not the MR). The worker
  # already receives BOUCLE_ISSUE_NOTES; the reviewer MUST too, so it can
  # verify those amendments are addressed (framagit 2026-08, MR !61: the
  # human posted "embed Instagram + related articles" as an ISSUE note; the
  # worker marked them SUPPRIMÉE and the reviewer PASSed because it never saw
  # the issue note — only the MR notes and issue body).
  export BOUCLE_ISSUE_NOTES
  BOUCLE_ISSUE_NOTES=$(forge_issue_notes "$BOUCLE_ISSUE" \
    | jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | reverse | .[]' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_NOTES" ]; then
    echo "[boucle] INFO: no prior notes for issue #$BOUCLE_ISSUE."
  fi

  # Describe image attachments (issue + MR comments) using a vision model,
  # then inject the text descriptions into the reviewer prompt. This replaces
  # the old detect-vision-need approach which swapped the reviewer's model
  # to minimax-m3 (worse at code review, prone to WASM OOM crashes).
  "$BOUCLE_HOME/bin/describe-images reviewer" || echo "[boucle] WARN: image description failed — continuing without descriptions"

  # Run the agent against the preview.
  # Use `|| rc=$?` to suppress set -e so the script continues to
  # verdict parsing even if the agent exits non-zero (step limit,
  # crash, etc.). The missing-verdict recovery below handles the
  # case where the agent didn't post a verdict.
  # Capture the highest reviewer verdict note ID that existed BEFORE this
  # run, so we can collapse duplicate v2 verdicts below.
  PRE_RUN_VERDICT_ID=$(forge_mr_notes "$MR_IID" \
    | jq -r '[.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=reviewer")) | .id] | max // 0' 2> /dev/null || echo 0)
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
  COMMENT=$(forge_mr_notes "$MR_IID" \
    | jq -r --arg sha "$MR_HEAD_SHORT" '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer") and contains("sha=\($sha)"))] | first | .body // empty')
  VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
  # Track whether the verdict we found matches the current MR head SHA.
  # The SHA-anchored parse above filters on sha=$MR_HEAD_SHORT, so if VERDICT is
  # non-empty here, the verdict is fresh (matches the current head).
  VERDICT_SHA_MATCHED=true

  # SHA-filter fallback: if the SHA-anchored parse found nothing, accept
  # the newest reviewer verdict ONLY when it carries no sha at all
  # (malformed marker tolerance). A verdict whose marker sha exists but
  # differs from the MR head is FOREIGN (previous iteration, another MR,
  # or copied from an old verdict — AGENTS.md P4) and MUST be rejected:
  # acting on it validates content that was never reviewed.
  if [ -z "$VERDICT" ]; then
    COMMENT=$(forge_mr_notes "$MR_IID" \
      | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer"))] | first | .body // empty')
    FOUND_SHA=$(printf '%s' "$COMMENT" | grep -oE 'sha=[a-f0-9]+' | head -1 | cut -d= -f2 || true)
    if [ -n "$FOUND_SHA" ] && [ "$FOUND_SHA" != "$MR_HEAD_SHORT" ]; then
      echo "[boucle] REJECTED foreign-SHA verdict: marker sha=$FOUND_SHA != MR head $MR_HEAD_SHORT. Not accepting."
      VERDICT=""
      VERDICT_SHA_MATCHED=false
    else
      VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
      VERDICT_SHA_MATCHED=false
      if [ -n "$VERDICT" ]; then
        echo "[boucle] WARN: SHA-anchored verdict parse empty — accepted newest reviewer verdict (SHA-unanchored fallback, may be stale)."
      fi
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
  # but exhausted steps before posting via the forge CLI; SHA-unanchored fallback
  # found an old UNCERTAIN verdict with a different SHA, set
  # VERDICT=UNCERTAIN, and the log-scraping was skipped — the FAIL verdict
  # was lost and the issue was wrongly escalated to human.)
  if [ -z "$VERDICT" ] || [ "$VERDICT_SHA_MATCHED" = false ]; then
    AGENT_LOG="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/agent-output.log"
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
            ' "$AGENT_LOG" 2> /dev/null || echo "")
      if [ -z "$DRAFTED_VERDICT" ]; then
        DRAFTED_VERDICT=$(awk '
                    /^<!-- boucle:verdict v=1 role=reviewer/ { found=1 }
                    found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
                ' "$AGENT_LOG" 2> /dev/null || echo "")
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
                ' "$AGENT_LOG" 2> /dev/null || echo "")
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
        NEW_COMMENT=$(forge_mr_notes "$MR_IID" \
          | jq -r --arg sha "$MR_HEAD" '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer") and contains("sha=\($sha)"))] | first | .body // empty')
        NEW_VERDICT=$(echo "$NEW_COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
        if [ -z "$NEW_VERDICT" ]; then
          NEW_COMMENT=$(forge_mr_notes "$MR_IID" \
            | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer"))] | first | .body // empty')
          # Reject a foreign-SHA re-fetch: a marker whose sha exists but
          # differs from the MR head is not this run's verdict (AGENTS.md P4).
          NEW_FOUND_SHA=$(printf '%s' "$NEW_COMMENT" | grep -oE 'sha=[a-f0-9]+' | head -1 | cut -d= -f2 || true)
          if [ -n "$NEW_FOUND_SHA" ] && [ "$NEW_FOUND_SHA" != "$MR_HEAD_SHORT" ]; then
            echo "[boucle] REJECTED foreign-SHA re-fetch: marker sha=$NEW_FOUND_SHA != MR head $MR_HEAD_SHORT. Not adopting."
            NEW_COMMENT=""
          fi
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

  # Collapse duplicate reviewer verdicts: replace the draft in place (PUT the
  # final verdict body onto the draft's note id so the #note_<id> anchor stays
  # stable) and delete redundant copies. Agent may post a v2; CI replaces the first.
  "$BOUCLE_HOME"/bin/collapse-duplicate-notes reviewer "$BOUCLE_PROJECT_ID" "$MR_IID" "$PRE_RUN_VERDICT_ID" "$BOUCLE_FORGE_HOST" "$MR_HEAD"

  # ── Obligations gate (mechanical, no LLM) ─────────────────────────
  # .boucle-state/<issue>/obligations.md holds the triage's `## Deliverables`
  # obligations (one `- O1 — type: … — … — condition: …` line each).
  # The reviewer must adjudicate EVERY obligation in the verdict. A PASS
  # that skips an obligation, or a PASS contradicting unaddressed /
  # unverifiable adjudications, is mechanically overridden below.
  OBLIGATIONS_FILE="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/obligations.md"
  if [ -f "$OBLIGATIONS_FILE" ]; then
    OBLIGATION_IDS=$(grep -oE '^- O[0-9]+' "$OBLIGATIONS_FILE" | tr -d '-' | tr '\n' ' ' || true)
    for oid in $OBLIGATION_IDS; do
      if ! printf '%s' "$COMMENT" | grep -qE "^\- $oid \[(addressed|unaddressed|unverifiable)\]"; then
        echo "[boucle] Obligations gate: $oid has NO adjudication in the verdict — verdict invalid."
        if [ "$VERDICT" = "PASS" ]; then
          VERDICT=""
          VERDICT_SHA_MATCHED=false
        fi
      fi
    done
    if [ "$VERDICT" = "PASS" ]; then
      if printf '%s' "$COMMENT" | grep -qE '^- O[0-9]+ \[unaddressed\]'; then
        echo "[boucle] Obligations gate: PASS contradicts a [unaddressed] adjudication — overriding to FAIL."
        VERDICT="FAIL"
      elif printf '%s' "$COMMENT" | grep -qE '^- O[0-9]+ \[unverifiable\]'; then
        echo "[boucle] Obligations gate: PASS contradicts a [unverifiable] adjudication — overriding to UNCERTAIN."
        VERDICT="UNCERTAIN"
      fi
    fi
    if [ -n "$VERDICT" ]; then
      echo "[boucle] Obligations gate: verdict after gate = $VERDICT"
    fi
  fi

  # ── Lesson candidate scraping (escalation only) ───────────────────
  # At MAX_ITERATION the reviewer prompt asks the agent to emit a lesson
  # candidate on stdout (## Lesson candidate ... ## End lesson candidate).
  # Scrape it from the agent log into .boucle-state/<issue>/lesson-candidate.yml
  # so the worker can validate + commit it on the next run. Never posted
  # as a forge note — the candidate is machine food, not human-facing.
  ITERATION="${BOUCLE_ITERATION:-1}"
  MAX_ITER="${BOUCLE_MAX_ITERATIONS:-5}"
  if [ "$ITERATION" -ge "$MAX_ITER" ]; then
    AGENT_LOG="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/agent-output.log"
    if [ -f "$AGENT_LOG" ]; then
      LESSON_CANDIDATE=$(awk '
        /^## Lesson candidate/ { found=1; next }
        /^## End lesson candidate/ { found=0 }
        found { print }
      ' "$AGENT_LOG" 2> /dev/null || echo "")
      if [ -n "$LESSON_CANDIDATE" ]; then
        printf '%s\n' "$LESSON_CANDIDATE" > "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/lesson-candidate.yml"
        echo "[boucle] Scraped lesson candidate from reviewer log → .boucle-state/$BOUCLE_ISSUE/lesson-candidate.yml"
      fi
    fi
  fi

  # Resolve the reporter id once, before the verdict case, so every branch
  # (PASS, FAIL, UNCERTAIN) can assign the MR to the author when their
  # action is required. Handles sub-issues: uses the parent issue's author.
  # resolve_reporter_id is provided by lib/boucle.sh (forge-aware).
  AUTHOR_ID=$(resolve_reporter_id "$BOUCLE_ISSUE")
  assign_mr_to_author() {
    # Assign the MR to the issue author.
    if [ -n "$AUTHOR_ID" ] && [ "$AUTHOR_ID" != "null" ] && [ -n "$MR_IID" ]; then
      forge_mr_assign "$MR_IID" "$AUTHOR_ID"
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
      APPROVAL_MSG=$(printf '✅ Reviewer verdict: **PASS**. MR !%s is ready to merge.\n\nThe MR has been assigned to you for approval. To approve and merge, click the **Approve** button on [MR !%s](%s). The merger will then rebase the MR onto %s and merge it serially (avoiding conflicts with other approved MRs).' "$MR_IID" "$MR_IID" "$MR_URL" "${BOUCLE_DEFAULT_BRANCH:-${CI_DEFAULT_BRANCH:-master}}")
      forge_issue_note "$BOUCLE_ISSUE" "$APPROVAL_MSG"
      # Race condition recovery: the human may have approved the MR
      # BEFORE the reviewer finished (the dispatch `approved` handler
      # silently skips when the issue is at boucle:review, not
      # boucle:approval). Check if the MR is already approved natively
      # — if so, trigger the merger immediately instead of waiting for
      # an approval webhook that was already silently dropped.
      MR_APPROVED=$(forge_mr_approvals "$MR_IID")
      if [ "$MR_APPROVED" = "true" ]; then
        echo "MR !${MR_IID} was already approved ($MR_APPROVED) before reviewer PASS — triggering merger (race condition recovery)"
        forge_trigger_role "$BOUCLE_ISSUE" "merger"
      fi
      ;;
    FAIL)
      ITERATION="${BOUCLE_ITERATION:-1}"
      MAX_ITER="${BOUCLE_MAX_ITERATIONS:-5}"
      # Closed-issue guard: if the issue was closed (e.g. by catchup after
      # a human merged the MR directly), do NOT re-trigger the worker —
      # it would run on a closed issue and create zombie MRs. The reviewer
      # FAIL is a dead end on a closed issue; just exit.
      REVIEW_FAIL_ISSUE_STATE=$(forge_issue_get "$BOUCLE_ISSUE" 2> /dev/null | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
      if [ "$REVIEW_FAIL_ISSUE_STATE" = "closed" ]; then
        echo "boucle: issue #$BOUCLE_ISSUE is closed — not re-triggering worker after reviewer FAIL (no-op on closed issue)"
        exit 0
      fi
      if [ "$ITERATION" -lt "$MAX_ITER" ]; then
        # The final-attempt warning now lives in the MR description (written by
        # the worker when it starts the last iteration), so the reviewer no
        # longer posts a separate notice here.
        set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
        # Chain back to worker with incremented iteration
        chain_to_role "$BOUCLE_ISSUE" "worker" BOUCLE_ITERATION=$((ITERATION + 1))
      else
        # Final reviewer FAIL after $MAX_ITER attempts: fused into boucle:human
        # (was boucle:blocked, deleted). Configurable via BOUCLE_MAX_ITERATIONS.
        # Note BEFORE the terminal label — never a muted boucle:human.
        ESCALATION_MSG=$(printf '⚠️ Reviewer verdict: **FAIL** after %s iterations. The loop could not satisfy the acceptance criteria automatically.\n\nReview [PR #%s](%s) and the reviewer verdicts, then either:\n- **Approve** the PR if the work is acceptable (the merger will rebase + merge), or\n- **Comment** with guidance and re-assign to the bot to re-trigger the worker.' "$MAX_ITER" "$MR_IID" "$MR_URL")
        if ! forge_issue_note "$BOUCLE_ISSUE" "$ESCALATION_MSG"; then
          echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
          exit 1
        fi
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
        # Assign the MR to the issue author so they're notified that human
        # intervention is required. Without this, the user never gets a
        # signal that the loop exhausted its iterations (issue #35 on
        # a consumer repo: MR stayed assigned to the bot after 3
        # reviewer FAILs, the user saw no notification).
        assign_mr_to_author
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
      # "unparsable" notes. See LESSONS.yml lesson #43.
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$BOUCLE_ISSUE" "Verdict unparsable or uncertain. Human review needed. The MR has been assigned to you.$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      # Assign the MR to the issue author on escalation (same rationale as
      # the FAIL-after-max branch above).
      assign_mr_to_author
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
    MAX_ITER="${BOUCLE_MAX_ITERATIONS:-5}"
    echo "FAIL: agent did not post a verdict for sha $MR_HEAD (iteration $ITERATION/$MAX_ITER)" >&2
    if [ "$ITERATION" -lt "$MAX_ITER" ]; then
      echo "Re-triggering reviewer (iteration $((ITERATION + 1))/$MAX_ITER)."
      chain_to_role "$BOUCLE_ISSUE" "reviewer" BOUCLE_ITERATION=$((ITERATION + 1))
    else
      echo "Max iterations reached — escalating to human."
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Reviewer agent failed to post a verdict after $MAX_ITER attempts. Human review needed. The MR has been assigned to you."; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      assign_mr_to_author
    fi
    exit 1
  fi
}
