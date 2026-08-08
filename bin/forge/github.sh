#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# bin/forge/github.sh — GitHub forge backend for boucle.
#
# Implements the contract defined in bin/forge/common.sh using the GitHub
# REST API via gh CLI and curl.
#
# All functions are best-effort (set +e, 2>/dev/null, || true) so transient
# API errors never kill the loop.
#
# Environment:
#   BOUCLE_PROJECT_ID     — "owner/repo" (GitHub uses string, not numeric ID)
#   BOUCLE_PROJECT_PATH   — same as BOUCLE_PROJECT_ID ("owner/repo")
#   BOUCLE_FORGE_HOST     — "github.com" (or enterprise hostname)
#   BOUCLE_DEFAULT_BRANCH — "main"
#   BOUCLE_TOKEN          — GitHub PAT (Authorization: Bearer header)
#   BOUCLE_BOT_ID         — bot login (e.g. "boucle-bot")
#   BOUCLE_BOT_USERNAME   — bot username (default "up-bot")
#   BOUCLE_TRIGGER_TOKEN  — empty (GitHub uses workflow_dispatch, not trigger tokens)

# ── Helper: gh api with auth ──────────────────────────────────────────────

_gh_api() {
  GH_TOKEN="$BOUCLE_TOKEN" gh api "$@" 2>/dev/null
}

_gh_api_silent() {
  GH_TOKEN="$BOUCLE_TOKEN" gh api "$@" > /dev/null 2>&1 || true
}

# ── Issue operations ─────────────────────────────────────────────────────

forge_issue_get() {
  local iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid" || true
}

forge_issue_note() {
  local iid="$1" message="$2"
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$iid/comments" \
    -f body="$message"
}

forge_issue_notes() {
  # GitHub issue comments are separate from timeline events.
  # Returns JSON array with normalized fields matching the contract.
  local iid="$1"
  local comments
  comments=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/comments") || { echo "[]"; return; }
  # Normalize: GitHub .user.login → .author.username, .user.id → .author.id,
  # add .system=false (GitHub comments are never "system" — system events
  # are in the timeline, not comments)
  echo "$comments" | jq -c '[.[] | {
    id: .id,
    body: .body,
    author: { id: .user.id, username: .user.login },
    system: false,
    created_at: .created_at
  }]' 2>/dev/null || echo "[]"
}

forge_issue_labels_get() {
  local iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/labels" | jq -r '[.[].name] | join(",")' 2>/dev/null || true
}

forge_issue_labels_set() {
  local iid="$1" labels="$2"
  # GitHub PUT /issues/{n}/labels replaces all labels.
  # Idempotence: GitHub does NOT record a "labeled" event on every PUT
  # if the label set is unchanged (unlike GitLab Resource Label Events).
  # But we still check to avoid unnecessary API calls.
  local current
  current=$(forge_issue_labels_get "$iid")
  # Compare as sorted sets
  local sorted_current sorted_labels
  sorted_current=$(echo "$current" | tr ',' '\n' | sort | tr '\n' ',')
  sorted_labels=$(echo "$labels" | tr ',' '\n' | sort | tr '\n' ',')
  [ "$sorted_current" = "$sorted_labels" ] && return 0
  # Build JSON array for GitHub API
  local json_labels
  json_labels=$(echo "$labels" | tr ',' '\n' | jq -R . | jq -s .)
  _gh_api_silent -X PUT "/repos/$BOUCLE_PROJECT_ID/issues/$iid/labels" \
    -F "labels[]=$labels"
}

forge_issue_assign() {
  local iid="$1" user_login="$2"
  [ -z "$user_login" ] && return 0
  # GitHub uses usernames (logins) for assignment, not numeric IDs
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f "assignees[]=$user_login"
}

forge_issue_close() {
  local iid="$1"
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f state=closed
}

forge_issue_create() {
  local title="$1" description="$2" labels="${3:-}"
  local -a args=(-X POST "/repos/$BOUCLE_PROJECT_ID/issues" -f title="$title" -f body="$description")
  [ -n "$labels" ] && args+=(-f "labels[]=$labels")
  _gh_api "${args[@]}" | jq -r '.number // empty' || true
}

forge_issue_reactions() {
  local iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/reactions" \
    -H "Accept: application/vnd.github.squirrel-girl-preview+json" || echo "[]"
}

forge_issue_add_reaction() {
  local iid="$1" emoji="$2"
  # Map common emoji names to GitHub reaction content values
  local content
  case "$emoji" in
    👍|thumbs_up|+1) content="+1" ;;
    👎|thumbs_down|-1) content="-1" ;;
    😄|laugh|smile) content="laugh" ;;
    😕|confused) content="confused" ;;
    ❤|heart|love) content="heart" ;;
    🎉|hooray|party) content="hooray" ;;
    🚀|rocket) content="rocket" ;;
    👀|eyes) content="eyes" ;;
    *) content="$emoji" ;;
  esac
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$iid/reactions" \
    -f content="$content" \
    -H "Accept: application/vnd.github.squirrel-girl-preview+json"
}

# ── MR (PR) operations ────────────────────────────────────────────────────

forge_mr_get() {
  local mr_iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" || true
}

forge_mr_note() {
  local mr_iid="$1" message="$2"
  # PR comments use the same issues/{n}/comments endpoint
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$mr_iid/comments" \
    -f body="$message"
}

forge_mr_notes() {
  local mr_iid="$1"
  forge_issue_notes "$mr_iid"
}

forge_mr_create() {
  local source_branch="$1" target_branch="$2" title="$3" description="$4"
  _gh_api -X POST "/repos/$BOUCLE_PROJECT_ID/pulls" \
    -f head="$source_branch" -f base="$target_branch" \
    -f title="$title" -f body="$description" | jq -r '.number // empty' || true
}

forge_mr_update() {
  local mr_iid="$1" title="$2" description="$3"
  local -a args=(-X PATCH "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid")
  [ -n "$title" ] && args+=(-f title="$title")
  [ -n "$description" ] && args+=(-f body="$description")
  _gh_api_silent "${args[@]}"
}

forge_mr_merge() {
  local mr_iid="$1"
  # Poll mergeable_state for up to 10 min (60×10s)
  local i state
  for i in $(seq 1 60); do
    state=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" | jq -r '.mergeable_state // "unknown"')
    case "$state" in
      clean|unstable)
        # mergeable — squash merge
        _gh_api_silent -X PUT "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid/merge" \
          -f merge_method=squash
        return 0
        ;;
      blocked|dirty|unknown)
        # blocked: waiting on required reviews/checks
        # dirty: merge conflict
        if [ "$state" = "dirty" ]; then
          echo "forge_mr_merge: PR #$mr_iid has merge conflicts — cannot merge." >&2
          return 1
        fi
        sleep 10
        ;;
      *)
        sleep 10
        ;;
    esac
  done
  # Still not mergeable after 10 min — try anyway and report
  _gh_api_silent -X PUT "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid/merge" \
    -f merge_method=squash
}

forge_mr_approve() {
  local mr_iid="$1"
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid/reviews" \
    -f event=APPROVE
}

forge_mr_rebase() {
  # GitHub doesn't have a direct rebase API via gh; the CI job does
  # git rebase locally and force-pushes. This is a no-op stub.
  return 0
}

# ── Hierarchy / parent-child ──────────────────────────────────────────────

forge_work_item_global_id() {
  # GitHub has no work-items API equivalent. Return empty — callers
  # fall back to body parsing + REST links.
  echo ""
}

forge_work_item_children() {
  local parent_iid="$1"
  # GitHub sub-issues API (if available) or timeline events fallback.
  # Try the sub-issues endpoint first (GitHub added sub-issues in 2025).
  local children
  children=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$parent_iid/sub_issues" 2>/dev/null) || children=""
  if [ -n "$children" ] && [ "$children" != "[]" ]; then
    # Normalize: .number → .iid, .state → .state, .title → .title
    echo "$children" | jq -c '[.[] | {iid: .number, state: .state, title: .title}]' 2>/dev/null || echo "[]"
    return
  fi
  # Fallback: parse body for "## Parent issue" marker (legacy boucle)
  # and check timeline for cross-references
  echo "[]"
}

forge_work_item_link_parent() {
  local child_iid="$1" parent_iid="$2"
  # GitHub sub-issues API: POST /repos/{owner}/{repo}/issues/{n}/sub_issues
  # body: {"sub_issue_id": <child_number>, ...}
  # If that fails, fall back to a comment with the marker
  local child_data child_node_id
  child_data=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$child_iid") || true
  child_node_id=$(echo "$child_data" | jq -r '.node_id // empty')
  if [ -n "$child_node_id" ]; then
    # Try sub-issues API (may not be available on all repos)
    _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$parent_iid/sub_issues" \
      -f sub_issue_id="$child_iid"
  fi
  # Always also post a comment marker as fallback (machine-readable)
  # — the legacy split-parent marker is forge-agnostic
}

# ── Attachments ───────────────────────────────────────────────────────────

forge_attachments_extract() {
  local text="$1"
  # GitHub attachment URL formats:
  # 1. https://github.com/user-attachments/assets/<id>
  # 2. https://user-images.githubusercontent.com/<user>/<id>.<ext>
  # 3. Camo URLs: https://camo.githubusercontent.com/<hash> (proxied)
  echo "$text" | grep -oE 'https://(github\.com/user-attachments/assets/[a-zA-Z0-9_-]+|user-images\.githubusercontent\.com/[0-9]+/[a-zA-Z0-9-]+\.[a-zA-Z0-9]+)' || true
}

forge_attachment_download() {
  local url="$1" dest="$2"
  # GitHub attachment URLs are publicly accessible (no auth needed for
  # public repos), but we pass the token for private repos.
  curl -sL -o "$dest" \
    -H "Authorization: Bearer $BOUCLE_TOKEN" \
    -H "Accept: application/octet-stream" \
    "$url" 2>/dev/null || true
}

# ── Pipeline / workflow triggering ───────────────────────────────────────

forge_trigger_role() {
  local issue_iid="$1" role="$2"
  shift 2
  # GitHub: trigger via workflow_dispatch API
  # POST /repos/{owner}/{repo}/actions/workflows/boucle.yml/dispatches
  # Body: {"ref": "main", "inputs": {"BOUCLE_ISSUE": "...", "BOUCLE_ROLE": "..."}}
  local inputs="{\"BOUCLE_ISSUE\": \"$issue_iid\""
  if [ -n "$role" ]; then
    inputs="$inputs, \"BOUCLE_ROLE\": \"$role\""
  fi
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    inputs="$inputs, \"$key\": \"$val\""
  done
  inputs="$inputs}"
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/actions/workflows/boucle.yml/dispatches" \
    -f ref="${BOUCLE_DEFAULT_BRANCH:-main}" \
    -f inputs="$inputs"
}

forge_pipeline_list_active() {
  local issue_iid="$1"
  # List in-progress workflow runs
  local runs
  runs=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runs?status=in_progress&per_page=100") || { echo "[]"; return; }
  # Filter by BOUCLE_ISSUE input — need to fetch each run's details
  # (GitHub doesn't expose inputs in the list endpoint)
  local result="[]"
  local run_id
  for run_id in $(echo "$runs" | jq -r '.workflow_runs[].id' 2>/dev/null); do
    local run_detail
    run_detail=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runs/$run_id") || continue
    local match
    match=$(echo "$run_detail" | jq -r --arg iid "$issue_iid" '.inputs.BOUCLE_ISSUE // empty | select(. == $iid)')
    [ -n "$match" ] && result=$(echo "$result" | jq --argjson p "{\"id\":$run_id,\"status\":\"in_progress\"}" '. + [$p]')
  done
  echo "$result"
}

# ── User / bot resolution ─────────────────────────────────────────────────

forge_resolve_user_id() {
  local username="$1"
  _gh_api "/users/$username" | jq -r '.id // empty' || true
}

# ── Webhook payload parsing ──────────────────────────────────────────────

forge_parse_webhook() {
  local payload="$1"
  # GitHub webhook payloads have different structure per event type.
  # The workflow receives the payload in $GITHUB_EVENT_PATH.
  echo "$payload" | jq -c '{
    event_type: .action,
    action: .action,
    object_iid: (.issue.number // .pull_request.number // .number // empty),
    object_kind: (if .issue then "issue" elif .pull_request then "pull_request" else .action end),
    is_system: false,
    actor: (.sender.login // .comment.user.login // empty),
    body: (.comment.body // .issue.body // .pull_request.body // empty),
    branch: (.pull_request.head.ref // .ref // empty)
  }' 2>/dev/null || echo '{}'
}

forge_webhook_issue_iid() {
  local payload="$1"
  echo "$payload" | jq -r '.issue.number // .pull_request.number // empty' 2>/dev/null || true
}

# ── CI variables (repo secrets) ──────────────────────────────────────────

forge_ci_var_set() {
  local key="$1" value="$2" masked="${3:-true}" protected="${4:-false}"
  # GitHub secrets are always masked (write-only). Use gh CLI for simplicity
  # (handles libsodium encryption internally).
  echo "$value" | GH_TOKEN="$BOUCLE_TOKEN" gh secret set "$key" --repo "$BOUCLE_PROJECT_ID" 2>/dev/null || true
}

forge_ci_var_get() {
  # GitHub secrets are write-only — cannot read values via API.
  # Return empty; callers must not rely on this for GitHub.
  echo ""
}

forge_ci_var_list() {
  GH_TOKEN="$BOUCLE_TOKEN" gh secret list --repo "$BOUCLE_PROJECT_ID" 2>/dev/null | awk '{print $1}' || true
}

# ── Branch protection ────────────────────────────────────────────────────

forge_branch_protect() {
  local branch="$1" push_level="$2" merge_level="$3"
  # GitHub branch protection via API is complex. Use gh CLI for simplicity.
  # push_level/merge_level are GitLab-specific; on GitHub we map to:
  # - require PR reviews (merge_level >= 30 → require at least 1 review)
  # - restrict direct push (push_level >= 30 → no direct push)
  GH_TOKEN="$BOUCLE_TOKEN" gh api -X PUT "/repos/$BOUCLE_PROJECT_ID/branches/$branch/protection" \
    -f required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true}' \
    -f allow_force_pushes=false \
    -f required_status_checks=null \
    -f enforce_admins=false \
    -f restrictions=null > /dev/null 2>&1 || true
}

# ── Runner check ─────────────────────────────────────────────────────────

forge_runner_check() {
  local tag="$1"
  local runners
  runners=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runners") || return 1
  # Check if any runner has the given tag in its labels
  echo "$runners" | jq -r '.runners[] | select(.status == "online") | .labels[].name' 2>/dev/null | grep -qx "$tag"
}

# ── Labels ───────────────────────────────────────────────────────────────

forge_label_create() {
  local name="$1" color="$2"
  # Strip # from color if present (GitHub wants "ffffff" not "#ffffff")
  color="${color#\#}"
  # Check if label exists (idempotent)
  _gh_api "/repos/$BOUCLE_PROJECT_ID/labels/$name" > /dev/null 2>&1 && return 0
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/labels" \
    -f name="$name" -f color="$color"
}

forge_label_list() {
  _gh_api "/repos/$BOUCLE_PROJECT_ID/labels?per_page=100" || echo "[]"
}

# ── Project ─────────────────────────────────────────────────────────────

forge_project_get() {
  _gh_api "/repos/$BOUCLE_PROJECT_ID" || true
}

forge_webhook_create() {
  # On GitHub, the workflow IS the webhook receiver (on: issues, on: pull_request, etc.).
  # No need to create a webhook via API — this is a no-op.
  # Only used if a consumer needs a custom webhook for non-workflow events.
  return 0
}
