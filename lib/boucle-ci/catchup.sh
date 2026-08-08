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
    # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script
    # under set -eo pipefail. Without pipefail, the var is just empty (which
    # we handle).
    set +o pipefail
    export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

    # ── Local helpers ──────────────────────────────────────────────────────
    # close_issue / get_work_item_children / maybe_close_parent /
    # set_boucle_label / chain_to_role come from lib/boucle.sh (sourced by
    # the lib/boucle-ci.sh bootstrap) — the local copies that used to live
    # here are removed. issue_has_active_pipeline and
    # maybe_unblock_dependents are NOT in lib/boucle.sh yet, so they stay
    # local.

    # Check if a pipeline with BOUCLE_ISSUE=$iid is already active.
    # Used by maybe_unblock_dependents to prevent double-trigger.
    # Delegates to forge_pipeline_list_active (lesson #33: match pipelines
    # to the issue via the BOUCLE_ISSUE variable, not updated_at).
    issue_has_active_pipeline() {
        local iid="$1" pipelines
        pipelines=$(forge_pipeline_list_active "$iid") || return 1
        echo "$pipelines" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
    }

    # Source the depends-on lib for parse_depends_on.
    source "$BOUCLE_HOME/bin/lib/depends-on.sh"

    # When a sub-issue closes, check whether any sibling sub-issues were
    # blocked waiting on it. For each blocked sibling whose deps are NOW all
    # closed, flip boucle:blocked → boucle:todo and trigger the worker.
    # Symmetric to maybe_close_parent (lesson #49 — unblock via a symmetric
    # maybe_unblock_dependents(), NOT via the doctor's capacity scan).
    maybe_unblock_dependents() {
        local closed_iid="$1"
        local closed_data parent_iid
        closed_data=$(forge_issue_get "$closed_iid") || {
            echo "maybe_unblock_dependents: can't fetch #$closed_iid — skipping."
            return 0
        }
        parent_iid=$(echo "$closed_data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
        if [ -z "$parent_iid" ]; then
            return 0 # not a sub-issue → no dependents
        fi
        # Find siblings via the same 3-tier fallback as maybe_close_parent.
        local children_data sibling_iids
        children_data=$(get_work_item_children "$parent_iid")
        sibling_iids=$(echo "$children_data" | jq -r '[.[].iid] | join(",")' 2>/dev/null)
        if [ -z "$sibling_iids" ]; then
            local parent_notes
            parent_notes=$(forge_issue_notes "$parent_iid") || return 0
            sibling_iids=$(echo "$parent_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
            if [ -z "$sibling_iids" ]; then
                # TODO: forge_* — no contract for listing issue links yet.
                local links_data
                links_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$parent_iid/links" 2>/dev/null) || links_data="[]"
                sibling_iids=$(echo "$links_data" | jq -r '[.[] | select(.iid != null) | .iid] | join(",")')
                [ -z "$sibling_iids" ] && return 0
            fi
        fi
        # For each sibling, check if it's boucle:blocked AND its deps include
        # the just-closed IID AND all its deps are now closed.
        local sib_iid sib_data sib_labels sib_desc sib_deps all_closed dep_iid dep_state
        for sib_iid in $(echo "$sibling_iids" | tr ',' ' '); do
            [ "$sib_iid" = "$closed_iid" ] && continue
            sib_data=$(forge_issue_get "$sib_iid") || continue
            sib_labels=$(echo "$sib_data" | jq -r '.labels | join(",")' 2>/dev/null)
            echo "$sib_labels" | grep -q "boucle:blocked" || continue
            sib_desc=$(echo "$sib_data" | jq -r '.description // empty' 2>/dev/null)
            sib_deps=$(parse_depends_on "$sib_desc")
            [ -z "$sib_deps" ] && continue
            # Does this sibling depend on the just-closed IID?
            echo ",$sib_deps," | grep -q ",$closed_iid," || continue
            # Are ALL deps now closed?
            all_closed=true
            for dep_iid in $(echo "$sib_deps" | tr ',' ' '); do
                dep_state=$(forge_issue_get "$dep_iid" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
                if [ "$dep_state" != "closed" ]; then
                    all_closed=false
                    break
                fi
            done
            if [ "$all_closed" = "true" ]; then
                echo "maybe_unblock_dependents: #$sib_iid deps all closed — unblocking"
                set_boucle_label "$sib_iid" "boucle:todo" "boucle::status::bot"
                local unblock_body
                unblock_body=$(printf '✅ Dependencies satisfied — worker starting.\n\n<!-- boucle:unblocked v=1 by=%s -->' "$closed_iid")
                forge_issue_note "$sib_iid" "$unblock_body"
                if ! issue_has_active_pipeline "$sib_iid"; then
                    chain_to_role "$sib_iid" "worker"
                fi
            fi
        done
    }

    # ── Main: inspect issue state, branch, close, cascade ──────────────────
    # Disable errexit for the main flow: grep (no match) / glab (transient
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
    ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels | join(",")')

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
        set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
        TARGET="done"
        ;;
    triage | needs-info | spec-review | todo | working | review | merging)
        # Merged before the loop finished its review. Honest signal: the
        # bot did not validate completion → mark human. Still close +
        # cascade so the issue doesn't stay stuck.
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
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
    # TODO: forge_* — no contract for listing MRs by source branch yet.
    MR_OPEN_STATE=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests?source_branch=boucle/$BOUCLE_ISSUE&state=opened" 2>/dev/null |
        jq -r '.[0].state // empty')
    if [ "$MR_OPEN_STATE" = "opened" ]; then
        echo "Catchup: open MR exists for branch boucle/$BOUCLE_ISSUE — issue reopened for new iteration, skipping close."
        exit 0
    fi

    # Post an audit comment (with hidden tag for idempotence/audit).
    # The MR IID isn't passed as a variable (dispatch only forwards
    # BOUCLE_ISSUE + BOUCLE_ROLE); reference the issue + branch instead.
    AUDIT_BODY="<!-- boucle:catchup v=1 iid=$BOUCLE_ISSUE state=$CURRENT_BOUCLE target=$TARGET -->"$'\n'"🤖 Rattrapage automatique — la MR sur la branche \`boucle/$BOUCLE_ISSUE\` a été fusionnée directement sans passer par le circuit d'approbation."$'\n\n'"État de l'issue au moment de la fusion : \`boucle:$CURRENT_BOUCLE\`."$'\n'"Issue marquée \`boucle:$TARGET\` et fermée."
    forge_issue_note "$BOUCLE_ISSUE" "$AUDIT_BODY"

    # Close the issue (boucle:done is a board label, not a close state).
    close_issue "$BOUCLE_ISSUE"
    echo "Catchup: closed issue #$BOUCLE_ISSUE"

    # Cascade: if this is a sub-issue, close the parent when all siblings are closed.
    maybe_close_parent "$BOUCLE_ISSUE"
    # Unblock dependents: if this sub-issue was a dependency of a sibling,
    # check whether that sibling's deps are now all closed and trigger it.
    maybe_unblock_dependents "$BOUCLE_ISSUE"
}
