# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# NOTE: no shebang — this file is sourced, not executed.
# lib/boucle-ci/gates.sh — shared gate functions, sourced by:
#   - lib/boucle-ci/dispatch.sh (defines check_sibling_gate inside boucle_ci_dispatch)
#   - lib/boucle-ci/catchup.sh  (defines maybe_unblock_dependents inside boucle_ci_catchup)
#   - lib/boucle-ci/e2e.sh      (defines maybe_unblock_dependents inside boucle_ci_e2e)
#   - .gitlab-ci.yml inline jobs (sourced directly, top-level scope)
# This file is the SINGLE source of truth for these functions. The nested
# copies in dispatch.sh/catchup.sh/e2e.sh and the inline copies in
# .gitlab-ci.yml are replaced by `source` of this file.

# ── Sibling serialization gate (a priori, no file manifest) ───────
# Two sub-issues of the SAME parent are executed SERIALLY: while one
# sibling is active (working/review/approval/merging — any state that
# has not reached done/closed), the others stay boucle:blocked. This
# prevents the most frequent class of merge conflicts — two issues of
# the same domain touching the same components with diverging amendment
# choices (consumer 2026-08: siblings #69/#71 diverged on
# RightToResistBlock.astro and the merger escalated). Costs only
# sibling parallelism; unrelated issues stay fully parallel. The unblock
# happens when a sibling reaches done/closed (maybe_unblock_dependents).
check_sibling_gate() {
  local iid="$1"
  local data parent_iid
  data=$(forge_issue_get "$iid" \
    | jq -r '.description // empty' 2> /dev/null || echo "")
  [ -z "$data" ] && return 0 # can't read → don't block (fail open)
  parent_iid=$(echo "$data" \
    | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' \
    | grep -oE '#[0-9]+' | head -1 | tr -d '#')
  [ -z "$parent_iid" ] && return 0 # not a sub-issue → no siblings
  local children active_sib
  children=$(get_work_item_children "$parent_iid" 2> /dev/null || echo "[]")
  if [ -z "$children" ] || [ "$children" = "[]" ]; then
    return 0 # no children resolvable → fail open
  fi
  # A sibling is "active" if it is open, is not this issue, and does NOT
  # carry boucle:done / boucle:human (done = merged/closed work; human =
  # parked on the human, not competing for the same files).
  active_sib=$(echo "$children" | jq -r --arg self "$iid" '
    [.[] | select((.iid | tostring) != $self)
           | select(.state == "opened")] | .[0].iid // empty' 2> /dev/null)
  if [ -n "$active_sib" ]; then
    # Check the sibling's labels: only block on ACTIVE work states.
    local sib_labels
    sib_labels=$(forge_issue_labels_get "$active_sib" 2> /dev/null || echo "")
    case ",$sib_labels," in
      *",boucle:working,"* | *",boucle:review,"* | *",boucle:approval,"* | *",boucle:merging,"* | *",boucle:blocked,"*)
        echo "[boucle] #$iid blocked — sibling #$active_sib is active (labels: $sib_labels)"
        set_boucle_label "$iid" "boucle:blocked" "boucle::status::bot"
        local sib_body
        sib_body=$(printf '⏳ Serialized sibling sub-issue #%s is still active (working/review/approval). This issue will start automatically once the sibling reaches done/closed — sibling issues share the same domain, so they run one at a time to avoid merge conflicts.\n\n<!-- boucle:sibling-blocked v=1 sib=%s -->' "$active_sib" "$active_sib")
        forge_issue_note "$iid" "$sib_body"
        return 1
        ;;
    esac
  fi
  return 0
}

# ── File-impact gate (MR 1 — declared marker) ────────────────────────
# Before a worker starts, compare the files its issue claims (via the
# `<!-- boucle:files v=1 paths=... -->` marker note) against the files
# claimed by in-flight issues (working/review/approval/merging). If
# overlapping, DEFER the worker (boucle:blocked) until the claim is
# released. Prevents parallel workers editing the same files from
# conflicting at rebase/merge (consumer 2026-08: siblings #69/#71
# diverged on RightToResistBlock.astro and the merger escalated).
#
# Fail-open everywhere: disabled (BOUCLE_FILE_GATE=false), missing own
# marker, missing other marker, forge API error → return 0 (pass). A
# flaky forge/git must never block the loop (CONTEXT.md §7).
check_file_gate() {
  local iid="$1"
  # Disabled → fail-open (legacy behavior).
  if [ "${BOUCLE_FILE_GATE:-true}" = "false" ]; then
    return 0
  fi
  # Read own latest files-marker. Absent → no claim → pass (fail-open).
  local own_notes own_paths
  own_notes=$(forge_issue_notes "$iid" 2> /dev/null || echo "[]")
  own_paths=$(parse_files_marker "$own_notes")
  [ -z "$own_paths" ] && return 0
  # List active issues (open, labeled working/review/approval/merging).
  # Exclude self. Build the in-flight claim map.
  local active_iids active_iid active_notes active_paths overlap
  active_iids=$(forge_issue_list_by_label "boucle:working,boucle:review,boucle:approval,boucle:merging" opened 2> /dev/null \
    | jq -r --arg self "$iid" '[.[] | select((.iid // .number | tostring) != $self) | .iid // .number] | join(" ")' 2> /dev/null || echo "")
  [ -z "$active_iids" ] && return 0
  for active_iid in $active_iids; do
    active_notes=$(forge_issue_notes "$active_iid" 2> /dev/null || echo "[]")
    active_paths=$(parse_files_marker "$active_notes")
    [ -z "$active_paths" ] && continue
    # Intersect own_paths with active_paths (exact match, normalized).
    # NOTE: `sort` (NOT `sort -u`) — we need duplicates to survive so
    # `uniq -d` can find the overlap. `sort -u` dedupes first and the gate
    # never blocks (the bug fix-8 surfaced: the gate was inert).
    overlap=$(printf '%s\n%s\n' "$own_paths" "$active_paths" \
      | tr ',' '\n' | sed 's|^\./||' | sort \
      | uniq -d | paste -sd, -)
    if [ -n "$overlap" ]; then
      echo "[boucle] #$iid blocked — file overlap with #$active_iid ($overlap)"
      set_boucle_label "$iid" "boucle:blocked" "boucle::status::bot"
      local block_body
      block_body=$(printf '⏳ Blocked on file overlap with #%s (%s). The worker will start once #%s reaches done/closed.\n\n<!-- boucle:file-blocked v=1 on=%s paths=%s -->' "$active_iid" "$overlap" "$active_iid" "$active_iid" "$overlap")
      forge_issue_note "$iid" "$block_body"
      return 1
    fi
  done
  return 0
}

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
  sibling_iids=$(echo "$children_data" | jq -r '[.[].iid] | join(",")' 2> /dev/null)
  if [ -z "$sibling_iids" ]; then
    local parent_notes
    parent_notes=$(forge_issue_notes "$parent_iid") || return 0
    sibling_iids=$(echo "$parent_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
    if [ -z "$sibling_iids" ]; then
      local links_data
      links_data=$(forge_issue_links "$parent_iid")
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
    sib_labels=$(echo "$sib_data" | jq -r '.labels | map(if type == "string" then . else .name end) | join(",")' 2> /dev/null)
    echo "$sib_labels" | grep -q "boucle:blocked" || continue
    sib_desc=$(echo "$sib_data" | jq -r '.description // empty' 2> /dev/null)
    sib_deps=$(parse_depends_on "$sib_desc")
    # ── Sibling-serialization unblock (a priori gate) ──────────────
    # A sibling blocked by the serialization gate carries a note with
    # `<!-- boucle:sibling-blocked v=1 sib=<active_iid> -->`. When that
    # active sibling reaches done/closed, unblock the waiting sibling —
    # BUT only if no OTHER sibling is still active (serialization: one
    # sibling at a time, per domain).
    local sib_notes sib_blocker active_other
    sib_blocker=""
    sib_notes=$(forge_issue_notes "$sib_iid" 2> /dev/null || echo "[]")
    sib_blocker=$(echo "$sib_notes" \
      | jq -r '[.[] | select(.body | contains("<!-- boucle:sibling-blocked"))] | last | .body // empty' 2> /dev/null \
      | grep -oE 'sib=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$sib_blocker" ] && [ "$sib_blocker" = "$closed_iid" ]; then
      # Only unblock if no other sibling is in an active work state.
      active_other=$(echo "$children_data" | jq -r --arg self "$sib_iid" --arg closed "$closed_iid" '
        [.[] | select((.iid | tostring) != $self and (.iid | tostring) != $closed)
               | select(.state == "opened")] | .[0].iid // empty' 2> /dev/null)
      if [ -z "$active_other" ]; then
        echo "maybe_unblock_dependents: #$sib_iid unblocked (serialized sibling #$closed_iid done, no other sibling active)"
        set_boucle_label "$sib_iid" "boucle:todo" "boucle::status::bot"
        local unblock_body
        unblock_body=$(printf '✅ Sibling #%s done — worker starting.\n\n<!-- boucle:unblocked v=1 by=%s -->' "$closed_iid" "$closed_iid")
        forge_issue_note "$sib_iid" "$unblock_body"
        if ! issue_has_active_pipeline "$sib_iid"; then
          chain_to_role "$sib_iid" "worker"
        fi
        continue
      fi
    fi
    # ── File-conflict unblock (F4 — direct unblock, no full-gate re-run) ─
    # A sibling blocked by the file gate carries a note with
    # `<!-- boucle:file-blocked v=1 on=N paths=... -->`. When the blocking
    # issue #N reaches done/closed, unblock the waiting issue directly —
    # the next dispatch attempt re-runs check_file_gate to catch a second
    # blocker (F4 simplification: no O(blocked × active) re-evaluation here).
    local file_blocker
    file_blocker=$(echo "$sib_notes" 2> /dev/null \
      | jq -r '[.[] | select(.body | contains("<!-- boucle:file-blocked"))] | last | .body // empty' 2> /dev/null \
      | grep -oE 'on=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$file_blocker" ] && [ "$file_blocker" = "$closed_iid" ]; then
      echo "maybe_unblock_dependents: #$sib_iid unblocked (file overlap with #$closed_iid cleared)"
      set_boucle_label "$sib_iid" "boucle:todo" "boucle::status::bot"
      local unblock_body
      unblock_body=$(printf '✅ File overlap with #%s cleared — worker starting.\n\n<!-- boucle:unblocked v=1 by=%s -->' "$closed_iid" "$closed_iid")
      forge_issue_note "$sib_iid" "$unblock_body"
      if ! issue_has_active_pipeline "$sib_iid"; then
        chain_to_role "$sib_iid" "worker"
      fi
      continue
    fi
    [ -z "$sib_deps" ] && continue
    # Does this sibling depend on the just-closed IID?
    echo ",$sib_deps," | grep -q ",$closed_iid," || continue
    # Are ALL deps now closed?
    all_closed=true
    for dep_iid in $(echo "$sib_deps" | tr ',' ' '); do
      dep_state=$(forge_issue_get "$dep_iid" | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
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
