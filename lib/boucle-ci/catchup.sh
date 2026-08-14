#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle-ci/catchup.sh — catchup stage: post-merge issue closure and cascade.
#
# Triggered by dispatch when a human merges a boucle/<iid> MR directly
# (merge_request webhook, action=merge), bypassing the approval circuit.
# Inspects the issue state, sets boucle:done (if was at boucle:approval) or
# boucle:human (if merged early), posts an audit comment, closes the issue,
# cascades the parent close, and unblocks dependents. No e2e agent runs —
# we trust the human's merge judgment.
#
# Extracted from the .gitlab-ci.yml catchup job (lines 3211-3569).

boucle_ci_catchup() {
  # Shared gate functions (check_sibling_gate, maybe_unblock_dependents) —
  # single source of truth in lib/boucle-ci/gates.sh.
  source "$BOUCLE_HOME/lib/boucle-ci/gates.sh"
  # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script
  # under set -eo pipefail. Without pipefail, the var is just empty (which
  # we handle).
  set +o pipefail
  export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

  # ── Local helpers ──────────────────────────────────────────────────────
  # close_issue / get_work_item_children / maybe_close_parent /
  # set_boucle_label / chain_to_role come from lib/boucle.sh (sourced by
  # the lib/boucle-ci.sh bootstrap) — the local copies that used to live
  # here are removed. issue_has_active_pipeline stays local;
  # maybe_unblock_dependents comes from lib/boucle-ci/gates.sh (sourced
  # above).

  # Check if a pipeline with BOUCLE_ISSUE=$iid is already active.
  # Used by maybe_unblock_dependents to prevent double-trigger.
  # Delegates to forge_pipeline_list_active (lesson #33: match pipelines
  # to the issue via the BOUCLE_ISSUE variable, not updated_at).
  issue_has_active_pipeline() {
    local iid="$1" pipelines
    pipelines=$(forge_pipeline_list_active "$iid") || return 1
    echo "$pipelines" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1
  }

  # Source the depends-on lib for parse_depends_on.
  source "$BOUCLE_HOME/bin/lib/depends-on.sh"

  # ── Main: inspect issue state, branch, close, cascade ──────────────────
  # Disable errexit for the main flow: grep (no match) / forge API (transient
  # API error) would abort before our explicit error handling can run. We
  # handle errors per-command instead (matches e2e's post-agent section
  # pattern).
  set +e
  # Fetch the issue's current labels.
  ISSUE_DATA=$(forge_issue_get "$BOUCLE_ISSUE")
  if [ -z "$ISSUE_DATA" ]; then
    echo "FAIL: can't fetch issue #$BOUCLE_ISSUE" >&2
    exit 1
  fi
  ISSUE_STATE=$(echo "$ISSUE_DATA" | jq -r '.state // "unknown"')
  ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels | map(if type == "string" then . else .name end) | join(",")')

  # If the issue is already closed, nothing to catch up — idempotence.
  if [ "$ISSUE_STATE" = "closed" ]; then
    echo "Issue #$BOUCLE_ISSUE already closed — nothing to catch up."
    exit 0
  fi

  # Determine the current boucle:* detail label (not the gross-axis
  # boucle::status::* labels, which also start with "boucle:").
  CURRENT_BOUCLE=$(echo "$ISSUE_LABELS" | tr ',' '\n' | grep -E '^boucle:(triage|needs-info|spec-review|todo|working|review|approval|merging|done|human|split|blocked)$' | head -1)

  case "$CURRENT_BOUCLE" in
    approval)
      # Happy path: the issue was waiting for approval and the human
      # merged directly. Trust the judgment → mark done.
      TARGET="done"
      ;;
    triage | needs-info | spec-review | todo | working | review | merging)
      # Merged before the loop finished its review. Honest signal: the
      # bot did not validate completion → mark human. Still close +
      # cascade so the issue doesn't stay stuck.
      TARGET="human"
      ;;
    done | human | split | blocked)
      # Already at a terminal state — issue was handled by another path.
      echo "Issue #$BOUCLE_ISSUE already at terminal state boucle:$CURRENT_BOUCLE — skipping."
      exit 0
      ;;
    "")
      # No boucle label — issue is outside the loop. Don't touch it.
      echo "Issue #$BOUCLE_ISSUE has no boucle label — outside the loop, skipping."
      exit 0
      ;;
  esac

  echo "Catchup: issue #$BOUCLE_ISSUE was boucle:$CURRENT_BOUCLE → now boucle:$TARGET"

  # If there is an OPEN MR with the same branch, the issue was reopened
  # for a new iteration (e.g. human requested changes after approval, or
  # a new MR was created after the first one was merged). Do NOT close —
  # the open MR is the active work. This prevents the catchup from
  # re-closing a reopened issue when an old merged MR exists alongside
  # the new open one.
  MR_OPEN_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "opened")
  MR_OPEN_STATE=""
  if [ -n "$MR_OPEN_IID" ]; then
    # GitHub PR .state is "open"; GitLab MR .state is "opened".
    MR_OPEN_STATE=$(forge_mr_get "$MR_OPEN_IID" | jq -r '.state // empty' 2> /dev/null || echo "")
  fi
  if [ "$MR_OPEN_STATE" = "opened" ] || [ "$MR_OPEN_STATE" = "open" ]; then
    echo "Catchup: open MR exists for branch boucle/$BOUCLE_ISSUE — issue reopened for new iteration, skipping close."
    exit 0
  fi

  # Post an audit comment (with hidden tag for idempotence/audit).
  # The MR IID isn't passed as a variable (dispatch only forwards
  # BOUCLE_ISSUE + BOUCLE_ROLE); reference the issue + branch instead.
  AUDIT_BODY="<!-- boucle:catchup v=1 iid=$BOUCLE_ISSUE state=$CURRENT_BOUCLE target=$TARGET -->"$'\n'"🤖 Automatic catch-up — the MR on branch \`boucle/$BOUCLE_ISSUE\` was merged directly without going through the approval flow."$'\n\n'"Issue state at merge time: \`boucle:$CURRENT_BOUCLE\`."$'\n'"Issue marked \`boucle:$TARGET\` and closed."
  # The audit note is the only explanation for the transition — if it cannot
  # be posted, do NOT proceed: a boucle:human/done transition with no note is
  # a mute state change. Abort BEFORE the label + close, keeping the issue
  # in its prior state so the loop can retry.
  if ! forge_issue_note "$BOUCLE_ISSUE" "$AUDIT_BODY"; then
    echo "FAIL: catchup audit note could not be posted on issue #$BOUCLE_ISSUE — aborting the transition (no mute state change)." >&2
    exit 1
  fi

  # Apply the terminal state ONLY after the audit note is confirmed posted.
  # In the done branch, also post a deploy-success note with the resolved
  # production URL BEFORE the terminal label (lesson #59: note FIRST, label
  # SECOND — abort without the label if the note cannot be posted).
  local catchup_live_url=""
  if [ "$TARGET" = "done" ]; then
    catchup_live_url=$(boucle_resolve_live_url "" 2>/dev/null || echo "")
    if [ -n "$catchup_live_url" ]; then
      # shfmt off  # preserve exact string content
      local DEPLOY_NOTE_BODY="✅ Successfully deployed to production (catch-up).

## Production URL
$catchup_live_url

## Commit
${CI_COMMIT_SHA:-unknown}"
      # shfmt on
      if ! forge_issue_note "$BOUCLE_ISSUE" "$DEPLOY_NOTE_BODY"; then
        echo "FAIL: could not post deploy-success note on issue #$BOUCLE_ISSUE — aborting transition." >&2
        exit 1
      fi
    fi
    set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
  else
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
  fi

  # Close the issue (boucle:done is a board label, not a close state).
  close_issue "$BOUCLE_ISSUE"
  echo "Catchup: closed issue #$BOUCLE_ISSUE"

  # Post-merge branch cleanup: delete the worker branch. Best-effort — a
  # failed deletion logs a warning but does not fail the job. lesson #68.
  local branch
  branch=$(boucle_branch_name "$BOUCLE_ISSUE")
  if ! forge_branch_delete "$branch"; then
    echo "WARN: could not delete branch $branch after catchup close (stale but harmless)" >&2
  else
    echo "Deleted worker branch $branch after catchup close"
  fi

  # Cascade: if this is a sub-issue, close the parent when all siblings are closed.
  maybe_close_parent "$BOUCLE_ISSUE" "$catchup_live_url"
  # Unblock dependents: if this sub-issue was a dependency of a sibling,
  # check whether that sibling's deps are now all closed and trigger it.
  maybe_unblock_dependents "$BOUCLE_ISSUE"
}
