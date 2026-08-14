#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250,SC2116
# lib/boucle-ci/e2e.sh — e2e stage: verify the deployment against the live
# (production) URL.
#
# Extracted from the .gitlab-ci.yml e2e job (script block only).
# Sourced by lib/boucle-ci.sh, which provides the forge_* layer
# (bin/forge/common.sh contract) and the lib/boucle.sh helpers
# (set_boucle_label, close_issue, maybe_close_parent, get_work_item_children,
# chain_to_role, ...).
#
# Environment (see lib/boucle-ci.sh):
#   BOUCLE_ISSUE          — issue IID (empty for deploy-triggered smoke test)
#   BOUCLE_LIVE_URL       — deployment URL (falls back to BOUCLE_PRODUCTION_URL)
#   BOUCLE_PROJECT_ID     — forge project identifier
#   BOUCLE_FORGE_HOST     — forge API host
#   BOUCLE_DEFAULT_BRANCH — default branch
#   BOUCLE_WORKSPACE      — checkout directory (agent-output.log lives under it)
#   BOUCLE_HOME           — boucle installation root
#
# Verdict contract: the agent posts `<!-- boucle:verdict v=1 role=e2e -->`
# + a `VERDICT: PASS|FAIL|UNCERTAIN` line on the issue. CI parses it from
# issue notes, with a log-scraping fallback (AGENTS.md lessons #41, #43, #47).

boucle_ci_e2e() {
  # Shared gate functions (check_sibling_gate, maybe_unblock_dependents) —
  # single source of truth in lib/boucle-ci/gates.sh.
  source "$BOUCLE_HOME/lib/boucle-ci/gates.sh"
  # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script
  # under set -eo pipefail. Without pipefail, the var is just empty (which
  # we handle).
  set +o pipefail
  export BOUCLE_ISSUE="${BOUCLE_ISSUE:-}"
  # Use deployment URL passed from deploy job (production domain may not have DNS yet)
  LIVE_URL="${BOUCLE_LIVE_URL:-$BOUCLE_PRODUCTION_URL}"
  export BOUCLE_LIVE_URL="$LIVE_URL"
  echo "E2E testing URL: $LIVE_URL"

  # Source the depends-on lib for parse_depends_on.
  source "$BOUCLE_HOME/bin/lib/depends-on.sh"

  # Check if a pipeline with BOUCLE_ISSUE=$iid is already running.
  # Used by maybe_unblock_dependents to prevent double-trigger.
  issue_has_active_pipeline() {
    local iid="$1"
    local active
    # forge_pipeline_list_active filters runs by BOUCLE_ISSUE=$iid; each
    # forge backend decides which statuses count as "active" (GitLab:
    # running; GitHub: in_progress). Mirrors the multi-status loop that
    # the GitLab e2e job used to inline.
    active=$(forge_pipeline_list_active "$iid" 2> /dev/null || echo "[]")
    echo "$active" | jq -e 'length > 0' > /dev/null 2>&1
  }

  # Deploy-triggered e2e: no issue context. Run a deterministic HTTP smoke test.
  if [ -z "${BOUCLE_ISSUE:-}" ]; then
    echo "Deploy-triggered e2e — no issue context. Running HTTP smoke test."
    HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "$BOUCLE_LIVE_URL")
    if [ "$HTTP_CODE" = "200" ]; then
      echo "E2E smoke test PASS — $BOUCLE_LIVE_URL returns 200"
      exit 0
    else
      echo "E2E smoke test FAIL — $BOUCLE_LIVE_URL returns $HTTP_CODE" >&2
      exit 1
    fi
  fi

  # Run the agent on the live URL.
  # Tolerate non-zero exit: the agent may post a valid verdict (PASS/FAIL)
  # yet exit non-zero (e.g. jcode cleanup, forge CLI "new version" warning on
  # stderr). We verify the verdict from the issue comment below, so the
  # agent exit code is not authoritative.
  # Capture the highest e2e verdict note ID that existed BEFORE this run,
  # so we can collapse duplicate v2 verdicts below.
  PRE_RUN_VERDICT_ID=$(forge_issue_notes "$BOUCLE_ISSUE" \
    | jq -r '[.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=e2e")) | .id] | max // 0' 2> /dev/null || echo 0)
  echo "PRE_RUN_VERDICT_ID=$PRE_RUN_VERDICT_ID"

  "$BOUCLE_HOME"/bin/jc e2e || true

  # Disable errexit for the post-agent section: the verdict parsing and
  # label/close calls below are all best-effort. GitLab Runner runs - |
  # blocks with `set -eo pipefail`, so a non-zero from grep (no match),
  # a forge API error, or jq (bad JSON) would kill the script before the
  # case statement can route to PASS/FAIL/UNCERTAIN. We handle errors
  # explicitly per-command instead.
  set +e
  # Parse verdict from agent output (bin/jc logs to stdout)
  # If BOUCLE_ISSUE is set, parse from issue comment; otherwise from agent stdout.
  # Tolerate forge CLI / jq non-zero exit (the CLI may warn about version updates on
  # stderr; jq may error on unexpected JSON). An empty COMMENT → empty VERDICT
  # → UNCERTAIN branch, which is safe.
  COMMENT=$(forge_issue_notes "$BOUCLE_ISSUE" 2> /dev/null \
    | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=e2e"))] | first | .body // empty' 2> /dev/null)
  # Reject a foreign-SHA verdict: a marker whose sha exists but differs from
  # the e2e head is not this run's verdict (AGENTS.md P4). Accept only when
  # the marker carries no sha at all (malformed marker tolerance).
  MR_HEAD_SHORT="${MR_HEAD:0:7}"
  FOUND_SHA=$(printf '%s' "$COMMENT" | grep -oE 'sha=[a-f0-9]+' | head -1 | cut -d= -f2 || true)
  if [ -n "$FOUND_SHA" ] && [ -n "$MR_HEAD_SHORT" ] && [ "$FOUND_SHA" != "$MR_HEAD_SHORT" ]; then
    echo "[boucle] REJECTED foreign-SHA e2e verdict: marker sha=$FOUND_SHA != head $MR_HEAD_SHORT. Not accepting."
    COMMENT=""
  fi
  VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)

  # ── Log-scraping fallback (step-limit recovery) ──────────────────
  # If the agent drafted a verdict but ran out of steps before posting it
  # (VERDICT empty), scrape the drafted verdict from the agent's stdout log
  # and post it ourselves. Mirrors the reviewer job's fallback.
  # All marker patterns are anchored to start-of-line (AGENTS.md lesson
  # #47) so prose that merely quotes the marker is never matched.
  if [ -z "$VERDICT" ]; then
    AGENT_LOG="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/agent-output.log"
    if [ -f "$AGENT_LOG" ]; then
      DRAFTED_VERDICT=$(awk '
                /^<!-- boucle:verdict v=1 role=e2e/ { found=1 }
                found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
            ' "$AGENT_LOG" 2> /dev/null || echo "")
      # If no boucle:verdict found, try the boucle:draft marker (first-pass
      # draft posted early per the post-early rule). Promote it to a
      # verdict by replacing the draft marker with the verdict marker.
      if [ -z "$DRAFTED_VERDICT" ]; then
        DRAFTED_VERDICT=$(awk '
                    /^<!-- boucle:draft role=e2e -->/ { found=1 }
                    found { print; if ($0 ~ /^VERDICT: (PASS|FAIL|UNCERTAIN)/) { exit } }
                ' "$AGENT_LOG" 2> /dev/null || echo "")
        if [ -n "$DRAFTED_VERDICT" ]; then
          echo "[boucle] WARN: no boucle:verdict in log — promoting boucle:draft to verdict (step-limit fallback)."
          DRAFTED_VERDICT=$(printf '%s' "$DRAFTED_VERDICT" | sed "s|<!-- boucle:draft role=e2e -->|<!-- boucle:verdict v=1 role=e2e sha=$MR_HEAD -->|")
          # If the promoted draft has no VERDICT line, default to UNCERTAIN
          # (the agent posted a draft checklist but ran out of steps before
          # posting a final verdict with a VERDICT: line).
          if ! echo "$DRAFTED_VERDICT" | grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'; then
            DRAFTED_VERDICT="$(printf '%s\n\nVERDICT: UNCERTAIN\n' "$DRAFTED_VERDICT")"
            echo "[boucle] WARN: promoted e2e draft had no VERDICT line — defaulting to UNCERTAIN."
          fi
        fi
      fi
      if [ -n "$DRAFTED_VERDICT" ] && echo "$DRAFTED_VERDICT" | grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'; then
        echo "[boucle] Recovering drafted e2e verdict from agent log (step-limit fallback)."
        DRAFTED_VERDICT=$(echo "$DRAFTED_VERDICT" | sed '/^```$/d')
        forge_issue_note "$BOUCLE_ISSUE" "$DRAFTED_VERDICT"
        COMMENT=$(forge_issue_notes "$BOUCLE_ISSUE" 2> /dev/null \
          | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=e2e"))] | first | .body // empty' 2> /dev/null)
        # Reject a foreign-SHA re-fetch: a marker whose sha exists but differs
        # from the e2e head is not this run's verdict (AGENTS.md P4).
        NEW_FOUND_SHA=$(printf '%s' "$COMMENT" | grep -oE 'sha=[a-f0-9]+' | head -1 | cut -d= -f2 || true)
        if [ -n "$NEW_FOUND_SHA" ] && [ -n "$MR_HEAD_SHORT" ] && [ "$NEW_FOUND_SHA" != "$MR_HEAD_SHORT" ]; then
          echo "[boucle] REJECTED foreign-SHA e2e re-fetch: marker sha=$NEW_FOUND_SHA != head $MR_HEAD_SHORT. Not adopting."
          COMMENT=""
        fi
        VERDICT=$(echo "$COMMENT" | grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
        if [ -n "$VERDICT" ]; then
          echo "[boucle] Step-limit fallback succeeded: recovered e2e verdict=$VERDICT."
        else
          echo "[boucle] Step-limit fallback failed: drafted verdict had no parsable VERDICT line."
        fi
      fi
    fi
  fi

  # Collapse duplicate e2e verdicts: replace the draft in place (PUT the
  # final verdict body onto the draft's note id so the #note_<id> anchor stays
  # stable) and delete redundant copies. Agent may post a v2; CI replaces the first.
  "$BOUCLE_HOME"/bin/collapse-duplicate-notes e2e "$BOUCLE_PROJECT_ID" "$BOUCLE_ISSUE" "$PRE_RUN_VERDICT_ID" "$BOUCLE_FORGE_HOST"

  case "$VERDICT" in
    PASS)
      # Post a deploy-success note on the issue BEFORE the terminal label so
      # the human sees the production URL. Lesson #59: note FIRST, label
      # SECOND — if the note cannot be posted, abort WITHOUT the label/close
      # so the issue stays in a retryable state (no mute state change).
      # forge_issue_note auto-stamps the <!-- boucle:agent --> marker.
      # shfmt off  # preserve exact string content
      DEPLOY_NOTE_BODY="✅ Successfully deployed to production.

## Production URL
$LIVE_URL

## Commit
${CI_COMMIT_SHA:-${MR_HEAD_SHORT:-unknown}}"
      # shfmt on
      if ! forge_issue_note "$BOUCLE_ISSUE" "$DEPLOY_NOTE_BODY"; then
        echo "FAIL: could not post deploy-success note on issue #$BOUCLE_ISSUE — aborting transition (no mute state change)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
      # boucle:done is a board label, not a close state — close the issue too
      close_issue "$BOUCLE_ISSUE"
      # If this issue is a sub-issue, check whether all siblings are closed
      # and close the parent when the last sub-issue completes.
      maybe_close_parent "$BOUCLE_ISSUE" "$LIVE_URL"
      # Unblock dependents: if this sub-issue was a dependency of a sibling,
      # check whether that sibling's deps are now all closed and trigger it.
      maybe_unblock_dependents "$BOUCLE_ISSUE"
      ;;
    FAIL)
      # Loop closure: open a new issue in triage with the trace.
      # Title includes the original issue title so the new issue is
      # identifiable in the board without opening it.
      E2E_ORIG_DATA=$(forge_issue_get "$BOUCLE_ISSUE" 2> /dev/null || true)
      E2E_ORIG_TITLE=$(printf '%s' "$E2E_ORIG_DATA" | jq -r '.title // empty' | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-60 | sed 's/ [^ ]*$//')
      # Inherit the parent linkage from the original issue so the follow-up
      # resolves to the same human author via resolve_reporter_id (which
      # walks one level up: issue → parent → parent.author.id). Without this,
      # the follow-up's author is the bot and the reviewer PASS branch
      # assigns the MR to the bot instead of the human.
      # Top-level issues have no parent to inherit: the follow-up ALWAYS
      # carries a QUALIFIED origin section (`<!-- boucle:e2e-origin v=1 iid=N -->`)
      # so resolve_reporter_id can still find the original human reporter
      # (consumer regression: MR assigned to up-bot after reviewer PASS).
      E2E_PARENT_IID=$(printf '%s' "$E2E_ORIG_DATA" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
      # shfmt off  # preserve exact string content (matches the original YAML block-scalar value)
      E2E_PARENT_SECTION=""

      ## Parent issue
      #$E2E_PARENT_IID"
      # shfmt on
      E2E_NEW_TITLE="fix: ${E2E_ORIG_TITLE:-issue} — E2E failure (#$BOUCLE_ISSUE)"
      # shfmt off  # preserve exact string content (matches the original YAML block-scalar value)
      E2E_NEW_DESC="E2E verification failed for issue #$BOUCLE_ISSUE.

## Origin — E2E regression
<!-- boucle:e2e-origin v=1 iid=$BOUCLE_ISSUE -->
Follow-up of #$BOUCLE_ISSUE: production E2E verification failed after its MR was merged (see Trace below). This is a qualified follow-up link — NOT a parent/child relationship.

## Trace
$(echo "$COMMENT")

## Live URL
$LIVE_URL${E2E_PARENT_SECTION}"
      # shfmt on
      # forge_issue_create returns the new issue IID on stdout (empty on failure).
      E2E_NEW_IID=$(forge_issue_create "$E2E_NEW_TITLE" "$E2E_NEW_DESC" "boucle:triage,boucle::status::bot")
      # Assign the new follow-up issue to the bot (it's on the bot side).
      if [ -n "$E2E_NEW_IID" ] && [ "$E2E_NEW_IID" != "null" ] && [ -n "${BOUCLE_BOT_ID:-}" ]; then
        # forge_issue_assign is best-effort; surface failure loudly
        # (mirrors the original curl || exit 1 guard).
        if ! forge_issue_assign "$E2E_NEW_IID" "$BOUCLE_BOT_ID"; then
          echo "ERROR: bot reassign failed for issue (BOUCLE_BOT_ID=$BOUCLE_BOT_ID set but forge call failed)" >&2
          exit 1
        fi
      fi
      # Close the original issue: work is transferred to the follow-up.
      # Post a link comment so the human can trace from #29 → #32, then
      # close #29 and cascade the parent (mirrors PASS branch behavior).
      # shfmt off  # preserve exact string content (matches the original YAML block-scalar value)
      E2E_LINK_BODY="<!-- boucle:e2e-fail v=1 iid=$BOUCLE_ISSUE followup=$E2E_NEW_IID -->
E2E verification FAILED. A follow-up issue #$E2E_NEW_IID has been opened in triage to fix the defect.

## Live URL
${BOUCLE_LIVE_URL:-unknown}

## E2E trace
\`\`\`
$(printf '%s' "${COMMENT:-}" | head -c 4000)
\`\`\`

Closing this issue — work continues in #$E2E_NEW_IID."
      # shfmt on
      forge_issue_note "$BOUCLE_ISSUE" "$E2E_LINK_BODY"
      set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
      close_issue "$BOUCLE_ISSUE"
      maybe_close_parent "$BOUCLE_ISSUE"
      maybe_unblock_dependents "$BOUCLE_ISSUE"
      ;;
    UNCERTAIN)
      # Genuinely UNCERTAIN verdict (agent posted VERDICT: UNCERTAIN).
      # NOT a catch-all for empty VERDICT — see reviewer job + AGENTS.md
      # lesson #43. Empty VERDICT is handled by the post-case assertion
      # below (re-trigger e2e or escalate to human).
      # Post a human-facing explanation so the human knows why the issue
      # landed at boucle:human. Without this, the human sees only the label
      # change with no context. Note BEFORE the terminal label — never a
      # muted boucle:human.
      E2E_TRACE=$(printf '%s' "${COMMENT:-}" | head -c 4000)
      # shfmt off  # preserve exact string content (matches the original YAML block-scalar value)
      E2E_ESCALATION_BODY="<!-- boucle:e2e-escalation v=1 iid=$BOUCLE_ISSUE verdict=uncertain -->
E2E verification could not reach a confident verdict. Human review needed.

## Live URL
${BOUCLE_LIVE_URL:-unknown}

## Agent trace (truncated)
\`\`\`
${E2E_TRACE:-no verdict comment was posted by the agent}
\`\`\`"
      # shfmt on
      if ! forge_issue_note "$BOUCLE_ISSUE" "$E2E_ESCALATION_BODY"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      ;;
  esac

  if [ -z "$VERDICT" ]; then
    # Post a human-facing explanation before failing the job. The agent
    # ran but posted no parsable verdict (step limit, crash, or empty
    # output). Without this comment the human sees only a failed pipeline.
    ITERATION="${BOUCLE_ITERATION:-1}"
    MAX_ITER="${BOUCLE_MAX_ITERATIONS:-5}"
    E2E_LOG_TAIL=""
    AGENT_LOG="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/agent-output.log"
    if [ -f "$AGENT_LOG" ]; then
      E2E_LOG_TAIL=$(tail -c 4000 "$AGENT_LOG" 2> /dev/null || echo "")
    fi
    if [ "$ITERATION" -lt "$MAX_ITER" ]; then
      echo "Re-triggering e2e (iteration $((ITERATION + 1))/$MAX_ITER)."
      chain_to_role "$BOUCLE_ISSUE" "e2e" BOUCLE_ITERATION=$((ITERATION + 1))
    else
      # Note BEFORE the terminal label — never a muted boucle:human.
      # shfmt off  # preserve exact string content (matches the original YAML block-scalar value)
      E2E_ESCALATION_BODY="<!-- boucle:e2e-escalation v=1 iid=$BOUCLE_ISSUE verdict=empty -->
E2E agent did not post a parsable verdict after $MAX_ITER attempts. Human review needed.

The agent ran against \`${BOUCLE_LIVE_URL:-the live URL}\` but exited without posting a \`VERDICT:\` comment. This usually means it hit the step limit or crashed before completing.

## Live URL
${BOUCLE_LIVE_URL:-unknown}

## Agent log tail (last 4000 chars)
\`\`\`
${E2E_LOG_TAIL:-no agent log was captured}
\`\`\`"
      # shfmt on
      if ! forge_issue_note "$BOUCLE_ISSUE" "$E2E_ESCALATION_BODY"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    fi
    echo "FAIL: e2e verdict not parsable" >&2
    exit 1
  fi
}
