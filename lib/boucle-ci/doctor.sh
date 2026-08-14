#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle-ci/doctor.sh — doctor stage: scheduled health check and recovery.
#
# Runs on a schedule (every 10 min). Detects orphaned triages: issues with
# boucle:needs-info that have a human reply after the last triage comment.
# Re-triggers triage for them. Also detects stuck boucle:triage issues with
# no active pipeline (canceled before dispatch ran). Recovers stuck
# boucle:working / boucle:review, orphaned boucle:blocked, deferred
# boucle:todo, zombie issues (closed but still working/review), approved-MR
# recovery (boucle:human / boucle:approval), and the split-parent cascade.
#
# Extracted from the .gitlab-ci.yml doctor job (lines 4006-4632).

boucle_ci_doctor() {
  # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script
  # under set -eo pipefail. Without pipefail, the var is just empty (which
  # we handle).
  set +o pipefail
  RECOVERED=0
  # Emoji reactions that count as spec approval — canonical set only.
  # The forge backends normalize via forge_reaction_canonical, so only
  # "thumbsup" can appear here.
  # Must mirror the dispatch job's constant — each CI job runs its own shell.
  BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup heart rocket tada"
  source "$BOUCLE_HOME/bin/lib/depends-on.sh" 2> /dev/null || true
  # Shared gate functions (check_sibling_gate, check_file_gate,
  # maybe_unblock_dependents) — single source of truth in lib/boucle-ci/gates.sh.
  source "$BOUCLE_HOME/lib/boucle-ci/gates.sh" 2> /dev/null || true

  # ── Adaptive cadence (#38) ─────────────────────────────────────────────
  # The doctor runs on a fixed schedule and always performs the full sweep.
  # On an idle repository that is a runner provisioned to confirm nothing
  # changed. This adds a cheap MONITOR pass: fingerprint the board, and when
  # nothing has moved since the last pass, skip the sweep.
  #
  # A backstop forces a full sweep every BOUCLE_DOCTOR_BACKSTOP regardless,
  # so a fingerprint that goes stale for the wrong reason cannot strand the
  # board forever.
  #
  # Persistence is the state cache, which survives on a shell-executor
  # runner. On an ephemeral runner (GitHub-hosted) the snapshot is never
  # found, so every run is a full sweep — the old behaviour exactly. No
  # regression, no saving. That is a deliberate degradation, not a bug.
  DOCTOR_STATE_DIR="${BOUCLE_STATE_CACHE:-${HOME}/.boucle-state-cache}/doctor"
  DOCTOR_FINGERPRINT_FILE="$DOCTOR_STATE_DIR/board-fingerprint"
  DOCTOR_SWEEP_STAMP="$DOCTOR_STATE_DIR/last-full-sweep"

  # Fingerprint = every boucle-labelled open issue and when it last moved.
  # Cheaper than the sweep: no per-issue pipeline checks, no note fetches.
  doctor_board_fingerprint() {
    local label out=""
    for label in boucle:triage boucle:working boucle:review boucle:todo \
      boucle:blocked boucle:human boucle:approval boucle:spec-review \
      boucle:needs-info boucle:split; do
      out="${out}$(forge_issue_list_by_label "$label" opened 2> /dev/null \
        | jq -r --arg l "$label" '.[] | "\($l):\(.iid // .number):\(.updated_at // "")"' 2> /dev/null || true)
"
    done
    printf '%s' "$out" | sort | cksum | awk '{ print $1 }'
  }

  DOCTOR_PASS="sweep"
  if [ "${BOUCLE_DOCTOR_ADAPTIVE:-true}" = "true" ]; then
    CURRENT_FINGERPRINT=$(doctor_board_fingerprint 2> /dev/null || echo "")
    BACKSTOP="${BOUCLE_DOCTOR_BACKSTOP:-21600}"
    case "$BACKSTOP" in
      '' | *[!0-9]*) BACKSTOP=21600 ;;
    esac
    SWEEP_AGE=999999
    if [ -f "$DOCTOR_SWEEP_STAMP" ]; then
      SWEEP_AGE=$(($(date +%s) - $(stat -c %Y "$DOCTOR_SWEEP_STAMP" 2> /dev/null || echo 0)))
    fi
    # An empty fingerprint means the listing failed. Degrade to a full
    # sweep — the doctor exists to unstick things, so a probe that cannot
    # see the board must never be the reason it stops.
    if [ -n "$CURRENT_FINGERPRINT" ] \
      && [ -f "$DOCTOR_FINGERPRINT_FILE" ] \
      && [ "$CURRENT_FINGERPRINT" = "$(cat "$DOCTOR_FINGERPRINT_FILE" 2> /dev/null || echo "")" ] \
      && [ "$SWEEP_AGE" -lt "$BACKSTOP" ]; then
      DOCTOR_PASS="monitor"
    fi
    if [ "$DOCTOR_PASS" = "monitor" ]; then
      echo "Doctor monitor pass — board unchanged since the last check (last full sweep ${SWEEP_AGE}s ago, backstop ${BACKSTOP}s). Nothing to sweep."
      return 0
    fi
    mkdir -p "$DOCTOR_STATE_DIR" 2> /dev/null || true
    [ -n "$CURRENT_FINGERPRINT" ] && echo "$CURRENT_FINGERPRINT" > "$DOCTOR_FINGERPRINT_FILE" 2> /dev/null || true
    touch "$DOCTOR_SWEEP_STAMP" 2> /dev/null || true
  fi

  # Idle boards get a longer staleness threshold: re-triggering costs a
  # runner, and nothing is in flight to be stuck. The busy value is
  # unchanged and must keep exceeding the max job timeout.
  if [ "${BOUCLE_DOCTOR_ADAPTIVE:-true}" = "true" ]; then
    IN_FLIGHT=$(forge_issue_count_by_label "boucle:working" opened 2> /dev/null || echo 1)
    case "$IN_FLIGHT" in
      '' | *[!0-9]*) IN_FLIGHT=1 ;;
    esac
    if [ "$IN_FLIGHT" -eq 0 ]; then
      IDLE_FACTOR="${BOUCLE_STALENESS_IDLE_FACTOR:-3}"
      case "$IDLE_FACTOR" in
        '' | *[!0-9]*) IDLE_FACTOR=3 ;;
      esac
      BOUCLE_STALENESS_THRESHOLD=$((${BOUCLE_STALENESS_THRESHOLD:-2400} * IDLE_FACTOR))
      export BOUCLE_STALENESS_THRESHOLD
      echo "Doctor: board idle — staleness threshold relaxed to ${BOUCLE_STALENESS_THRESHOLD}s"
    fi
  fi

  # ── Local helpers ──────────────────────────────────────────────────────
  # set_boucle_label / chain_to_role / close_issue / get_work_item_children
  # come from lib/boucle.sh (sourced by the lib/boucle-ci.sh bootstrap) —
  # the local copies that used to live here are removed.
  # issue_has_active_pipeline, doctor_should_skip_dedup and
  # doctor_mark_triggered are NOT in lib/boucle.sh, so they stay local.

  # Active-pipeline guard (lesson #33): a pipeline with BOUCLE_ISSUE=$iid
  # is already running/pending/created — skip re-trigger. Replaces the
  # unreliable updated_at proxy (bumped by any issue activity, not just
  # pipeline runs). Delegates to forge_pipeline_list_active which matches
  # pipelines to the issue via the BOUCLE_ISSUE variable — no false
  # positives.
  issue_has_active_pipeline() {
    local iid="$1" pipelines
    pipelines=$(forge_pipeline_list_active "$iid") || return 1
    echo "$pipelines" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1
  }

  # Doctor-side dedup: track the last time the doctor triggered each
  # issue in $BOUCLE_STATE_CACHE/doctor-triggers/<iid>. Skip re-trigger
  # if the doctor already triggered this issue within the STALENESS
  # window — prevents the same issue from being re-fired every 10 min
  # while waiting for a queued pipeline to start. The active-pipeline
  # check (issue_has_active_pipeline) is the primary guard; this is a
  # secondary backstop (lesson #33) for the case where a triggered
  # pipeline is still in `created`/`waiting_for_resource` but the
  # variables API hasn't caught up, or the pipeline was triggered but
  # hasn't yet registered.
  doctor_should_skip_dedup() {
    local iid="$1" now_epoch last_epoch delta
    local cache_dir="${BOUCLE_STATE_CACHE:-.boucle-state}/doctor-triggers"
    local stamp_file="$cache_dir/$iid"
    now_epoch=$(date +%s)
    if [ -f "$stamp_file" ]; then
      last_epoch=$(cat "$stamp_file" 2> /dev/null || echo 0)
      delta=$((now_epoch - last_epoch))
      local staleness="${BOUCLE_STALENESS_THRESHOLD:-2400}"
      if [ "$delta" -lt "$staleness" ]; then
        echo "  → #$iid: doctor already triggered ${delta}s ago (< ${staleness}s) — dedup skip"
        return 0
      fi
    fi
    return 1
  }
  doctor_mark_triggered() {
    local iid="$1"
    local cache_dir="${BOUCLE_STATE_CACHE:-.boucle-state}/doctor-triggers"
    mkdir -p "$cache_dir" 2> /dev/null || true
    date +%s > "$cache_dir/$iid" 2> /dev/null || true
  }

  # ── Recover orphaned boucle:needs-info issues ──────────────────────────
  # A human reply after the last triage comment means the reporter
  # answered the blocking questions. If the issue still has
  # boucle:needs-info, the triage pipeline was canceled/orphaned — re-trigger.
  # GitHub issues expose .number instead of .iid — extract either.
  NEEDS_INFO_ISSUES=$(forge_issue_list_by_label "boucle:needs-info" opened \
    | jq -r '.[] | .iid // .number')

  for IID in $NEEDS_INFO_ISSUES; do
    echo "Checking #$IID (boucle:needs-info)..."

    # Fetch notes for the issue (newest-first).
    NOTES=$(forge_issue_notes "$IID")

    # Find the last triage comment (has <!-- boucle:triage marker).
    LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .id // 0')

    # Find the last human (non-bot) note after the triage comment.
    HUMAN_REPLY_AFTER_TRIAGE=$(echo "$NOTES" | jq -r --arg tid "$LAST_TRIAGE_NOTE_ID" --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '
          [.[] | select(.author.username != $bname) | select(.id > ($tid | tonumber))]
          | length
        ')

    if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ]; then
      echo "  → #$IID has a human reply after last triage comment — orphaned triage detected"
      # Active-pipeline guard: skip if a pipeline for this issue is
      # already running/pending/created. Prevents the doctor from
      # firing duplicate triggers every 10 min while a previous one
      # is still queued in resource_group.
      if issue_has_active_pipeline "$IID"; then
        echo "  → #$IID: active pipeline already running — skipping re-trigger"
        continue
      fi
      if doctor_should_skip_dedup "$IID"; then
        continue
      fi
      # Re-trigger: set boucle:triage label (preserve non-boucle labels).
      set_boucle_label "$IID" "boucle:triage" "boucle::status::bot"
      # Trigger triage pipeline.
      chain_to_role "$IID" ""
      doctor_mark_triggered "$IID"
      echo "  → re-triggered triage for #$IID"
      RECOVERED=$((RECOVERED + 1))
    else
      echo "  → #$IID: no human reply after triage — still waiting for reporter"
    fi
  done

  # ── Recover orphaned boucle:spec-review issues ─────────────────────────
  # The author replied (any non-bot note after the last triage comment) but
  # the dispatch pipeline was canceled/orphaned before it could trigger the
  # worker. Issue still has boucle:spec-review (dispatch didn't run to
  # strip it). Worker relabels to boucle:working on start, which clears it.
  SPEC_REVIEW_ISSUES=$(forge_issue_list_by_label "boucle:spec-review" opened \
    | jq -r '.[] | .iid // .number')

  for IID in $SPEC_REVIEW_ISSUES; do
    echo "Checking #$IID (boucle:spec-review) for spec approval..."
    NOTES=$(forge_issue_notes "$IID")
    # Find the last triage comment (same as needs-info recovery above).
    LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .id // 0')
    # Detect any non-bot note after the last triage comment.
    HUMAN_REPLY_AFTER_TRIAGE=$(echo "$NOTES" | jq -r --arg tid "$LAST_TRIAGE_NOTE_ID" --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '
          [.[] | select(.author.username != $bname) | select(.id > ($tid | tonumber))]
          | length
        ')
    # Check for an approval emoji on the triage comment AND any standalone
    # spec-review note. The validation instructions are appended to the
    # triage comment itself (single message to read/approve), so the
    # "React with" lookup usually resolves to the same note as the triage
    # comment. The fallback path (triage note unresolved / PUT failed)
    # posts a standalone note — poll both to cover that case too.
    # Polls the award_emoji API — recovers even if the emoji webhook was
    # missed (emoji_events disabled or webhook delivery failed).
    SPEC_INVITE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("React with"))] | last | .id // 0')
    EMOJI_APPROVAL_FOUND=false
    for NOTE_ID in $LAST_TRIAGE_NOTE_ID $SPEC_INVITE_NOTE_ID; do
      [ "$NOTE_ID" = "0" ] || [ -z "$NOTE_ID" ] && continue
      # forge_note_reactions normalizes both backends to
      # {name, user.username} — the jq filter below works unchanged.
      AWARDS=$(forge_note_reactions issue "$IID" "$NOTE_ID")
      if echo "$AWARDS" | jq -e --arg emojis "$BOUCLE_SPEC_APPROVAL_EMOJIS" --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '
                [.[] | select(.user.username != $bname) | .name]
                | map(select(. as $n | ($emojis | split("|")) | index($n)))
                | length > 0
            ' > /dev/null 2>&1; then
        EMOJI_APPROVAL_FOUND=true
        break
      fi
    done
    if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ] || [ "$EMOJI_APPROVAL_FOUND" = true ]; then
      echo "  → #$IID approved (reply=$HUMAN_REPLY_AFTER_TRIAGE, emoji=$EMOJI_APPROVAL_FOUND) — re-triggering worker"
      if issue_has_active_pipeline "$IID"; then
        echo "  → #$IID: active pipeline already running — skipping re-trigger"
        continue
      fi
      if doctor_should_skip_dedup "$IID"; then
        continue
      fi
      # Dependency gate (lesson #49): a reply/approval on an issue whose body
      # declares a dependency on OPEN siblings must NOT start the worker —
      # park it at boucle:blocked until every dep closes. The webhook path
      # (dispatch) does this; the doctor must too, or a missed emoji/note
      # webhook starts premature work (framagit #56/#55, 2026-08).
      DEP_IIDS=$(parse_depends_on "$(forge_issue_get "$IID" | jq -r '.description // ""' 2> /dev/null)" 2> /dev/null)
      if [ -n "$DEP_IIDS" ]; then
        OPEN_DEPS=""
        while IFS= read -r D; do
          [ -z "$D" ] && continue
          DSTATE=$(forge_issue_get "$D" 2> /dev/null | jq -r '.state // "unknown"' 2> /dev/null)
          [ "$DSTATE" = "opened" ] && OPEN_DEPS="${OPEN_DEPS:+$OPEN_DEPS,}$D"
        done <<< "$(printf '%s' "$DEP_IIDS" | tr ',' '\n')"
        if [ -n "$OPEN_DEPS" ]; then
          echo "  → #$IID: dependency on open #$OPEN_DEPS — parking at boucle:blocked (no worker trigger)"
          set_boucle_label "$IID" "boucle:blocked" "boucle::status::bot"
          forge_issue_note "$IID" "⏳ Blocked on sibling sub-issue(s): #$OPEN_DEPS (declared in the issue body). The worker will start automatically once all of them are closed."
          continue
        fi
      fi
      set_boucle_label "$IID" "boucle:todo" "boucle::status::bot"
      # File-impact gate: a boucle:todo issue re-triggered by the doctor must
      # not start into a file conflict with an in-flight issue.
      if ! check_file_gate "$IID"; then
        echo "  → #$IID: file-gate blocked — skipping worker trigger"
        continue
      fi
      # Allow-list gate (safety net): the doctor must not start work on
      # an issue whose resolved human reporter is not in
      # BOUCLE_ALLOWED_USERS. Fail-open when the variable is unset.
      if ! check_allow_list_gate "$IID"; then
        echo "doctor: issue #$IID rejected by the allow list — skipping worker re-trigger"
        continue
      fi
      chain_to_role "$IID" "worker"
      doctor_mark_triggered "$IID"
      echo "  → re-triggered worker for #$IID"
      RECOVERED=$((RECOVERED + 1))
    else
      echo "  → #$IID: still waiting for author reply or approval emoji"
    fi
  done

  # ── Recover stuck boucle:triage issues ─────────────────────────────────
  # Triage label set but no active pipeline running for them — e.g. the
  # pipeline was canceled before dispatch ran. Re-trigger only if no triage
  # comment exists at all, or the last one is older than 15 min (triage may
  # still be in progress otherwise).
  TRIAGE_ISSUES=$(forge_issue_list_by_label "boucle:triage" opened \
    | jq -r '.[] | .iid // .number')

  for IID in $TRIAGE_ISSUES; do
    echo "Checking #$IID (boucle:triage) for stuck pipeline..."
    NOTES=$(forge_issue_notes "$IID")
    LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .id // 0')

    # If there's a recent triage comment (within last 15 min), skip —
    # triage may still be running.
    LAST_TRIAGE_TIME=$(echo "$NOTES" | jq -r --arg tid "$LAST_TRIAGE_NOTE_ID" '
          [.[] | select(.id == ($tid | tonumber))] | first | .created_at // empty
        ' 2> /dev/null)

    if [ -n "$LAST_TRIAGE_TIME" ]; then
      # Parse ISO timestamp and compare to now-15min.
      LAST_EPOCH=$(date -d "$LAST_TRIAGE_TIME" +%s 2> /dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      AGE=$((NOW_EPOCH - LAST_EPOCH))
      if [ "$AGE" -lt 900 ]; then
        echo "  → #$IID: last triage comment is ${AGE}s old (< 15 min) — still in progress, skipping"
        continue
      fi
    fi

    # No recent triage comment — re-trigger.
    echo "  → #$IID: boucle:triage with no recent triage comment — re-triggering"
    if issue_has_active_pipeline "$IID"; then
      echo "  → #$IID: active pipeline already running — skipping re-trigger"
      continue
    fi
    if doctor_should_skip_dedup "$IID"; then
      continue
    fi
    chain_to_role "$IID" ""
    doctor_mark_triggered "$IID"
    echo "  → re-triggered triage for #$IID"
    RECOVERED=$((RECOVERED + 1))
  done

  # ── Recover orphaned triages on UNLABELED open issues ──────────────────
  # Open issues with NO boucle label that have a triage comment AND a human
  # reply after it. Root cause: triage ran, asked NEEDS-INFO, the user
  # replied, but the issue never got a boucle:needs-info label (e.g. the
  # triage pipeline was interrupted before labeling). The label-based
  # recovery above can't see these issues — scan all unlabeled open issues.
  echo "Scanning open issues without boucle labels for orphaned triages..."
  # GitHub issue labels are objects (.name), GitLab labels are strings —
  # normalize in jq so the boucle:-prefix filter works on both backends.
  UNLABELED_ISSUES=$(forge_issue_list_all opened \
    | jq -r '[.[] | select(.labels | map(if type == "string" then . else .name end) | map(startswith("boucle:")) | any | not)] | .[] | .iid // .number')

  for IID in $UNLABELED_ISSUES; do
    echo "Checking #$IID (no boucle label) for orphaned triage..."
    NOTES=$(forge_issue_notes "$IID")

    # Does this issue have any triage comment at all?
    LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .id // 0')
    if [ "$LAST_TRIAGE_NOTE_ID" = "0" ]; then
      # No triage comment — this is a brand-new issue that was never
      # triaged. The dispatch job should pick it up on the next webhook.
      # Skip to avoid re-triaging issues that are mid-dispatch.
      continue
    fi

    # Is there a human reply after the last triage comment?
    HUMAN_REPLY_AFTER_TRIAGE=$(echo "$NOTES" | jq -r --arg tid "$LAST_TRIAGE_NOTE_ID" --arg bname "${BOUCLE_BOT_USERNAME:-up-bot}" '
          [.[] | select(.author.username != $bname) | select(.id > ($tid | tonumber))]
          | length
        ')
    if [ "$HUMAN_REPLY_AFTER_TRIAGE" -eq 0 ]; then
      echo "  → #$IID: triage comment exists but no human reply — still waiting"
      continue
    fi

    # Orphaned triage detected: triage ran, user replied, but no boucle
    # label was set. Re-trigger triage so the agent can re-read the user's
    # answers and route the issue correctly this time.
    echo "  → #$IID: orphaned triage (triage comment + human reply, no boucle label) — re-triggering"
    if issue_has_active_pipeline "$IID"; then
      echo "  → #$IID: active pipeline already running — skipping re-trigger"
      continue
    fi
    if doctor_should_skip_dedup "$IID"; then
      continue
    fi
    set_boucle_label "$IID" "boucle:triage" "boucle::status::bot"
    chain_to_role "$IID" ""
    doctor_mark_triggered "$IID"
    echo "  → re-triggered triage for #$IID"
    RECOVERED=$((RECOVERED + 1))
  done

  # ── Recover stuck boucle:working / boucle:review / boucle:blocked ──────
  # A worker/reviewer pipeline can be interrupted (runner crash, manual
  # cancel, force-push mid-run) leaving the issue stuck at boucle:working
  # or boucle:review with no active pipeline. The dispatch job does NOT
  # re-route these labels (it only handles triage/todo/needs-info/spec-
  # review), so without this recovery the issue hangs forever. Re-trigger
  # the appropriate role if the label has been stale (configurable via
  # BOUCLE_STALENESS_THRESHOLD, default 300s/5min) with no matching role
  # pipeline currently running.
  echo "Scanning for stuck boucle:working / boucle:review / boucle:blocked issues..."
  STUCK_WORKING=$(forge_issue_list_by_label "boucle:working" opened \
    | jq -r '.[] | .iid // .number')
  STUCK_REVIEW=$(forge_issue_list_by_label "boucle:review" opened \
    | jq -r '.[] | .iid // .number')

  # Stuck blocked issues: a blocked issue whose parent is closed is
  # orphaned — its deps (siblings) will never close. Close it + boucle:done.
  STUCK_BLOCKED=$(forge_issue_list_by_label "boucle:blocked" opened \
    | jq -r '.[] | .iid // .number')
  for IID in $STUCK_BLOCKED; do
    BLOCK_PARENT_IID=$(forge_issue_get "$IID" \
      | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    if [ -n "$BLOCK_PARENT_IID" ]; then
      PARENT_STATE=$(forge_issue_get "$BLOCK_PARENT_IID" | jq -r '.state // "unknown"')
      if [ "$PARENT_STATE" = "closed" ]; then
        echo "  → #$IID (boucle:blocked): parent #$BLOCK_PARENT_IID closed — closing orphaned sub-issue + boucle:done"
        set_boucle_label "$IID" "boucle:done" "boucle::status::done"
        close_issue "$IID"
        RECOVERED=$((RECOVERED + 1))
        continue
      fi
    fi
  done

  # ── Deferred todo recovery (worker slot freed) ─────────────────────────
  # Only applies when BOUCLE_MAX_PARALLEL_ISSUES is set (> 0).
  MAX_PARALLEL="${BOUCLE_MAX_PARALLEL_ISSUES:-0}"
  if [ "$MAX_PARALLEL" -gt 0 ] 2> /dev/null; then
    WORKING_COUNT=$(forge_issue_count_by_label "boucle:working" opened)
    if [ "$WORKING_COUNT" -lt "$MAX_PARALLEL" ]; then
      TODO_ISSUES=$(forge_issue_list_by_label "boucle:todo" opened | jq -r '.[] | .iid // .number')
      for IID in $TODO_ISSUES; do
        # Re-check working count each iteration (a previous trigger may have flipped it).
        WORKING_COUNT=$(forge_issue_count_by_label "boucle:working" opened)
        if [ "$WORKING_COUNT" -ge "$MAX_PARALLEL" ]; then
          echo "  → slots full again ($WORKING_COUNT/$MAX_PARALLEL) — stopping todo recovery"
          break
        fi
        echo "  → #$IID (boucle:todo): slot available ($WORKING_COUNT/$MAX_PARALLEL) — triggering worker"
        if issue_has_active_pipeline "$IID"; then
          echo "  → #$IID: active pipeline already running — skipping re-trigger"
          continue
        fi
        if doctor_should_skip_dedup "$IID"; then
          continue
        fi
        # File-impact gate: a boucle:todo issue re-triggered by the doctor's
        # capacity scan must not start into a file conflict with an in-flight
        # issue.
        if ! check_file_gate "$IID"; then
          echo "  → #$IID: file-gate blocked — skipping worker trigger"
          continue
        fi
        # Allow-list gate (safety net): the doctor must not start work on
        # an issue whose resolved human reporter is not in
        # BOUCLE_ALLOWED_USERS. Fail-open when the variable is unset.
        if ! check_allow_list_gate "$IID"; then
          echo "doctor: issue #$IID rejected by the allow list — skipping worker re-trigger"
          continue
        fi
        chain_to_role "$IID" "worker"
        doctor_mark_triggered "$IID"
        RECOVERED=$((RECOVERED + 1))
      done
    fi
  fi

  for IID in $STUCK_WORKING $STUCK_REVIEW; do
    # Determine which role to re-trigger based on the label.
    ISSUE_LABELS=$(forge_issue_get "$IID" | jq -r '.labels | map(if type == "string" then . else .name end) | join(",")')
    if echo "$ISSUE_LABELS" | grep -q "boucle:working"; then
      ROLE="worker"
    elif echo "$ISSUE_LABELS" | grep -q "boucle:review"; then
      ROLE="reviewer"
    else
      continue
    fi

    # Check if a MR for this issue was already merged (branch boucle/$IID).
    # If so, the issue should be closed + boucle:done, NOT re-triggered.
    # This happens when a human merged the MR manually (bypassing the
    # merger job), leaving the issue stuck at working/review forever.
    #
    # BUT: if there is also an OPEN MR with the same branch, the issue was
    # reopened for a new iteration (e.g. human requested changes after
    # approval, or a new MR was created after the first one was merged).
    # In that case, do NOT close — the open MR is the active work.
    # forge_mr_lookup_by_branch returns only the IID — fetch the full MR
    # via forge_mr_get for .state. GitHub has no state=merged filter (a
    # merged PR surfaces via state=closed + .merged=true), so normalize
    # .merged → "merged" here; on GitHub the closed-MR branch below still
    # recovers the issue (state=closed includes merged PRs).
    MR_MERGED_IID=$(forge_mr_lookup_by_branch "boucle/$IID" merged)
    MR_STATE=""
    if [ -n "$MR_MERGED_IID" ]; then
      MR_STATE=$(forge_mr_get "$MR_MERGED_IID" | jq -r 'if .merged == true then "merged" else .state // empty end')
    fi
    if [ "$MR_STATE" = "merged" ]; then
      MR_OPEN_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
      MR_OPEN_STATE=""
      if [ -n "$MR_OPEN_IID" ]; then
        # GitHub reports .state="open" — normalize to "opened".
        MR_OPEN_STATE=$(forge_mr_get "$MR_OPEN_IID" | jq -r 'if .state == "open" then "opened" else .state // empty end')
      fi
      if [ "$MR_OPEN_STATE" = "opened" ]; then
        echo "  → #$IID ($ROLE): merged MR exists but an open MR also exists — issue reopened for new iteration, skipping close"
        # FALL THROUGH (no close, no continue): an open MR means the issue
        # is being worked again, so the re-trigger logic below still
        # applies — the doctor must recover a STUCK worker/reviewer even
        # when a stale closed/merged MR lingers on the same branch. A
        # `continue` here strands the issue at boucle:working forever
        # (consumer 2026-08: a closed MR from a previous iteration
        # blocked re-triggering for hours while the issue occupied the
        # worker slot).
      else
        echo "  → #$IID ($ROLE): MR already merged — closing issue + boucle:done"
        set_boucle_label "$IID" "boucle:done" "boucle::status::done"
        close_issue "$IID"
        RECOVERED=$((RECOVERED + 1))
        continue
      fi
    fi

    # If the MR is open, approved, and mergeable, trigger the merger
    # instead of re-running the worker/reviewer. This recovers issues
    # stuck at boucle:working/boucle:review where a human already
    # approved the MR natively (the dispatch `approved` case only
    # acts on boucle:approval, so these issues would otherwise loop
    # forever re-running the worker/reviewer).
    MR_OPEN_DATA=""
    MR_OPEN_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
    if [ -n "$MR_OPEN_IID" ]; then
      MR_OPEN_DATA=$(forge_mr_get "$MR_OPEN_IID")
    fi
    if [ -n "$MR_OPEN_DATA" ] && [ "$MR_OPEN_DATA" != "null" ]; then
      MR_OIID=$(echo "$MR_OPEN_DATA" | jq -r '.iid // .number')
      # GitHub PRs expose .mergeable_state (clean/unstable ≈ mergeable,
      # dirty ≈ conflict) — normalize to the GitLab-style statuses the
      # logic below switches on.
      MR_OSTATUS=$(echo "$MR_OPEN_DATA" | jq -r 'if has("mergeable_state") then
                (if .mergeable_state == "clean" or .mergeable_state == "unstable" then "mergeable"
                 elif .mergeable_state == "dirty" then "conflict"
                 else .mergeable_state end)
                else (.detailed_merge_status // .merge_status // "unknown") end')
      # forge_mr_approvals returns "true"/"false" — map to 1/0 so the
      # count-based checks and log messages below keep working.
      MR_OAPPROVED=$(forge_mr_approvals "$MR_OIID")
      [ "$MR_OAPPROVED" = "true" ] && MR_OAPPROVED=1 || MR_OAPPROVED=0
      # In mono-user mode, there are no formal reviews — the reviewer
      # posts a verdict PASS as a comment on the PR. Detect that as an
      # approval signal so the doctor can merge without a native review.
      if [ "$MR_OAPPROVED" -eq 0 ] && [ "${BOUCLE_MONO_USER:-false}" = "true" ]; then
        MR_NOTES=$(forge_mr_notes "$MR_OIID" 2>/dev/null || echo "[]")
        echo "  → mono-user: MR_OIID=$MR_OIID notes_len=${#MR_NOTES} first100=${MR_NOTES:0:100}"
        if echo "$MR_NOTES" | jq -e '[.[] | select(.body | contains("VERDICT: PASS"))] | length > 0' > /dev/null 2>&1; then
          MR_OAPPROVED=1
        fi
      fi
      if [ "$MR_OAPPROVED" -gt 0 ] && { [ "$MR_OSTATUS" = "mergeable" ] || [ "$MR_OSTATUS" = "unknown" ]; }; then
        # When approved + mergeable: trigger merger directly.
        # When approved + unknown (GitHub hasn't computed mergeable_state
        # yet): trigger merger anyway — it will rebase and check
        # mergeability itself. Skipping here leaves approved PRs stuck
        # forever because the doctor is the only one that polls.
        echo "  → #$IID ($ROLE): MR !$MR_OIID approved ($MR_OAPPROVED) + $MR_OSTATUS — triggering merger"
        set_boucle_label "$IID" "boucle:merging" "boucle::status::bot"
        chain_to_role "$IID" "merger"
        echo "  → triggered merger for #$IID"
        RECOVERED=$((RECOVERED + 1))
        continue
      fi
    fi

    # Also detect closed (non-merged) MRs: the work was abandoned or
    # the user closed the MR rather than merging it. The loop should
    # still settle the issue rather than re-triggering the worker
    # forever (issue #34/#35 — the dispatch's close action now
    # escalates to boucle:human or stays terminal, but the doctor
    # needs to land the issue at boucle:done + close if the MR is
    # already closed at the moment of recovery).
    MR_CLOSED_IID=$(forge_mr_lookup_by_branch "boucle/$IID" closed)
    MR_CLOSED_STATE=""
    if [ -n "$MR_CLOSED_IID" ]; then
      # On GitHub a merged PR also reports .state="closed" — but the
      # merged branch above already handled it (or the open-MR check
      # below distinguishes a reopened iteration), so the net effect
      # (close issue + boucle:done) is the same on both backends.
      MR_CLOSED_STATE=$(forge_mr_get "$MR_CLOSED_IID" | jq -r '.state // empty')
    fi
    if [ "$MR_CLOSED_STATE" = "closed" ]; then
      MR_OPEN_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
      MR_OPEN_STATE=""
      if [ -n "$MR_OPEN_IID" ]; then
        # GitHub reports .state="open" — normalize to "opened".
        MR_OPEN_STATE=$(forge_mr_get "$MR_OPEN_IID" | jq -r 'if .state == "open" then "opened" else .state // empty end')
      fi
      if [ "$MR_OPEN_STATE" = "opened" ]; then
        echo "  → #$IID ($ROLE): closed MR exists but an open MR also exists — issue reopened for new iteration, skipping close"
        # FALL THROUGH (no close, no continue): an open MR means the issue
        # is being worked again, so the re-trigger logic below still
        # applies — the doctor must recover a STUCK worker/reviewer even
        # when a stale closed MR lingers on the same branch. A `continue`
        # here strands the issue at boucle:working forever (consumer
        # 2026-08: a closed MR from a previous iteration blocked
        # re-triggering for hours while the issue occupied the worker
        # slot).
      else
        echo "  → #$IID ($ROLE): MR already closed (non-merged) — closing issue + boucle:done"
        set_boucle_label "$IID" "boucle:done" "boucle::status::done"
        close_issue "$IID"
        RECOVERED=$((RECOVERED + 1))
        continue
      fi
    fi

    # Active-pipeline check: skip if a pipeline with BOUCLE_ISSUE=$IID is
    # already running/pending/created. Replaces the unreliable updated_at
    # proxy (lesson #33).
    if issue_has_active_pipeline "$IID"; then
      echo "  → #$IID ($ROLE): active pipeline already running — skipping re-trigger"
      continue
    fi
    # Staleness backstop: only re-trigger if the issue has been stuck
    # (no active pipeline) for longer than STALENESS. This catches the
    # case where a pipeline finished but the label was never advanced
    # (e.g. runner crashed mid-job before the label write).
    UPDATED_AT=$(forge_issue_get "$IID" | jq -r '.updated_at')
    UPDATED_EPOCH=$(date -d "$UPDATED_AT" +%s 2> /dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$((NOW_EPOCH - UPDATED_EPOCH))
    STALENESS="${BOUCLE_STALENESS_THRESHOLD:-2400}"
    if [ "$AGE" -lt "$STALENESS" ]; then
      echo "  → #$IID ($ROLE): issue updated ${AGE}s ago (< ${STALENESS}s) — may still be processing, skipping"
      continue
    fi
    # Doctor-side dedup: skip if the doctor already triggered this issue
    # within the STALENESS window. Secondary backstop for the case where
    # a triggered pipeline is in `created`/`waiting_for_resource` but the
    # variables API hasn't caught up yet.
    if doctor_should_skip_dedup "$IID"; then
      continue
    fi

    echo "  → #$IID ($ROLE): stuck for ${AGE}s — re-triggering $ROLE"
    chain_to_role "$IID" "$ROLE"
    doctor_mark_triggered "$IID"
    echo "  → re-triggered $ROLE for #$IID"
    RECOVERED=$((RECOVERED + 1))
  done

  # ── Recover stuck boucle:merging issues ──────────────────────────────────
  # The merger can fail mid-run (runner timeout, network "remote end hung
  # up unexpectedly", TLS handshake timeout, runner crash) leaving the issue
  # at boucle:merging with no active pipeline. No other doctor scan covers
  # this label — boucle:working/review scan skips it, boucle:human/approval
  # scan skips it — so the issue hangs at boucle:merging forever, blocking
  # the single merge slot if BOUCLE_MAX_PARALLEL_ISSUES=1. Recovery: if the
  # issue has been stuck at boucle:merging with no active pipeline for
  # longer than STALENESS, re-trigger the merger. The merger is idempotent
  # (rebase + push + merge or MWPS), so a re-trigger is always safe.
  echo "Scanning for stuck boucle:merging issues..."
  STUCK_MERGING=$(forge_issue_list_by_label "boucle:merging" opened \
    | jq -r '.[] | .iid // .number')
  for IID in $STUCK_MERGING; do
    echo "Checking #$IID (boucle:merging) for stuck merger..."
    # Active-pipeline guard: skip if a merger pipeline for this issue is
    # already running/pending/created (the merger may be slow but still
    # in flight — e.g. a long rebase or a slow push on a congested network).
    if issue_has_active_pipeline "$IID"; then
      echo "  → #$IID: active pipeline already running — skipping re-trigger"
      continue
    fi
    # Staleness: only re-trigger if the issue has been stuck (no active
    # pipeline) for longer than the merger timeout + margin. The merger
    # timeout is 10m, so 900s (15 min) gives ample room for a slow merger
    # to complete before the doctor fires a duplicate. The default
    # BOUCLE_STALENESS_THRESHOLD (2400s/40min) is too long for the
    # merger — a mergeable + approved MR should not wait 40 min for
    # recovery.
    UPDATED_AT=$(forge_issue_get "$IID" | jq -r '.updated_at')
    UPDATED_EPOCH=$(date -d "$UPDATED_AT" +%s 2> /dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$((NOW_EPOCH - UPDATED_EPOCH))
    MERGE_STALENESS="${BOUCLE_MERGE_STALENESS_THRESHOLD:-900}"
    if [ "$AGE" -lt "$MERGE_STALENESS" ]; then
      echo "  → #$IID: issue updated ${AGE}s ago (< ${MERGE_STALENESS}s) — may still be processing, skipping"
      continue
    fi
    if doctor_should_skip_dedup "$IID"; then
      continue
    fi
    # Verify the MR still exists and is still mergeable/approved before
    # re-triggering — the human may have closed the MR or revoked approval
    # while the issue sat at boucle:merging. If the MR is gone or not
    # approved, fall back to boucle:human (the merger cannot run without an
    # approved MR).
    MR_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
    if [ -z "$MR_IID" ]; then
      echo "  → #$IID: no open MR found — escalating to boucle:human (merger cannot run)"
      if ! forge_issue_note "$IID" "⚠️ Merger stuck at boucle:merging but no open MR found for branch boucle/$IID. Human intervention needed.$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      RECOVERED=$((RECOVERED + 1))
      continue
    fi
    APPROVED_COUNT=$(forge_mr_approvals "$MR_IID")
    [ "$APPROVED_COUNT" = "true" ] && APPROVED_COUNT=1 || APPROVED_COUNT=0
    if [ "$APPROVED_COUNT" -eq 0 ]; then
      echo "  → #$IID: MR !$MR_IID no longer approved — escalating to boucle:human (merger cannot run without approval)"
      if ! forge_issue_note "$IID" "⚠️ Merger stuck at boucle:merging but MR !$MR_IID is no longer approved. Human intervention needed.$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      RECOVERED=$((RECOVERED + 1))
      continue
    fi
    echo "  → #$IID: stuck at boucle:merging for ${AGE}s — re-triggering merger"
    chain_to_role "$IID" "merger"
    doctor_mark_triggered "$IID"
    echo "  → re-triggered merger for #$IID"
    RECOVERED=$((RECOVERED + 1))
  done

  # ── Recover CLOSED issues stuck at boucle:working/boucle:review ─────────
  # The doctor's main scan filters state=opened, so a closed issue that
  # still has boucle:working or boucle:review is invisible. This happens
  # when a human merges the MR directly (catchup closes the issue) while
  # a worker iteration is in flight — the worker's rebase-conflict
  # re-trigger or the reviewer FAIL handler re-triggers the worker on
  # the closed issue, creating zombie MRs and failed pipeline cascades
  # (lesson #44). Recovery: set boucle:done + close any open zombie MRs.
  ZOMBIE_WORKING=$(forge_issue_list_by_label "boucle:working" closed | jq -r '.[] | .iid // .number')
  ZOMBIE_REVIEW=$(forge_issue_list_by_label "boucle:review" closed | jq -r '.[] | .iid // .number')
  for IID in $ZOMBIE_WORKING $ZOMBIE_REVIEW; do
    echo "  → #$IID: closed but stuck at working/review — zombie recovery"
    # Close any open MR on the boucle/$IID branch (zombie MR created by
    # the worker running on the closed issue).
    ZOMBIE_MR_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
    if [ -n "$ZOMBIE_MR_IID" ]; then
      echo "  → #$IID: closing zombie MR !${ZOMBIE_MR_IID}"
      forge_mr_close "$ZOMBIE_MR_IID"
    fi
    set_boucle_label "$IID" "boucle:done" "boucle::status::done"
    RECOVERED=$((RECOVERED + 1))
  done

  # ── Recover boucle:human AND boucle:approval issues with approved MRs ──
  # The reviewer agent may escalate to boucle:human after 3 failed
  # verdict attempts (agent step budget exhausted). But if a human has
  # manually approved the MR, the loop should still merge it — the
  # work is done, it just needs the merger to run. Also scan
  # boucle:approval: a race condition can occur where the human approves
  # the MR BEFORE the reviewer finishes (the dispatch `approved` handler
  # silently skips when the issue is at boucle:review, not boucle:approval).
  # When the reviewer then PASSes and sets boucle:approval, the already-
  # existing approval is stranded — the loop waits for an approval that
  # already happened. This recovery path catches that race.
  # Accept both `mergeable` and `conflict` MRs: the merger handles rebase
  # conflicts by re-triggering the worker (rebase conflict → boucle:todo
  # → worker iteration 1), so triggering the merger on a conflicted MR
  # is safe — it either merges (after successful rebase) or re-runs the
  # worker on fresh $BOUCLE_DEFAULT_BRANCH.
  echo "Scanning boucle:human + boucle:approval issues for approved MRs..."
  RECOVERY_IIDS=""
  for RECOV_LABEL in boucle:human boucle:approval; do
    RECOV_IIDS=$(forge_issue_list_by_label "$RECOV_LABEL" opened \
      | jq -r '.[] | .iid // .number')
    RECOVERY_IIDS="$RECOVERY_IIDS $RECOV_IIDS"
  done

  for IID in $RECOVERY_IIDS; do
    [ -z "$IID" ] && continue
    echo "Checking #$IID (boucle:human/approval) for approved MR..."
    # Find an open MR for this issue (branch boucle/$IID).
    MR_DATA=""
    MR_LOOKUP_IID=$(forge_mr_lookup_by_branch "boucle/$IID" opened)
    if [ -n "$MR_LOOKUP_IID" ]; then
      MR_DATA=$(forge_mr_get "$MR_LOOKUP_IID")
    fi
    if [ -z "$MR_DATA" ] || [ "$MR_DATA" = "null" ]; then
      echo "  → #$IID: no open MR — skipping"
      continue
    fi
    MR_IID=$(echo "$MR_DATA" | jq -r '.iid // .number')
    # GitHub PRs expose .mergeable_state — normalize to the GitLab-style
    # statuses (clean/unstable ≈ mergeable, dirty ≈ conflict) the logic
    # below switches on.
    MR_MERGE_STATUS=$(echo "$MR_DATA" | jq -r 'if has("mergeable_state") then
            (if .mergeable_state == "clean" or .mergeable_state == "unstable" then "mergeable"
             elif .mergeable_state == "dirty" then "conflict"
             else .mergeable_state end)
            else (.detailed_merge_status // .merge_status // "unknown") end')
    # Check approvals on the MR. forge_mr_approvals returns "true"/"false"
    # — map to 0/1 so the count-based logic and messages keep working.
    APPROVED_COUNT=$(forge_mr_approvals "$MR_IID")
    [ "$APPROVED_COUNT" = "true" ] && APPROVED_COUNT=1 || APPROVED_COUNT=0
    # In mono-user mode, there are no formal reviews — the reviewer
    # posts a verdict PASS as a comment on the PR. Detect that as an
    # approval signal so the doctor can merge without a native review.
    if [ "$APPROVED_COUNT" -eq 0 ] && [ "${BOUCLE_MONO_USER:-false}" = "true" ]; then
      MR_NOTES=$(forge_mr_notes "$MR_IID" 2>/dev/null || echo "[]")
      if echo "$MR_NOTES" | jq -e '[.[] | select(.body | contains("VERDICT: PASS"))] | length > 0' > /dev/null 2>&1; then
        APPROVED_COUNT=1
      fi
    fi
    # Guard: if the merger already escalated a SEMANTIC merge conflict on
    # this issue (boucle_escalate_merge_conflict posts a note with "Merge
    # conflict — human intervention required" and sets boucle:human), do
    # NOT re-trigger the merger — it will reproduce the same conflict.
    # The human must resolve it manually (the escalation note gives them
    # options). Without this check, the doctor re-triggers the merger
    # every run (10 min) for a conflicted MR at boucle:human, producing
    # an infinite loop of duplicate merge-conflict notes (framagit
    # 2026-08, issue #62: 100+ duplicate notes in ~15 hours).
    ESCALATION_NOTES=$(forge_issue_notes "$IID" 2> /dev/null \
      | jq -r '[.[] | select(.body | test("Merge conflict — human intervention required"))] | length' 2> /dev/null || echo 0)
    if [ "$ESCALATION_NOTES" -gt 0 ]; then
      echo "  → #$IID: merger already escalated a merge conflict ($ESCALATION_NOTES note(s)) — human must resolve, skipping"
      continue
    fi
    if [ "$APPROVED_COUNT" -gt 0 ] && { [ "$MR_MERGE_STATUS" = "mergeable" ] || [ "$MR_MERGE_STATUS" = "conflict" ] || [ "$MR_MERGE_STATUS" = "unknown" ]; }; then
      echo "  → #$IID: MR !$MR_IID is approved ($APPROVED_COUNT) + $MR_MERGE_STATUS — triggering merger"
      set_boucle_label "$IID" "boucle:merging" "boucle::status::bot"
      chain_to_role "$IID" "merger"
      echo "  → triggered merger for #$IID"
      RECOVERED=$((RECOVERED + 1))
    elif [ "$APPROVED_COUNT" -gt 0 ] && [ "$MR_MERGE_STATUS" != "mergeable" ] && [ "$MR_MERGE_STATUS" != "unknown" ]; then
      # Approved but NOT mergeable (conflict/checking/blocked). Trigger
      # the merger anyway: it will rebase onto fresh $BOUCLE_DEFAULT_BRANCH.
      # On conflict the merger reverts to boucle:todo + worker (iter 1) to
      # regenerate the MR. Without this, an approved MR with conflicts
      # at boucle:approval/boucle:human hangs forever — no other path
      # triggers the merger for these labels.
      echo "  → #$IID: MR !$MR_IID approved ($APPROVED_COUNT) but not mergeable ($MR_MERGE_STATUS) — triggering merger to rebase/recover"
      set_boucle_label "$IID" "boucle:merging" "boucle::status::bot"
      chain_to_role "$IID" "merger"
      echo "  → triggered merger for #$IID (recovery path)"
      RECOVERED=$((RECOVERED + 1))
    else
      echo "  → #$IID: MR !$MR_IID status=$MR_MERGE_STATUS, approvals=$APPROVED_COUNT — not ready, skipping"
    fi
  done

  # ── Split-parent cascade ────────────────────────────────────────────────
  # Also check boucle:split parents: close the parent when all its
  # sub-issues are closed. This is the fallback cascade for sub-issues
  # closed via MR merge (Closes #N) where the deploy-triggered e2e
  # had no BOUCLE_ISSUE context and maybe_close_parent() never ran.
  SPLIT_PARENTS=$(forge_issue_list_by_label "boucle:split" opened \
    | jq -r '.[] | .iid // .number')

  for IID in $SPLIT_PARENTS; do
    echo "Checking #$IID (boucle:split) for parent-close cascade..."
    # Check children via the work-items hierarchy API (source of truth).
    CHILDREN_DATA=$(get_work_item_children "$IID")
    SIBLING_IIDS=$(echo "$CHILDREN_DATA" | jq -r '[.[].iid] | join(",")' 2> /dev/null)
    if [ -z "$SIBLING_IIDS" ]; then
      # No children via hierarchy API — fall back to legacy marker comment.
      NOTES=$(forge_issue_notes "$IID")
      SIBLING_IIDS=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
      if [ -z "$SIBLING_IIDS" ]; then
        # No legacy marker — fall back to REST issue links API.
        echo "  → #$IID: no children via hierarchy API and no split-parent marker — checking REST links..."
        # forge_issue_links returns a JSON array on both backends
        # (GitHub always [] — sub-issues use the hierarchy API).
        LINKS_DATA=$(forge_issue_links "$IID")
        SIBLING_IIDS=$(echo "$LINKS_DATA" | jq -r '[.[] | select(.iid != null) | .iid] | join(",")')
        if [ -z "$SIBLING_IIDS" ]; then
          echo "  → #$IID: no children, no marker, and no REST links — skipping"
          continue
        fi
        echo "  → #$IID: found siblings $SIBLING_IIDS via REST links fallback"
        # REST links fallback: check each sibling individually.
        ALL_CLOSED=true
        for SIB in $(echo "$SIBLING_IIDS" | tr ',' ' '); do
          SIB_STATE=$(forge_issue_get "$SIB" | jq -r '.state // "unknown"')
          if [ "$SIB_STATE" != "closed" ]; then
            echo "  → #$IID: sibling #$SIB is $SIB_STATE — parent stays open"
            ALL_CLOSED=false
            break
          fi
        done
        if [ "$ALL_CLOSED" = "true" ]; then
          echo "  → #$IID: all sub-issues closed — closing parent"
          close_issue "$IID"
          RECOVERED=$((RECOVERED + 1))
        fi
        continue
      fi
      echo "  → #$IID: found siblings $SIBLING_IIDS via legacy split-parent marker"
      # Legacy marker fallback: check each sibling individually.
      ALL_CLOSED=true
      for SIB in $(echo "$SIBLING_IIDS" | tr ',' ' '); do
        SIB_STATE=$(forge_issue_get "$SIB" | jq -r '.state // "unknown"')
        if [ "$SIB_STATE" != "closed" ]; then
          echo "  → #$IID: sibling #$SIB is $SIB_STATE — parent stays open"
          ALL_CLOSED=false
          break
        fi
      done
      if [ "$ALL_CLOSED" = "true" ]; then
        echo "  → #$IID: all sub-issues closed — closing parent"
        close_issue "$IID"
        RECOVERED=$((RECOVERED + 1))
      fi
      continue
    fi

    # Hierarchy API path: children response includes .state directly.
    OPEN_COUNT=$(echo "$CHILDREN_DATA" | jq '[.[] | select(.state != "closed")] | length' 2> /dev/null || echo 1)
    if [ "${OPEN_COUNT:-1}" -eq 0 ]; then
      echo "  → #$IID: all sub-issues closed — closing parent"
      close_issue "$IID"
      RECOVERED=$((RECOVERED + 1))
    else
      OPEN_IIDS=$(echo "$CHILDREN_DATA" | jq -r '[.[] | select(.state != "closed") | .iid] | join(",")')
      echo "  → #$IID: open sub-issue(s) #$OPEN_IIDS — parent stays open"
    fi
  done

  # ── Scheduled maintenance issues (#39) ─────────────────────────────────
  # Opt-in. Turns the doctor from purely inward-facing (healing state) into
  # an entry point that can also produce work.
  boucle_schedules_run || true

  # ── Status board (#36) ─────────────────────────────────────────────────
  # The sweep already holds the data; rendering it costs one read and, when
  # nothing moved, zero writes.
  boucle_board_upsert || true

  echo "Doctor complete. Recovered $RECOVERED orphaned issue(s)."
}
