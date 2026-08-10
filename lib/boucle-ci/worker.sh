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

  # ── Persist .boucle/<issue>/ across iterations ───────────────────
  BOUCLE_STATE_CACHE="${BOUCLE_STATE_CACHE:-${HOME}/.boucle-state-cache}"
  ISSUE_STATE_CACHE="${BOUCLE_STATE_CACHE}/${BOUCLE_ISSUE}"

  save_state_cache() {
    if [ -d ".boucle/$BOUCLE_ISSUE" ]; then
      mkdir -p "$ISSUE_STATE_CACHE"
      cp -a ".boucle/$BOUCLE_ISSUE/." "$ISSUE_STATE_CACHE/" 2> /dev/null || true
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
  BRANCH="boucle/$BOUCLE_ISSUE"
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
          echo "[boucle] Rebase conflicted — resetting to origin/$BOUCLE_DEFAULT_BRANCH (prior work lost)."
          git rebase --abort 2> /dev/null || true
          git reset --hard "origin/$BOUCLE_DEFAULT_BRANCH"
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
    echo "[boucle] Restoring .boucle/$BOUCLE_ISSUE/ from $ISSUE_STATE_CACHE"
    mkdir -p ".boucle/$BOUCLE_ISSUE"
    cp -a "$ISSUE_STATE_CACHE/." ".boucle/$BOUCLE_ISSUE/" 2> /dev/null || true
  fi

  # ── Configure git credentials for push ───────────────────────────
  git config user.email "bot@ankaboot.dev"
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

## Approach
(to be determined by worker)

## Tried and rejected
(none yet)

## Awaiting human
nothing
EOF
  fi

  # ── Seed iterations.md on first run ───────────────────────────────
  if [ ! -f ".boucle/$BOUCLE_ISSUE/iterations.md" ]; then
    # mkdir is NOT conditional here: the restore-from-cache block above only
    # creates .boucle/<iid>/ when the cache exists — on a first run (or after
    # GIT_CLEAN_FLAGS wiped the gitignored dir) the seed below would fail
    # with "No such file or directory" (observed on framagit, 2026-08).
    mkdir -p ".boucle/$BOUCLE_ISSUE"
    cat > ".boucle/$BOUCLE_ISSUE/iterations.md" << 'EOF'
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

  # ── Download attachments ─────────────────────────────────────────
  export BOUCLE_MR_IID="$mr_for_feedback"
  "$BOUCLE_HOME/bin/fetch-mr-attachments" || echo "[boucle] WARN: MR attachment fetch failed — continuing without MR attachments"
  "$BOUCLE_HOME/bin/fetch-issue-attachments" || echo "[boucle] WARN: attachment fetch failed — continuing without attachments"

  # ── Detect image attachments and route to vision model ───────────
  eval "$("$BOUCLE_HOME/bin/detect-vision-need" worker)"

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
  rc=0
  "$BOUCLE_HOME/bin/jc" worker || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: $BOUCLE_HOME/bin/jc worker exited $rc — proceeding to safety-net commit."
  fi

  # ── Model/API failure detection (exit 4) ─────────────────────────
  if [ "$rc" -eq 4 ]; then
    local agent_log_file log_snippet diagnostic_body
    agent_log_file="$BOUCLE_WORKSPACE/.boucle/$BOUCLE_ISSUE/agent-output.log"
    log_snippet="(log file not found or empty)"
    if [ -f "$agent_log_file" ]; then
      log_snippet=$(tail -c 2000 "$agent_log_file" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "(log read failed)")
    fi
    diagnostic_body=$(printf '%s\n' \
      "## ⚠️ Worker — échec du modèle (API indisponible ou crédits épuisés)" \
      "" \
      "Le worker n'a produit **aucune sortie** — le log agent est vide ou ne montre aucune activité. Cela indique que l'API du modèle est probablement **indisponible** ou **à court de crédits**." \
      "" \
      "### Logs" \
      "" \
      '```' \
      "$log_snippet" \
      '```' \
      "" \
      "### Action requise" \
      "" \
      "- Vérifiez le statut de l'API du modèle." \
      "- Vérifiez les crédits/quota restants." \
      "- Une fois le modèle disponible, re-déclenchez le worker en remettant le label \`boucle:todo\` et en assignant l'issue au bot." \
      "" \
      "---" \
      "*Diagnostic posté par boucle (exit 4 — model/API failure).*")
    forge_issue_note "$BOUCLE_ISSUE" "$diagnostic_body"
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
    echo "FAIL: worker model/API failure (exit 4) — diagnostic posted on issue #$BOUCLE_ISSUE, escalated to human." >&2
    exit 1
  fi

  # ── Safety-net commit ────────────────────────────────────────────
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A -- ':!.boucle' || true
    git commit -m "feat: worker changes for #$BOUCLE_ISSUE [skip ci]" --no-verify
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
    local max_iter="${BOUCLE_MAX_ITERATIONS:-3}"
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
    mkdir -p "$BOUCLE_WORKSPACE/.boucle/$BOUCLE_ISSUE" 2> /dev/null || true
    echo "no-changes" > "$BOUCLE_WORKSPACE/.boucle/$BOUCLE_ISSUE/last-outcome" 2> /dev/null || true
    if [ "$ITERATION" -lt "$max_iter" ]; then
      echo "WARN: worker produced no changes — re-triggering (iteration $((ITERATION + 1))/$max_iter)." >&2
      set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
      forge_issue_note "$BOUCLE_ISSUE" "🔄 Worker produced no code changes on iteration $ITERATION (agent likely exhausted its step budget). Re-running (iteration $((ITERATION + 1))/$max_iter).$(job_link)"
      chain_to_role "$BOUCLE_ISSUE" "worker" "BOUCLE_ITERATION=$((ITERATION + 1))"
    else
      echo "Escalating to human — worker produced no changes after $max_iter attempts." >&2
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      forge_issue_note "$BOUCLE_ISSUE" "⚠️ Worker produced no code changes after $max_iter attempts. The agent may be unable to implement this issue within its step budget. Human intervention needed.$(job_link)"
    fi
    exit 1
  fi

  # The worker shipped code: the next iteration must PRESERVE this work.
  echo "committed" > ".boucle/$BOUCLE_ISSUE/last-outcome" 2> /dev/null || true

  # ── Rebase before build ──────────────────────────────────────────
  git fetch origin "$BOUCLE_DEFAULT_BRANCH"
  boucle_deepen_rebase_fetch
  if ! git rebase "origin/$BOUCLE_DEFAULT_BRANCH"; then
    echo "FAIL: rebase onto origin/$BOUCLE_DEFAULT_BRANCH conflicted." >&2
    git rebase --abort 2> /dev/null || true
    ITERATION="${BOUCLE_ITERATION:-1}"
    local max_iter="${BOUCLE_MAX_ITERATIONS:-3}"
    if [ "$ITERATION" -lt "$max_iter" ]; then
      # Closed-issue guard
      local rebase_issue_state
      rebase_issue_state=$(forge_issue_get "$BOUCLE_ISSUE" | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
      if [ "$rebase_issue_state" = "closed" ]; then
        echo "boucle: issue #$BOUCLE_ISSUE is closed — not re-triggering worker after rebase conflict"
        exit 1
      fi
      echo "Re-triggering worker (iteration $((ITERATION + 1))/$max_iter)." >&2
      set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
      forge_issue_note "$BOUCLE_ISSUE" "🔄 Master advanced since this branch was created, causing a rebase conflict. Re-running the worker on fresh $BOUCLE_DEFAULT_BRANCH (iteration $((ITERATION + 1))/$max_iter).$(job_link)"
      chain_to_role "$BOUCLE_ISSUE" "worker" "BOUCLE_ITERATION=$((ITERATION + 1))"
    else
      echo "Escalating to human — iteration cap ($max_iter) reached after repeated rebase conflicts." >&2
      set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
      forge_issue_note "$BOUCLE_ISSUE" "⚠️ Worker could not rebase onto $BOUCLE_DEFAULT_BRANCH (conflict) after $max_iter attempts. Master keeps advancing. Human intervention needed.$(job_link)"
    fi
    exit 1
  fi

  # ── Build ────────────────────────────────────────────────────────
  eval "$BOUCLE_BUILD_CMD"

  # ── Preview freshness marker ─────────────────────────────────────
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
    deploy_log=$(mktemp)
    (eval "$BOUCLE_DEPLOY_CMD") > "$deploy_log" 2>&1
    deploy_rc=$?
    preview_url=$(grep -oE "$BOUCLE_DEPLOY_URL_REGEX" "$deploy_log" | head -1)
    if [ "$deploy_rc" -ne 0 ] && [ -n "$preview_url" ]; then
      echo "WARN: deploy exited non-zero ($deploy_rc) but emitted a preview URL — proceeding" >&2
    fi
    if [ "$deploy_rc" -ne 0 ] && [ -z "$preview_url" ]; then
      echo "FAIL: deploy exited $deploy_rc with no preview URL" >&2
      cat "$deploy_log" >&2
      rm -f "$deploy_log"
      exit 1
    fi
    rm -f "$deploy_log"
  else
    echo "[boucle] Deploy skipped (mode: $(boucle_deploy_mode), review: $(boucle_review_mode))"
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
    issue_labels=$(echo "$issue_data" | jq -r '.labels | map(. | ascii_downcase) | join(",") // empty')
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
  fi
  # Cost breakdown (#35): empty until an agent run reported usage, so the
  # description is unchanged on providers that report none. Only added on
  # runs that ship code — lesson #24 keeps no-changes runs from clobbering
  # a useful description, and lesson #19 wants it refreshed otherwise.
  local cost_block
  cost_block=$(boucle_cost_summary "$BOUCLE_ISSUE" || true)
  local mr_description
  mr_description=$(printf '## Issue #%s — iteration %s\n\n%s\n\n### What changed\n%s\n\n### Approach\n%s\n\n%s\n\n---\n_Closes #%s | %s commit(s) | boucle worker run %s_ | mode: deploy=%s review=%s' \
    "$BOUCLE_ISSUE" "$ITERATION" "$preview_line" "${commit_summary:-(no commits)}" "${approach:-(not recorded)}" "$cost_block" "$BOUCLE_ISSUE" "$commit_count" "$ITERATION" "$(boucle_deploy_mode)" "$(boucle_review_mode)")

  # ── MR create or update ──────────────────────────────────────────
  local mr_iid
  mr_iid=$(forge_mr_lookup_by_branch "$BRANCH" "opened" 2> /dev/null || echo "")
  if [ -z "$mr_iid" ]; then
    mr_iid=$(forge_mr_create "$BRANCH" "$BOUCLE_DEFAULT_BRANCH" "$mr_title" "$mr_description")
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
