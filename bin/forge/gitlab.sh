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
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid" 2>/dev/null || true
}

forge_issue_note() {
  local iid="$1" message="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes" \
    -f body="$message" > /dev/null 2>&1 || true
}

forge_issue_notes() {
  local iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid/notes" 2>/dev/null || echo "[]"
}

forge_issue_labels_get() {
  local iid="$1" resp
  resp=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid" 2>/dev/null) || true
  echo "$resp" | jq -r '.labels | join(",")' 2>/dev/null || true
}

forge_issue_labels_set() {
  local iid="$1" labels="$2"
  # Idempotence: skip if all labels already present
  local current_all
  current_all=$(forge_issue_labels_get "$iid")
  local all_present=true lbl
  for lbl in $(echo "$labels" | tr ',' ' '); do
    [ -z "$lbl" ] && continue
    echo "$current_all" | tr ',' '\n' | grep -qx "$lbl" || { all_present=false; break; }
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
    --data-urlencode "assignee_ids[]=$user_id" 2>/dev/null || true
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
  glab api "${args[@]}" 2>/dev/null | jq -r '.iid // empty' || true
}

forge_issue_reactions() {
  local iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/issues/$iid/award_emoji" 2>/dev/null || echo "[]"
}

forge_issue_add_reaction() {
  local iid="$1" emoji="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$iid/award_emoji" \
    -f name="$emoji" > /dev/null 2>&1 || true
}

# ── MR operations ─────────────────────────────────────────────────────────

forge_mr_get() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" 2>/dev/null || true
}

forge_mr_note() {
  local mr_iid="$1" message="$2"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/notes" \
    -f body="$message" > /dev/null 2>&1 || true
}

forge_mr_notes() {
  local mr_iid="$1"
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/notes" 2>/dev/null || echo "[]"
}

forge_mr_create() {
  local source_branch="$1" target_branch="$2" title="$3" description="$4"
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/merge_requests" \
    -f source_branch="$source_branch" -f target_branch="$target_branch" \
    -f title="$title" -f description="$description" 2>/dev/null | jq -r '.iid // empty' || true
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
    status=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid" 2>/dev/null | jq -r '.detailed_merge_status // "unknown"')
    case "$status" in
      mergeable)
        glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT "/projects/$BOUCLE_PROJECT_ID/merge_requests/$mr_iid/merge" \
          -f should_remove_source_branch=true > /dev/null 2>&1 && return 0
        ;;
      checking|pipeline_status_must_pass|pipeline_blocked)
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

# ── Hierarchy / parent-child ──────────────────────────────────────────────

forge_work_item_global_id() {
  local iid="$1" wi_data
  wi_data=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/-/work_items/$iid" 2>/dev/null) || { echo ""; return; }
  printf '%s' "$wi_data" | jq -r 'if (type == "object" and has("id")) then .id else empty end' 2>/dev/null || true
}

forge_work_item_children() {
  local parent_iid="$1" children
  children=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/-/work_items/$parent_iid/children" 2>/dev/null) || { echo "[]"; return; }
  printf '%s' "$children" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || echo "[]"
}

forge_work_item_link_parent() {
  local child_iid="$1" parent_iid="$2"
  local parent_gid
  parent_gid=$(forge_work_item_global_id "$parent_iid")
  if [ -n "$parent_gid" ]; then
    # Try hierarchy API first
    local http_code
    http_code=$(glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$child_iid/links" \
      -f target_issue_iid="$parent_iid" -f link_type=relates_to 2>/dev/null | jq -r '.http_status // empty' 2>/dev/null)
    # Fall back to REST relates_to link
    glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/issues/$child_iid/links" \
      -f target_issue_iid="$parent_iid" -f link_type=relates_to > /dev/null 2>&1 || true
  fi
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
      -H "Accept: application/octet-stream" > "$dest" 2>/dev/null
  fi
}

# ── Pipeline / workflow triggering ────────────────────────────────────────

forge_trigger_role() {
  local issue_iid="$1" role="$2"
  shift 2
  local -a args=(
    -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$BOUCLE_PROJECT_ID/trigger/pipeline"
    -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=${BOUCLE_DEFAULT_BRANCH:-main}"
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
  pipelines=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/pipelines?status=running" 2>/dev/null) || { echo "[]"; return; }
  # For each pipeline, check if BOUCLE_ISSUE matches
  local result="[]"
  local pid vars match
  for pid in $(echo "$pipelines" | jq -r '.[].id' 2>/dev/null); do
    vars=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/pipelines/$pid/variables" 2>/dev/null) || continue
    match=$(echo "$vars" | jq -r --arg iid "$issue_iid" '.[] | select(.key == "BOUCLE_ISSUE" and .value == $iid) | .value' 2>/dev/null)
    [ -n "$match" ] && result=$(echo "$result" | jq --argjson p "{\"id\":$pid,\"status\":\"running\"}" '. + [$p]')
  done
  echo "$result"
}

# ── User / bot resolution ─────────────────────────────────────────────────

forge_resolve_user_id() {
  local username="$1"
  curl -s "https://$BOUCLE_FORGE_HOST/api/v4/users?username=$username" \
    --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" 2>/dev/null | jq -r '.[0].id // empty' || true
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
  }' 2>/dev/null || echo '{}'
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
  ' 2>/dev/null || true
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
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/variables/$key" 2>/dev/null | jq -r '.value // empty' || true
}

forge_ci_var_list() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/variables" 2>/dev/null | jq -r '.[].key' 2>/dev/null || true
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
  runners=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/runners" 2>/dev/null) || return 1
  echo "$runners" | jq -r '.[].tag_list[]' 2>/dev/null | grep -qx "$tag"
}

# ── Labels ───────────────────────────────────────────────────────────────

forge_label_create() {
  local name="$1" color="$2"
  # Check if label exists first (idempotent)
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/labels?search=$name" 2>/dev/null | jq -e ".[] | select(.name == \"$name\")" > /dev/null 2>&1 && return 0
  glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$BOUCLE_PROJECT_ID/labels" \
    -f name="$name" -f color="$color" > /dev/null 2>&1 || true
}

forge_label_list() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID/labels" 2>/dev/null || echo "[]"
}

# ── Project ─────────────────────────────────────────────────────────────

forge_project_get() {
  glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$BOUCLE_PROJECT_ID" 2>/dev/null || true
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
