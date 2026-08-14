#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/worker.sh — Worker stage for boucle CI.
#
# Extracted from .gitlab-ci.yml lines 1754-2445.
# Implements: state cache, closed-issue guard, branch checkout/rebase,
# seed state.md/iterations.md, feedback channel, attachments, run agent,
# exit-4 detection, safety-net commit, empty-MR guard, rebase before build,
# build, preview freshness marker, push, deploy, preview assertion,
# MR create/update, set review label, chain to reviewer.
#
# All forge API calls go through forge_* functions (bin/forge/*.sh).
# No direct glab/gh/curl calls. No CI_* or GITHUB_* variable references.

boucle_ci_worker() {
  set +o pipefail
  export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"
  ITERATION="${BOUCLE_ITERATION:-1}"
  export BOUCLE_ITERATION

  # ── Persist .boucle-state/<issue>/ across iterations ─────────────
  # Per-issue state lives in .boucle-state/ (gitignored) — never in
  # .boucle/, which is the engine submodule on consumers (git submodule
  # update would clobber in-flight state). LESSONS.yml lesson #20: the
  # worker fills state.md's Approach section; the MR description reads
  # it back from the same .boucle-state/<issue>/state.md path.
  BOUCLE_STATE_CACHE="${BOUCLE_STATE_CACHE:-${HOME}/.boucle-state-cache}"
  ISSUE_STATE_CACHE="${BOUCLE_STATE_CACHE}/${BOUCLE_ISSUE}"

  save_state_cache() {
    if [ -d ".boucle-state/$BOUCLE_ISSUE" ]; then
      mkdir -p "$ISSUE_STATE_CACHE"
      cp -a ".boucle-state/$BOUCLE_ISSUE/." "$ISSUE_STATE_CACHE/" 2> /dev/null || true
    fi
  }
  trap save_state_cache EXIT

  # ── Closed-issue guard ───────────────────────────────────────────
  local worker_issue_state
  worker_issue_state=$(forge_issue_get "$BOUCLE_ISSUE" | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
  if [ "$worker_issue_state" = "closed" ]; then
    echo "boucle: issue #$BOUCLE_ISSUE is closed — worker cannot run on a closed issue (no-op)"
    exit 0
  fi

  # ── Label-state guard (GitHub labeled-event race) ─────────────────
  # On GitHub the workflow fires the worker on `labeled` issue events
  # (the approval path: doctor sets boucle:todo after human validation).
  # The same event fires for triage's OWN transitions (boucle:triage,
  # boucle:spec-review, gate-skip flags), so a worker started by a
  # non-todo label event MUST refuse to run or it races the triage
  # pipeline and implements before the spec gate. Proceed only when the
  # issue carries boucle:todo (new work / retrigger) or boucle:working
  # (mid-flight safety-net continuation).
  worker_labels=$(forge_issue_labels_get "$BOUCLE_ISSUE" 2> /dev/null || echo "")
  if ! echo "$worker_labels" | tr ',' '\n' | grep -qx "boucle:todo" \
    && ! echo "$worker_labels" | tr ',' '\n' | grep -qx "boucle:working"; then
    echo "[boucle] Issue #$BOUCLE_ISSUE not at boucle:todo/working (labels: ${worker_labels:-none}) — labeled-event race, refusing to run."
    exit 0
  fi

  # ── Set working label ────────────────────────────────────────────
  set_boucle_label "$BOUCLE_ISSUE" "boucle:working" "boucle::status::bot"

  # ── Fetch latest default branch ──────────────────────────────────
  git fetch origin "$BOUCLE_DEFAULT_BRANCH"
  boucle_deepen_rebase_fetch

  # ── Retry strategy: classify the previous iteration (#44) ────────
  # Boucle always retried CUMULATIVELY: prior worker commits were rebased
  # and kept. That is right after a reviewer FAIL — the fix is incremental
  # and discarding valid work would burn iterations re-doing it.
  #
  # It is wrong after a contamination failure. A run that exhausted its step
  # budget still gets a safety-net commit (see below), so the half-written
  # tree becomes DURABLE on the branch, and iteration N+1 spends its budget
  # working out what the previous run was in the middle of instead of
  # implementing. That is the compounding-error case a Ralph-style loop
  # resets to avoid.
  #
  # Boucle already gets the rest of that cycle for free: every iteration is
  # a fresh CI job and a fresh agent process, so no conversation is carried.
  # Only the worktree was missing.
  local retry_strategy="${BOUCLE_RETRY_STRATEGY:-adaptive}"
  local prev_outcome=""
  if [ -f "$ISSUE_STATE_CACHE/last-outcome" ]; then
    prev_outcome=$(cat "$ISSUE_STATE_CACHE/last-outcome" 2> /dev/null || echo "")
  fi
  local want_reset=0
  case "$retry_strategy" in
    preserve) want_reset=0 ;;
    reset) want_reset=1 ;;
    adaptive) [ "$prev_outcome" = "no-changes" ] && want_reset=1 ;;
    *)
      echo "[boucle] WARN: unknown BOUCLE_RETRY_STRATEGY='$retry_strategy' — using 'preserve' (never destroys work)."
      retry_strategy="preserve"
      ;;
  esac
  echo "[boucle] retry strategy=$retry_strategy previous_outcome=${prev_outcome:-none} reset=$want_reset"

  # ── Branch checkout ──────────────────────────────────────────────
  BRANCH=$(boucle_branch_name "$BOUCLE_ISSUE")
  DISCARDED_SHA=""
  DISCARDED_TAG=""
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
    if git log --oneline "origin/$BOUCLE_DEFAULT_BRANCH..$BRANCH" 2> /dev/null | grep -q .; then
      if [ "$want_reset" -eq 1 ]; then
        # Never lose work silently: the discarded head is tagged and named
        # in an issue comment below, once git credentials are configured.
        DISCARDED_SHA=$(git rev-parse HEAD 2> /dev/null || echo "")
        DISCARDED_TAG="boucle/$BOUCLE_ISSUE/discarded-$(date -u +%Y%m%d%H%M%S)"
        echo "[boucle] Previous iteration shipped no code (contaminated tree) — resetting to origin/$BOUCLE_DEFAULT_BRANCH. Discarded head: ${DISCARDED_SHA:-unknown}"
        git reset --hard "origin/$BOUCLE_DEFAULT_BRANCH"
      else
        echo "[boucle] Branch has prior worker commits — rebasing onto origin/$BOUCLE_DEFAULT_BRANCH to preserve work."
        if ! git rebase "origin/$BOUCLE_DEFAULT_BRANCH"; then
          # PRESERVE, never reset (lessons #22/#51). Conflict-retry runs
          # (BOUCLE_CONFLICT_FEEDBACK set) hand the conflicted tree to the
          # agent; other runs keep the bounded abort → re-trigger → escalate.
          boucle_worker_rebase_conflict "🔄 Rebase conflict on the preserved worker branch. Re-running the worker (iteration {ITER}) — prior commits are kept."
        fi
      fi
    else
      git reset --hard "origin/$BOUCLE_DEFAULT_BRANCH"
    fi
  else
    git checkout -b "$BRANCH"
  fi

  # ── Restore state cache AFTER checkout ───────────────────────────
  if [ -d "$ISSUE_STATE_CACHE" ]; then
    echo "[boucle] Restoring .boucle-state/$BOUCLE_ISSUE/ from $ISSUE_STATE_CACHE"
    mkdir -p ".boucle-state/$BOUCLE_ISSUE"
    cp -a "$ISSUE_STATE_CACHE/." ".boucle-state/$BOUCLE_ISSUE/" 2> /dev/null || true
  fi

  # ── Configure git credentials for push ───────────────────────────
  git config user.email "${BOUCLE_BOT_EMAIL:-boucle-bot@boucle.local}"
  git config user.name "${BOUCLE_BOT_USERNAME:-up-bot}"
  git remote set-url origin "https://${BOUCLE_BOT_USERNAME:-up-bot}:${BOUCLE_TOKEN}@${BOUCLE_FORGE_HOST}/${BOUCLE_PROJECT_PATH}.git"

  # ── Publish the discarded head (#44) ─────────────────────────────
  # A reset that cannot be inspected afterwards is a data-loss bug. The tag
  # is pushed so the commits survive the force-push of the reset branch.
  # Best-effort: failing to tag must not stop the run.
  if [ -n "$DISCARDED_SHA" ] && [ -n "$DISCARDED_TAG" ]; then
    if git tag -f "$DISCARDED_TAG" "$DISCARDED_SHA" 2> /dev/null \
      && git push -f origin "refs/tags/$DISCARDED_TAG" 2> /dev/null; then
      forge_issue_note "$BOUCLE_ISSUE" "♻️ Previous iteration shipped no code, so the worker restarted from a clean \`$BOUCLE_DEFAULT_BRANCH\` instead of building on a half-written tree. The discarded work is kept at tag \`$DISCARDED_TAG\` (\`${DISCARDED_SHA:0:8}\`).$(job_link)"
    else
      echo "[boucle] WARN: could not publish discarded head $DISCARDED_SHA as $DISCARDED_TAG"
    fi
  fi

  # ── Seed state.md on first run ───────────────────────────────────
  if [ ! -f ".boucle-state/$BOUCLE_ISSUE/state.md" ]; then
    mkdir -p ".boucle-state/$BOUCLE_ISSUE"
    local triage_comment
    triage_comment=$(forge_issue_notes "$BOUCLE_ISSUE" \
      | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .body // ""')
    cat > ".boucle-state/$BOUCLE_ISSUE/state.md" << EOF
# Issue #$BOUCLE_ISSUE

## Goal
$(echo "$triage_comment" | sed -n '/^## Analysis/,/^## /p' | head -n -1 | tail -n +2)

## Acceptance criteria
$(echo "$triage_comment" | sed -n '/^## Draft acceptance criteria/,/^## /p' | head -n -1 | tail -n +2)

## Must-haves
$(echo "$triage_comment" | sed -n '/^## Must-haves/,/^## /p' | head -n -1 | tail -n +2)

## Spec delta
(none yet — record amendments here as ADDED/MODIFIED/REMOVED with source)

## Approach
(to be determined by worker)

## Tried and rejected
(none yet)

## Awaiting human
nothing
EOF
  fi

  # ── Seed iterations.md on first run ───────────────────────────────
  if [ ! -f ".boucle-state/$BOUCLE_ISSUE/iterations.md" ]; then
    # mkdir is NOT conditional here: the restore-from-cache block above only
    # creates .boucle-state/<iid>/ when the cache exists — on a first run (or after
    # GIT_CLEAN_FLAGS wiped the gitignored dir) the seed below would fail
    # with "No such file or directory" (observed on framagit, 2026-08).
    mkdir -p ".boucle-state/$BOUCLE_ISSUE"
    cat > ".boucle-state/$BOUCLE_ISSUE/iterations.md" << 'EOF'
# Iteration log — issue #$BOUCLE_ISSUE

Each entry: timestamp — role (agent) — iteration — result + files touched.
Read this BEFORE implementing to avoid repeating rejected approaches.
EOF
  fi

  # ── Feedback channel: inject reviewer verdicts + human MR comments ──
  export BOUCLE_REVIEWER_FEEDBACK
  BOUCLE_REVIEWER_FEEDBACK=""
  local mr_for_feedback
  mr_for_feedback=$(forge_mr_lookup_by_branch "boucle/$BOUCLE_ISSUE" "opened" 2> /dev/null || echo "")
  if [ -n "$mr_for_feedback" ]; then
    BOUCLE_REVIEWER_FEEDBACK=$(forge_mr_notes "$mr_for_feedback" \
      | jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | .[]' 2> /dev/null || echo "")
  fi

  # ── Build feedback channel: inject previous iteration's build error ──
  # Mirrors BOUCLE_REVIEWER_FEEDBACK. On a build failure the worker writes
  # the build log tail to .boucle-state/<issue>/build-feedback.md (restored from
  # the state cache on the next run) and exports it as BOUCLE_BUILD_FEEDBACK
  # so bin/jc injects it into the worker prompt. Empty on the first run or
  # after a successful build.
  export BOUCLE_BUILD_FEEDBACK
  BOUCLE_BUILD_FEEDBACK=""
  if [ -f ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" ]; then
    BOUCLE_BUILD_FEEDBACK=$(cat ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" 2> /dev/null || echo "")
  fi

  # ── Download attachments ─────────────────────────────────────────
  export BOUCLE_MR_IID="$mr_for_feedback"
  "$BOUCLE_HOME/bin/fetch-mr-attachments" || echo "[boucle] WARN: MR attachment fetch failed — continuing without MR attachments"
  "$BOUCLE_HOME/bin/fetch-issue-attachments" || echo "[boucle] WARN: attachment fetch failed — continuing without attachments"

  # ── Describe image attachments (vision model → text) ─────────────
  # Replaces detect-vision-need: the worker stays on deepseek-v4-flash
  # (code model) and gets image context as text descriptions.
  "$BOUCLE_HOME/bin/describe-images worker" || echo "[boucle] WARN: image description failed — continuing without descriptions"

  # ── Export issue body + notes for the agent prompt ───────────────
  export BOUCLE_ISSUE_BODY
  BOUCLE_ISSUE_BODY=$(forge_issue_get "$BOUCLE_ISSUE" | jq -r '.description // empty' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_BODY" ]; then
    echo "[boucle] WARN: could not fetch issue #$BOUCLE_ISSUE body — worker will fall back to forge CLI."
  fi

  export BOUCLE_ISSUE_NOTES
  BOUCLE_ISSUE_NOTES=$(forge_issue_notes "$BOUCLE_ISSUE" \
    | jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | reverse | .[]' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_NOTES" ]; then
    echo "[boucle] INFO: no prior notes for issue #$BOUCLE_ISSUE (first worker run)."
  fi

  # ── Sibling sub-issues (context for the worker) ──────────────────
  export BOUCLE_SIBLINGS
  BOUCLE_SIBLINGS=""
  local sib_parent_iid
  sib_parent_iid=$(forge_issue_get "$BOUCLE_ISSUE" \
    | jq -r '.description // empty' 2> /dev/null \
    | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
  if [ -n "$sib_parent_iid" ] && [ "$sib_parent_iid" != "$BOUCLE_ISSUE" ]; then
    local sib_children
    sib_children=$(forge_work_item_children "$sib_parent_iid" 2> /dev/null || echo "[]")
    if [ "$sib_children" = "[]" ]; then
      # Fallback: split-parent marker
      sib_children=$(forge_issue_notes "$sib_parent_iid" \
        | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' \
        | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
      if [ -n "$sib_children" ]; then
        sib_children=$(echo "$sib_children" | tr ',' '\n' | jq -R . | jq -s 'map({"iid": .})')
      else
        sib_children="[]"
      fi
    fi
    BOUCLE_SIBLINGS=$(echo "$sib_children" | jq -c --arg self "$BOUCLE_ISSUE" '
      map(select(.iid != ($self | tonumber)))
      | map({
          iid: .iid,
          title: .title,
          state: .state,
          mr_url: (.web_url // "")
        })' 2> /dev/null || echo "[]")
  fi

  # ── Run the agent ────────────────────────────────────────────────
  # Model/API failure retry: bin/jc exits 4 when the LLM API is
  # unavailable or credits are exhausted. A transient outage (rate
  # limit, brief downtime) should not immediately escalate to
  # boucle:human — retry with exponential backoff + jitter before
  # giving up.
  # BOUCLE_WORKER_MODEL_FAILURE_RETRIES controls the retry count (default 3).
  # BOUCLE_WORKER_MODEL_FAILURE_BASE_DELAY controls the base delay in
  # seconds (default 15). The delay for attempt N is:
  #   base_delay * 2^(N-1) + jitter(0..base_delay)
  # e.g. with defaults: attempt 1 → 15-30s, attempt 2 → 30-45s, attempt 3 → 60-75s.
  local model_failure_retries="${BOUCLE_WORKER_MODEL_FAILURE_RETRIES:-3}"
  case "$model_failure_retries" in '' | *[!0-9]*) model_failure_retries=3 ;; esac
  local base_delay="${BOUCLE_WORKER_MODEL_FAILURE_BASE_DELAY:-15}"
  case "$base_delay" in '' | *[!0-9]*) base_delay=15 ;; esac
  local attempt=0
  rc=0
  while true; do
    "$BOUCLE_HOME/bin/jc" worker || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
      echo "WARN: $BOUCLE_HOME/bin/jc worker exited $rc — proceeding to safety-net commit."
      break
    fi
    if [ "$rc" -eq 4 ] && [ "$attempt" -lt "$model_failure_retries" ]; then
      attempt=$((attempt + 1))
      # Exponential backoff: base * 2^(attempt-1), capped at 300s (5 min).
      local exp_delay=$((base_delay * (1 << (attempt - 1))))
      [ "$exp_delay" -gt 300 ] && exp_delay=300
      # Jitter: random 0..base_delay seconds, added to exp_delay.
      local jitter=$((RANDOM % (base_delay + 1)))
      local total_delay=$((exp_delay + jitter))
      echo "WARN: bin/jc worker exited 4 (model/API failure) — retrying ($attempt/$model_failure_retries) in ${total_delay}s (backoff=${exp_delay}s + jitter=${jitter}s)..."
      sleep "$total_delay"
      rc=0
      continue
    fi
    break
  done
  if [ "$rc" -ne 0 ]; then
    echo "WARN: $BOUCLE_HOME/bin/jc worker exited $rc after $attempt retry(s) — proceeding to safety-net commit."
  fi

  # ── Model/API failure detection (exit 4) ─────────────────────────
  if [ "$rc" -eq 4 ]; then
    local agent_log_file log_snippet diagnostic_body
    agent_log_file="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/agent-output.log"
    log_snippet="(log file not found or empty)"
    if [ -f "$agent_log_file" ]; then
      log_snippet=$(tail -c 2000 "$agent_log_file" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "(log read failed)")
    fi
    diagnostic_body=$(printf '%s\n' \
      "## ⚠️ Worker — model failure (API unavailable or credits exhausted)" \
      "" \
      "The worker produced **no output** — the agent log is empty or shows no activity. This indicates the model API is probably **unavailable** or **out of credits**." \
      "" \
      "### Logs" \
      "" \
      '```' \
      "$log_snippet" \
      '```' \
      "" \
      "### Action required" \
      "" \
      "- Check the model API status." \
      "- Check the remaining credits/quota." \
      "- Once the model is available, re-trigger the worker by re-applying the \`boucle:todo\` label and assigning the issue to the bot." \
      "" \
      "---" \
      "*Diagnostic posted by boucle (exit 4 — model/API failure).*")
    if ! forge_issue_note "$BOUCLE_ISSUE" "$diagnostic_body"; then
      echo "FAIL: worker model/API failure (exit 4) — diagnostic note could NOT be posted on issue #$BOUCLE_ISSUE. NOT escalating to boucle:human (a silent escalation is worse than a retry)." >&2
      exit 1
    fi
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    echo "FAIL: worker model/API failure (exit 4) — diagnostic posted on issue #$BOUCLE_ISSUE, escalated to human." >&2
    exit 1
  fi

  # ── Safety-net commit ────────────────────────────────────────────
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A -- ':!.boucle' || true
    # || true: the agent may already have committed everything (only
    # .boucle/ state files remain, excluded above) — `git commit` then
    # fails with "no changes added to commit". A bare commit under set -e
    # kills the job BEFORE the push, orphaning the agent's commits on the
    # local branch (consumer 2026-08: worker ran fine, job died at the
    # safety-net, MR never updated). The safety-net is best-effort by
    # design — never fail the job because there was nothing to commit.
    git commit -m "feat: worker changes for #$BOUCLE_ISSUE [skip ci]" --no-verify || true
  fi

  # Ensure wrangler cache isn't committed
  if ! grep -q '.wrangler/' .gitignore 2> /dev/null; then
    echo '.wrangler/' >> .gitignore
    git add .gitignore
    git commit -m "chore: ignore .wrangler/ cache [skip ci]" --no-verify
  fi

  # ── Empty-MR guard ───────────────────────────────────────────────
  local diff_files
  diff_files=$(git diff --name-only "origin/$BOUCLE_DEFAULT_BRANCH..HEAD" 2> /dev/null | grep -v '^\.gitignore$' || true)
  if [ -z "$diff_files" ]; then
    ITERATION="${BOUCLE_ITERATION:-1}"
    local max_iter="${BOUCLE_MAX_ITERATIONS:-5}"
    # Update MR title only (not description — lesson #24)
    local existing_mr_iid
    existing_mr_iid=$(forge_mr_lookup_by_branch "$BRANCH" "opened" 2> /dev/null || echo "")
    if [ -n "$existing_mr_iid" ]; then
      local nochg_title="feat: worker iteration $ITERATION — no code changes yet (#$BOUCLE_ISSUE)"
      forge_mr_update "$existing_mr_iid" "$nochg_title" ""
    fi
    # Record the outcome so the NEXT iteration can classify this failure
    # (#44). A step-exhausted run leaves a half-written tree that the
    # safety-net commit makes durable on the branch; iteration N+1 would
    # otherwise inherit it and spend its budget working out what happened.
    mkdir -p "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE" 2> /dev/null || true
    echo "no-changes" > "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/last-outcome" 2> /dev/null || true
    if [ "$ITERATION" -lt "$max_iter" ]; then
      echo "WARN: worker produced no changes — re-triggering (iteration $((ITERATION + 1))/$max_iter)." >&2
      set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
      boucle_health_outcome "$BOUCLE_ISSUE" "worker" "no-changes" "iteration $ITERATION" || true
      forge_issue_note "$BOUCLE_ISSUE" "🔄 Worker produced no code changes on iteration $ITERATION/$max_iter (agent likely exhausted its step budget). Re-running (iteration $((ITERATION + 1))/$max_iter).$(job_link)" || true
      chain_to_role "$BOUCLE_ISSUE" "worker" "BOUCLE_ITERATION=$((ITERATION + 1))"
    else
      echo "Escalating to human — worker produced no changes after $max_iter attempts." >&2
      # Note BEFORE the terminal label: an escalation whose note could not be
      # posted must NOT land at boucle:human muted (label flipped at 14:55:50,
      # note swallowed by a silent POST — the human saw a state, no message).
      if ! forge_issue_note "$BOUCLE_ISSUE" "$(boucle_escalation_diagnostic "$BOUCLE_ISSUE" "no-changes")$(job_link)"; then
        echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
        boucle_health_outcome "$BOUCLE_ISSUE" "worker" "no-changes" "iteration $ITERATION (cap reached, note FAILED)" || true
        exit 1
      fi
      boucle_health_outcome "$BOUCLE_ISSUE" "worker" "no-changes" "iteration $ITERATION (cap reached)" || true
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    fi
    exit 1
  fi

  # The worker shipped code: the next iteration must PRESERVE this work.
  echo "committed" > ".boucle-state/$BOUCLE_ISSUE/last-outcome" 2> /dev/null || true
  boucle_health_outcome "$BOUCLE_ISSUE" "worker" "committed" "iteration $ITERATION" || true

  # ── Rebase before build ──────────────────────────────────────────
  git fetch origin "$BOUCLE_DEFAULT_BRANCH"
  boucle_deepen_rebase_fetch
  if ! git rebase "origin/$BOUCLE_DEFAULT_BRANCH"; then
    # On conflict: conflict-retry runs (BOUCLE_CONFLICT_FEEDBACK set) hand
    # the conflicted tree to the agent; other runs keep the bounded
    # abort → re-trigger → escalate path.
    boucle_worker_rebase_conflict "🔄 Master advanced since this branch was created, causing a rebase conflict. Re-running the worker on fresh $BOUCLE_DEFAULT_BRANCH (iteration {ITER})."
  fi

  # ── Build gate (#53): fail fast on build errors, feed back to next iter ──
  # BOUCLE_BUILD_CMD is empty for projects without a build → skip entirely.
  if [ -n "${BOUCLE_BUILD_CMD:-}" ]; then
    local build_log build_rc
    build_log=$(mktemp)
    # Guard against set -e: without `|| build_rc=$?`, a non-zero build exit
    # kills the shell BEFORE `build_rc=$?` executes, so the build gate's
    # error handling (re-trigger worker, write build-feedback.md) NEVER
    # fires — the job fails with a plain exit 1 and the issue is stranded.
    # Observed on a consumer (2026-08): WASM OOM in @astrojs/compiler
    # killed the worker job, the Instagram embed fix was lost, and the
    # issue sat at boucle:working with no re-trigger.
    (eval "$BOUCLE_BUILD_CMD") > "$build_log" 2>&1 || build_rc=$?
    build_rc=${build_rc:-0}
    if [ "$build_rc" -ne 0 ]; then
      echo "FAIL: BOUCLE_BUILD_CMD exited $build_rc — feeding build error to next iteration." >&2
      tail -c 4000 "$build_log" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g' > ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" 2> /dev/null || true
      rm -f "$build_log"
      # Clean the build output so it does not dirty the tree / block rebase.
      [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] && rm -rf "$BOUCLE_BUILD_OUTPUT" 2> /dev/null || true
      ITERATION="${BOUCLE_ITERATION:-1}"
      local max_iter="${BOUCLE_MAX_ITERATIONS:-5}"
      if [ "$ITERATION" -lt "$max_iter" ]; then
        echo "Re-triggering worker (iteration $((ITERATION + 1))/$max_iter) with build error in feedback." >&2
        set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
        forge_issue_note "$BOUCLE_ISSUE" "🔄 Build failed on iteration $ITERATION/$max_iter (\`$BOUCLE_BUILD_CMD\` exited $build_rc). Re-running with the build error in the feedback channel (iteration $((ITERATION + 1))/$max_iter).$(job_link)"
        chain_to_role "$BOUCLE_ISSUE" "worker" "BOUCLE_ITERATION=$((ITERATION + 1))"
      else
        echo "Escalating to human — build failed after $max_iter attempts." >&2
        # Note BEFORE the terminal label — never a muted boucle:human.
        if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Build failed after $max_iter attempts (\`$BOUCLE_BUILD_CMD\` exited $build_rc). The worker could not produce a buildable tree. Human intervention needed.$(job_link)"; then
          echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
          boucle_health_outcome "$BOUCLE_ISSUE" "worker" "build-fail" "iteration $ITERATION (cap reached, note FAILED)" || true
          exit 1
        fi
        boucle_health_outcome "$BOUCLE_ISSUE" "worker" "build-fail" "iteration $ITERATION (cap reached)" || true
        set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      fi
      exit 1
    fi
    rm -f "$build_log"
    # Build succeeded: clear stale feedback. Keep the build output if a
    # deploy follows (the marker + deploy need it); clean it only when no
    # deploy is planned, so it does not dirty the tree on non-deploy runs.
    rm -f ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" 2> /dev/null || true
    if ! boucle_worker_should_deploy && ! boucle_is_screenshot_review; then
      [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] && rm -rf "$BOUCLE_BUILD_OUTPUT" 2> /dev/null || true
    fi
  else
    echo "[boucle] Build gate skipped (BOUCLE_BUILD_CMD is empty)"
  fi

  # ── Preview freshness marker ─────────────────────────────────────
  # BOUCLE_BUILD_OUTPUT defaults to "public" (the .gitlab-ci.yml default);
  # consumers on forges whose workflow does not pass the variable (GitHub
  # Actions) would hit an unbound-variable error under set -u.
  BOUCLE_BUILD_OUTPUT="${BOUCLE_BUILD_OUTPUT:-public}"
  local head_sha marker_html marker_txt
  head_sha=$(git rev-parse HEAD)
  if boucle_worker_should_deploy; then
    marker_html="<!-- boucle:commit sha=${head_sha} -->"
    marker_txt="boucle:commit sha=${head_sha}"
    if [ -f "$BOUCLE_BUILD_OUTPUT/index.html" ]; then
      sed "1i\\${marker_html}" "$BOUCLE_BUILD_OUTPUT/index.html" > "$BOUCLE_BUILD_OUTPUT/index.html.boucle" \
        && mv "$BOUCLE_BUILD_OUTPUT/index.html.boucle" "$BOUCLE_BUILD_OUTPUT/index.html"
    fi
    printf '%s\n' "$marker_txt" > "$BOUCLE_BUILD_OUTPUT/__boucle_commit__.txt"
  else
    echo "[boucle] SHA marker stamp skipped (no deploy in $(boucle_deploy_mode)/$(boucle_review_mode) mode)"
  fi

  # ── Push branch ──────────────────────────────────────────────────
  git push --force origin "$BRANCH"

  # ── Deploy (gated by deploy/review mode) ─────────────────────────
  local deploy_log deploy_rc preview_url
  preview_url=""

  if boucle_worker_should_deploy; then
    # GitHub Actions does not pass BOUCLE_DEPLOY_PROJECT (cf. GitLab
    # .gitlab-ci.yml:49 which exports it empty); the deploy command
    # references it, so default it here or the eval subshell dies on an
    # unbound variable under set -u.
    BOUCLE_DEPLOY_PROJECT="${BOUCLE_DEPLOY_PROJECT:-}"
    deploy_log=$(mktemp)
    # Same set -e guard as the build subshell above — without `|| deploy_rc=$?`,
    # a non-zero deploy exit kills the shell before the error handling runs.
    deploy_out=$(boucle_worker_deploy "$deploy_log") || deploy_rc=$?
    deploy_rc=${deploy_rc:-0}
    rm -f "$deploy_log"
    if [ "$deploy_rc" -ne 0 ]; then
      echo "FAIL: deploy failed ($deploy_rc)" >&2
      exit 1
    fi
    if [ -n "$deploy_out" ]; then
      preview_url=$(printf '%s\n' "$deploy_out" | grep -oE "$BOUCLE_DEPLOY_URL_REGEX" | head -1)
    fi
    # GitHub Pages declarative mode: the worker pushed gh-pages itself and
    # there is no per-branch preview URL — record the site URL so the MR
    # and the reviewer know the site is live (diff review fallback).
    if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "github-pages" ]; then
      boucle_site_url=$(boucle_github_pages_url)
      echo "[boucle] GitHub Pages site URL: $boucle_site_url (no per-branch preview — diff review)"
    fi
  else
    # GitLab Pages declarative mode: the forge serves the production site
    # at $CI_PAGES_URL. Branch previews are NOT possible on CE instances —
    # pages.path_prefix is a Premium feature that CE ignores SILENTLY
    # (publishes at the ROOT, clobbering production; verified on framagit
    # 2026-08). Display the real site URL in the MR description; the
    # reviewer falls back to diff review (its pages.dev extraction regex
    # cannot match the Pages domain).
    if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "gitlab-pages" ] && [ -n "${CI_PAGES_URL:-}" ]; then
      boucle_site_url="${CI_PAGES_URL%/}"
      echo "[boucle] GitLab Pages site URL: $boucle_site_url (no per-branch preview on CE)"
    else
      echo "[boucle] Deploy skipped (mode: $(boucle_deploy_mode), review: $(boucle_review_mode))"
    fi
  fi

  # ── Screenshot review mode ─────────────────────────────────────────
  # When BOUCLE_REVIEW_MODE=screenshot, the worker builds the site, serves
  # it locally (python3 -m http.server — zero dependencies, available on
  # every CI runner), captures screenshots of impacted pages via puppeteer/
  # chromium (reusing bin/render-preview.cjs with HTTP URL support), and
  # uploads them as MR attachments. The reviewer then receives the
  # screenshots as text descriptions (via describe-images --criteria) —
  # no deployed preview URL, no token, no CDN propagation wait.
  # Fail-open: a screenshot failure degrades to diff review, never blocks
  # the loop.
  local screenshot_urls=""
  if boucle_is_screenshot_review && [ -d "$BOUCLE_BUILD_OUTPUT" ]; then
    echo "[boucle] Screenshot review mode — capturing impacted pages..."
    local server_pid server_port server_ready
    server_port=8099
    # Start a static file server on the build output. python3 is available
    # on every CI runner (GitLab shell executors, GitHub ubuntu-latest).
    # --directory is supported on Python 3.7+ (2018+).
    python3 -m http.server "$server_port" --directory "$BOUCLE_BUILD_OUTPUT" >/dev/null 2>&1 &
    server_pid=$!
    # Give the server a moment to bind. A short poll loop is more reliable
    # than a fixed sleep — it starts shooting as soon as the port is open.
    server_ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -s -o /dev/null "http://localhost:${server_port}/" 2>/dev/null; then
        server_ready=true
        break
      fi
      sleep 0.5
    done
    if [ "$server_ready" = "true" ]; then
      # Determine the impacted page path from the branch diff (same logic
      # as preview_url_for_changed_files, but we need the path alone).
      local impacted_path=""
      impacted_path=$(preview_url_for_changed_files "http://localhost:${server_port}" \
        | sed "s|http://localhost:${server_port}||")
      [ -z "$impacted_path" ] && impacted_path="/"
      echo "[boucle] Screenshotting: $impacted_path"

      # Install puppeteer-core + @sparticuz/chromium (same as triage).
      local npm_tmp render_stderr
      npm_tmp="/tmp/npm-screenshot-${CI_JOB_ID:-$$}"
      render_stderr="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/screenshot-stderr.log"
      mkdir -p "$(dirname "$render_stderr")"
      if npm install --prefix "$npm_tmp" puppeteer-core @sparticuz/chromium >/dev/null 2>&1; then
        local screenshot_png
        screenshot_png="$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/screenshot.png"
        # render-preview.cjs now supports HTTP URLs — pass the full
        # localhost URL so puppeteer navigates to the served page.
        local rendered_pngs
        rendered_pngs=$(NODE_PATH="$npm_tmp/node_modules" node "$BOUCLE_HOME/bin/render-preview.cjs" \
          "http://localhost:${server_port}${impacted_path}" "$screenshot_png" 2>"$render_stderr" || true)
        if [ -n "$rendered_pngs" ]; then
          # Upload each PNG to the forge and collect embeddable URLs.
          local png_bytes=0
          local png_max="${BOUCLE_IMAGE_TOTAL_MAX_BYTES:-52428800}"
          while IFS= read -r png; do
            [ -s "$png" ] || continue
            local png_size
            png_size=$(wc -c < "$png" 2>/dev/null || echo 0)
            if [ "$((png_bytes + png_size))" -gt "$png_max" ]; then
              echo "[boucle] WARN: screenshot $(basename "$png") skipped — would exceed BOUCLE_IMAGE_TOTAL_MAX_BYTES"
              continue
            fi
            local img_path
            img_path=$(forge_attachment_upload "$BOUCLE_ISSUE" "$png" "$(basename "$png")" 2>/dev/null || true)
            if [ -n "$img_path" ]; then
              png_bytes=$((png_bytes + png_size))
              local dims label width
              dims=$(basename "$png" .png | sed 's/^.*-//')
              width=${dims%%x*}
              case "$width" in
                '' | *[!0-9]*) label="$dims" ;;
                *)
                  if [ "$width" -lt 600 ]; then
                    label="📱 Mobile ($dims)"
                  elif [ "$width" -lt 1024 ]; then
                    label="📲 Tablet ($dims)"
                  else
                    label="🖥️ Desktop ($dims)"
                  fi
                  ;;
              esac
              screenshot_urls="${screenshot_urls}**${label}**

![Screenshot ${dims}](${img_path})

"
            fi
          done <<< "$rendered_pngs"
          echo "[boucle] Screenshots captured and uploaded (${png_bytes} bytes)"
        else
          echo "[boucle] WARN: screenshot render failed — falling back to diff review"
          if [ -s "$render_stderr" ]; then
            echo "[boucle:screenshot-stderr] last 20 lines:"
            tail -n 20 "$render_stderr" | sed 's/^/[boucle:screenshot-stderr] /' >&2
          fi
        fi
      else
        echo "[boucle] WARN: could not install puppeteer/chromium — falling back to diff review"
      fi
    else
      echo "[boucle] WARN: local HTTP server did not start — falling back to diff review"
    fi
    # Always kill the server, even on failure paths.
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi

  # ── Preview URL deep-link ────────────────────────────────────────
  if [ -n "$preview_url" ]; then
    preview_url=$(preview_url_for_changed_files "$preview_url")
  fi

  # ── MR title + description ───────────────────────────────────────
  ITERATION="${BOUCLE_ITERATION:-1}"
  local commit_count commit_summary approach
  commit_count=$(git log "origin/$BOUCLE_DEFAULT_BRANCH..$BRANCH" --oneline 2> /dev/null | wc -l | tr -d ' ')
  commit_summary=$(git log "origin/$BOUCLE_DEFAULT_BRANCH..$BRANCH" --format='- %s' 2> /dev/null | head -10)
  approach=""
  if [ -f ".boucle-state/$BOUCLE_ISSUE/state.md" ]; then
    approach=$(sed -n '/^## Approach/,/^## /p' ".boucle-state/$BOUCLE_ISSUE/state.md" | head -n -1 | tail -n +2 | head -20)
  fi
  if [ -z "$approach" ] || [ "$approach" = "(to be determined by worker)" ]; then
    approach="(worker did not record an approach — see commit messages in 'What changed' above)"
  fi

  # Infer MR type from issue labels
  local issue_title issue_labels issue_data mr_type
  issue_data=$(forge_issue_get "$BOUCLE_ISSUE" 2> /dev/null || true)
  if [ -n "$issue_data" ]; then
    issue_title=$(echo "$issue_data" | jq -r '.title // empty')
    # GitHub issue labels are objects (.name), GitLab labels are strings —
    # normalize in jq so ascii_downcase works on both backends.
    issue_labels=$(echo "$issue_data" | jq -r '.labels | map(if type == "string" then . else .name end | ascii_downcase) | join(",") // empty')
  fi
  mr_type="feat"
  if echo "$issue_labels" | grep -qE 'bug|defect|fix'; then
    mr_type="fix"
  elif echo "$issue_labels" | grep -qE 'feature|enhancement|feat'; then
    mr_type="feat"
  elif echo "$issue_labels" | grep -qE 'documentation|docs'; then
    mr_type="docs"
  elif echo "$issue_labels" | grep -qE 'refactor'; then
    mr_type="refactor"
  elif echo "$issue_labels" | grep -qE 'chore|maintenance|tech-debt'; then
    mr_type="chore"
  fi

  local mr_title
  if [ -n "$issue_title" ]; then
    local mr_title_clean mr_title_summary
    mr_title_clean=$(echo "$issue_title" \
      | tr '\r\n\t' '   ' \
      | sed 's/  */ /g; s/^ //; s/ $//' \
      | sed 's/ *[(#][0-9]*[)]* *$//')
    if [ "${#mr_title_clean}" -gt 70 ]; then
      mr_title_summary=$(echo "$mr_title_clean" | cut -c1-70 | sed 's/ [^ ]*$//')
    else
      mr_title_summary="$mr_title_clean"
    fi
    mr_title="$mr_type: $mr_title_summary (#$BOUCLE_ISSUE)"
  else
    mr_title="boucle: issue #$BOUCLE_ISSUE"
  fi

  local preview_line=""
  if [ -n "$preview_url" ]; then
    preview_line="Preview: $preview_url"
  elif [ -n "$screenshot_urls" ]; then
    # Screenshot review mode: screenshots were captured and uploaded.
    # Embed them directly in the MR description so the human and the
    # reviewer see them inline.
    preview_line="### Screenshots (screenshot review mode)

${screenshot_urls}"
  elif [ -n "${boucle_site_url:-}" ]; then
    # Declarative forge Pages (GitLab CE or GitHub Pages): no per-branch
    # preview — display the real site URL so the MR does not look like a
    # broken duplicate.
    preview_line="Site (${BOUCLE_DEPLOY_PROVIDER:-pages}): $boucle_site_url — no per-branch preview; reviewed via diff"
  else
    # Diff-review mode (no deploy command — e.g. GitLab Pages): state it
    # plainly so the MR does not look like a broken duplicate (a blank
    # Preview: line reads as an unfinished deploy to a human scanning
    # the MR list).
    preview_line="Diff review (no preview deploy — BOUCLE_DEPLOY_CMD empty)"
  fi
  # Cost breakdown (#35): empty until an agent run reported usage, so the
  # description is unchanged on providers that report none. Only added on
  # runs that ship code — lesson #24 keeps no-changes runs from clobbering
  # a useful description, and lesson #19 wants it refreshed otherwise.
  local cost_block
  cost_block=$(boucle_cost_summary "$BOUCLE_ISSUE" || true)
  # Iteration budget, spelled out. "iteration 3" alone does not tell a human
  # whether the loop is progressing or on its last attempt before escalating
  # to boucle:human — the label carries the state, never how much budget is
  # left inside it.
  local mr_max_iter="${BOUCLE_MAX_ITERATIONS:-5}"
  # Final-attempt warning, self-renewing in the MR description. The worker
  # rebuilds the description every run, so the block appears only on the last
  # iteration and naturally disappears when a human comment renews the budget
  # (dispatch re-triggers the worker without BOUCLE_ITERATION → iteration 1).
  local final_attempt_block=""
  if [ "$ITERATION" -eq "$mr_max_iter" ]; then
    final_attempt_block=$(printf '> ⏳ **Final attempt** (%s/%s) — if this iteration does not satisfy the acceptance criteria, the loop stops and hands the MR to you (`boucle:human`) instead of retrying. Commenting now — on this MR or on the issue — still amends the spec and reaches the worker.' "$ITERATION" "$mr_max_iter")
  fi
  local mr_description
  mr_description=$(printf '## Issue #%s — iteration %s/%s\n\n%s\n\n%s\n\n### What changed\n%s\n\n### Approach\n%s\n\n%s\n\n---\n_Closes #%s | %s commit(s) | boucle worker run %s/%s_ | mode: deploy=%s review=%s' \
    "$BOUCLE_ISSUE" "$ITERATION" "$mr_max_iter" "$final_attempt_block" "$preview_line" "${commit_summary:-(no commits)}" "${approach:-(not recorded)}" "$cost_block" "$BOUCLE_ISSUE" "$commit_count" "$ITERATION" "$mr_max_iter" "$(boucle_deploy_mode)" "$(boucle_review_mode)")

  # ── File-impact marker refresh (F1 guard) ─────────────────────────
  # Refresh the <!-- boucle:files v=1 paths=... --> marker with the actual
  # branch diff. The triage agent embeds the marker inside its spec comment
  # (the `## Fichiers impactés` section); the refresh MUST NOT target that
  # spec note — updating it with a marker-only body would destroy the
  # human-visible spec. Instead, target the newest marker note that is NOT
  # a triage spec comment (a prior refresh note); if none exists, post a
  # new standalone marker note. The gate (parse_files_marker) picks the
  # newest marker note across all notes, so the refresh supersedes the
  # triage prediction. Skipped when the branch has no commits ahead (e.g.
  # after an adaptive reset) to preserve the last non-empty claim mid-flight
  # — a parallel worker would otherwise start into the same files.
  if [ "${BOUCLE_FILE_GATE:-true}" != "false" ]; then
    if [ -n "$(git log "origin/$BOUCLE_DEFAULT_BRANCH..HEAD" --oneline 2> /dev/null)" ]; then
      local refresh_paths
      refresh_paths=$(git diff --name-only "origin/$BOUCLE_DEFAULT_BRANCH...HEAD" 2> /dev/null \
        | sed 's|^\./||' | sort -u | paste -sd, -)
      if [ -n "$refresh_paths" ]; then
        local marker_body existing_note_id
        marker_body="<!-- boucle:files v=1 paths=$refresh_paths -->"
        # Newest files-marker note that is NOT the triage spec comment
        # (excludes bodies carrying `boucle:triage` or `boucle:draft role=triage`).
        existing_note_id=$(forge_issue_notes "$BOUCLE_ISSUE" 2> /dev/null \
          | jq -r '[.[] | select(.body | contains("<!-- boucle:files v=1")) | select(.body | test("boucle:triage v=1|boucle:draft role=triage") | not)] | sort_by(.created_at) | last | .id // empty' 2> /dev/null)
        if [ -n "$existing_note_id" ]; then
          forge_issue_note_update "$BOUCLE_ISSUE" "$existing_note_id" "$marker_body" \
            || echo "[boucle] WARN: marker note update failed — leaving stale marker (fail-open)"
        else
          forge_issue_note "$BOUCLE_ISSUE" "$marker_body" \
            || echo "[boucle] WARN: marker note post failed (fail-open)"
        fi
      fi
    else
      echo "[boucle] file-impact marker refresh SKIPPED — branch has no commits ahead (F1 guard, preserving last non-empty marker)"
    fi
  fi

  # ── MR create or update ──────────────────────────────────────────
  local mr_iid
  mr_iid=$(forge_mr_lookup_by_branch "$BRANCH" "opened" 2> /dev/null || echo "")
  if [ -z "$mr_iid" ]; then
    if ! mr_iid=$(forge_mr_create "$BRANCH" "$BOUCLE_DEFAULT_BRANCH" "$mr_title" "$mr_description"); then
      echo "FAIL: could not create MR for $BRANCH — stopping before setting boucle:review (no PR to review)" >&2
      exit 1
    fi
  else
    echo "MR !$mr_iid already exists for $BRANCH — updating title/description (worker iteration $ITERATION)"
    forge_mr_update "$mr_iid" "$mr_title" "$mr_description"
  fi

  # ── Preview assertion (HTTP 200 + SHA marker match) ──────────────
  if [ -n "$preview_url" ]; then
    local preview_ok http_code attempt delay
    preview_ok=false
    attempt=0
    delay=5
    while [ "$attempt" -lt 6 ]; do
      attempt=$((attempt + 1))
      http_code=$(curl -sL -o /dev/null -w "%{http_code}" "$preview_url" 2> /dev/null || echo "000")
      if [ "$http_code" = "200" ]; then
        echo "Preview URL 200 OK (attempt $attempt/6)"
        preview_ok=true
        break
      fi
      if [ "$attempt" -lt 6 ]; then
        echo "Preview URL returned $http_code (attempt $attempt/6) — retrying in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
      fi
    done
    if [ "$preview_ok" != "true" ]; then
      echo "FAIL: preview URL not 200 after $attempt attempts (last code: $http_code)" >&2
      exit 1
    fi

    local propagation_wait propagation_step elapsed deployed_sha
    propagation_wait="${BOUCLE_PREVIEW_PROPAGATION_WAIT:-60}"
    propagation_step=5
    elapsed=0
    deployed_sha=""
    local marker_path="${BOUCLE_PREVIEW_MARKER_PATH:-__boucle_commit__.txt}"
    while [ "$elapsed" -lt "$propagation_wait" ]; do
      deployed_sha=$(curl -s "${preview_url%/}/${marker_path}" 2> /dev/null \
        | grep -oE 'sha=[a-f0-9]{7,40}' | head -1 | sed 's/sha=//')
      if [ "$deployed_sha" = "$head_sha" ]; then
        echo "Preview fresh: deployed SHA ${deployed_sha:0:12} matches head ${head_sha:0:12} (after ${elapsed}s)"
        break
      fi
      echo "Preview not fresh yet (got '${deployed_sha:-none}', want '${head_sha:0:12}') — retrying in ${propagation_step}s (${elapsed}/${propagation_wait}s)"
      sleep "$propagation_step"
      elapsed=$((elapsed + propagation_step))
    done
    if [ "$deployed_sha" != "$head_sha" ]; then
      echo "FAIL: preview stale after ${propagation_wait}s — deployed SHA '${deployed_sha:-none}' != head '${head_sha:0:12}'" >&2
      exit 1
    fi
  else
    echo "[boucle] Preview assertion skipped (no preview URL in $(boucle_deploy_mode)/$(boucle_review_mode) mode)"
  fi

  # ── Set review label ─────────────────────────────────────────────
  set_boucle_label "$BOUCLE_ISSUE" "boucle:review" "boucle::status::bot"

  # ── Chain to reviewer ────────────────────────────────────────────
  chain_to_role "$BOUCLE_ISSUE" "reviewer" "BOUCLE_ITERATION=$ITERATION"
}

# forge_mr_lookup_by_branch <source_branch> [state] is provided by the
# forge backend (bin/forge/gitlab.sh / bin/forge/github.sh), loaded via
# forge_init() in lib/boucle-ci.sh before this stage runs. The local
# duplicate was removed — the contract version is authoritative (commit
# 2bea653). Returns the MR IID on stdout, empty on failure.
