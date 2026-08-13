#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# bin/forge/gitlab.sh — GitLab forge backend for boucle.
#
# Implements the contract defined in bin/forge/common.sh using the GitLab
# REST API via glab and curl.
#
# All functions are best-effort (set +e, 2>/dev/null, || true) so transient
# API errors never kill the loop.
#
# Environment:
#   BOUCLE_PROJECT_ID     — GitLab project ID (numeric)
#   BOUCLE_PROJECT_PATH   — e.g. "group/project"
#   BOUCLE_FORGE_HOST     — e.g. "framagit.org"
#   BOUCLE_DEFAULT_BRANCH — e.g. "main"
#   BOUCLE_TOKEN          — GitLab PAT (PRIVATE-TOKEN header)
#   BOUCLE_BOT_ID         — bot user ID (numeric)
#   BOUCLE_BOT_USERNAME   — bot username (default "up-bot")
#   BOUCLE_TRIGGER_TOKEN  — pipeline trigger token

# ── Issue operations ─────────────────────────────────────────────────────

forge_issue_get() {
  local iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid" 2> /dev/null || true
}

forge_issue_note() {
  local iid="$1" message="$2" rc=0
  message=$(stamp_agent_marker "$message")
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes" \
    -f body="$message" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_issue_note failed (rc=$rc) for issue #$iid — the human was NOT notified of this message" >&2
  fi
  return "$rc"
}

forge_issue_notes() {
  local iid="$1"
  # --paginate: notes lists default to 20/page; boucle issues accumulate
  # many bot comments (triage + validation + status), so pagination is
  # mandatory to return ALL notes (the original inline calls used
  # per_page=100 + --paginate).
  glab api --hostname "$BOUCLE_FORGE_HOST" --paginate \
    "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes?per_page=100" 2> /dev/null || echo "[]"
}

forge_issue_labels_get() {
  local iid="$1" resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid" 2> /dev/null) || true
  echo "$resp" | jq -r '.labels | join(",")' 2> /dev/null || true
}

forge_issue_labels_set() {
  local iid="$1" labels="$2"
  # Idempotence: skip if all labels already present
  local current_all
  current_all=$(forge_issue_labels_get "$iid")
  local all_present=true lbl
  for lbl in $(echo "$labels" | tr ',' ' '); do
    [ -z "$lbl" ] && continue
    echo "$current_all" | tr ',' '\n' | grep -qx "$lbl" || {
      all_present=false
      break
    }
  done
  [ "$all_present" = true ] && return 0
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f labels="$labels" > /dev/null 2>&1 || true
}

forge_issue_assign() {
  local iid="$1" user_id="$2"
  [ -z "$user_id" ] && return 0
  curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$BOUCLE_PROJECT_ID/issues/$iid" \
    --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
    --data-urlencode "assignee_ids[]=$user_id" 2> /dev/null || true
}

forge_issue_close() {
  local iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f state_event=close > /dev/null 2>&1 || true
}

forge_issue_create() {
  local title="$1" description="$2" labels="${3:-}"
  local -a args=(--hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues" -f title="$title" -f description="$description")
  [ -n "$labels" ] && args+=(-f labels="$labels")
  glab api "${args[@]}" 2> /dev/null | jq -r '.iid // empty' || true
}

forge_issue_reactions() {
  local iid="$1"
  local resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid/award_emoji" 2> /dev/null) || {
    echo "[]"
    return
  }
  # Keep only the canonical reaction set (same on every forge, see
  # forge_reaction_canonical) — GitLab also stores non-approval emoji
  # that MUST NOT be reported.
  echo "$resp" | jq -r '.[] | [.name, (.user.id // 0), (.user.username // "")] | @tsv' 2> /dev/null \
    | while IFS=$'\t' read -r name uid uname; do
      canon=$(forge_reaction_canonical "$name")
      [ -n "$canon" ] || continue
      jq -nc --arg name "$canon" --arg id "$uid" --arg uname "$uname" \
        '{name: $name, user: {id: ($id | tonumber), username: $uname}}' 2> /dev/null
    done | jq -s '.' 2> /dev/null || echo "[]"
}

forge_issue_add_reaction() {
  local iid="$1" emoji="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$iid/award_emoji" \
    -f name="$emoji" > /dev/null 2>&1 || true
}

# ── Issue listing ─────────────────────────────────────────────────────────

forge_issue_list_by_label() {
  local label_csv="$1" state="${2:-opened}"
  # URL-encode ':' → %3A: boucle:* labels contain a colon, and a raw ':' in the
  # labels= query param makes GitLab return [] (doctor never found spec-review
  # / todo issues — approvals stranded at boucle:spec-review, framagit 2026-08).
  label_csv=$(printf '%s' "$label_csv" | sed 's/:/%3A/g')
  glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/issues?state=$state&labels=$label_csv&per_page=100" 2> /dev/null || echo "[]"
}

forge_issue_list_all() {
  local state="${1:-opened}"
  glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/issues?state=$state&per_page=100" 2> /dev/null || echo "[]"
}

forge_issue_count_by_label() {
  local label_csv="$1" state="$2"
  local data
  data=$(forge_issue_list_by_label "$label_csv" "$state")
  echo "$data" | jq 'length' 2> /dev/null || echo 0
}

# ── Issue update ──────────────────────────────────────────────────────────

forge_issue_update() {
  local iid="$1" key="$2" value="$3"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f "$key=$value" > /dev/null 2>&1 || true
}

# ── Issue links ───────────────────────────────────────────────────────────

forge_issue_links() {
  local iid="$1"
  local resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid/links" 2> /dev/null) || {
    echo "[]"
    return
  }
  # GitLab returns an object with .issue_link or an array; coerce to array
  echo "$resp" | jq -c 'if type == "array" then . else [] end' 2> /dev/null || echo "[]"
}

forge_issue_link_relates_to() {
  local child_iid="$1" parent_iid="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$child_iid/links" \
    -f target_issue_iid="$parent_iid" -f link_type=relates_to > /dev/null 2>&1 || true
}

# ── Note operations ───────────────────────────────────────────────────────

forge_issue_note_get() {
  local iid="$1" note_id="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes/$note_id" 2> /dev/null || true
}

forge_issue_note_update() {
  local iid="$1" note_id="$2" new_body="$3" rc=0
  new_body=$(stamp_agent_marker "$new_body")
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes/$note_id" \
    -f body="$new_body" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_issue_note_update failed (rc=$rc) for issue #$iid note $note_id" >&2
  fi
  return "$rc"
}

forge_mr_note_update() {
  local mr_iid="$1" note_id="$2" new_body="$3" rc=0
  new_body=$(stamp_agent_marker "$new_body")
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/notes/$note_id" \
    -f body="$new_body" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_mr_note_update failed (rc=$rc) for MR !$mr_iid note $note_id" >&2
  fi
  return "$rc"
}

forge_note_delete() {
  local kind="$1" object_iid="$2" note_id="$3"
  local endpoint
  case "$kind" in
    issue) endpoint="issues" ;;
    mr | merge_request) endpoint="merge_requests" ;;
    *) return 0 ;;
  esac
  glab api --hostname "$BOUCLE_FORGE_HOST" -X DELETE \
    "/projects/$BOUCLE_PROJECT_ID/$endpoint/$object_iid/notes/$note_id" > /dev/null 2>&1 || true
}

# ── MR lookup + approvals + assign + close ────────────────────────────────

forge_mr_lookup_by_branch() {
  local branch="$1" state="${2:-opened}"
  local encoded
  encoded=$(printf '%s' "$branch" | jq -sRr @uri)
  # Prefix matching for the protocol key "boucle/<digits>": the ACTUAL worker
  # branch is "boucle/<iid>-<slug>" (readable, deterministic), so an exact
  # source_branch match on the bare key would miss it. When the arg is a bare
  # boucle/<digits> key, first try the exact match (backward compat with
  # legacy branches), then fall back to listing MRs and filtering by prefix.
  if printf '%s' "$branch" | grep -qE '^boucle/[0-9]+$'; then
    local exact
    exact=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
      "/projects/$BOUCLE_PROJECT_ID/merge_requests?source_branch=$encoded&state=$state&per_page=1" 2> /dev/null \
      | jq -r '.[0].iid // empty' 2> /dev/null || true)
    if [ -n "$exact" ]; then
      echo "$exact"
      return 0
    fi
    # No exact match — list MRs in the requested state and filter by prefix.
    glab api --hostname "$BOUCLE_FORGE_HOST" --paginate \
      "/projects/$BOUCLE_PROJECT_ID/merge_requests?state=$state&per_page=100" 2> /dev/null \
      | jq -r --arg prefix "$branch" '[.[] | select(.source_branch | startswith($prefix))] | first | .iid // empty' 2> /dev/null || true
    return 0
  fi
  glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/merge_requests?source_branch=$encoded&state=$state&per_page=1" 2> /dev/null \
    | jq -r '.[0].iid // empty' 2> /dev/null || true
}

forge_mr_merge_status() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" 2> /dev/null \
    | jq -r '.["detailed_merge_status"] // .merge_status // "unknown"' 2> /dev/null || echo "unknown"
}

forge_mr_approvals() {
  local mr_iid="$1"
  local resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/approvals" 2> /dev/null) || {
    echo "false"
    return
  }
  echo "$resp" | jq -r '.approved // false' 2> /dev/null || echo "false"
}

forge_mr_assign() {
  local mr_iid="$1" user_login="$2"
  [ -z "$user_login" ] && return 0
  # glab array-param is broken for assignee_ids[] — use curl directly
  curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" \
    --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
    --data-urlencode "assignee_ids[]=$user_login" 2> /dev/null || true
}

forge_mr_close() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" \
    -f state_event=close > /dev/null 2>&1 || true
}

forge_branch_delete() {
  local branch="$1"
  local encoded
  encoded=$(printf '%s' "$branch" | jq -sRr @uri)
  glab api --hostname "$BOUCLE_FORGE_HOST" -X DELETE \
    "/projects/$BOUCLE_PROJECT_ID/repository/branches/$encoded" > /dev/null 2>&1
}

# ── Note reactions ────────────────────────────────────────────────────────

forge_note_reactions() {
  local kind="$1" object_iid="$2" note_id="$3"
  local endpoint resp
  case "$kind" in
    issue) endpoint="issues" ;;
    mr | merge_request) endpoint="merge_requests" ;;
    *)
      echo "[]"
      return
      ;;
  esac
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/$endpoint/$object_iid/notes/$note_id/award_emoji" 2> /dev/null) || {
    echo "[]"
    return
  }
  # Keep only the canonical reaction set (same on every forge, see
  # forge_reaction_canonical).
  echo "$resp" | jq -r '.[] | [.name, (.user.id // 0), (.user.username // "")] | @tsv' 2> /dev/null \
    | while IFS=$'\t' read -r name uid uname; do
      canon=$(forge_reaction_canonical "$name")
      [ -n "$canon" ] || continue
      jq -nc --arg name "$canon" --arg id "$uid" --arg uname "$uname" \
        '{name: $name, user: {id: ($id | tonumber), username: $uname}}' 2> /dev/null
    done | jq -s '.' 2> /dev/null || echo "[]"
}

# ── Attachment upload ─────────────────────────────────────────────────────

forge_attachment_upload() {
  local iid="$1" file_path="$2" filename="$3"
  [ ! -f "$file_path" ] && return 0
  local resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/uploads" \
    -F "file=@$file_path" 2> /dev/null) || return 0
  # Prefer .url (relative /uploads/<hash>/<file>) — the same path GitLab's
  # .markdown field wraps, so callers can embed it as ![alt](<url>).
  echo "$resp" | jq -r '.url // .full_path // empty' 2> /dev/null || true
}

forge_branch_url() {
  local branch="$1"
  [ -z "${BOUCLE_FORGE_HOST:-}" ] && return 0
  [ -z "${BOUCLE_PROJECT_PATH:-}" ] && return 0
  echo "https://$BOUCLE_FORGE_HOST/$BOUCLE_PROJECT_PATH/-/tree/$branch"
}

# ── MR operations ─────────────────────────────────────────────────────────

forge_mr_get() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" 2> /dev/null || true
}

forge_mr_note() {
  local mr_iid="$1" message="$2" rc=0
  message=$(stamp_agent_marker "$message")
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/notes" \
    -f body="$message" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_mr_note failed (rc=$rc) for MR !$mr_iid — the human was NOT notified of this message" >&2
  fi
  return "$rc"
}

forge_mr_notes() {
  local mr_iid="$1"
  # --paginate: see forge_issue_notes.
  glab api --hostname "$BOUCLE_FORGE_HOST" --paginate \
    "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/notes?per_page=100" 2> /dev/null || echo "[]"
}

forge_mr_create() {
  local source_branch="$1" target_branch="$2" title="$3" description="$4"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/merge_requests" \
    -f source_branch="$source_branch" -f target_branch="$target_branch" \
    -f title="$title" -f description="$description" 2> /dev/null | jq -r '.iid // empty' || true
}

forge_mr_update() {
  local mr_iid="$1" title="$2" description="$3"
  local -a args=(--hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid")
  [ -n "$title" ] && args+=(-f title="$title")
  [ -n "$description" ] && args+=(-f description="$description")
  glab api "${args[@]}" > /dev/null 2>&1 || true
}

forge_mr_merge() {
  local mr_iid="$1"
  # Poll detailed_merge_status for up to 10 min (60×10s)
  local i status
  for i in $(seq 1 60); do
    status=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" 2> /dev/null | jq -r '.detailed_merge_status // "unknown"')
    case "$status" in
      mergeable)
        glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/merge" \
          -f should_remove_source_branch=true > /dev/null 2>&1 && return 0
        ;;
      checking | pipeline_status_must_pass | pipeline_blocked)
        sleep 10
        ;;
      *)
        # Try immediate merge, fall back to MWPS
        glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/merge" \
          -f should_remove_source_branch=true > /dev/null 2>&1 && return 0
        sleep 10
        ;;
    esac
  done
  # Still not mergeable after 10 min — use MWPS
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/merge" \
    -f merge_when_pipeline_succeeds=true > /dev/null 2>&1 || true
}

forge_mr_approve() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/approve" > /dev/null 2>&1 || true
}

forge_mr_rebase() {
  # GitLab doesn't have a direct rebase API; the CI job does git rebase
  # locally and force-pushes. This is a no-op stub — the actual rebase
  # is handled by the worker/merger job's git commands.
  return 0
}

# ── MR diff + check suites (review modes) ──────────────────────────────────

forge_mr_diff() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/diff" 2> /dev/null \
    | jq -r '.[].diff // empty' 2> /dev/null || true
}

forge_mr_check_suites() {
  local mr_iid="$1" head_sha="$2"
  # GitLab: fetch pipelines for the MR
  local raw_data
  raw_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/pipelines" 2> /dev/null) || {
    echo "[boucle] WARN: forge_mr_check_suites API call failed (glab api merge_requests/$mr_iid/pipelines)" >&2
    echo "[]"
    return
  }
  echo "$raw_data" \
    | jq -c '[.[] | {
        name: (.ref // "pipeline"),
        status: (if .status == "pending" then "queued" elif .status == "running" then "in_progress" else .status end),
        conclusion: (if .status == "success" then "success"
                     elif .status == "failed" then "failure"
                     elif .status == "canceled" then "cancelled"
                     elif .status == "running" or .status == "pending" then null
                     else .status end)
      }]' 2> /dev/null || {
    echo "[boucle] WARN: forge_mr_check_suites jq parse failed" >&2
    echo "[]"
  }
}

forge_commit_check_suites() {
  local sha="$1"
  # GitLab: fetch statuses for a commit
  local raw_data
  raw_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/repository/commits/$sha/statuses" 2> /dev/null) || {
    echo "[boucle] WARN: forge_commit_check_suites API call failed (glab api commits/$sha/statuses)" >&2
    echo "[]"
    return
  }
  echo "$raw_data" \
    | jq -c '[.[] | {
        name: (.name // .ref // "pipeline"),
        status: (if .status == "pending" then "queued" elif .status == "running" then "in_progress" else .status end),
        conclusion: (if .status == "success" then "success"
                     elif .status == "failed" then "failure"
                     elif .status == "canceled" then "cancelled"
                     elif .status == "running" or .status == "pending" then null
                     else .status end)
      }]' 2> /dev/null || {
    echo "[boucle] WARN: forge_commit_check_suites jq parse failed" >&2
    echo "[]"
  }
}

# ── Hierarchy / parent-child ──────────────────────────────────────────────

forge_work_item_global_id() {
  local iid="$1" wi_data
  wi_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/-/work_items/$iid" 2> /dev/null) || {
    echo ""
    return
  }
  printf '%s' "$wi_data" | jq -r 'if (type == "object" and has("id")) then .id else empty end' 2> /dev/null || true
}

forge_work_item_children() {
  local parent_iid="$1" children
  children=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/-/work_items/$parent_iid/children" 2> /dev/null) || {
    echo "[]"
    return
  }
  printf '%s' "$children" | jq -c 'if type == "array" then . else [] end' 2> /dev/null || echo "[]"
}

forge_work_item_link_parent() {
  local child_iid="$1" parent_iid="$2"
  local parent_gid
  parent_gid=$(forge_work_item_global_id "$parent_iid")
  if [ -n "$parent_gid" ] && [ "$parent_gid" != "null" ]; then
    # Hierarchy API first (creates the real "Child items" relationship
    # visible in the UI). Requires the parent's GLOBAL work-item ID (not its
    # project-scoped IID). The PATCH response carries the work item's .id on
    # success — empty means the hierarchy API is unavailable (403, disabled
    # work_item_rest_api flag on self-managed GitLab), so fall back below.
    local patched
    patched=$(glab api --hostname "$BOUCLE_FORGE_HOST" -X PATCH \
      "/projects/$BOUCLE_PROJECT_ID/-/work_items/$child_iid" \
      -H "Content-Type: application/json" \
      -d "{\"features\":{\"hierarchy\":{\"parent_id\":$parent_gid}}}" 2> /dev/null \
      | jq -r '.id // empty' 2> /dev/null || true)
    [ -n "$patched" ] && return 0
  fi
  # Fall back to the REST relates_to issue link (visible under "Linked items"
  # on the parent). Best-effort — the `## Parent issue` body section remains
  # the final navigation fallback.
  echo "forge_work_item_link_parent: hierarchy API unavailable (or no global id for #$parent_iid) — falling back to relates_to issue link" >&2
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$child_iid/links" \
    -f target_issue_iid="$parent_iid" -f link_type=relates_to > /dev/null 2>&1 || true
}

# ── Attachments ───────────────────────────────────────────────────────────

forge_attachments_extract() {
  local text="$1"
  # GitLab uploads: /uploads/<secret>/<filename>
  echo "$text" | grep -oE '/uploads/[a-zA-Z0-9]+/[^" )]+' || true
}

forge_attachment_download() {
  local url="$1" dest="$2"
  # Extract secret + filename from /uploads/<secret>/<filename>
  local secret filename
  secret=$(echo "$url" | sed -n 's|.*/uploads/\([a-zA-Z0-9]*\)/.*|\1|p')
  filename=$(echo "$url" | sed -n 's|.*/uploads/[a-zA-Z0-9]*/\(.*\)|\1|p')
  if [ -n "$secret" ] && [ -n "$filename" ]; then
    glab api --hostname "$BOUCLE_FORGE_HOST" --method GET "/projects/$BOUCLE_PROJECT_ID/uploads/$secret/$filename" \
      -H "Accept: application/octet-stream" > "$dest" 2> /dev/null
  fi
}

# ── Pipeline / workflow triggering ────────────────────────────────────────

forge_trigger_role() {
  local issue_iid="$1" role="$2"
  shift 2
  local -a args=(
    -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$BOUCLE_PROJECT_ID/trigger/pipeline"
    -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=${BOUCLE_DEFAULT_BRANCH:-${CI_DEFAULT_BRANCH:-master}}"
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
  curl "${args[@]}" > /dev/null 2>&1 || true
}

forge_pipeline_list_active() {
  local issue_iid="$1"
  # List active pipelines and filter by BOUCLE_ISSUE variable
  local pipelines
  pipelines=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/pipelines?status=running" 2> /dev/null) || {
    echo "[]"
    return
  }
  # For each pipeline, check if BOUCLE_ISSUE matches
  local result="[]"
  local pid vars match
  for pid in $(echo "$pipelines" | jq -r '.[].id' 2> /dev/null); do
    vars=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/pipelines/$pid/variables" 2> /dev/null) || continue
    match=$(echo "$vars" | jq -r --arg iid "$issue_iid" '.[] | select(.key == "BOUCLE_ISSUE" and .value == $iid) | .value' 2> /dev/null)
    [ -n "$match" ] && result=$(echo "$result" | jq --argjson p "{\"id\":$pid,\"status\":\"running\"}" '. + [$p]')
  done
  echo "$result"
}

forge_pipeline_status_for_ref() {
  local ref="$1" event="${2:-push}"
  local pipelines
  pipelines=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
    "/projects/$BOUCLE_PROJECT_ID/pipelines?ref=$(printf '%s' "$ref" | jq -sRr @uri)&order_by=id&sort=desc&per_page=1" 2> /dev/null) || {
    echo "unknown"
    return
  }
  echo "$pipelines" | jq -r '.[0].status // "unknown"' 2> /dev/null || echo "unknown"
}

# ── User / bot resolution ─────────────────────────────────────────────────

forge_resolve_user_id() {
  local username="$1"
  curl -s "https://$BOUCLE_FORGE_HOST/api/v4/users?username=$username" \
    --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" 2> /dev/null | jq -r '.[0].id // empty' || true
}

forge_current_user_login() {
  curl -s "https://$BOUCLE_FORGE_HOST/api/v4/user" \
    --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" 2> /dev/null | jq -r '.username // empty' 2> /dev/null || true
}

# ── Webhook payload parsing ──────────────────────────────────────────────

forge_parse_webhook() {
  local payload="$1"
  # GitLab webhook payload is in $TRIGGER_PAYLOAD (JSON string)
  echo "$payload" | jq -c '{
    event_type: .object_kind,
    action: .object_attributes.action,
    object_iid: (.object_attributes.iid // .issue.iid // .merge_request.iid // empty),
    object_kind: .object_kind,
    is_system: (.object_attributes.system // false),
    actor: (.user.username // empty),
    body: (.object_attributes.description // .object_attributes.note // .object_attributes.content // empty),
    branch: (.object_attributes.source_branch // .object_attributes.ref // empty)
  }' 2> /dev/null || echo '{}'
}

forge_webhook_issue_iid() {
  local payload="$1"
  # Extract issue IID from various GitLab webhook event types
  echo "$payload" | jq -r '
    .object_attributes.iid //
    .issue.iid //
    .merge_request.iid //
    (if .object_kind == "note" then
      (.object_attributes.noteable_id | tostring)
    else empty end) //
    empty
  ' 2> /dev/null || true
}

# ── CI variables ─────────────────────────────────────────────────────────

forge_ci_var_set() {
  local key="$1" value="$2" masked="${3:-false}" protected="${4:-false}"
  local -a args=(-X POST "/projects/$BOUCLE_PROJECT_ID/variables" -f key="$key" -f value="$value")
  [ "$masked" = true ] && args+=(-f masked=true)
  [ "$protected" = true ] && args+=(-f protected=true)
  glab api --hostname "$BOUCLE_FORGE_HOST" "${args[@]}" > /dev/null 2>&1 || true
}

forge_ci_var_get() {
  local key="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/variables/$key" 2> /dev/null | jq -r '.value // empty' || true
}

forge_ci_var_list() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/variables" 2> /dev/null | jq -r '.[].key' 2> /dev/null || true
}

# ── Branch protection ────────────────────────────────────────────────────

forge_branch_protect() {
  local branch="$1" push_level="$2" merge_level="$3"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/protected_branches/$branch" \
    -f push_access_level="$push_level" -f merge_access_level="$merge_level" > /dev/null 2>&1 || true
}

# ── Runner check ─────────────────────────────────────────────────────────

forge_runner_check() {
  local tag="$1"
  local runners
  runners=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/runners" 2> /dev/null) || return 1
  echo "$runners" | jq -r '.[].tag_list[]' 2> /dev/null | grep -qx "$tag"
}

# ── Labels ───────────────────────────────────────────────────────────────

forge_label_create() {
  local name="$1" color="$2"
  # Check if label exists first (idempotent)
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/labels?search=$name" 2> /dev/null | jq -e ".[] | select(.name == \"$name\")" > /dev/null 2>&1 && return 0
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/labels" \
    -f name="$name" -f color="$color" > /dev/null 2>&1 || true
}

forge_label_list() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/labels" 2> /dev/null || echo "[]"
}

# ── Project ─────────────────────────────────────────────────────────────

forge_project_get() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID" 2> /dev/null || true
}

forge_webhook_create() {
  local url="$1"
  shift
  local -a args=(-X POST "/projects/$BOUCLE_PROJECT_ID/hooks" -f url="$url")
  local ev
  for ev in "$@"; do
    args+=(-f "${ev}=true")
  done
  glab api --hostname "$BOUCLE_FORGE_HOST" "${args[@]}" > /dev/null 2>&1 || true
}
