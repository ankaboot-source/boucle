#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle-ci/catchup.sh — catchup stage: post-merge verification after a
# direct (human) merge.
#
# Triggered by dispatch when a human merges a boucle/<iid> MR directly
# (merge_request webhook, action=merge), bypassing the approval circuit.
# Inspects the issue state, posts an audit comment, sets boucle:merging as a
# transitional label, deletes the worker branch, and chains to post-merge
# (deploy-wait + e2e). The e2e verdict routing then applies the terminal
# label (boucle:done on PASS, boucle:human on FAIL/UNCERTAIN), closes the
# issue, and cascades the parent close + dependent unblock.
#
# E2e runs on a direct merge because production health is orthogonal to who
# approved the merge: clicking Merge does not verify the live URL, the deploy
# pipeline, or regressions on the merged build. A manual merge used to get
# LESS verification than an automated one — that was the wrong direction.
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
  # set_boucle_label / chain_to_role / boucle_branch_name /
  # boucle_board_upsert / forge_branch_delete come from lib/boucle.sh
  # (sourced by the lib/boucle-ci.sh bootstrap) and the forge layer.
  # issue_has_active_pipeline stays local; the gate functions from
  # lib/boucle-ci/gates.sh are sourced above but no longer called here —
  # the terminal close + cascade + dependent unblock is now done by the
  # e2e verdict routing (lib/boucle-ci/e2e.sh) after production verification.

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

  # ── Main: inspect issue state, branch, chain to post-merge ───────────
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
  # a new MR was created after the first one was merged). Do NOT chain to
  # post-merge — the open MR is the active work. This prevents the catchup
  # from re-triggering post-merge/e2e on a reopened issue when an old
  # merged MR exists alongside the new open one.
  MR_OPEN_IID=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "opened")
  MR_OPEN_STATE=""
  if [ -n "$MR_OPEN_IID" ]; then
    # GitHub PR .state is "open"; GitLab MR .state is "opened".
    MR_OPEN_STATE=$(forge_mr_get "$MR_OPEN_IID" | jq -r '.state // empty' 2> /dev/null || echo "")
  fi
  if [ "$MR_OPEN_STATE" = "opened" ] || [ "$MR_OPEN_STATE" = "open" ]; then
    echo "Catchup: open MR exists for branch boucle/$BOUCLE_ISSUE — issue reopened for new iteration, skipping post-merge chain."
    exit 0
  fi

  # Post an audit comment (with hidden tag for idempotence/audit).
  # The MR IID isn't passed as a variable (dispatch only forwards
  # BOUCLE_ISSUE + BOUCLE_ROLE); reference the issue + branch instead.
  # The target recorded here is the terminal state the loop WOULD have
  # applied pre-#E2E-on-direct-merge; the actual terminal state is now
  # decided by the e2e verdict (PASS→done, FAIL/UNCERTAIN→human). We keep
  # the field for audit continuity with older catchup notes.
  AUDIT_BODY="<!-- boucle:catchup v=1 iid=$BOUCLE_ISSUE state=$CURRENT_BOUCLE target=$TARGET -->"$'\n'"🤖 Automatic catch-up — the $(forge_mr_term) on branch \`boucle/$BOUCLE_ISSUE\` was merged directly without going through the approval flow."$'\n\n'"Issue state at merge time: \`boucle:$CURRENT_BOUCLE\`."$'\n'"Chaining to post-merge for deploy + e2e verification — the terminal state will be decided by the e2e verdict."
  # The audit note is the only explanation for the transition — if it cannot
  # be posted, do NOT proceed: a transition with no note is a mute state
  # change. Abort BEFORE the label + chain, keeping the issue in its prior
  # state so the loop can retry.
  if ! forge_issue_note "$BOUCLE_ISSUE" "$AUDIT_BODY"; then
    echo "FAIL: catchup audit note could not be posted on issue #$BOUCLE_ISSUE — aborting the transition (no mute state change)." >&2
    exit 1
  fi

  # Set boucle:merging as a transitional label. The terminal label
  # (boucle:done / boucle:human) is applied by the e2e verdict routing
  # (lib/boucle-ci/e2e.sh) AFTER production verification. This means:
  #   - The doctor's boucle:merging scan covers direct merges too (a
  #     stuck post-merge/e2e is recovered like any stuck merger).
  #   - The board shows the issue as "merging" while e2e runs — an
  #     honest signal that the loop is verifying the merge.
  # The pre-e2e target (done/human) is NOT applied here; it was a guess
  # based on the issue state at merge time, and e2e is the authority.
  set_boucle_label "$BOUCLE_ISSUE" "boucle:merging" "boucle::status::bot"
  # Refresh the board — the issue moved to merging (lesson #97: refresh
  # on transition, not only on doctor sweep).
  boucle_board_upsert || true

  # Post-merge branch cleanup: delete the worker branch. Best-effort — a
  # failed deletion logs a warning but does not fail the job. lesson #68.
  # Done BEFORE chaining to post-merge so a stale branch never blocks the
  # deploy-wait. The merged commit is already on the default branch.
  local branch
  branch=$(boucle_branch_name "$BOUCLE_ISSUE")
  if ! forge_branch_delete "$branch"; then
    echo "WARN: could not delete branch $branch after catchup (stale but harmless)" >&2
  else
    echo "Deleted worker branch $branch after catchup"
  fi

  # Chain to post-merge (deploy-wait + e2e trigger). post-merge resolves
  # the live URL (self mode: wait for deploy pipeline; external mode: wait
  # for consumer's check suites) and chains to e2e with BOUCLE_ISSUE set.
  # e2e's verdict routing then applies the terminal label, closes the
  # issue, cascades the parent, and unblocks dependents — the same path
  # as an approved merge through the merger job.
  echo "Catchup: chaining to post-merge for issue #$BOUCLE_ISSUE (was boucle:$CURRENT_BOUCLE)"
  chain_to_role "$BOUCLE_ISSUE" "post-merge"
}
