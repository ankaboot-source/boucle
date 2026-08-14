#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2154
# lib/boucle-ci/triage.sh — triage stage: analyze issue, route based on disposition+size.
#
# Extracted from the `triage:` job in .gitlab-ci.yml (lines 981-1754) into a
# forge-agnostic shell function, part of the forge-abstraction effort
# (GitLab + GitHub support). Sourced by lib/boucle-ci.sh, which provides:
#   - forge_* abstraction (bin/forge/common.sh + bin/forge/<forge>.sh)
#   - lib/boucle.sh helpers (set_boucle_label, resolve_reporter_id,
#     get_work_item_children, get_work_item_global_id, chain_to_role, ...)
#
# Environment contract: BOUCLE_* vars (see lib/boucle-ci.sh header).
# This function does NOT include before_script setup — only the script block.
#
# Extraction notes (for review):
#   - All forge_* calls are best-effort per the contract (transient API errors
#     never kill the loop). The original mixed `|| true` with bare POSTs that
#     would abort the job under set -e; extraction normalizes to best-effort.
#   - The original assumes notes arrive newest-first (`first` = newest in the
#     COMMENT / PRE_RUN_TRIAGE_ID / TRIAGE_NOTE_ID jq filters). GitLab returns
#     newest-first natively; a GitHub backend must reverse to match.
#   - Note read/update/delete (forge_issue_note_get/update, forge_note_delete),
#     issue count (forge_issue_count_by_label), attachment upload
#     (forge_attachment_upload), parent linking (forge_work_item_link_parent —
#     hierarchy PATCH + relates_to fallback), and description update
#     (forge_issue_update) are all ported to the contract. No raw glab/curl
#     calls remain in this file.

boucle_ci_triage() {
  set +o pipefail
  # Disable pipefail: grep in $(...) exits 1 on no-match, killing the script under set -eo pipefail. Without pipefail, the var is just empty (which we handle).
  # Guard: if dispatch skipped (bot note event, anti-loop), no .boucle-issue artifact
  if [ ! -f .boucle-issue ]; then
    # Recovery path: allow manual triage trigger via BOUCLE_ISSUE variable
    if [ -n "${BOUCLE_ISSUE:-}" ]; then
      echo "No .boucle-issue artifact, but BOUCLE_ISSUE=$BOUCLE_ISSUE set via trigger. Using it."
      IID="$BOUCLE_ISSUE"
    else
      echo "No .boucle-issue artifact (dispatch skipped) and no BOUCLE_ISSUE variable. Nothing to triage."
      exit 0
    fi
  else
    IID=$(cat .boucle-issue)
  fi
  export BOUCLE_ISSUE="$IID"

  # ── No-key detection (freeride mode) ──────────────────────────────
  # If no LLM configuration is available (no BOUCLE_LLM_BASE_URL and no
  # freeride provider key), post a help message explaining how to set up
  # a free-tier API key. The issue goes to boucle:needs-info — the user
  # re-triggers by reacting with 👍 ❤️ 🎉 or 🚀 after adding a key.
  # This runs BEFORE attachment fetch / agent invocation to avoid wasting
  # a runner on an issue that cannot be triaged.
  if ! has_llm_config 2>/dev/null; then
    echo "[boucle:no-key] no LLM configuration found — posting help message"
    # Check if a help message already exists (update instead of duplicate).
    EXISTING_HELP=$(forge_issue_notes "$IID" 2>/dev/null \
      | jq -r '[.[] | select(.body | contains("<!-- boucle:needs-info") and contains("reason=no-key"))] | last | .id // 0' 2>/dev/null || echo "0")

    HELP_MSG=$(cat << 'HELP_EOF'
## Boucle needs an API key to start

Boucle can run on **free-tier LLM providers** — no paid account required.
Pick one (or more), create a free API key, and add it as a CI/CD variable.

### Free-tier providers

| Provider | CI/CD variable | Sign up |
|---|---|---|
| NVIDIA NIM | `BOUCLE_NVIDIA_API_KEY` | https://build.nvidia.com |
| Groq | `BOUCLE_GROQ_API_KEY` | https://console.groq.com/keys |
| Cerebras | `BOUCLE_CEREBRAS_API_KEY` | https://cloud.cerebras.ai |
| Zhipu (GLM) | `BOUCLE_ZHIPU_API_KEY` | https://open.bigmodel.cn |
| Cloudflare | `BOUCLE_CLOUDFLARE_API_KEY` + `BOUCLE_CLOUDFLARE_ACCOUNT_ID` | https://dash.cloudflare.com |
| HuggingFace | `BOUCLE_HUGGINGFACE_API_KEY` | https://huggingface.co/settings/tokens |
| Mistral | `BOUCLE_MISTRAL_API_KEY` | https://console.mistral.ai |

### How to set up

1. Create a free account on one of the providers above
2. Generate an API key
3. Add it as a CI/CD variable in **Settings → CI/CD → Variables** (masked, protected)
4. React to this comment with 👍 to re-trigger boucle

### Want better quality?

Configure a dedicated endpoint instead:
- `BOUCLE_LLM_BASE_URL` — your OpenAI-compatible endpoint
- `BOUCLE_LLM_API_KEY` — your API key

Free-tier models are less capable and less reliable. For production use,
a paid provider is recommended.

<!-- boucle:needs-info v=1 reason=no-key -->
HELP_EOF
)

    if [ "$EXISTING_HELP" != "0" ] && [ -n "$EXISTING_HELP" ]; then
      forge_issue_note_update "$IID" "$EXISTING_HELP" "$HELP_MSG" 2>/dev/null || true
    else
      forge_issue_note "$IID" "$HELP_MSG" 2>/dev/null || true
    fi

    # Assign the human author (resolve via reporter pattern).
    REPORTER_ID=$(resolve_reporter_id "$IID" 2>/dev/null || echo "")
    if [ -n "$REPORTER_ID" ]; then
      forge_issue_assign "$IID" "$REPORTER_ID" 2>/dev/null || true
    fi

    # Set boucle:needs-info (preserve non-boucle labels).
    set_boucle_label "$IID" "boucle:needs-info" "boucle::status::bot" 2>/dev/null || true
    exit 0
  fi

  # Label helper: preserve non-boucle labels when writing a boucle label.
  # The jq filter uses startswith("boucle:") which catches BOTH the detail
  # axis (boucle:triage) AND the gross axis (boucle::status::bot, also
  # starts with "boucle:"), so we strip all boucle-managed labels when
  # writing a new pair. Caller passes detail as $2 and gross as $3.
  # Resolve the human reporter to notify on NEEDS-INFO. For a sub-issue
  # created by the bot via NEEDS-SPLIT, the issue's own author is up-bot
  # (useless to assign). The human who must answer is the PARENT issue's
  # author. Parse the "## Parent issue\n#N" link from the sub-issue body
  # (same format maybe_close_parent uses) and fetch the parent's author.
  # For a top-level issue, use its own author.
  # NOTE: use printf '%s' (not echo) to feed JSON to jq — echo in some
  # shells (zsh) interprets backslash escapes and corrupts JSON whose
  # description contains literal control characters.
  # Fetch the global work-item ID for an issue (needed as parent_id for
  # the child-items hierarchy API). Issues and work items share the same
  # IID space since 16.0, so /work_items/:iid works for issues too.
  # Returns empty string on failure (loop must not break).
  # NOTE: the forge CLI may exit 0 on HTTP 403 (e.g. when the work_item_rest_api
  # feature flag is disabled) and print the error JSON to stdout, so we
  # validate the response shape rather than rely on the exit code.
  # List child work items of a parent. Returns JSON array (empty array on
  # failure). Each child has .iid, .state ("opened"|"closed"), .title.
  # NOTE: the forge CLI may exit 0 on HTTP 403 (e.g. when the work_item_rest_api
  # feature flag is disabled) and print the error JSON to stdout. A 403
  # error object like {"message":"403 Forbidden ..."} is a JSON OBJECT,
  # not an array — jq 'length' on an object returns its key count (1),
  # which would falsely trip the idempotency guard. We therefore validate
  # that the response is a JSON ARRAY and return [] otherwise.
  # Download attachments uploaded to the issue (capped per BOUCLE_IMAGE_*_BYTES).
  # Makes them available to the triage agent via BOUCLE_ISSUE_ATTACHMENTS.
  $BOUCLE_HOME/bin/fetch-issue-attachments || echo "[boucle] WARN: attachment fetch failed — continuing without attachments"

  # Describe image attachments using a vision model, then inject the text
  # descriptions into the agent prompt. This replaces the old detect-vision-need
  # approach which swapped the entire model to minimax-m3 (worse at code, prone
  # to WASM OOM crashes). With describe-images, the agent stays on its default
  # model and gets image context as text.
  "$BOUCLE_HOME/bin/describe-images" triage || echo "[boucle] WARN: image description failed — continuing without descriptions"

  # Fetch the issue body and export it so the triage agent does not
  # waste steps calling forge issue view (minimax-m3
  # burned 4+ steps on failed fetches before posting its comment).
  export BOUCLE_ISSUE_BODY
  BOUCLE_ISSUE_BODY=$(forge_issue_get "$IID" | jq -r '.description // empty' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_BODY" ]; then
    echo "[boucle] WARN: could not fetch issue #$IID body — agent will fall back to forge issue view."
  fi

  # Fetch the issue notes (comments) and export them so the triage
  # agent can see prior triage Questions AND the author's answers.
  # Without this, every re-triage re-asks questions the author already
  # answered (issue #27: 6 repeated triage notes on a consumer repo).
  # The notes API returns newest-first; we reverse to oldest-first
  # and format each note as "[<author>] <body>". We keep ALL notes
  # (including prior triage comments) so the agent can see what it
  # already asked and avoid re-asking. System/internal notes are
  # excluded (type != null). The current run's about-to-be-posted
  # note does not exist yet at fetch time, so it is naturally absent.
  export BOUCLE_ISSUE_NOTES
  # NOTE: forge_issue_notes paginates in the GitLab backend (--paginate,
  # per_page=100) so all notes are returned, matching the original inline
  # call. The GitHub backend paginates via _gh_api (gh api --paginate).
  BOUCLE_ISSUE_NOTES=$(forge_issue_notes "$IID" \
    | jq -r '[.[] | select(.system == false or .system == null) | "[\(.author.username // .author.name // "unknown")] \(.body)"] | reverse | .[]' 2> /dev/null || echo "")
  if [ -z "$BOUCLE_ISSUE_NOTES" ]; then
    echo "[boucle] INFO: no prior notes for issue #$IID (first triage run)."
  fi

  # Run the agent. Use `|| rc=$?` to suppress set -e so the script
  # continues to comment parsing even if the agent exits non-zero
  # (step limit, crash, etc.).
  # Record the newest triage note ID BEFORE running the agent, so we can
  # distinguish a NEW triage comment (posted by this run) from OLD ones.
  # Without this, a run where the agent doesn't post a new comment would
  # re-parse the OLD triage comment and re-apply its disposition, causing
  # a label bounce with no new question asked.
  PRE_RUN_TRIAGE_ID=$(forge_issue_notes "$IID" \
    | jq -r '[.[] | select(.body | contains("<!-- boucle:triage")) | select(.body | test("## TL;DR")) | select(.body | test("## Disposition"))] | first | .id // 0')
  rc=0
  $BOUCLE_HOME/bin/jc triage || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: $BOUCLE_HOME/bin/jc triage exited $rc — checking if a triage comment was posted anyway."
  fi

  # Parse the triage comment for Disposition and Size
  # Notes API returns notes newest-first, so `first` = newest.
  # Only consider triage comments NEWER than the one present before this
  # run (PRE_RUN_TRIAGE_ID). If the agent didn't post a new comment, this
  # returns empty, which we handle below by leaving the issue at
  # boucle:triage instead of re-applying the OLD disposition.
  COMMENT=$(forge_issue_notes "$IID" \
    | jq -r --argjson pre "$PRE_RUN_TRIAGE_ID" \
      '[.[] | select(.body | contains("<!-- boucle:triage")) | select(.body | test("## TL;DR")) | select(.body | test("## Disposition")) | select(.id > $pre)] | first | .body // ""')

  # Debug: log what we found (helps diagnose empty DISPOSITION on new forges)
  echo "triage: PRE_RUN_TRIAGE_ID=$PRE_RUN_TRIAGE_ID COMMENT_LEN=${#COMMENT} DISPOSITION_PREVIEW=$(echo "$COMMENT" | head -c 80 | tr '\n' ' ')"

  # Parse Disposition and Size from their SECTIONS only, not the whole body.
  # Scoping prevents false matches: e.g. "already" in an acceptance criterion
  # contains "ready" and would match a whole-body grep for READY.
  DISPOSITION=$(echo "$COMMENT" | awk '/^## Disposition[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE '^(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$' | head -1 | tr '[:lower:]' '[:upper:]')
  SIZE=$(echo "$COMMENT" | awk '/^## Classification[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE 'Size:[[:space:]]*[SML]' | grep -oiE '[SML][[:space:]]*$' | tr -d '[:space:]' | head -1 | tr '[:lower:]' '[:upper:]')

  # ── Log-scraping fallback (step-limit recovery) ──────────────────
  # If the agent drafted a triage comment but ran out of steps before
  # posting it (DISPOSITION empty), scrape the drafted comment from the
  # agent's stdout log and post it ourselves. The agent's post-early
  # prompt rule should prevent this, but this catches the residual case.
  if [ -z "$DISPOSITION" ]; then
    AGENT_LOG="$BOUCLE_WORKSPACE/.boucle-state/$IID/agent-output.log"
    if [ -f "$AGENT_LOG" ]; then
      # Extract the drafted triage comment: from the boucle:triage marker
      # to the end of the fenced block. The agent prints the full comment
      # (often inside a ``` fence) in its stdout when it can't call the forge CLI.
      # Marker patterns are anchored to start-of-line (AGENTS.md lesson
      # #47): a marker quoted in prose must not start the scrape.
      DRAFTED_COMMENT=$(awk '
                /^<!-- boucle:triage v=1 -->/ { found=1 }
                found { print; if (/^## Disposition/) { disp=1 } }
                disp && /^(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ { exit }
            ' "$AGENT_LOG" 2> /dev/null || echo "")
      # If no boucle:triage found, try the boucle:draft marker (first-pass
      # draft posted early per the post-early rule). Promote it to a
      # triage comment by replacing the draft marker with the triage marker.
      if [ -z "$DRAFTED_COMMENT" ]; then
        DRAFTED_COMMENT=$(awk '
                    /^<!-- boucle:draft role=triage -->/ { found=1 }
                    found { print; if (/^## Disposition/) { disp=1 } }
                    disp && /^(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ { exit }
                ' "$AGENT_LOG" 2> /dev/null || echo "")
        if [ -n "$DRAFTED_COMMENT" ]; then
          echo "[boucle] WARN: no boucle:triage in log — promoting boucle:draft to triage (step-limit fallback)."
          DRAFTED_COMMENT=$(printf '%s' "$DRAFTED_COMMENT" | sed 's|<!-- boucle:draft role=triage -->|<!-- boucle:triage v=1 -->|')
        fi
      fi
      if [ -n "$DRAFTED_COMMENT" ] && echo "$DRAFTED_COMMENT" | grep -qiE '^## Disposition'; then
        echo "[boucle] Recovering drafted triage comment from agent log (step-limit fallback)."
        # Strip leading/trailing ``` fences if the agent wrapped the comment.
        DRAFTED_COMMENT=$(echo "$DRAFTED_COMMENT" | sed '/^```$/d')
        forge_issue_note "$IID" "$DRAFTED_COMMENT"
        # Parse DIRECTLY from the promoted draft. A first-pass draft has no
        # ## TL;DR (triage.md draft format), so re-fetching through the
        # COMMENT filter — which requires ## TL;DR — would find nothing and
        # drop the recovered disposition.
        COMMENT="$DRAFTED_COMMENT"
        DISPOSITION=$(echo "$COMMENT" | awk '/^## Disposition[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE '^(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$' | head -1 | tr '[:lower:]' '[:upper:]')
        SIZE=$(echo "$COMMENT" | awk '/^## Classification[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE 'Size:[[:space:]]*[SML]' | grep -oiE '[SML][[:space:]]*$' | tr -d '[:space:]' | head -1 | tr '[:lower:]' '[:upper:]')
        # A first-pass draft may state the size in prose ("Size M ...")
        # instead of a ## Classification section — recover it so the spec
        # gate still applies for M (recovery path only).
        if [ -z "$SIZE" ]; then
          SIZE=$(echo "$COMMENT" | grep -oiE 'Size[[:space:]]+[SML]' | grep -oiE '[SML][[:space:]]*$' | tr -d '[:space:]' | head -1 | tr '[:lower:]' '[:upper:]')
        fi
        if [ -n "$DISPOSITION" ]; then
          echo "[boucle] Step-limit fallback succeeded: recovered disposition=$DISPOSITION size=${SIZE:-?}."
        else
          echo "[boucle] Step-limit fallback failed: drafted comment had no parsable Disposition."
        fi
      fi
    fi
  fi

  # ── Posted-draft promotion (log-scrape missed) ───────────────────
  # If the agent POSTED a first-pass draft (post-early rule) but the
  # log-scrape above found nothing (agent-output.log absent/moved, or the
  # draft only ever existed as the posted note), recover the disposition
  # from the posted comment itself: promote the draft marker IN PLACE and
  # parse it directly. The in-place update keeps the note id stable, so a
  # promoted draft can never be promoted twice (its body no longer carries
  # the draft marker).
  if [ -z "$DISPOSITION" ]; then
    DRAFT_NOTE_ID=$(forge_issue_notes "$IID" 2> /dev/null \
      | jq -r --argjson pre "$PRE_RUN_TRIAGE_ID" \
        '[.[] | select(.body | contains("<!-- boucle:draft role=triage -->")) | select(.body | test("## Disposition")) | select(.id > $pre)] | first | .id // ""' 2> /dev/null || echo "")
    if [ -n "$DRAFT_NOTE_ID" ]; then
      DRAFTED_COMMENT=$(forge_issue_note_get "$IID" "$DRAFT_NOTE_ID" 2> /dev/null \
        | jq -r '.body // empty' 2> /dev/null)
      if [ -n "$DRAFTED_COMMENT" ]; then
        echo "[boucle] WARN: no boucle:triage in log — promoting posted boucle:draft (note $DRAFT_NOTE_ID) to triage."
        DRAFTED_COMMENT=$(printf '%s' "$DRAFTED_COMMENT" | sed 's|<!-- boucle:draft role=triage -->|<!-- boucle:triage v=1 -->|')
        if forge_issue_note_update "$IID" "$DRAFT_NOTE_ID" "$DRAFTED_COMMENT"; then
          # Parse DIRECTLY from the promoted draft. A first-pass draft has no
          # ## TL;DR (triage.md draft format), so re-fetching through the
          # COMMENT filter — which requires ## TL;DR — would find nothing and
          # drop the recovered disposition.
          COMMENT="$DRAFTED_COMMENT"
          DISPOSITION=$(echo "$COMMENT" | awk '/^## Disposition[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE '^(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$' | head -1 | tr '[:lower:]' '[:upper:]')
          SIZE=$(echo "$COMMENT" | awk '/^## Classification[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oiE 'Size:[[:space:]]*[SML]' | grep -oiE '[SML][[:space:]]*$' | tr -d '[:space:]' | head -1 | tr '[:lower:]' '[:upper:]')
          # A first-pass draft may state the size in prose ("Size M ...")
          # instead of a ## Classification section — recover it so the spec
          # gate still applies for M (recovery path only).
          if [ -z "$SIZE" ]; then
            SIZE=$(echo "$COMMENT" | grep -oiE 'Size[[:space:]]+[SML]' | grep -oiE '[SML][[:space:]]*$' | tr -d '[:space:]' | head -1 | tr '[:lower:]' '[:upper:]')
          fi
          if [ -n "$DISPOSITION" ]; then
            echo "[boucle] Posted-draft promotion succeeded: disposition=$DISPOSITION size=${SIZE:-?}."
          else
            echo "[boucle] Posted-draft promotion failed: posted draft had no parsable Disposition."
          fi
        else
          echo "[boucle] Posted-draft promotion failed: note update rejected (note $DRAFT_NOTE_ID)." >&2
        fi
      fi
    fi
  fi

  # ── Persist triage Deliverables as obligations.md ─────────────────
  # The triage comment may carry an optional `## Deliverables` section
  # (one `- O1 — type: … — … — condition: …` line per obligation). The
  # reviewer's obligations gate + prompt injection depend on this file;
  # a missing file simply disables the gate, so this is best-effort.
  OBLIGATIONS_TEXT=$(printf '%s\n' "$COMMENT" | awk '/^## Deliverables/{f=1;next}/^## /{f=0} f' 2> /dev/null || true)
  if [ -n "$OBLIGATIONS_TEXT" ]; then
    BOUCLE_STATE_CACHE="${BOUCLE_STATE_CACHE:-${HOME}/.boucle-state-cache}"
    mkdir -p "$BOUCLE_STATE_CACHE/${BOUCLE_ISSUE}"
    {
      printf '<!-- boucle:obligations v=1 -->\n'
      printf '%s\n' "$OBLIGATIONS_TEXT"
    } > "$BOUCLE_STATE_CACHE/${BOUCLE_ISSUE}/obligations.md" 2> /dev/null || true
  fi

  # If no NEW triage comment was posted by this run (agent crashed, hit
  # step limit, or decided no new triage was needed), leave the issue at
  # boucle:triage and exit without changing labels. Re-applying the OLD
  # disposition would bounce the label (e.g. triage→needs-info) with no
  # new question asked — the exact "back to a human review although
  # no question was asked" symptom.
  if [ -z "$DISPOSITION" ]; then
    # ── Circuit breaker (silent-failure escalation) ─────────────────
    # bin/jc exits 3 when the agent produced NO posted comment AND NO
    # drafted comment (silent failure — e.g. hit OUTPUT_TOKEN_MAX
    # mid-comment before reaching the forge tool call). If we leave the
    # issue at boucle:triage, the doctor re-triggers it every 10 min
    # and the agent fails identically every time → infinite loop
    # (issue #27 on a consumer repo). Escalate to human instead
    # so a human can investigate. The issue keeps its boucle:triage
    # label for traceability but moves to boucle::status::human.
    if [ "$rc" -eq 3 ]; then
      echo "[boucle] Silent triage failure (bin/jc exit 3) — escalating issue #$IID to human to break doctor re-trigger loop."
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$IID" ":rotating_light: Triage failed silently (the agent produced no comment). Escalating to human review to break the re-trigger loop. See the job logs at $BOUCLE_JOB_URL."; then
        echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      exit 1
    elif [ "$rc" -eq 4 ]; then
      # Model/API failure (provider down or quota exhausted). bin/jc exits 4
      # when the agent log shows no activity or persistent quota errors. A
      # provider-down re-trigger fails identically every time (doctor re-trigger
      # loop, LESSONS.yml lesson #29/#30), so post a diagnostic and escalate to
      # the human instead — the same contract worker.sh honors.
      local agent_log_file log_snippet diagnostic_body
      agent_log_file="$BOUCLE_WORKSPACE/.boucle-state/$IID/agent-output.log"
      log_snippet="(log file not found or empty)"
      if [ -f "$agent_log_file" ]; then
        log_snippet=$(tail -c 2000 "$agent_log_file" 2> /dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "(log read failed)")
      fi
      diagnostic_body=$(printf '%s\n' \
        "## ⚠️ Triage — model failure (API unavailable or credits exhausted)" \
        "" \
        "The triage agent produced **no output** — the agent log is empty or shows no activity. This indicates the model API is probably **unavailable** or **out of credits**." \
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
        "- Once the model is available, re-trigger triage by re-applying the \`boucle:triage\` label and assigning the issue to the bot." \
        "" \
        "---" \
        "*Diagnostic posted by boucle (exit 4 — model/API failure).*")
      if ! forge_issue_note "$IID" "$diagnostic_body"; then
        echo "FAIL: triage model/API failure (exit 4) — diagnostic note could NOT be posted on issue #$IID. NOT escalating to boucle:human (a silent escalation is worse than a retry)." >&2
        exit 1
      fi
      set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      echo "FAIL: triage model/API failure (exit 4) — diagnostic posted on issue #$IID, escalated to human." >&2
      exit 1
    fi
    echo "[boucle] No new triage comment posted by this run — leaving issue #$IID at boucle:triage, no label change."
    exit 0
  fi

  # Collapse duplicate triage comments: replace the draft in place (PUT the
  # final body onto the draft's note id so the #note_<id> anchor stays stable)
  # and delete redundant copies. Agent may post a v2; CI replaces the first.
  # NOTE: bin/collapse-duplicate-notes is fully forge-agnostic (uses the
  # forge_* contract: forge_issue_notes / forge_issue_note_update /
  # forge_note_delete) since the GitHub-support port.
  $BOUCLE_HOME/bin/collapse-duplicate-notes triage "$BOUCLE_PROJECT_ID" "$IID" "$PRE_RUN_TRIAGE_ID" "$BOUCLE_FORGE_HOST" || true
  # Route based on disposition
  case "$DISPOSITION" in
    READY)
      if [ "$SIZE" = "L" ]; then
        set_boucle_label "$IID" "boucle:human,size:l" "boucle::status::human"
      else
        # Spec-validation gate (configurable via BOUCLE_SPEC_PROFILE).
        # Default "product" gates M, skips S. "off" never gates (legacy).
        # "strict" gates all sizes. An unknown profile falls back to "product".
        SPEC_PROFILE="${BOUCLE_SPEC_PROFILE:-product}"
        SHOULD_GATE=false
        case "$SPEC_PROFILE" in
          off) SHOULD_GATE=false ;;
          strict) SHOULD_GATE=true ;;
          product) [ "$SIZE" = "M" ] && SHOULD_GATE=true ;;
          *)
            echo "WARN: unknown BOUCLE_SPEC_PROFILE '$SPEC_PROFILE' — treating as product"
            [ "$SIZE" = "M" ] && SHOULD_GATE=true
            ;;
        esac
        # Gate-skip transparency: when the spec gate is auto-validated
        # (DND window or boucle:autonomous label), record WHY on the issue
        # so the human understands why no gate was respected. Each skip
        # path applies a flag label (visible on the board) AND posts an
        # explanatory comment. See AGENTS.md lesson "Gate-skip
        # transparency" + AGENTS.md (lesson 47).
        # Two paths flip SHOULD_GATE=false:
        #   1. boucle:autonomous label on the issue (per-issue opt-in,
        #      applied at creation — takes precedence, intentional).
        #   2. DND window active (time-based, global).
        GATE_SKIP_LABELS=""
        AUTONOMOUS=$(forge_issue_get "$IID" 2> /dev/null \
          | jq -r '(.labels // []) | map(select(. == "boucle:autonomous")) | length' 2> /dev/null || echo 0)
        if [ "$SHOULD_GATE" = "true" ] && [ "${AUTONOMOUS:-0}" -gt 0 ] 2> /dev/null; then
          echo "[boucle] 🤖 Issue flagged autonomous — auto-validating spec gate for #$IID"
          SHOULD_GATE=false
          GATE_SKIP_LABELS="boucle:autonomous"
          AUTONOMOUS_NOTE=$(printf "🤖 **Spec gate auto-approved — issue flagged autonomous**\n\nThe human spec validation was automatically approved because this issue carries the \`boucle:autonomous\` label. The loop therefore continues up to the MR without human contact.\n\nThe \`boucle:autonomous\` label remains visible on the issue (board) until the next state transition.\n\nYou can validate the MR when it is ready. To stop auto-approving the spec for this issue, remove the \`boucle:autonomous\` label.")
          forge_issue_note "$IID" "$AUTONOMOUS_NOTE"
        fi
        if [ "$SHOULD_GATE" = "true" ] && "$BOUCLE_HOME/bin/dnd" 2> /dev/null; then
          DND_START="${BOUCLE_DND_START:-22:00}"
          DND_END="${BOUCLE_DND_END:-07:00}"
          DND_TZ="${BOUCLE_DND_TZ:-UTC}"
          echo "[boucle] 🌙 DND active — auto-validating spec gate for #$IID"
          SHOULD_GATE=false
          GATE_SKIP_LABELS="${GATE_SKIP_LABELS:+$GATE_SKIP_LABELS,}boucle:dnd"
          DND_NOTE=$(printf "🌙 **Spec gate auto-approved — Do-Not-Disturb active**\n\nThe human spec validation was automatically approved because the DND window is active (%s–%s %s). The loop therefore continues up to the MR without human contact.\n\nThe \`boucle:dnd\` label was applied to the issue (visible on the board) to flag this auto-approval; it will be removed at the next state transition.\n\nYou can validate the MR when it is ready. DND is disabled by default: this auto-approval only happens when \`BOUCLE_DND_ENABLED=true\` is explicitly set in the project CI variables — set the variable to \`false\` (or remove it) to disable it." "$DND_START" "$DND_END" "$DND_TZ")
          forge_issue_note "$IID" "$DND_NOTE"
        fi
        if [ "$SHOULD_GATE" = "true" ]; then
          # Pause for author to validate the spec (acceptance criteria) before
          # the worker runs. Assign to the reporter (handles sub-issues via
          # the parent's author — resolve_reporter_id defined above) and post
          # a comment with clear next-action instructions. Do NOT trigger worker.
          set_boucle_label "$IID" "boucle:spec-review" "boucle::status::human"
          AUTHOR_ID=$(resolve_reporter_id "$IID")
          if [ -n "$AUTHOR_ID" ] && [ "$AUTHOR_ID" != "null" ]; then
            forge_issue_assign "$IID" "$AUTHOR_ID"
          fi
          # Append validation instructions to the triage comment itself so
          # the human has ONE message to read/approve (instead of a separate
          # note). Falls back to a standalone POST if the triage note cannot
          # be resolved or the PUT fails — approval detection tolerates both
          # shapes (doctor polls "React with" across all notes).
          SPEC_MSG=$(printf '## Validation\n\nReview the **TL;DR** above. If it matches what you want:\n- React with 👍 ❤️ 🎉 or 🚀 on this comment to approve, OR\n- Reply to this issue with any comment.\nIf not, reply with corrections.')
          TRIAGE_NOTE_ID=$(forge_issue_notes "$IID" 2> /dev/null \
            | jq -r '[.[] | select(.body | contains("<!-- boucle:triage") and contains("## TL;DR") and contains("## Disposition"))]
                            | sort_by(.created_at) | last | .id' 2> /dev/null || echo "")
          SPEC_MSG_APPENDED=false
          if [ -n "$TRIAGE_NOTE_ID" ]; then
            EXISTING_BODY=$(forge_issue_note_get "$IID" "$TRIAGE_NOTE_ID" 2> /dev/null \
              | jq -r '.body // empty' 2> /dev/null)
            # Idempotency guard: skip if the validation section is already
            # present (re-runs of triage on the same issue).
            if [ -n "$EXISTING_BODY" ] && ! echo "$EXISTING_BODY" | grep -q "## Validation"; then
              UPDATED_BODY=$(printf '%s\n\n%s' "$EXISTING_BODY" "$SPEC_MSG")
              if forge_issue_note_update "$IID" "$TRIAGE_NOTE_ID" "$UPDATED_BODY"; then
                SPEC_MSG_APPENDED=true
              fi
            elif [ -n "$EXISTING_BODY" ]; then
              SPEC_MSG_APPENDED=true
            fi
          fi
          if [ "$SPEC_MSG_APPENDED" != "true" ]; then
            forge_issue_note "$IID" "$SPEC_MSG"
          fi
        else
          # Include gate-skip flag labels (boucle:autonomous / boucle:dnd)
          # so the board shows WHY the gate was skipped. Consumed on the
          # next state transition (set_boucle_label strips boucle:* labels).
          set_boucle_label "$IID" "boucle:todo,size:$(echo $SIZE | tr '[:upper:]' '[:lower:]')${GATE_SKIP_LABELS:+,$GATE_SKIP_LABELS}" "boucle::status::bot"
          # Dependency gate FIRST: a blocked issue is not "ready",
          # so it should not count against the capacity cap.
          if ! check_dependencies_and_gate "$IID"; then
            : # blocked — note already posted, label already set
          else
            # Concurrency cap: defer worker trigger if too many issues are already working.
            MAX_PARALLEL="${BOUCLE_MAX_PARALLEL_ISSUES:-0}"
            WORKING_COUNT=0
            if [ "$MAX_PARALLEL" -gt 0 ] 2> /dev/null; then
              WORKING_COUNT=$(forge_issue_count_by_label "boucle:working" "opened" 2> /dev/null || echo 0)
              if [ "$WORKING_COUNT" -ge "$MAX_PARALLEL" ]; then
                echo "[boucle] Max parallel issues ($MAX_PARALLEL) reached — $WORKING_COUNT already working. Deferring #$IID (stays at boucle:todo, doctor will re-trigger when a slot frees)."
                forge_issue_note "$IID" "⏳ Worker deferred — $WORKING_COUNT issues already in progress (cap: $MAX_PARALLEL). Will start automatically when a slot frees up."
                # Do NOT chain to worker — leave at boucle:todo. Doctor recovers it.
              else
                # Chain to worker
                chain_to_role "$IID" "worker"
              fi
            else
              # Chain to worker (cap disabled)
              chain_to_role "$IID" "worker"
            fi
          fi
        fi
      fi

      # ── Visual preview (systematic for UI/UX issues) ────────────────
      # Fires for ALL READY dispositions (Size S/M/L, gated or not).
      # The triage agent writes RENDER_REQUEST + preview.html for
      # UI/UX issues (mandatory per triage.md). Non-UI/UX issues have
      # no RENDER_REQUEST → block is a no-op (zero Chromium cost).
      # Failure is isolated: fallback note, never blocks the loop.
      # Idempotent: RENDER_REQUEST deleted after successful embed.
      PREVIEW_HTML="$BOUCLE_WORKSPACE/.boucle-state/$IID/preview.html"
      RENDER_REQUEST_FILE="$BOUCLE_WORKSPACE/.boucle-state/$IID/RENDER_REQUEST"

      if [ "${BOUCLE_PREVIEW_DISABLE:-false}" != "true" ] && [ -s "$RENDER_REQUEST_FILE" ] && [ -s "$PREVIEW_HTML" ]; then
        echo "[boucle] RENDER_REQUEST found — attempting visual preview"

        # 1. Resolve the triage comment note_id (separate fetch so we
        #    don't disturb the existing comment parse).
        TRIAGE_NOTE_ID=$(forge_issue_notes "$IID" 2> /dev/null \
          | jq -r '[.[] | select(.body | contains("<!-- boucle:triage") and contains("## TL;DR") and contains("## Disposition"))]
                        | sort_by(.created_at) | last | .id' 2> /dev/null || echo "")

        if [ -z "$TRIAGE_NOTE_ID" ]; then
          echo "[boucle] WARN: triage comment not found — cannot embed preview"
        else
          # 2. Install Chromium + puppeteer-core (only now, in a per-job dir).
          NPM_TMP="/tmp/npm-${CI_JOB_ID:-$$}"
          RENDER_STDERR="$BOUCLE_WORKSPACE/.boucle-state/$IID/render-stderr.log"
          mkdir -p "$(dirname "$RENDER_STDERR")"
          if npm install --prefix "$NPM_TMP" puppeteer-core @sparticuz/chromium > /dev/null 2>&1; then
            # 3. Render preview.html → preview.png (1280x800, fullPage).
            #    NODE_PATH=$NPM_TMP/node_modules so the script (bin/) resolves
            #    the modules installed in the per-job dir.
            PREVIEW_PNG="$BOUCLE_WORKSPACE/.boucle-state/$IID/preview.png"
            #    The renderer emits one PNG per BOUCLE_PREVIEW_VIEWPORTS
            #    entry (default: one phone, one desktop) and prints each
            #    path on stdout. A spec approved on a desktop-only shot
            #    hides exactly the class of regression this audience
            #    cannot read from a diff.
            #    Capture stderr to a log file (CI artifact) so render
            #    failures are diagnosable. stdout (produced PNG paths) is
            #    captured in RENDERED_PNGS as before. Lesson: never swallow
            #    render errors.
            RENDERED_PNGS=$(NODE_PATH="$NPM_TMP/node_modules" node "$BOUCLE_HOME/bin/render-preview.cjs" "$PREVIEW_HTML" "$PREVIEW_PNG" 2> "$RENDER_STDERR" || true)
            if [ -n "$RENDERED_PNGS" ]; then
              # 4. Upload each PNG via the forge contract. The backend
              #    returns the embeddable path (GitLab: /uploads/...;
              #    GitHub: no upload API → empty, handled below).
              #    Total bytes respect BOUCLE_IMAGE_TOTAL_MAX_BYTES: N
              #    viewports must not blow the per-issue attachment budget.
              IMG_URL=""
              PREVIEW_BYTES=0
              PREVIEW_MAX="${BOUCLE_IMAGE_TOTAL_MAX_BYTES:-52428800}"
              while IFS= read -r png; do
                [ -s "$png" ] || continue
                png_size=$(wc -c < "$png" 2> /dev/null || echo 0)
                if [ "$((PREVIEW_BYTES + png_size))" -gt "$PREVIEW_MAX" ]; then
                  echo "[boucle] WARN: viewport $(basename "$png") skipped — would exceed BOUCLE_IMAGE_TOTAL_MAX_BYTES"
                  continue
                fi
                # "preview-390x844.png" → "390x844" → a label the human reads.
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
                img_path=$(forge_attachment_upload "$IID" "$png" "$(basename "$png")" 2> /dev/null || true)
                if [ -n "$img_path" ]; then
                  PREVIEW_BYTES=$((PREVIEW_BYTES + png_size))
                  IMG_URL="${IMG_URL}**${label}**

![Preview ${dims}](${img_path})

"
                fi
              done <<< "$RENDERED_PNGS"

              if [ -n "$IMG_URL" ]; then
                # 5. Fetch the existing comment, insert Preview right after
                #    the TL;DR section (first thing the human sees), PUT.
                #    Guard: if EXISTING_BODY is empty (fetch failed), do NOT
                #    PUT — otherwise we overwrite the entire triage comment
                #    (losing the boucle:triage marker + criteria + disposition).
                EXISTING_BODY=$(forge_issue_note_get "$IID" "$TRIAGE_NOTE_ID" 2> /dev/null \
                  | jq -r '.body // empty' 2> /dev/null)
                if [ -n "$EXISTING_BODY" ]; then
                  NEW_BODY=$(printf '%s\n' "$EXISTING_BODY" | awk -v img="$IMG_URL" '
                                        /^## TL;DR/ { in_tldr=1; print; next }
                                        in_tldr && /^## / && !inserted {
                                            print "## Preview"; print img; print ""; inserted=1; in_tldr=0
                                        }
                                        { print }
                                        END { if (!inserted) { print ""; print "## Preview"; print img } }
                                    ')
                  if forge_issue_note_update "$IID" "$TRIAGE_NOTE_ID" "$NEW_BODY"; then
                    # 6. Idempotence: delete RENDER_REQUEST (no re-render on retry).
                    rm -f "$RENDER_REQUEST_FILE"
                    echo "[boucle] Visual preview embedded in triage comment #$TRIAGE_NOTE_ID"
                  else
                    echo "[boucle] WARN: PUT notes failed — RENDER_REQUEST kept for retry"
                  fi
                else
                  echo "[boucle] WARN: existing comment body empty — posting fallback note"
                  forge_issue_note "$IID" "Preview unavailable (comment read failed) — validate from the TL;DR."
                fi
              else
                echo "[boucle] WARN: PNG upload failed — posting fallback note"
                forge_issue_note "$IID" "Preview unavailable (upload failed) — validate from the TL;DR."
              fi
            else
              echo "[boucle] WARN: Chromium render failed — posting fallback note"
              # Surface the render stderr in the job trace for diagnosis.
              if [ -s "$RENDER_STDERR" ]; then
                echo "[boucle:render-stderr] last 50 lines of render error:"
                tail -n 50 "$RENDER_STDERR" | sed 's/^/[boucle:render-stderr] /' >&2
              fi
              forge_issue_note "$IID" "Preview unavailable (render failed) — validate from the TL;DR."
            fi
          else
            echo "[boucle] WARN: Chromium install failed — posting fallback note"
            forge_issue_note "$IID" "Preview unavailable (Chromium unavailable) — validate from the TL;DR."
            # Chain to worker (cap disabled)
            chain_to_role "$IID" "worker"
          fi
        fi
      fi
      ;;
    NEEDS-INFO)
      set_boucle_label "$IID" "boucle:needs-info" "boucle::status::human"
      # Assign the issue to its reporter (author) so they're notified
      # and know to answer the blocking questions. For a sub-issue
      # created by the bot via NEEDS-SPLIT, the author is up-bot — so
      # resolve the PARENT issue's author instead (the human who filed
      # the original request). The loop pauses here until the reporter
      # replies, which re-triggers triage.
      AUTHOR_ID=$(resolve_reporter_id "$IID")
      if [ -n "$AUTHOR_ID" ] && [ "$AUTHOR_ID" != "null" ]; then
        forge_issue_assign "$IID" "$AUTHOR_ID"
      fi
      ;;
    NEEDS-SPLIT)
      # Idempotency guard: if the parent already has children via the
      # hierarchy API, the split was already done — skip to
      # avoid duplicate sub-issues. Fall back to the legacy split-parent
      # marker comment for data produced by older boucle versions.
      CHILDREN_COUNT=$(get_work_item_children "$IID" | jq 'length' 2> /dev/null || echo 0)
      if [ "${CHILDREN_COUNT:-0}" -gt 0 ]; then
        echo "Parent #$IID already has $CHILDREN_COUNT child work item(s) — skipping split (idempotency guard)"
        exit 0
      fi
      # Legacy fallback: check for the old split-parent marker comment
      EXISTING_SPLIT=$(forge_issue_notes "$IID" \
        | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | length' 2> /dev/null || echo 0)
      if [ "${EXISTING_SPLIT:-0}" -gt 0 ]; then
        echo "Parent #$IID already has a legacy boucle:split-parent marker — skipping split (idempotency guard)"
        exit 0
      fi
      # Parse sub-issues from the triage comment. Format:
      #   ## Sub-issues
      #   <!-- boucle:sub-issue v=1 -->
      #   ### Sub-issue 1: <title>
      #   <body...>
      #   Size: S | M
      #   ### Sub-issue 2: ...
      SUBISSUES_SECTION=$(echo "$COMMENT" | sed -n '/^## Sub-issues/,/^## /p' | sed -e '${/^## /d}')
      # If the selected comment has no Sub-issues section, the agent may have
      # posted a truncated duplicate. Search ALL triage comments (newest-first)
      # for one that has a parseable Sub-issues section.
      if [ -z "$SUBISSUES_SECTION" ] || ! echo "$SUBISSUES_SECTION" | grep -qE '^### Sub-issue [0-9]+[[:space:]]*:'; then
        echo "Selected triage comment has no Sub-issues section — searching all triage comments..."
        SUBISSUES_SECTION=$(forge_issue_notes "$IID" \
          | jq -r '[.[] | select(.body | contains("<!-- boucle:triage")) | select(.body | test("### Sub-issue [0-9]+[[:space:]]*:"))] | first | .body' \
          | sed -n '/^## Sub-issues/,/^## /p' | sed -e '${/^## /d}')
      fi
      # Skip if still no parseable sub-issues after searching all comments
      if [ -z "$SUBISSUES_SECTION" ] || ! echo "$SUBISSUES_SECTION" | grep -qE '^### Sub-issue [0-9]+[[:space:]]*:'; then
        echo "NEEDS-SPLIT but no parseable sub-issues — falling back to boucle:human"
        # Note BEFORE the terminal label — never a muted boucle:human.
        if ! forge_issue_note "$IID" "Triage requested NEEDS-SPLIT but no parseable sub-issues were found in the triage comment. Please split this issue manually."; then
          echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
          exit 1
        fi
        set_boucle_label "$IID" "boucle:human" "boucle::status::human"
        exit 0
      fi

      # Extract parent context (title + URL) for the sub-issue body
      PARENT_DATA=$(forge_issue_get "$IID")
      PARENT_TITLE=$(echo "$PARENT_DATA" | jq -r '.title')
      PARENT_URL=$(echo "$PARENT_DATA" | jq -r '.web_url')
      PARENT_IID="$IID"

      CREATED_IIDS=""
      # awk splits the section into records, one per sub-issue.
      # First line of each record is "TITLE:<title>"; following lines are body;
      # last non-empty line should be "Size: X".
      SUBISSUE_COUNT=0
      PARSE_FAILURES=0
      echo "$SUBISSUES_SECTION" | awk '
                BEGIN { rec = 0 }
                /^<!-- boucle:sub-issue/ { next }
                /^### Sub-issue [0-9]+[[:space:]]*:/ {
                    if (rec > 0) { print "---END---" }
                    rec++
                    sub(/^### Sub-issue [0-9]+[[:space:]]*:[[:space:]]*/, "")
                    print "TITLE:" $0
                    next
                }
                /^## Sub-issues/ { next }
                # Capture "Depends on: #N, #M" as a DEPS: record prefix.
                # N and M are 1-based sibling indices (NOT GitLab IIDs).
                /^Depends on:[[:space:]]*#/ {
                    # Extract the #-prefixed numbers, strip #, comma-join.
                    line = $0
                    sub(/^Depends on:[[:space:]]*/, "", line)
                    gsub(/[^0-9,[:space:]]/, "", line)
                    gsub(/[[:space:]]/, "", line)
                    print "DEPS:" line
                    next
                }
                { print }
                END { if (rec > 0) print "---END---" }
            ' > "/tmp/subissues-${CI_JOB_ID:-$$}.parsed"

      while IFS= read -r line; do
        if [ "$line" = "---END---" ]; then
          # Finalize the current sub-issue
          if [ -n "$CUR_TITLE" ]; then
            # Strip the Size: line from the body
            CUR_BODY_NO_SIZE=$(echo "$CUR_BODY" | sed '/^Size:[[:space:]]*[SML]/d')
            CUR_BODY_NO_SIZE=$(echo "$CUR_BODY_NO_SIZE" | sed '/^Depends on:[[:space:]]*#/d')
            # Default size to M if not present
            CUR_SIZE="${CUR_SIZE_RAW:-M}"
            # Validate: if "- [ ]" appears mid-line (not at start), newlines
            # were stripped — the agent posted a single-line body that won't
            # render as markdown. Skip creation so we fall back to human
            # instead of shipping an unrenderable sub-issue.
            if echo "$CUR_BODY_NO_SIZE" | grep -qE '[^[:space:]]- \[ \]'; then
              echo "WARN: sub-issue '$CUR_TITLE' has checkbox markers not at line start (newlines stripped) — skipping creation"
              PARSE_FAILURES=$((PARSE_FAILURES + 1))
            else
              # Build the sub-issue body with parent reference (single-line to keep YAML literal block happy)
              SUB_BODY=$(printf 'Split from #%s (%s).\n\n%s\n\n## Parent issue\n#%s — %s' "$PARENT_IID" "$PARENT_TITLE" "$CUR_BODY_NO_SIZE" "$PARENT_IID" "$PARENT_URL")
              SUB_SIZE_LOWER=$(echo "$CUR_SIZE" | tr '[:upper:]' '[:lower:]')
              # Validate: only S or M
              if [ "$CUR_SIZE" != "S" ] && [ "$CUR_SIZE" != "M" ]; then
                echo "WARN: sub-issue '$CUR_TITLE' has size '$CUR_SIZE' (not S/M) — defaulting to M"
                CUR_SIZE="M"
                SUB_SIZE_LOWER="m"
              fi
              echo "Creating sub-issue: $CUR_TITLE (Size: $CUR_SIZE)"
              # TODO: forge_issue_create returns only the IID (not the
              # full API JSON the original parsed); the failure message
              # below loses the API response body.
              NEW_IID=$(forge_issue_create "$CUR_TITLE" "$SUB_BODY" "boucle:triage,boucle::status::bot,size:$SUB_SIZE_LOWER")
              if [ -n "$NEW_IID" ] && [ "$NEW_IID" != "null" ]; then
                CREATED_IIDS="${CREATED_IIDS:+$CREATED_IIDS,}$NEW_IID"
                SUBISSUE_COUNT=$((SUBISSUE_COUNT + 1))
                echo "  → created #$NEW_IID"
                # Assign the sub-issue to the bot (it's on the bot side from
                # creation). Best-effort: skip silently if BOUCLE_BOT_ID unset.
                # NOTE: the original hard-failed (exit 1) when the curl
                # failed with BOUCLE_BOT_ID set; forge_issue_assign is
                # best-effort per the contract, so that abort is dropped.
                if [ -n "${BOUCLE_BOT_ID:-}" ]; then
                  forge_issue_assign "$NEW_IID" "$BOUCLE_BOT_ID"
                fi
                # Set the parent via the forge contract. The backend
                # tries the work-items hierarchy API first (real
                # "Child items" relationship — needs the parent's
                # GLOBAL work-item ID, not the project-scoped IID);
                # if unavailable (work_item_rest_api feature flag
                # disabled on self-managed GitLab), it falls back to
                # a REST relates_to issue link (visible under
                # "Linked items" on the parent). Final fallback: the
                # ## Parent issue body text provides navigation.
                forge_work_item_link_parent "$NEW_IID" "$PARENT_IID"
                # Trigger triage directly via trigger API (bot-created issues would
                # hit the anti-loop guard in dispatch because ACTOR=up-bot).
                chain_to_role "$NEW_IID" ""
              else
                echo "  → FAIL to create sub-issue: ${NEW_IID:-empty response from forge_issue_create}" >&2
                PARSE_FAILURES=$((PARSE_FAILURES + 1))
              fi
            fi
          fi
          # Reset for next record
          CUR_TITLE=""
          CUR_BODY=""
          CUR_SIZE_RAW=""
          CUR_DEPS=""
        elif [[ "$line" == TITLE:* ]]; then
          CUR_TITLE="${line#TITLE:}"
          CUR_BODY=""
          CUR_SIZE_RAW=""
          CUR_DEPS=""
        elif [[ "$line" == DEPS:* ]]; then
          CUR_DEPS="${line#DEPS:}"
        else
          # Append line to body. Direct assignment (not command
          # substitution) preserves the trailing newline: $(...) strips
          # trailing newlines, which would collapse the whole body to a
          # single line and make the mid-line checkbox guard false-positive
          # on "Acceptance criteria:- [ ] ..." (colon is non-space before
          # "- [ ]"). $'\n' keeps the newline literal.
          CUR_BODY="${CUR_BODY}${line}"$'\n'
          # Capture Size: line
          if [[ "$line" =~ ^Size:[[:space:]]*([SML]) ]]; then
            CUR_SIZE_RAW="${BASH_REMATCH[1]}"
          fi
        fi
      done < "/tmp/subissues-${CI_JOB_ID:-$$}.parsed"

      # ── Resolve dependencies (index → IID) and update sub-issue bodies ──
      # CUR_DEPS holds 1-based sibling indices (e.g. "2"). Map them to
      # real IIDs via the creation order. Then append a "## Depends on"
      # section + the boucle:depends-on marker to each dependent sub-issue.
      # Cycle detection: build the dep graph and reject cycles → human.
      #
      # CREATED_IIDS is a comma-separated list in creation order, so
      # index N → the N-th IID in that list.
      if [ -n "$CREATED_IIDS" ] && [ "$SUBISSUE_COUNT" -gt 0 ]; then
        # Source the depends-on lib for detect_cycle + resolve_dep_indices.
        source "$BOUCLE_HOME/bin/lib/depends-on.sh"

        # Re-parse to get per-sub-issue deps (we lost CUR_DEPS across the
        # loop boundary, so re-derive from the per-job subissues file).
        declare -a DEPS_BY_INDEX=()
        CUR_IDX=0
        while IFS= read -r line; do
          if [ "$line" = "---END---" ]; then
            CUR_IDX=$((CUR_IDX + 1))
          elif [[ "$line" == DEPS:* ]]; then
            DEPS_BY_INDEX[$CUR_IDX]="${line#DEPS:}"
          fi
        done < "/tmp/subissues-${CI_JOB_ID:-$$}.parsed"

        # Build graph string for detect_cycle: "0:1;1:0" where nodes are
        # 0-based array indices and deps are 0-based space-separated.
        # Include ALL nodes (even those with no deps) so detect_cycle
        # has the correct node count.
        GRAPH_STR=""
        for ((gi = 0; gi < SUBISSUE_COUNT; gi++)); do
          raw="${DEPS_BY_INDEX[$gi]:-}"
          resolved=""
          for d in $(echo "$raw" | tr ',' ' '); do
            if [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -ge 1 ] && [ "$d" -le "$SUBISSUE_COUNT" ]; then
              resolved="$resolved $((d - 1))"
            else
              echo "WARN: sub-issue $((gi + 1)) depends on #$d which is out of range (1..$SUBISSUE_COUNT) — dropping that dep"
            fi
          done
          GRAPH_STR="${GRAPH_STR:+$GRAPH_STR;}$gi:${resolved# }"
        done

        if detect_cycle "$GRAPH_STR"; then
          echo "FAIL: dependency cycle detected involving sub-issues ($CREATED_IIDS)"
          # Note BEFORE the terminal label — never a muted boucle:human.
          if ! forge_issue_note "$IID" "⚠️ Triage declared a dependency cycle between sub-issues ($CREATED_IIDS). The sub-issues were created but their dependencies could not be resolved. Please fix the dependencies manually."; then
            echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
            exit 1
          fi
          set_boucle_label "$IID" "boucle:human" "boucle::status::human"
          # Still mark split so dispatch doesn't re-triage the parent.
          set_boucle_label "$IID" "boucle:split" "boucle::status::bot"
          exit 0
        fi

        # Second pass: update each dependent sub-issue's description.
        # DEPS_BY_INDEX is 0-based (CUR_IDX starts at 0), so i is the
        # 0-based sub-issue index. The dep indices stored are 1-based
        # sibling indices (from the triage comment), which resolve_dep_indices
        # maps to real IIDs.
        for i in "${!DEPS_BY_INDEX[@]}"; do
          raw="${DEPS_BY_INDEX[$i]:-}"
          [ -z "$raw" ] && continue
          # Resolve indices to IIDs using the lib function.
          resolved_iids=$(resolve_dep_indices "$raw" "$CREATED_IIDS")
          [ -z "$resolved_iids" ] && continue
          cur_iid=$(echo "$CREATED_IIDS" | cut -d',' -f$((i + 1)))
          [ -z "$cur_iid" ] && continue
          # Fetch current description, append the Depends on section.
          cur_desc=$(forge_issue_get "$cur_iid" 2> /dev/null | jq -r '.description // empty' 2> /dev/null || echo "")
          if [ -z "$cur_desc" ]; then
            echo "WARN: can't fetch description of #$cur_iid to append deps — skipping"
            continue
          fi
          # Human-readable #N list + machine marker.
          human_list=$(echo "$resolved_iids" | sed 's/,/, #/g; s/^/#/')
          new_desc=$(printf '%s\n\n## Depends on\n%s\n<!-- boucle:depends-on iids=%s -->' "$cur_desc" "$human_list" "$resolved_iids")
          forge_issue_update "$cur_iid" "description" "$new_desc" \
            || echo "WARN: failed to update #$cur_iid description with deps"
          echo "  → #$cur_iid depends on $resolved_iids"
        done
      fi

      if [ "$SUBISSUE_COUNT" -eq 0 ]; then
        echo "NEEDS-SPLIT but zero sub-issues created — falling back to boucle:human"
        # Note BEFORE the terminal label — never a muted boucle:human.
        if ! forge_issue_note "$IID" "Triage requested NEEDS-SPLIT but no sub-issues could be created from the triage comment. Please split this issue manually."; then
          echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
          exit 1
        fi
        set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      else
        # Mark the parent boucle:split FIRST so dispatch and doctor stop
        # re-triaging it even if the comment POST below fails. The parent
        # stays open and is closed by maybe_close_parent() (e2e) or the
        # doctor's split-parent cascade when all sub-issues close.
        set_boucle_label "$IID" "boucle:split" "boucle::status::bot"
        # Post ONE merged comment: human-readable sub-issue list + the
        # machine-readable split-parent marker. Merging makes the two
        # atomic (single POST) — a job failure cannot leave a human
        # comment without its marker, which caused duplicate "Split into"
        # comments and duplicate sub-issues on retry. The marker is parsed
        # by maybe_close_parent's legacy fallback path when the hierarchy
        # API is unavailable (feature flag disabled on self-managed GitLab).
        SPLIT_MSG=$(printf 'Split into: #%s.\n\nParent stays open until all sub-issues close. The loop closes this parent automatically when the last sub-issue completes.\n\n<!-- boucle:split-parent iids=%s -->' "$(echo "$CREATED_IIDS" | sed 's/,/, #/g')" "$CREATED_IIDS")
        forge_issue_note "$IID" "$SPLIT_MSG"
        echo "Split parent #$IID into $SUBISSUE_COUNT sub-issue(s): $CREATED_IIDS (parent marked boucle:split)"
        if [ "$PARSE_FAILURES" -gt 0 ]; then
          echo "WARN: $PARSE_FAILURES sub-issue(s) failed to create"
        fi
      fi
      rm -f "/tmp/subissues-${CI_JOB_ID:-$$}.parsed"
      ;;
    *)
      echo "Unparsable disposition: $DISPOSITION → routing to human"
      # Note BEFORE the terminal label — never a muted boucle:human.
      if ! forge_issue_note "$IID" "⚠️ Triage disposition was not parsable — the issue could not be routed automatically. Human intervention needed."; then
        echo "FAIL: escalation note could not be posted on issue #$IID — NOT escalating to boucle:human (retry instead of muting)." >&2
        exit 1
      fi
      set_boucle_label "$IID" "boucle:human" "boucle::status::human"
      ;;
  esac

  # Assert: triage comment exists and disposition parsable
  if [ -z "$DISPOSITION" ]; then
    echo "FAIL: disposition not parsable" >&2
    exit 1
  fi
}
