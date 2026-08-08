#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle.sh — shared helpers for the boucle CI loop.
#
# This is the single source of truth for all shell helpers that were
# previously copy-pasted into each .gitlab-ci.yml job's script block.
# Sourced by the default.before_script (one line: source lib/boucle.sh).
#
# Conventions:
#   - All GitLab API calls use $BOUCLE_FORGE_HOST / $CI_PROJECT_ID
#     (the doctor job previously used $HOST/$PID aliases — normalized).
#   - Error-suppressing variant (set +e, 2>/dev/null, || true) is used
#     so transient API errors never kill the loop.
#   - Functions are idempotent: set_boucle_label skips no-op writes.

# ── Label management ────────────────────────────────────────────────────

# set_boucle_label <iid> <new_detail_label> <gross_status_label>
#
# Preserve non-boucle: labels, strip old boucle: detail + boucle::status::*
# labels, then write <new> + <gross>. Idempotent: skips the PUT when every
# label in "$new,$gross" is already on the issue (GitLab records a Resource
# Label Event on every PUT, even no-ops).
#
# Side effect: reassigns the issue.
#   - boucle::status::bot  → assign to the bot (BOUCLE_BOT_ID, best-effort).
#   - boucle::status::human → assign to the human reporter (walks up the
#     parent chain via resolve_reporter_id to skip bot-authored sub-issues).
set_boucle_label() {
  local iid="$1" new="$2" gross="$3"
  local current resp current_all
  resp=$(
    set +e
    glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$iid" 2> /dev/null
  ) || true
  current=$(echo "$resp" | jq -r '.labels | map(select(startswith("boucle:") | not)) | join(",")' 2> /dev/null) || true
  current_all=$(echo "$resp" | jq -r '.labels | join(",")' 2> /dev/null) || true
  # Idempotence: skip the PUT when every label in "$new,$gross" is already
  # on the issue. GitLab records a Resource Label Event on every PUT even
  # if the label set is unchanged — this guard prevents the no-op writes
  # that surface as spurious "status changes" on the board.
  local all_present=true lbl
  for lbl in $(echo "$new,$gross" | tr ',' ' '); do
    [ -z "$lbl" ] && continue
    echo "$current_all" | tr ',' '\n' | grep -qx "$lbl" || {
      all_present=false
      break
    }
  done
  [ "$all_present" = true ] && return 0
  local merged="${current:+$current,}$new,$gross"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$CI_PROJECT_ID/issues/$iid" -f labels="$merged" > /dev/null 2>&1 || true
  # When the issue moves to the bot side, assign it to the bot user so
  # the board reflects who owns the next action. Best-effort: skip
  # silently if BOUCLE_BOT_ID is unset (backward compat).
  if [ "$gross" = "boucle::status::bot" ] && [ -n "${BOUCLE_BOT_ID:-}" ]; then
    curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/issues/$iid" \
      --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
      --data-urlencode "assignee_ids[]=$BOUCLE_BOT_ID" 2> /dev/null || { if [ -n "${BOUCLE_BOT_ID:-}" ]; then
        echo "ERROR: bot reassign failed for issue (BOUCLE_BOT_ID=$BOUCLE_BOT_ID set but API call failed)" >&2
        exit 1
      fi; }
  elif [ "$gross" = "boucle::status::human" ]; then
    # Reassign the issue to the human reporter (walks up parent chain to skip
    # bot-authored sub-issues). Best-effort: skip silently if resolve fails.
    local human_id
    human_id=$(resolve_reporter_id "$iid" 2> /dev/null)
    if [ -n "$human_id" ] && [ "$human_id" != "null" ] && [ "$human_id" != "${BOUCLE_BOT_ID:-}" ]; then
      curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/issues/$iid" \
        --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
        --data-urlencode "assignee_ids[]=$human_id" 2> /dev/null || true
    fi
  fi
}

# ── Issue / hierarchy helpers ───────────────────────────────────────────

# resolve_reporter_id <iid>
#
# Walk up the parent-issue chain until we find a non-bot author.
# Returns the GitLab user ID of the original human reporter.
# Bot-authored sub-issues (created by up-bot) are skipped by matching
# BOUCLE_BOT_USERNAME (default "up-bot"). Max depth 10 to prevent loops.
resolve_reporter_id() {
  local iid="$1" data parent_iid parent_data reporter_id author_username
  local bot_user="${BOUCLE_BOT_USERNAME:-up-bot}"
  local depth=0 max_depth=10
  data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$iid" 2> /dev/null) || {
    echo ""
    return
  }
  reporter_id=$(printf '%s' "$data" | jq -r '.author.id // empty')
  author_username=$(printf '%s' "$data" | jq -r '.author.username // empty')
  # Walk up the parent chain until we find a non-bot author.
  while [ "$author_username" = "$bot_user" ] && [ "$depth" -lt "$max_depth" ]; do
    parent_iid=$(printf '%s' "$data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    [ -z "$parent_iid" ] && break
    parent_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$parent_iid" 2> /dev/null) || break
    reporter_id=$(printf '%s' "$parent_data" | jq -r '.author.id // empty')
    author_username=$(printf '%s' "$parent_data" | jq -r '.author.username // empty')
    data="$parent_data"
    depth=$((depth + 1))
  done
  echo "$reporter_id"
}

# get_work_item_global_id <iid>
#
# Fetch the global work-item ID for a project issue. Returns empty on
# failure (403, non-JSON, missing .id field). Used by triage to convert
# issue IIDs into work-item global IDs for the hierarchy API.
get_work_item_global_id() {
  local iid="$1" wi_data out
  wi_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/-/work_items/$iid" 2> /dev/null) || {
    echo ""
    return
  }
  # Only accept a JSON object that actually has an .id field; anything
  # else (403 error object, empty, non-JSON) is treated as a miss.
  out=$(printf '%s' "$wi_data" | jq -r 'if (type == "object" and has("id")) then .id else empty end' 2> /dev/null)
  printf '%s' "$out"
}

# get_work_item_children <parent_iid>
#
# List child work items of a parent via the hierarchy API.
# Returns a JSON array (empty array on failure). Each child has
# .iid, .state ("opened"|"closed"), .title.
# NOTE: glab may exit 0 on HTTP 403 (work_item_rest_api feature flag
# disabled) and print the error JSON to stdout. A 403 error object is
# a JSON OBJECT, not an array — jq 'length' on an object returns its
# key count (1), which would falsely trip the idempotency guard. We
# therefore validate that the response is a JSON ARRAY and return []
# otherwise.
get_work_item_children() {
  local parent_iid="$1" children out
  children=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/-/work_items/$parent_iid/children" 2> /dev/null) || {
    echo "[]"
    return
  }
  # Only pass through genuine arrays; coerce anything else (403 error
  # object, empty, non-JSON) to []. Capture jq output so empty input
  # (jq emits nothing, exits 0) still yields [].
  out=$(printf '%s' "$children" | jq -c 'if type == "array" then . else [] end' 2> /dev/null)
  printf '%s' "${out:-[]}"
}

# close_issue <iid>
#
# Close a GitLab issue. Best-effort (boucle:done is a board label, not
# a close state — closing is a separate lifecycle event).
close_issue() {
  local iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$CI_PROJECT_ID/issues/$iid" \
    -f state_event=close > /dev/null 2>&1 || true
}

# maybe_close_parent <child_iid>
#
# Parent-close cascade: if this issue is a sub-issue (has a "## Parent
# issue" section in its description), check whether ALL siblings are
# closed. If so, close the parent too.
#
# Sibling discovery order:
#   1. Work-items hierarchy API (source of truth — includes .state).
#   2. Legacy split-parent marker comment (older boucle versions).
#   3. REST issue links API (fallback for very old data).
maybe_close_parent() {
  local child_iid="$1"
  # Parse parent IID from the sub-issue body ("## Parent issue\n#N — <url>")
  local child_data parent_iid
  child_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$child_iid" 2> /dev/null) || {
    echo "maybe_close_parent: can't fetch issue #$child_iid — skipping."
    return 0
  }
  parent_iid=$(echo "$child_data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
  if [ -z "$parent_iid" ]; then
    echo "maybe_close_parent: no parent issue link in #$child_iid — not a sub-issue."
    return 0
  fi

  # Fetch parent; skip if already closed
  local parent_data parent_state
  parent_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$parent_iid" 2> /dev/null) || {
    echo "maybe_close_parent: can't fetch parent #$parent_iid — skipping."
    return 0
  }
  parent_state=$(echo "$parent_data" | jq -r '.state')
  if [ "$parent_state" = "closed" ]; then
    echo "maybe_close_parent: parent #$parent_iid already closed."
    return 0
  fi

  # Check children via the work-items hierarchy API (source of truth).
  # The children endpoint returns each child's .state directly, so we
  # can check all siblings in one call. Fall back to the legacy
  # split-parent marker comment and REST links for data produced by
  # older boucle versions that didn't use the hierarchy API.
  local children_data sibling_iids
  children_data=$(get_work_item_children "$parent_iid")
  sibling_iids=$(echo "$children_data" | jq -r '[.[].iid] | join(",")' 2> /dev/null)
  if [ -z "$sibling_iids" ]; then
    # No children via hierarchy API — fall back to legacy marker comment
    local parent_notes
    parent_notes=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$parent_iid/notes" 2> /dev/null) || {
      echo "maybe_close_parent: can't fetch parent notes — skipping."
      return 0
    }
    sibling_iids=$(echo "$parent_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
    if [ -z "$sibling_iids" ]; then
      # No legacy marker either — fall back to REST issue links API
      echo "maybe_close_parent: no children via hierarchy API and no split-parent marker on #$parent_iid — checking REST links..."
      local links_data
      links_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$parent_iid/links" 2> /dev/null) || links_data="[]"
      sibling_iids=$(echo "$links_data" | jq -r '[.[] | select(.iid != null) | .iid] | join(",")')
      if [ -z "$sibling_iids" ]; then
        echo "maybe_close_parent: parent #$parent_iid has no children, no marker, and no REST links — can't check siblings."
        return 0
      fi
      echo "maybe_close_parent: found $sibling_iids via REST links fallback"
      # REST links fallback: check each sibling state individually
      local all_closed=true iid
      for iid in $(echo "$sibling_iids" | tr ',' ' '); do
        local sib_state
        sib_state=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$iid" 2> /dev/null | jq -r '.state // "unknown"')
        if [ "$sib_state" != "closed" ]; then
          echo "maybe_close_parent: sibling #$iid is $sib_state — parent #$parent_iid stays open."
          all_closed=false
          break
        fi
      done
      if [ "$all_closed" = "true" ]; then
        echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
        close_issue "$parent_iid"
      fi
      return 0
    fi
    echo "maybe_close_parent: found $sibling_iids via legacy split-parent marker"
    # Legacy marker fallback: check each sibling state individually
    local all_closed=true iid
    for iid in $(echo "$sibling_iids" | tr ',' ' '); do
      local sib_state
      sib_state=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$iid" 2> /dev/null | jq -r '.state // "unknown"')
      if [ "$sib_state" != "closed" ]; then
        echo "maybe_close_parent: sibling #$iid is $sib_state — parent #$parent_iid stays open."
        all_closed=false
        break
      fi
    done
    if [ "$all_closed" = "true" ]; then
      echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
      close_issue "$parent_iid"
    fi
    return 0
  fi

  # Hierarchy API path: children response includes .state directly,
  # so we can check all siblings in one call (no per-sibling fetch).
  local all_closed=true
  local open_count
  open_count=$(echo "$children_data" | jq '[.[] | select(.state != "closed")] | length' 2> /dev/null || echo 1)
  if [ "${open_count:-1}" -gt 0 ]; then
    local open_iids
    open_iids=$(echo "$children_data" | jq -r '[.[] | select(.state != "closed") | .iid] | join(",")')
    echo "maybe_close_parent: open sub-issue(s) #$open_iids — parent #$parent_iid stays open."
    all_closed=false
  fi
  if [ "$all_closed" = "true" ]; then
    echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
    close_issue "$parent_iid"
  fi
}

# ── Preview URL deep-linking ────────────────────────────────────────────

# preview_url_for_changed_files <base_url>
#
# Map the first changed src/pages/*.astro or src/content/*/*.md file to
# its route and append it to the base preview URL. Falls back to the
# base URL if no changed file maps to a route.
preview_url_for_changed_files() {
  base_url="$1"
  [ -z "$base_url" ] && {
    echo ""
    return
  }
  changed=$(git diff --name-only origin/${CI_DEFAULT_BRANCH:-main}..."$BRANCH" 2> /dev/null)
  [ -z "$changed" ] && {
    echo "$base_url"
    return
  }
  path=""
  for f in $changed; do
    case "$f" in
      src/pages/*.astro)
        rel="${f#src/pages/}"
        rel="${rel%.astro}"
        if echo "$rel" | grep -qE '\[(\.\.\.)?slug\]'; then
          # Dynamic route component → fall back to parent static route
          dir=$(dirname "$rel")
          [ "$dir" = "." ] && dir=""
          path="/$dir"
        elif [ "$rel" = "index" ]; then
          path="/"
        else
          path="/$rel"
        fi
        break
        ;;
      src/content/*/*.md)
        # Content collection entry → map to listing page if a matching
        # dynamic route component exists under src/pages/<col>/.
        col=$(echo "$f" | sed -n 's|^src/content/\([^/]*\)/.*|\1|p')
        if [ -n "$col" ]; then
          if [ -f "src/pages/$col/[...slug].astro" ] || [ -f "src/pages/$col/[slug].astro" ]; then
            path="/$col"
            break
          fi
        fi
        ;;
    esac
  done
  # Normalize: collapse double slashes, strip trailing slash (except root)
  path=$(echo "$path" | sed 's|//\+|/|g; s|/\+$||')
  [ -z "$path" ] && path="/"
  echo "${base_url%/}${path}"
}

# ── Cross-role variable forwarding ──────────────────────────────────────

# chain_to_role <issue_iid> <role> [var=value ...]
#
# Trigger the next role in the boucle loop via the GitLab trigger API.
# Always forwards BOUCLE_ISSUE=<issue_iid> and BOUCLE_ROLE=<role>.
# Extra variables are passed as var=value pairs (e.g.
#   chain_to_role "$BOUCLE_ISSUE" worker BOUCLE_ITERATION=2
# ).
#
# This is the single contract point for cross-role state forwarding.
# Previously each job hand-rolled its curl -F "variables[...]=..." calls,
# which led to missing variables (e.g. BOUCLE_ITERATION was not forwarded
# worker→reviewer, causing infinite loops at iteration 2).
#
# When <role> is empty, only BOUCLE_ISSUE is forwarded (used by triage
# re-triggers and bot-created issue launches where dispatch infers the role).
chain_to_role() {
  local issue_iid="$1" role="$2"
  shift 2
  # Build the curl args array dynamically — no eval needed.
  local -a args=(
    -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline"
    -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=${CI_DEFAULT_BRANCH:-main}"
    -F "variables[BOUCLE_ISSUE]=$issue_iid"
  )
  if [ -n "$role" ]; then
    args+=(-F "variables[BOUCLE_ROLE]=$role")
  fi
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    args+=(-F "variables[$key]=$val")
  done
  curl "${args[@]}" > /dev/null
}
