#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC1091,SC2250
# lib/boucle-ci/dispatch.sh — dispatch stage (webhook router).
#
# Extracted from the .gitlab-ci.yml `dispatch:` job's script block into a
# forge-agnostic shell function. Sourced by lib/boucle-ci.sh, which first
# sources the forge backend (bin/forge/${BOUCLE_FORGE}.sh) and the shared
# helpers (lib/boucle.sh: set_boucle_label, chain_to_role, ...).
#
# This is the loop's webhook router: it parses $BOUCLE_TRIGGER_PAYLOAD,
# determines the issue IID and which role to chain to, and triggers the
# next stage. All forge API calls go through the forge_* abstraction layer
# (bin/forge/common.sh contract); inline glab/curl calls with no forge_*
# equivalent yet are kept with a `# TODO: forge_*` marker.
#
# Environment contract: see lib/boucle-ci.sh (BOUCLE_* vars, set by the
# CI runner / forge shim, not assigned in this file — hence SC2154).
# The before_script bootstrap (tool install, BOUCLE_BOT_ID resolution,
# BOUCLE_HOME detection) is NOT part of this function.

# dispatch_note_body
#
# The comment body from the trigger payload, or empty when the event is not
# a comment. Forge-agnostic by trying both shapes rather than branching on
# $BOUCLE_FORGE: GitLab puts the body at .object_attributes.note, GitHub at
# .comment.body. The keys are disjoint, so a single filter is unambiguous.
#
# Silent on a missing or non-file payload — callers treat empty as "not a
# comment", which is the safe reading: it means "do not skip on the marker",
# and the routing below still applies its own guards.
dispatch_note_body() {
  [ -n "${BOUCLE_TRIGGER_PAYLOAD:-}" ] || return 0
  [ -f "$BOUCLE_TRIGGER_PAYLOAD" ] || return 0
  jq -r '.object_attributes.note // .comment.body // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || true
}

# dispatch_is_github_pr_comment
#
# True when the trigger payload is a GitHub issue_comment on a PULL REQUEST
# (.issue.pull_request non-null). GitHub multiplexes issue comments and PR
# comments into one event; the distinction matters because a PR comment must
# route to the MR-note handler (with the PR's source branch), NOT the generic
# issue path (a PR has no labels → dispatch would ABORT). False for a
# plain-issue comment and for any non-GitHub payload. Silent on a missing or
# non-file payload.
dispatch_is_github_pr_comment() {
  [ -n "${BOUCLE_TRIGGER_PAYLOAD:-}" ] || return 1
  [ -f "$BOUCLE_TRIGGER_PAYLOAD" ] || return 1
  [ "$(jq -r '.issue.pull_request != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo false)" = "true" ]
}

# dispatch_noop
#
# Exit 0 for a LEGITIMATE dispatch no-op (closed-issue guard, bot-event
# filter, chain_to_role paths, unhandled event classes). Writes a
# .boucle-noop marker so the anti-accumulation EXIT trap (which flips a
# bare `exit 0` without .boucle-issue to `exit 1`) does NOT fail the job.
# Every no-op path MUST call this instead of a bare `exit 0` — otherwise a
# webhook storm on a closed issue produces dozens of failed trigger
# pipelines that saturate the runners and block real work.
dispatch_noop() {
  touch .boucle-noop
  exit 0
}

boucle_ci_dispatch() {
  # Shared gate functions (check_sibling_gate, maybe_unblock_dependents) —
  # single source of truth in lib/boucle-ci/gates.sh.
  source "$BOUCLE_HOME/lib/boucle-ci/gates.sh"
  # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script under set -eo pipefail. Without pipefail, the var is just empty (which we handle).
  set +o pipefail
  # Anti-accumulation: if dispatch exits 0 without writing .boucle-issue
  # (real work) AND without writing .boucle-noop (a legitimate no-op),
  # fail instead so downstream triage (needs: [dispatch] without optional)
  # is skipped. This prevents no-op webhook pipelines (bot events, MR
  # actions that chain via API, unhandled events) from consuming the
  # data runner while triage bootstraps only to find no work to do.
  #
  # The .boucle-noop marker distinguishes a LEGITIMATE no-op (closed-issue
  # guard, bot-event filter, chain_to_role paths, unhandled event classes)
  # from an ACCIDENTAL no-op (a code path that forgot to write .boucle-issue).
  # Legitimate no-ops call dispatch_noop(), which writes the marker before
  # exit 0; a bare `exit 0` without either marker still fails the job.
  trap 'if [ $? -eq 0 ] && [ ! -f .boucle-issue ] && [ ! -f .boucle-noop ]; then exit 1; fi' EXIT

  # Clear any stale .boucle-issue / .boucle-noop from a previous run. The
  # files are NOT in .gitignore and survive `git clean` on some runner
  # configurations (observed on framagit 2026-08: a previous issue-webhook
  # dispatch wrote .boucle-issue; the next run's MR-note trigger dispatch
  # didn't write it, but the file still existed — the EXIT trap found it
  # and didn't flip to exit 1, so triage ran and re-triaged the issue,
  # setting spec-review + status::human and blocking the loop). The same
  # staleness applies to .boucle-noop: a leftover marker from a previous
  # run would let an accidental no-op pass the trap.
  rm -f .boucle-issue .boucle-noop

  # Sanity-check the trigger payload before jq touches it. GitLab file-type
  # CI variables resolve to a temp file path; on shared runners
  # the path can be unset, empty, or point to a deleted file. Without this
  # guard, `set -e` (GitLab default) propagates jq's exit 5 (system error,
  # file not found) and the script terminates silently with zero stdout —
  # exactly the failure that hit pipeline #1433434 on a consumer repo.
  # Always produce a breadcrumb (lessons #5, #47) so the next failure mode
  # is visible in the trace.
  echo "dispatch: begin (runner has jq=$(command -v jq 2> /dev/null || echo MISSING), BOUCLE_TRIGGER_PAYLOAD='${BOUCLE_TRIGGER_PAYLOAD:-unset}')"
  if [ -z "${BOUCLE_TRIGGER_PAYLOAD:-}" ]; then
    echo "dispatch: ABORT — BOUCLE_TRIGGER_PAYLOAD is unset (no trigger payload passed to this job)"
    exit 1
  fi
  if [ ! -f "$BOUCLE_TRIGGER_PAYLOAD" ]; then
    echo "dispatch: ABORT — BOUCLE_TRIGGER_PAYLOAD='$BOUCLE_TRIGGER_PAYLOAD' is set but the file is missing/unreadable (exit 5 trigger)"
    exit 1
  fi
  if [ ! -r "$BOUCLE_TRIGGER_PAYLOAD" ]; then
    echo "dispatch: ABORT — BOUCLE_TRIGGER_PAYLOAD='$BOUCLE_TRIGGER_PAYLOAD' is not readable (permissions?)"
    exit 1
  fi
  PAYLOAD_BYTES=$(wc -c < "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo 0)
  echo "dispatch: payload file OK ($PAYLOAD_BYTES bytes)"

  # Parse the webhook payload. Use `|| rc=$?` to suppress `set -e` (GitLab
  # default) so a jq parse error or missing field does not silently kill
  # the dispatch script before triage/no-op routing can run. The original
  # `// empty` filters already handle missing keys gracefully, but jq itself
  # can still fail on a malformed payload (jq exit 2 usage/parse error) or
  # a system-level file problem (jq exit 5) — we want a visible log, not a
  # silent abort. We catch errors here and degrade to "no recognizable
  # event" so the EXIT trap fails the job and triage is skipped; better a
  # loud failure than a phantom triage pipeline on garbage input.
  rc=0
  ACTOR=$(jq -r '.user.username // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "dispatch: ABORT — jq failed on user.username (exit $rc); payload may be malformed or unreadable"
    head -c 200 "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null | tr -d '\0' || true
    echo
    exit 1
  fi
  OBJECT_KIND=$(jq -r '.object_kind // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
  MR_ACTION=$(jq -r '.object_attributes.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true

  # ── GitHub payload normalisation ──────────────────────────────────
  # GitHub Actions events have a different shape than GitLab webhooks:
  #   - No .object_kind — the event type is in $BOUCLE_PIPELINE_SOURCE
  #     (github.event_name: "issues", "pull_request", "issue_comment", etc.)
  #   - .issue.number instead of .issue.iid
  #   - .pull_request.number instead of .object_attributes.iid
  #   - .sender.login instead of .user.username
  #   - .action instead of .object_attributes.action
  # Normalise the GitHub payload to the GitLab shape so the rest of the
  # dispatch logic works unchanged.
  if [ -z "$OBJECT_KIND" ]; then
    case "${BOUCLE_PIPELINE_SOURCE:-}" in
      issues)
        OBJECT_KIND="issue"
        ACTION=$(jq -r '.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        IID=$(jq -r '.issue.number // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ACTOR=$(jq -r '.sender.login // .user.login // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ;;
      pull_request)
        OBJECT_KIND="merge_request"
        MR_ACTION=$(jq -r '.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ACTOR=$(jq -r '.sender.login // .user.login // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ;;
      issue_comment)
        OBJECT_KIND="note"
        ACTION=$(jq -r '.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        IID=$(jq -r '.issue.number // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ACTOR=$(jq -r '.sender.login // .user.login // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        # GitHub: a comment on a PULL REQUEST arrives as issue_comment with
        # .issue.number = the PR number and .issue.pull_request non-null.
        # It is NOT an issue comment: the MR-note handler (GitLab shape
        # .merge_request.*) must receive the PR number + source branch, or
        # dispatch reads the PR's (empty) labels and ABORTS — human PR
        # feedback could never re-trigger the worker.
        if dispatch_is_github_pr_comment; then
          MR_NOTE_IID="$IID"
          MR_NOTE_SOURCE_BRANCH=$(forge_mr_get "$IID" | jq -r '.head.ref // empty' 2> /dev/null || echo "")
        fi
        ;;
      pull_request_review | pull_request_review_comment)
        OBJECT_KIND="note"
        MR_ACTION=$(jq -r '.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ACTOR=$(jq -r '.sender.login // .user.login // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
        ;;
    esac
  fi
  # ── Anti-loop: boucle's own comments ──────────────────────────────
  # Applies in BOTH modes. Forges do not guarantee webhook delivery order,
  # so the label-change webhook of a transition can overtake the comment
  # that preceded it; the comment then lands on the NEW (possibly paused)
  # state and would route — starting the worker before the human approved
  # the spec, or re-triggering triage in a loop. The marker identifies
  # boucle's own writes regardless of ordering, which the actor check
  # cannot do once the ordering assumption breaks.
  NOTE_BODY=$(dispatch_note_body)
  if [ -n "$NOTE_BODY" ] && has_agent_marker "$NOTE_BODY"; then
    echo "dispatch: comment carries the boucle:agent marker — boucle's own write, skipping"
    dispatch_noop
  fi

  # ── Anti-loop: bot-originated events, by identity ─────────────────
  # Only meaningful when boucle has an account of its own. In mono-user
  # mode ACTOR is the human on EVERY event — the loop's and the human's
  # alike — so this guard would discard the human's legitimate triggers
  # (opening an issue, replying on needs-info, approving the spec) and the
  # loop would never fire. The marker above replaces it; the other event
  # classes need no identity filter, since label changes are already
  # guarded by PREV_LABELS below and MR routing is action-based.
  #
  # The merge exception must survive: when the merger job merges a MR the
  # webhook fires with ACTOR=<bot>, and without letting it through the
  # catchup never runs and the issue stays stuck at boucle:merging (the
  # merger's e2e close path can fail, leaving no fallback).
  if ! boucle_mono_user; then
    if [ "$ACTOR" = "${BOUCLE_BOT_USERNAME:-up-bot}" ] && [ "$MR_ACTION" != "merge" ]; then
      dispatch_noop
    fi
  fi

  # ── Merge request events ──────────────────────────────────────────
  # GitLab emits a Merge Request Hook for each MR lifecycle action:
  #   open, update, close, reopen, approved, unapproved, merge
  # We route each to the appropriate loop stage:
  #   approved  → merger (existing behavior)
  #   update    → reviewer (MR was revised → re-review)
  #   close     → worker (MR rejected → re-run with feedback)
  #   reopen    → reviewer (MR reopened → re-review)
  #   unapproved→ reviewer (approval revoked → re-review)
  #   open/merge→ skip (worker chains to reviewer; merger handles merge)
  # Bot-originated events are filtered by the ACTOR guard above, except
  # merge actions (which trigger catchup to close the issue).
  if [ "$OBJECT_KIND" = "merge_request" ]; then
    # Late payload reads: the trigger payload file can vanish mid-job (jq
    # exit 5 "system error" — same failure as pipeline #1433434 on a
    # consumer repo). Deferred with a fallback so a vanished file degrades
    # to an empty value instead of killing dispatch silently under set -e.
    SOURCE_BRANCH=$(jq -r '.object_attributes.source_branch // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "")
    MR_IID=$(jq -r '.object_attributes.iid // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "")
    # Extract issue IID from branch name boucle/<iid>
    MR_ISSUE_IID=$(printf '%s' "$SOURCE_BRANCH" | sed -n 's/^boucle\/\([0-9]\+\).*/\1/p')
    if [ -z "$MR_ISSUE_IID" ]; then
      echo "MR !${MR_IID} ($MR_ACTION) but source_branch '$SOURCE_BRANCH' is not a boucle branch, skipping"
      dispatch_noop
    fi

    # Global guard: if the issue is already closed, skip ALL MR webhooks.
    # A closed issue is terminal from the loop's perspective; re-triggering
    # roles on it only produces pipeline noise (issue #35). The catchup
    # (merge action) is idempotent on a closed issue, and all other actions
    # are meaningless once the issue is closed.
    if [ -n "$MR_ISSUE_IID" ]; then
      ISSUE_STATE=$(forge_issue_get "$MR_ISSUE_IID" | jq -r '.state // empty' 2> /dev/null || true)
      if [ "$ISSUE_STATE" = "closed" ]; then
        echo "boucle: issue #$MR_ISSUE_IID is closed — skipping $MR_ACTION webhook (no-op)"
        dispatch_noop
      fi
    fi

    case "$MR_ACTION" in
      approved)
        # Trigger merger if the issue is at boucle:approval (reviewer
        # PASS'd it) OR boucle:human (human override — the reviewer
        # failed/UNCERTAIN but the human manually approves the MR,
        # overriding the reviewer's verdict). Without this fallback,
        # a reviewer failure strands the issue at boucle:human with no
        # path forward even after the human approves the MR natively.
        MR_LABELS=$(forge_issue_labels_get "$MR_ISSUE_IID")
        if ! echo "$MR_LABELS" | grep -qE "boucle:(approval|human)"; then
          echo "Issue #$MR_ISSUE_IID not at boucle:approval or boucle:human (labels: $MR_LABELS) — ignoring MR approval, skipping"
          dispatch_noop
        fi
        if echo "$MR_LABELS" | grep -q "boucle:human"; then
          echo "MR !${MR_IID} approved (native GitLab approval) for issue #$MR_ISSUE_IID — human override of reviewer verdict, triggering merger"
        else
          echo "MR !${MR_IID} approved (native GitLab approval) for issue #$MR_ISSUE_IID — triggering merger"
        fi
        chain_to_role "$MR_ISSUE_IID" "merger"
        dispatch_noop
        ;;
      update)
        # MR branch updated (new commits pushed by a human). Re-trigger
        # the reviewer so it re-reviews the revised MR. If the issue was
        # already at boucle:approval (approved before the update), the
        # update invalidates the approval — revert to boucle:review first.
        MR_LABELS=$(forge_issue_labels_get "$MR_ISSUE_IID")
        if echo "$MR_LABELS" | grep -q "boucle:approval"; then
          echo "MR !${MR_IID} updated after approval — reverting issue #$MR_ISSUE_IID to boucle:review"
          # Preserve non-boucle labels, set boucle:review + bot status
          NON_BOUCLE=$(echo "$MR_LABELS" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
          # Idempotence: skip the PUT when the target labels are already set
          # (GitLab records a Resource Label Event on every PUT, even no-ops).
          if ! (echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle:review" && echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle::status::bot"); then
            forge_issue_labels_set "$MR_ISSUE_IID" "${NON_BOUCLE:+$NON_BOUCLE,}boucle:review,boucle::status::bot"
          fi
        fi
        echo "MR !${MR_IID} updated — re-triggering reviewer for issue #$MR_ISSUE_IID"
        chain_to_role "$MR_ISSUE_IID" "reviewer"
        dispatch_noop
        ;;
      close)
        # MR closed (not merged). The semantics depend on the issue's
        # current boucle label (issue #34):
        #   - terminal (done, human): the loop considers this issue
        #     settled; a close webhook is a no-op.
        #   - approval: the user closed the MR without merging while
        #     awaiting approval — a human decision, escalate to
        #     boucle:human rather than restarting the worker.
        #   - any other state (todo, working, review, merging, …): a
        #     real rejection — revert to boucle:todo and re-trigger
        #     the worker with feedback.
        MR_LABELS=$(forge_issue_labels_get "$MR_ISSUE_IID")
        CURRENT_BOUCLE=$(echo "$MR_LABELS" | tr ',' '\n' | grep -E '^boucle:(triage|needs-info|spec-review|todo|working|review|approval|merging|done|human|split|blocked)$' | head -1)
        case "$CURRENT_BOUCLE" in
          boucle:done | boucle:human)
            echo "boucle: issue #$MR_ISSUE_IID is already at $CURRENT_BOUCLE (terminal) — close webhook ignored"
            dispatch_noop
            ;;
          boucle:approval)
            # User closed the MR without merging while it was awaiting
            # approval. This is a human decision, not a rejection to
            # redo. Escalate to human instead of restarting the worker
            # loop (issue #34).
            echo "boucle: MR !${MR_IID} closed while at $CURRENT_BOUCLE — escalating to boucle:human (user decision)"
            NON_BOUCLE_HUMAN=$(echo "$MR_LABELS" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
            HUMAN_LABELS="${NON_BOUCLE_HUMAN:+$NON_BOUCLE_HUMAN,}boucle:human,boucle::status::human"
            # Idempotence: skip the PUT when the target labels are already
            # set (GitLab records a Resource Label Event on every PUT,
            # even no-ops).
            if ! (echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle:human" && echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle::status::human"); then
              forge_issue_labels_set "$MR_ISSUE_IID" "$HUMAN_LABELS"
            fi
            # Note BEFORE the terminal label — never a muted boucle:human.
            if ! forge_issue_note "$MR_ISSUE_IID" ":warning: MR !${MR_IID} was closed while awaiting approval. Escalated to **boucle:human** (user decision, not auto-redo)."; then
              echo "FAIL: escalation note could not be posted on issue #$MR_ISSUE_IID — issue already at human labels, flagging loudly (note missing)." >&2
              exit 1
            fi
            dispatch_noop
            ;;
        esac
        # Legitimate rejection: revert the issue to boucle:todo so the
        # worker re-runs and produces a new MR addressing the rejection
        # feedback. Preserve non-boucle labels.
        echo "MR !${MR_IID} closed (rejected) — reverting issue #$MR_ISSUE_IID to boucle:todo for worker re-run"
        NON_BOUCLE=$(echo "$MR_LABELS" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
        # Idempotence: skip the PUT when the target labels are already set
        # (GitLab records a Resource Label Event on every PUT, even no-ops).
        if ! (echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle:todo" && echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle::status::bot"); then
          forge_issue_labels_set "$MR_ISSUE_IID" "${NON_BOUCLE:+$NON_BOUCLE,}boucle:todo,boucle::status::bot"
        fi
        chain_to_role "$MR_ISSUE_IID" "worker"
        dispatch_noop
        ;;
      reopen)
        # MR reopened — re-trigger the reviewer to re-review it.
        echo "MR !${MR_IID} reopened — re-triggering reviewer for issue #$MR_ISSUE_IID"
        chain_to_role "$MR_ISSUE_IID" "reviewer"
        dispatch_noop
        ;;
      unapproved)
        # Author revoked approval — revert to boucle:review and re-trigger
        # the reviewer so the MR gets re-reviewed before re-approval.
        echo "MR !${MR_IID} unapproved — reverting issue #$MR_ISSUE_IID to boucle:review"
        MR_LABELS=$(forge_issue_labels_get "$MR_ISSUE_IID")
        NON_BOUCLE=$(echo "$MR_LABELS" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
        # Idempotence: skip the PUT when the target labels are already set
        # (GitLab records a Resource Label Event on every PUT, even no-ops).
        if ! (echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle:review" && echo "$MR_LABELS" | tr ',' '\n' | grep -qx "boucle::status::bot"); then
          forge_issue_labels_set "$MR_ISSUE_IID" "${NON_BOUCLE:+$NON_BOUCLE,}boucle:review,boucle::status::bot"
        fi
        chain_to_role "$MR_ISSUE_IID" "reviewer"
        dispatch_noop
        ;;
      merge)
        # A boucle/<iid> MR was merged directly (human clicked Merge in the
        # GitLab UI, bypassing the approval circuit → merger job). The
        # push to $BOUCLE_DEFAULT_BRANCH already triggered deploy → smoke e2e (no issue
        # context). Catch up: trigger the catchup job to close the issue
        # + cascade the parent, so it doesn't stay stuck at boucle:approval.
        # MR_ISSUE_IID was extracted from the branch name above (line 173);
        # non-boucle branches already exited at line 174-176.
        echo "MR !${MR_IID} merged directly (action=merge) for issue #$MR_ISSUE_IID — triggering catchup"
        chain_to_role "$MR_ISSUE_IID" "catchup"
        dispatch_noop
        ;;
      open)
        # open: the worker creates the MR and chains to reviewer itself —
        # no dispatch action needed.
        echo "MR !${MR_IID} action=$MR_ACTION — handled by worker, skipping"
        dispatch_noop
        ;;
      *)
        echo "MR !${MR_IID} action=$MR_ACTION — not handled, skipping"
        dispatch_noop
        ;;
    esac
  fi

  # For note events, .object_attributes.iid is the note's DB id, not the issue IID.
  # The issue IID lives in the sibling key: .issue.iid (classic issues),
  # .work_item.iid (work items), or .epic.iid (epics).
  # Notes on a MR live in .merge_request.iid — handled separately below.
  if [ "$OBJECT_KIND" = "note" ] || [ "$OBJECT_KIND" = "emoji" ]; then
    # Skip system notes (assignee changes, label changes, branch
    # additions, status changes). GitLab fires a note webhook with
    # .object_attributes.system = true for these. They are NOT human
    # replies and must not trigger the loop — otherwise creating an
    # issue + assigning the bot in the same form fires BOTH an `issue`
    # webhook (open → triage) AND a `note` webhook (system "assigned
    # to @up-bot" → triage again), double-triggering triage. The
    # BOT_JUST_ASSIGNED path already handles assignment via the issue
    # update webhook, so the system note is pure redundancy. Emoji
    # events have no `system` field and are unaffected.
    if [ "$OBJECT_KIND" = "note" ]; then
      NOTE_SYSTEM=$(jq -r '.object_attributes.system // false' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "false")
      if [ "$NOTE_SYSTEM" = "true" ]; then
        echo "System note (non-human) — skipping"
        dispatch_noop
      fi
    fi
    # ── Notes on a MR: human comment → re-trigger worker with feedback ──
    # When a human comments on a boucle MR, they're reviewing it and
    # providing feedback. Re-trigger the worker so it re-runs and can
    # address the comments. Bot notes are filtered by the ACTOR guard.
    # GitLab payload: .merge_request.iid. GitHub PR comments: resolved in
    # the normalisation (issue_comment on a PR carries .issue.number, the
    # branch is fetched via the API — not in the payload).
    PAYLOAD_MR_NOTE_IID=$(jq -r '.merge_request.iid // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "")
    if [ -n "$PAYLOAD_MR_NOTE_IID" ]; then
      MR_NOTE_IID="$PAYLOAD_MR_NOTE_IID"
    fi
    if [ -n "${MR_NOTE_IID:-}" ] && [ "$OBJECT_KIND" = "note" ]; then
      # GitLab payload carries .merge_request.source_branch; for GitHub PR
      # comments the branch was already resolved in the normalisation
      # (MR_NOTE_SOURCE_BRANCH set there). Keep whichever is available.
      PAYLOAD_MR_NOTE_SOURCE_BRANCH=$(jq -r '.merge_request.source_branch // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "")
      if [ -n "$PAYLOAD_MR_NOTE_SOURCE_BRANCH" ]; then
        MR_NOTE_SOURCE_BRANCH="$PAYLOAD_MR_NOTE_SOURCE_BRANCH"
      fi
      MR_NOTE_ISSUE_IID=$(printf '%s' "${MR_NOTE_SOURCE_BRANCH:-}" | sed -n 's/^boucle\/\([0-9]\+\).*/\1/p')
      if [ -z "$MR_NOTE_ISSUE_IID" ]; then
        echo "Note on MR !${MR_NOTE_IID} but source_branch '$MR_NOTE_SOURCE_BRANCH' is not a boucle branch, skipping"
        dispatch_noop
      fi
      echo "Note on MR !${MR_NOTE_IID} (issue #$MR_NOTE_ISSUE_IID) — re-triggering worker with feedback"
      # Count reviewer verdicts on the MR to determine the next iteration
      # number. Each verdict = one completed worker+reviewer cycle, so the
      # next worker run is verdicts + 1. Without this, the MR-note dispatch
      # was the only re-trigger path that omitted BOUCLE_ITERATION, so the
      # worker defaulted to 1 and the MR description always showed
      # "iteration 1" even after multiple feedback rounds.
      MR_NOTE_VERDICTS=$(forge_mr_notes "$MR_NOTE_IID" \
        | jq '[.[] | select(.body | contains("boucle:verdict"))] | length' 2> /dev/null || echo 0)
      MR_NOTE_ITERATION=$((MR_NOTE_VERDICTS + 1))
      echo "MR !${MR_NOTE_IID} has $MR_NOTE_VERDICTS verdict(s) — re-triggering worker as iteration $MR_NOTE_ITERATION"
      # Revert to boucle:todo so the worker re-runs (preserving non-boucle labels)
      MR_NOTE_LABELS=$(forge_issue_labels_get "$MR_NOTE_ISSUE_IID")
      NON_BOUCLE=$(echo "$MR_NOTE_LABELS" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
      # Idempotence: skip the PUT when the target labels are already set
      # (GitLab records a Resource Label Event on every PUT, even no-ops).
      if ! (echo "$MR_NOTE_LABELS" | tr ',' '\n' | grep -qx "boucle:todo" && echo "$MR_NOTE_LABELS" | tr ',' '\n' | grep -qx "boucle::status::bot"); then
        forge_issue_labels_set "$MR_NOTE_ISSUE_IID" "${NON_BOUCLE:+$NON_BOUCLE,}boucle:todo,boucle::status::bot"
      fi
      chain_to_role "$MR_NOTE_ISSUE_IID" "worker" "BOUCLE_ITERATION=$MR_NOTE_ITERATION"
      dispatch_noop
    fi
    IID=$(jq -r '.issue.iid // .work_item.iid // .epic.iid // .issue.number // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
  else
    IID=$(jq -r '.object_attributes.iid // .issue.iid // .issue.number // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
  fi

  if [ -z "$IID" ]; then
    # Recovery path: allow manual triage trigger via BOUCLE_ISSUE variable
    if [ -n "${BOUCLE_ISSUE:-}" ]; then
      echo "No IID in payload, but BOUCLE_ISSUE=$BOUCLE_ISSUE set via trigger. Using it."
      IID="$BOUCLE_ISSUE"
    else
      echo "No issue IID in payload, skipping"
      dispatch_noop
    fi
  fi

  # Closed-issue guard for issue webhooks (update/note/emoji). A closed
  # issue is terminal — label changes and notes on it must NOT re-trigger
  # the loop, otherwise the dispatch no-ops and the EXIT trap flips the
  # exit 0 to exit 1, producing a cascade of failed pipelines. The one
  # exception is BOT_JUST_ASSIGNED: a human assigning the bot to a closed
  # issue is an explicit re-trigger signal (the human wants to reopen and
  # resume work), so we let that path through and check state there.
  # MR webhooks already have their own guard at lines 307-313.
  if [ "$OBJECT_KIND" != "merge_request" ]; then
    echo "dispatch: checking issue state for #$IID (closed-issue guard)"
    ISSUE_STATE_FOR_GUARD=$(forge_issue_get "$IID" | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
    if [ "$ISSUE_STATE_FOR_GUARD" = "closed" ]; then
      # Check if this is a BOT_JUST_ASSIGNED event — if so, let it through
      # (the human explicitly assigned the bot to reopen the issue).
      GUARD_ACTION=$(jq -r '.object_attributes.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null || echo "")
      GUARD_BOT_ASSIGNED=false
      if [ "$OBJECT_KIND" = "issue" ] && [ "$GUARD_ACTION" = "update" ]; then
        if [ -n "${BOUCLE_BOT_ID:-}" ] && [[ "$BOUCLE_BOT_ID" =~ ^[0-9]+$ ]]; then
          # Late payload reads — same vanished-file guard as the inline
          # dispatch copy (jq exit 5, pipeline #1433434): degrade to
          # "no assignee change" instead of dying under set -e.
          GUARD_BOT_IN_CURRENT=$(jq -r --arg bid "$BOUCLE_BOT_ID" '.changes.assignees.current // [] | map(.id | tostring) | index($bid) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || GUARD_BOT_IN_CURRENT=false
          GUARD_BOT_IN_PREVIOUS=$(jq -r --arg bid "$BOUCLE_BOT_ID" '.changes.assignees.previous // [] | map(.id | tostring) | index($bid) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || GUARD_BOT_IN_PREVIOUS=false
        else
          GUARD_BOT_IN_CURRENT=$(jq -r --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '.changes.assignees.current // [] | map(.username) | index($bname) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || GUARD_BOT_IN_CURRENT=false
          GUARD_BOT_IN_PREVIOUS=$(jq -r --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '.changes.assignees.previous // [] | map(.username) | index($bname) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || GUARD_BOT_IN_PREVIOUS=false
        fi
        if [ "$GUARD_BOT_IN_CURRENT" = "true" ] && [ "$GUARD_BOT_IN_PREVIOUS" != "true" ]; then
          GUARD_BOT_ASSIGNED=true
        fi
      fi
      if [ "$GUARD_BOT_ASSIGNED" != "true" ]; then
        echo "boucle: issue #$IID is closed — skipping $OBJECT_KIND webhook (no-op on closed issue)"
        dispatch_noop
      fi
      echo "boucle: issue #$IID is closed but bot was just assigned — letting through (human re-trigger)"
    fi
  fi

  # ── Allow-list gate ──────────────────────────────────────────────────
  # Safety net: only issues whose resolved human reporter is in
  # BOUCLE_ALLOWED_USERS are accepted. Fail-open when the variable is
  # unset (legacy consumers). The reporter is resolved through the parent
  # chain (bot-authored sub-issues resolve to their parent's author). On
  # rejection an explanatory note is posted and NO role is triggered — the
  # anti-accumulation EXIT trap turns this no-op exit into a visible
  # pipeline failure. Only applies to issue/note/emoji events: MR and
  # MR-note events already exited above.
  if ! check_allow_list_gate "$IID"; then
    echo "dispatch: issue #$IID rejected by the allow list — skipping"
    dispatch_noop
  fi

  # Label helper: preserve non-boucle labels when writing a boucle label.
  # The jq filter uses startswith("boucle:") which catches BOTH the detail
  # axis (boucle:triage) AND the gross axis (boucle::status::bot, also
  # starts with "boucle:"), so we strip all boucle-managed labels when
  # writing a new pair. Caller passes detail as $2 and gross as $3.
  # Label helper set_boucle_label is sourced from $BOUCLE_HOME/lib/boucle.sh
  # in the before_script (idempotent writes + bot/human reassignment).

  # ── Dependency gate helpers ──────────────────────────────────────────
  # Source the depends-on lib for parse_depends_on.
  # shellcheck source=/dev/null
  source "$BOUCLE_HOME/bin/lib/depends-on.sh"

  # Dependency gate: if the issue has a "## Depends on" section (or the
  # boucle:depends-on marker), check that ALL dep IIDs are closed. If any
  # dep is open → set boucle:blocked (NOT boucle:todo), post an explanatory
  # note, and return 1 (caller must NOT trigger the worker). If all deps
  # are closed (or there are no deps) → return 0 (caller triggers normally).
  #
  # This is a DIFFERENT defer reason than the capacity cap: capacity = "ready
  # but no slot"; blocked = "not ready, waiting for a sibling". The doctor
  # re-triggers boucle:todo on capacity-free; it does NOT re-trigger
  # boucle:blocked (only the unblock path does, when a dep closes).
  check_dependencies_and_gate() {
    local iid="$1"
    local desc deps_iids dep_iid dep_state open_deps
    desc=$(forge_issue_get "$iid" \
      | jq -r '.description // empty' 2> /dev/null || echo "")
    [ -z "$desc" ] && return 0 # can't check → don't block (fail open)
    deps_iids=$(parse_depends_on "$desc")
    [ -z "$deps_iids" ] && return 0 # no deps → not blocked
    open_deps=""
    for dep_iid in $(echo "$deps_iids" | tr ',' ' '); do
      dep_state=$(forge_issue_get "$dep_iid" \
        | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
      if [ "$dep_state" != "closed" ]; then
        open_deps="${open_deps:+$open_deps,}#$dep_iid ($dep_state)"
      fi
    done
    if [ -n "$open_deps" ]; then
      echo "[boucle] #$iid blocked — waiting on deps: $open_deps"
      # Set boucle:blocked (replaces any boucle:todo). Preserve non-boucle labels.
      set_boucle_label "$iid" "boucle:blocked" "boucle::status::bot"
      # Post explanatory note (idempotent-ish: the unblock path will post a
      # follow-up when deps clear). Use a marker so the note is identifiable.
      local human_list
      human_list=$(echo "$deps_iids" | sed 's/,/, #/g; s/^/#/')
      local blocked_body
      blocked_body=$(printf '⏳ Blocked on sibling sub-issue(s): %s. The worker will start automatically once all of them are closed.\n\n<!-- boucle:blocked v=1 iids=%s -->' "$human_list" "$deps_iids")
      forge_issue_note "$iid" "$blocked_body"
      return 1
    fi
    return 0
  }

  # Get current labels. Guard with || true so a forge_issue_labels_get
  # failure (missing BOUCLE_FORGE_HOST, auth error on shared runner,
  # network issue) does not kill the script under set -e before routing
  # echos fire (lesson #5).
  echo "dispatch: fetching labels for #$IID (forge=$BOUCLE_FORGE_HOST, project=$BOUCLE_PROJECT_ID)"
  LABELS=$(forge_issue_labels_get "$IID")
  if [ -z "$LABELS" ]; then
    echo "dispatch: ABORT — forge_issue_labels_get failed to fetch labels for #$IID (BOUCLE_FORGE_HOST=${BOUCLE_FORGE_HOST:-unset}, exit non-zero)"
    exit 1
  fi
  echo "dispatch: labels for #$IID: $LABELS"

  # Resolve: issue opened, body edited in triage/needs-info/todo, or author reply on needs-info
  ACTION=$(jq -r '.object_attributes.action // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true

  # Parent issue split into sub-issues — waiting for them to close.
  # Do not re-triage or re-work; the doctor closes it when sub-issues complete.
  if echo "$LABELS" | grep -q "boucle:split"; then
    echo "Issue #$IID has boucle:split — waiting for sub-issues, skipping"
    dispatch_noop
  fi

  # Emoji reactions that count as spec approval — canonical set only.
  # The webhook carries the raw GitLab award name; the backends normalize
  # via forge_reaction_canonical, so only "thumbsup" counts.
  # Must mirror the doctor job's constant — each CI job runs its own shell.
  BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup heart rocket tada"

  # Detect if the bot was just assigned to this issue (update action with
  # an assignee change). This lets a human trigger boucle by assigning the
  # issue to the bot, without needing to add a boucle: label. The ACTOR
  # guard above already filters bot-originated events, so this only fires
  # when a HUMAN assigns the bot — no loop risk.
  BOT_JUST_ASSIGNED=false
  if [ "$OBJECT_KIND" = "issue" ] && [ "$ACTION" = "update" ]; then
    if [ -n "${BOUCLE_BOT_ID:-}" ] && [[ "$BOUCLE_BOT_ID" =~ ^[0-9]+$ ]]; then
      BOT_IN_CURRENT=$(jq -r --arg bid "$BOUCLE_BOT_ID" '.changes.assignees.current // [] | map(.id | tostring) | index($bid) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      BOT_IN_PREVIOUS=$(jq -r --arg bid "$BOUCLE_BOT_ID" '.changes.assignees.previous // [] | map(.id | tostring) | index($bid) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
    else
      # Fallback: detect by bot username "up-bot" when BOUCLE_BOT_ID is unset
      BOT_IN_CURRENT=$(jq -r --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '.changes.assignees.current // [] | map(.username) | index($bname) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      BOT_IN_PREVIOUS=$(jq -r --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '.changes.assignees.previous // [] | map(.username) | index($bname) != null' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
    fi
    if [ "$BOT_IN_CURRENT" = "true" ] && [ "$BOT_IN_PREVIOUS" != "true" ]; then
      BOT_JUST_ASSIGNED=true
      echo "Issue #$IID: bot was just assigned — will trigger triage"
    fi
  fi

  # If the bot was just assigned by a human, trigger triage — unless the
  # loop is already actively processing or has finished this issue. Active
  # states (working/review/approval/merging) and terminal states (done/split)
  # are skipped to avoid disrupting in-progress work. This takes precedence
  # over label-based routing so assigning the bot works from ANY idle state
  # (boucle:human, boucle:needs-info without reply, unlabeled, etc.).
  if [ "$BOT_JUST_ASSIGNED" = "true" ]; then
    if echo "$LABELS" | grep -qE 'boucle:(working|review|approval|merging|done)'; then
      echo "Issue #$IID: bot assigned but issue is at an active/terminal boucle state ($LABELS) — skipping"
      dispatch_noop
    fi
    echo "Issue #$IID: bot assigned by human — triggering triage"
    echo "$IID" > .boucle-issue
    if ! echo "$LABELS" | grep -q "boucle:triage"; then
      set_boucle_label "$IID" "boucle:triage" "boucle::status::bot"
    fi
    # Skip the label-based routing below — triage is already triggered.
    # The triage job (needs: dispatch, optional) picks up .boucle-issue.
    dispatch_noop
  fi

  SHOULD_TRIAGE=false
  SHOULD_WORK=false
  # The status board (#36) is boucle's own artefact, not work. Creating it
  # fires an issue webhook like any other; without this guard the dispatcher
  # would triage the board and the loop would start working on itself.
  if echo "$LABELS" | tr ',' '\n' | grep -qx "boucle:board"; then
    echo "Issue #$IID is the boucle status board — never dispatched."
    dispatch_noop
  fi
  if echo "$LABELS" | grep -q "boucle:triage"; then
    SHOULD_TRIAGE=true
  elif echo "$LABELS" | grep -q "boucle:needs-info"; then
    # Re-trigger on author reply (note event by non-bot) OR on emoji
    # reaction (thumbsup/heart/rocket/tada) on a bot note — the user
    # signals they've taken action (e.g. added an API key after a no-key
    # or quota-exhausted help message).
    if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "${BOUCLE_BOT_USERNAME:-up-bot}" ]; then
      SHOULD_TRIAGE=true
    elif [ "$OBJECT_KIND" = "emoji" ] && [ "$ACTOR" != "${BOUCLE_BOT_USERNAME:-up-bot}" ]; then
      EMOJI_NAME=$(jq -r '.object_attributes.name // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      EMOJI_ACTION=$(jq -r '.object_attributes.action // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      AWARDABLE_TYPE=$(jq -r '.object_attributes.awardable_type // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      if [ "$EMOJI_ACTION" = "award" ] \
        && [ "$AWARDABLE_TYPE" = "Note" ] \
        && echo "$EMOJI_NAME" | grep -Eq "^($BOUCLE_SPEC_APPROVAL_EMOJIS)$"; then
        SHOULD_TRIAGE=true
      fi
    fi
  elif echo "$LABELS" | grep -q "boucle:todo"; then
    # If boucle:todo was just added (by triage), triage already triggered
    # the worker — skip to avoid a duplicate worker pipeline. Detect by
    # checking whether boucle:todo was in the previous labels (before
    # this webhook event). If it was already there, this is a re-trigger
    # (body edit, note, manual label toggle) → trigger worker directly.
    # GitLab: .changes.labels.previous lists the labels before this event.
    # GitHub: no .changes.labels — the labeled event carries the added
    # label in .label.name, and any non-labeled event (comment, edit) on
    # a boucle:todo issue means boucle:todo was already there.
    if [ -n "$(jq -r '.changes.labels.previous // empty' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_LABELS=$(jq -r '.changes.labels.previous | join(",")' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
    elif [ "$ACTION" = "labeled" ]; then
      PREV_LABELS=$(jq -r 'if .label.name == "boucle:todo" then "just-added" else "boucle:todo" end' "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
    else
      PREV_LABELS="boucle:todo"
    fi
    if echo "$PREV_LABELS" | grep -q "boucle:todo"; then
      SHOULD_WORK=true
    else
      echo "boucle:todo just added (likely by triage) — worker already triggered, skipping"
      dispatch_noop
    fi
  elif echo "$LABELS" | grep -q "boucle:spec-review"; then
    # Author approved the spec (added a non-bot note to an issue that
    # was at boucle:spec-review). The boucle:spec-approved label was
    # removed — authors now approve by replying instead. Trigger the
    # worker — it will relabel to boucle:working (replacing all boucle:
    # labels, including the stale boucle:spec-review). We do NOT strip
    # boucle:spec-review here.
    if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "${BOUCLE_BOT_USERNAME:-up-bot}" ]; then
      SHOULD_WORK=true
    elif [ "$OBJECT_KIND" = "emoji" ] && [ "$ACTOR" != "${BOUCLE_BOT_USERNAME:-up-bot}" ]; then
      EMOJI_NAME=$(jq -r '.object_attributes.name // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      EMOJI_ACTION=$(jq -r '.object_attributes.action // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      AWARDABLE_TYPE=$(jq -r '.object_attributes.awardable_type // empty' "$BOUCLE_TRIGGER_PAYLOAD")
      if [ "$EMOJI_ACTION" = "award" ] \
        && [ "$AWARDABLE_TYPE" = "Note" ] \
        && echo "$EMOJI_NAME" | grep -Eq "^($BOUCLE_SPEC_APPROVAL_EMOJIS)$"; then
        SHOULD_WORK=true
      fi
    fi
  elif echo "$LABELS" | grep -q "boucle:human"; then
    # Human comment on an issue at boucle:human — the human is providing
    # feedback or amendments. Re-trigger the worker so it picks up the
    # comments and re-implements. Without this, comments on an issue at
    # boucle:human are silently ignored (the loop is paused, waiting for
    # a terminal action like MR approval or manual re-assignment). The
    # human expects their comment to be acted on, not ignored.
    if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "${BOUCLE_BOT_USERNAME:-up-bot}" ]; then
      SHOULD_WORK=true
    fi
  elif [ -z "$LABELS" ] || [ "$ACTION" = "open" ]; then
    # New issue with no boucle label → triage
    SHOULD_TRIAGE=true
  fi

  if [ "$SHOULD_TRIAGE" = "true" ]; then
    echo "Triggering triage for issue #$IID"
    # Chain to triage job by writing to a file that downstream jobs read
    echo "$IID" > .boucle-issue
    # Apply boucle:triage + boucle::status::bot if not present (preserving any non-boucle labels)
    if ! echo "$LABELS" | grep -q "boucle:triage"; then
      set_boucle_label "$IID" "boucle:triage" "boucle::status::bot"
    fi
  elif [ "$SHOULD_WORK" = "true" ]; then
    # Dependency gate: check before triggering. If blocked, the issue
    # stays at boucle:blocked and the worker is NOT triggered. The
    # unblock path (maybe_unblock_dependents) re-triggers when deps close.
    if check_dependencies_and_gate "$IID"; then
      # Sibling serialization gate: sub-issues of the same parent run one
      # at a time (a priori, no file manifest). If a sibling is active,
      # stay boucle:blocked until it reaches done/closed.
      if check_sibling_gate "$IID"; then
        # File-impact gate: defer the worker if its issue claims files
        # already claimed by an in-flight issue (prevents parallel workers
        # editing the same files from conflicting at rebase/merge).
        if check_file_gate "$IID"; then
          # Revert to boucle:todo before chaining — the worker refuses to
          # run on any other label (spec-review, human, etc.). Idempotent:
          # skip the PUT when boucle:todo is already set.
          if ! echo "$LABELS" | tr ',' '\n' | grep -qx "boucle:todo"; then
            set_boucle_label "$IID" "boucle:todo" "boucle::status::bot"
          fi
          echo "Triggering worker for issue #$IID (boucle:todo re-trigger)"
          chain_to_role "$IID" "worker"
        fi
      fi
    fi
    dispatch_noop
  else
    echo "No action needed for issue #$IID (labels: $LABELS)"
    dispatch_noop
  fi
}
