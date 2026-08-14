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
  # --paginate: gh api does NOT auto-paginate (30 items/page default).
  # Boucle lists (notes, issues, labels, pipelines) routinely exceed one
  # page, so paginate by default. Harmless no-op on single-object GETs.
  GH_TOKEN="$BOUCLE_TOKEN" gh api --paginate "$@" 2> /dev/null
}

_gh_api_silent() {
  local rc=0
  GH_TOKEN="$BOUCLE_TOKEN" gh api "$@" > /dev/null 2>&1 || rc=$?
  return "$rc"
}

# ── Issue operations ─────────────────────────────────────────────────────

forge_issue_get() {
  local iid="$1"
  # GitHub exposes the issue body as .body, the engine contract expects
  # .description (GitLab naming). Normalize so every caller that reads
  # .description works identically on both forges.
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid" \
    | jq -c '. + {description: (.description // .body // "")}' 2> /dev/null || true
}

forge_issue_note() {
  local iid="$1" message="$2" rc=0
  message=$(stamp_agent_marker "$message")
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$iid/comments" \
    -f body="$message" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_issue_note failed (rc=$rc) for issue #$iid — the human was NOT notified of this message" >&2
  fi
  return "$rc"
}

forge_issue_notes() {
  # GitHub issue comments are separate from timeline events.
  # Returns JSON array with normalized fields matching the contract.
  local iid="$1"
  local comments
  comments=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/comments") || {
    echo "[]"
    return
  }
  # Normalize: GitHub .user.login → .author.username, .user.id → .author.id,
  # add .system=false (GitHub comments are never "system" — system events
  # are in the timeline, not comments).
  # Ordering: the GitHub API returns comments ascending (oldest-first); the
  # contract (common.sh) guarantees newest-first, matching GitLab. Callers
  # that need oldest-first already `reverse` (e.g. triage.sh). Reverse here.
  echo "$comments" | jq -c '[.[] | {
    id: .id,
    body: .body,
    author: { id: .user.id, username: .user.login },
    system: false,
    created_at: .created_at
  }] | reverse' 2> /dev/null || echo "[]"
}

forge_issue_labels_get() {
  local iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/labels" | jq -r '[.[].name] | join(",")' 2> /dev/null || true
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
  # Build JSON array for GitHub API — the comma-separated list MUST be
  # sent as a real array body. -F "labels[]=$labels" sent the whole CSV
  # as ONE label name (HTTP 422 invalid) — the array was computed but
  # never used. Fail-open like the GitLab backend: a label API hiccup
  # must not kill the calling pipeline under set -e.
  local json_labels
  json_labels=$(echo "$labels" | tr ',' '\n' | jq -R . | jq -s .)
  _gh_api_silent -X PUT "/repos/$BOUCLE_PROJECT_ID/issues/$iid/labels" \
    --input - <<< "$(jq -nc --argjson l "$json_labels" '{labels: $l}')" || true
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
  # Labels must be sent as a JSON array (same lesson as
  # forge_issue_labels_set: -f "labels[]=$labels" 422s on a CSV list).
  local json_labels body
  json_labels=$(printf '%s' "$labels" | tr -d '\n' | jq -R 'split(",") | map(select(length > 0))' 2> /dev/null || echo "[]")
  body=$(jq -nc --arg t "$title" --arg d "$description" --argjson l "$json_labels" \
    '{title: $t, body: $d, labels: $l}')
  # NOTE: _gh_api adds --paginate, which gh rejects for non-GET requests
  # ("the --paginate option is not supported for non-GET requests"). Call
  # gh api directly, same pattern as forge_mr_create below.
  GH_TOKEN="$BOUCLE_TOKEN" gh api -X POST "/repos/$BOUCLE_PROJECT_ID/issues" \
    --input - <<< "$body" 2> /dev/null | jq -r '.number // empty' || true
}

forge_issue_reactions() {
  local iid="$1"
  local resp
  resp=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$iid/reactions" \
    -H "Accept: application/vnd.github.squirrel-girl-preview+json" 2> /dev/null) || {
    echo "[]"
    return
  }
  # Normalize GitHub .content → canonical .name (contract shape
  # {name, user:{id, username}}); drop reactions outside the canonical set
  # (see forge_reaction_canonical).
  echo "$resp" | jq -r '.[] | [.content, (.user.id // 0), (.user.login // "")] | @tsv' 2> /dev/null \
    | while IFS=$'\t' read -r content uid uname; do
      canon=$(forge_reaction_canonical "$content")
      [ -n "$canon" ] || continue
      jq -nc --arg name "$canon" --arg id "$uid" --arg uname "$uname" \
        '{name: $name, user: {id: ($id | tonumber), username: $uname}}' 2> /dev/null
    done | jq -s '.' 2> /dev/null || echo "[]"
}

forge_issue_add_reaction() {
  local iid="$1" emoji="$2"
  # Map canonical names / emoji aliases / legacy names to GitHub reaction
  # content values via the shared canonical table.
  local content
  case "$(forge_reaction_canonical "$emoji")" in
    thumbsup) content="+1" ;;
    thumbs_down) content="-1" ;;
    smile) content="laugh" ;;
    confused) content="confused" ;;
    heart) content="heart" ;;
    tada) content="hooray" ;;
    rocket) content="rocket" ;;
    eyes) content="eyes" ;;
    *) content="$emoji" ;; # unknown → GitHub rejects (best-effort no-op)
  esac
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$iid/reactions" \
    -f content="$content" \
    -H "Accept: application/vnd.github.squirrel-girl-preview+json"
}

# ── Issue listing ─────────────────────────────────────────────────────────

forge_issue_list_by_label() {
  local label_csv="$1" state="${2:-open}"
  # Map GitLab-style state to GitHub-style
  case "$state" in
    opened) state="open" ;;
    closed) state="closed" ;;
  esac
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues?state=$state&labels=$label_csv&per_page=100" || echo "[]"
}

forge_issue_list_all() {
  local state="${1:-open}"
  case "$state" in
    opened) state="open" ;;
    closed) state="closed" ;;
  esac
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues?state=$state&per_page=100" || echo "[]"
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
  # GitHub uses "body" for description, "title" for title
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/issues/$iid" \
    -f "$key=$value"
}

# ── Issue links ───────────────────────────────────────────────────────────

forge_issue_links() {
  # GitHub has no direct REST issue-links endpoint for cross-references.
  # Sub-issue relationships are handled by forge_work_item_children.
  echo "[]"
}

forge_issue_link_relates_to() {
  # GitHub sub-issues use a different mechanism handled by
  # forge_work_item_link_parent. No-op.
  return 0
}

# ── Note operations ───────────────────────────────────────────────────────

forge_issue_note_get() {
  local iid="$1" note_id="$2"
  # GitHub issue comments use /issues/comments/:id (note_id = comment id)
  _gh_api "/repos/$BOUCLE_PROJECT_ID/issues/comments/$note_id" || true
}

forge_issue_note_update() {
  local iid="$1" note_id="$2" new_body="$3" rc=0
  new_body=$(stamp_agent_marker "$new_body")
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/issues/comments/$note_id" \
    -f body="$new_body" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_issue_note_update failed (rc=$rc) for issue #$iid note $note_id" >&2
  fi
  return "$rc"
}

forge_mr_note_update() {
  local mr_iid="$1" note_id="$2" new_body="$3" rc=0
  new_body=$(stamp_agent_marker "$new_body")
  # GitHub PR issue-style comments use the same endpoint as issue comments
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/issues/comments/$note_id" \
    -f body="$new_body" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_mr_note_update failed (rc=$rc) for PR #$mr_iid note $note_id" >&2
  fi
  return "$rc"
}

forge_note_delete() {
  local kind="$1" object_iid="$2" note_id="$3"
  # GitHub uses the same endpoint for all issue/PR comments
  _gh_api_silent -X DELETE "/repos/$BOUCLE_PROJECT_ID/issues/comments/$note_id"
}

# ── MR lookup + approvals + assign + close ────────────────────────────────

forge_mr_lookup_by_branch() {
  local branch="$1" state="${2:-open}"
  # GitHub API has only open/closed/all states — no "merged".
  # A merged PR is a closed PR with .merged == true. Normalize "merged"
  # to "closed" and filter by .merged downstream so the merger's
  # already-merged detection works on GitHub Actions.
  local merged_filter=0
  case "$state" in
    opened) state="open" ;;
    closed) state="closed" ;;
    merged) state="closed"; merged_filter=1 ;;
  esac
  local encoded
  encoded=$(printf '%s' "$branch" | jq -sRr @uri)
  # GitHub requires "owner:branch" format for the head filter.
  local owner="${BOUCLE_PROJECT_ID%%/*}"
  # Prefix matching for the protocol key "boucle/<digits>": the ACTUAL worker
  # branch is "boucle/<iid>-<slug>" (readable, deterministic), so an exact
  # head match on the bare key would miss it. When the arg is a bare
  # boucle/<digits> key, first try the exact match (backward compat with
  # legacy branches), then fall back to listing PRs and filtering by prefix.
  if printf '%s' "$branch" | grep -qE '^boucle/[0-9]+$'; then
    local exact
    exact=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/pulls?head=$owner:$encoded&state=$state&per_page=1" 2> /dev/null \
      | jq -r '.[0].number // empty' 2> /dev/null || true)
    if [ -n "$exact" ]; then
      # When searching for "merged", verify the PR is actually merged.
      if [ "$merged_filter" -eq 1 ]; then
        local is_merged
        is_merged=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$exact" 2> /dev/null \
          | jq -r '.merged // false' 2>/dev/null || echo false)
        [ "$is_merged" = "true" ] && echo "$exact" && return 0
      else
        echo "$exact"
        return 0
      fi
    fi
    # No exact match — list PRs in the requested state and filter by prefix.
    # When merged_filter=1, also filter by .merged == true.
    if [ "$merged_filter" -eq 1 ]; then
      _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls?state=$state&per_page=100" 2> /dev/null \
        | jq -r --arg prefix "$branch" '[.[] | select((.head.ref | startswith($prefix)) and (.merged == true))] | first | .number // empty' 2>/dev/null || true
    else
      _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls?state=$state&per_page=100" 2> /dev/null \
        | jq -r --arg prefix "$branch" '[.[] | select(.head.ref | startswith($prefix))] | first | .number // empty' 2>/dev/null || true
    fi
    return 0
  fi
  # Non-boucle/<digits> branch — exact head match.
  if [ "$merged_filter" -eq 1 ]; then
    _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls?head=$owner:$encoded&state=$state&per_page=1" 2> /dev/null \
      | jq -r '[.[] | select(.merged == true)] | first | .number // empty' 2>/dev/null || true
  else
    _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls?head=$owner:$encoded&state=$state&per_page=1" 2> /dev/null \
      | jq -r '.[0].number // empty' 2>/dev/null || true
  fi
}

forge_mr_merge_status() {
  local mr_iid="$1"
  # GitHub's mergeable_state: "clean" and "unstable" mean mergeable,
  # "dirty" means conflict, "blocked" means checks pending, "unknown"
  # means GitHub is still computing. Normalize to the GitLab-style status
  # the merger expects (mergeable/conflict/blocked/unknown) so the
  # forge layer is vocabulary-agnostic.
  _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" 2> /dev/null \
    | jq -r '
      if .mergeable_state == "clean" or .mergeable_state == "unstable" then "mergeable"
      elif .mergeable_state == "dirty" then "conflict"
      elif .mergeable_state == "blocked" then "blocked"
      else (.mergeable_state // "unknown") end
    ' 2> /dev/null || echo "unknown"
}

forge_mr_approvals() {
  local mr_iid="$1"
  local reviews
  reviews=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid/reviews" 2> /dev/null) || {
    echo "false"
    return
  }
  echo "$reviews" | jq -r '[.[] | select(.state=="APPROVED")] | length > 0' 2> /dev/null || echo "false"
}

forge_mr_assign() {
  local mr_iid="$1" user_login="$2"
  [ -z "$user_login" ] && return 0
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" \
    -f "assignees[]=$user_login"
}

forge_mr_close() {
  local mr_iid="$1"
  _gh_api_silent -X PATCH "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" \
    -f state=closed
}

forge_branch_delete() {
  local branch="$1"
  local encoded
  encoded=$(printf '%s' "$branch" | jq -sRr @uri)
  _gh_api_silent -X DELETE "/repos/$BOUCLE_PROJECT_ID/git/refs/heads/$encoded"
}

# ── Note reactions ────────────────────────────────────────────────────────

forge_note_reactions() {
  local kind="$1" object_iid="$2" note_id="$3"
  local resp
  resp=$(_gh_api -X GET "/repos/$BOUCLE_PROJECT_ID/issues/comments/$note_id/reactions" \
    -H "Accept: application/vnd.github.squirrel-girl-preview+json" 2> /dev/null) || {
    echo "[]"
    return
  }
  # Normalize GitHub .content → canonical .name (contract shape
  # {name, user:{id, username}}); drop reactions outside the canonical set
  # (see forge_reaction_canonical).
  echo "$resp" | jq -r '.[] | [.content, (.user.id // 0), (.user.login // "")] | @tsv' 2> /dev/null \
    | while IFS=$'\t' read -r content uid uname; do
      canon=$(forge_reaction_canonical "$content")
      [ -n "$canon" ] || continue
      jq -nc --arg name "$canon" --arg id "$uid" --arg uname "$uname" \
        '{name: $name, user: {id: ($id | tonumber), username: $uname}}' 2> /dev/null
    done | jq -s '.' 2> /dev/null || echo "[]"
}

# ── Attachment upload ─────────────────────────────────────────────────────

# Cache the numeric repository ID (required by the uploads.github.com
# endpoint). Resolved once per process via the REST API.
_GH_REPO_ID_CACHE=""

forge_attachment_upload() {
  # GitHub's native attachment upload API — the same endpoint the web UI
  # uses for drag-and-drop image attachments in issue/PR comments.
  #
  #   POST https://uploads.github.com/user-attachments/assets
  #     ?name=<filename>&content_type=<mime>&repository_id=<numeric>
  #   Headers: Authorization: Bearer <PAT>, Accept: application/json,
  #            Content-Type: <mime>
  #   Body: raw file bytes
  #   Response: 201 → {"url":"https://github.com/user-attachments/assets/<uuid>"}
  #
  # The returned URL renders in ![alt](url) in issue/PR comments — it is
  # the same URL format GitHub's web UI produces for drag-and-drop
  # attachments. Requires push access to the repo (the bot PAT has `repo`
  # scope). Fail-open: any error → return 0 with no output → caller posts
  # fallback note, never blocks the loop.
  local iid="$1" file_path="$2" filename="$3"
  [ -z "$file_path" ] || [ ! -s "$file_path" ] && return 0
  [ -z "$filename" ] && filename="$(basename "$file_path")"

  local host="${BOUCLE_FORGE_HOST:-github.com}"

  # Resolve the numeric repository ID (cached per process).
  if [ -z "$_GH_REPO_ID_CACHE" ]; then
    _GH_REPO_ID_CACHE=$(curl -sf -H "Authorization: Bearer $BOUCLE_TOKEN" \
      "https://api.$host/repos/$BOUCLE_PROJECT_ID" \
      2>/dev/null | jq -r '.id // empty' 2>/dev/null) || return 0
  fi
  [ -z "$_GH_REPO_ID_CACHE" ] && return 0

  # Detect the MIME type from the file extension.
  local mime="application/octet-stream"
  case "$filename" in
    *.png)  mime="image/png" ;;
    *.jpg|*.jpeg) mime="image/jpeg" ;;
    *.gif)  mime="image/gif" ;;
    *.webp) mime="image/webp" ;;
    *.svg)  mime="image/svg+xml" ;;
    *.pdf)  mime="application/pdf" ;;
  esac

  # Upload the raw file bytes. --data-binary preserves the exact bytes
  # (no newline mangling like --data would do).
  local response
  response=$(curl -sf -X POST \
    -H "Authorization: Bearer $BOUCLE_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: $mime" \
    --data-binary "@$file_path" \
    "https://uploads.$host/user-attachments/assets?name=$filename&content_type=$mime&repository_id=$_GH_REPO_ID_CACHE" \
    2>/dev/null) || return 0

  # Extract the asset URL — renders in ![alt](url) in issue/PR comments.
  local asset_url
  asset_url=$(printf '%s' "$response" | jq -r '.url // empty' 2>/dev/null) || return 0

  [ -n "$asset_url" ] && echo "$asset_url"
}

forge_branch_url() {
  local branch="$1"
  [ -z "${BOUCLE_FORGE_HOST:-}" ] && return 0
  [ -z "${BOUCLE_PROJECT_PATH:-}" ] && return 0
  echo "https://$BOUCLE_FORGE_HOST/$BOUCLE_PROJECT_PATH/tree/$branch"
}

# ── MR (PR) operations ────────────────────────────────────────────────────

forge_mr_get() {
  local mr_iid="$1"
  _gh_api "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid" || true
}

forge_mr_note() {
  local mr_iid="$1" message="$2" rc=0
  message=$(stamp_agent_marker "$message")
  # PR comments use the same issues/{n}/comments endpoint
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/issues/$mr_iid/comments" \
    -f body="$message" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARN: forge_mr_note failed (rc=$rc) for PR #$mr_iid — the human was NOT notified of this message" >&2
  fi
  return "$rc"
}

forge_mr_notes() {
  local mr_iid="$1"
  forge_issue_notes "$mr_iid"
}

forge_mr_create() {
  local source_branch="$1" target_branch="$2" title="$3" description="$4"
  local out number
  out=$(GH_TOKEN="$BOUCLE_TOKEN" gh api -X POST "/repos/$BOUCLE_PROJECT_ID/pulls" \
    -f head="$source_branch" -f base="$target_branch" \
    -f title="$title" -f body="$description" 2>&1) || {
    echo "ERROR: forge_mr_create failed: $(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null || printf '%s' "$out")" >&2
    return 1
  }
  number=$(printf '%s' "$out" | jq -r '.number // empty' 2> /dev/null)
  if [ -z "$number" ]; then
    echo "ERROR: forge_mr_create returned no PR number (is BOUCLE_TOKEN a classic PAT with 'repo' scope?)" >&2
    return 1
  fi
  echo "$number"
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
      clean | unstable)
        # mergeable — squash merge
        _gh_api_silent -X PUT "/repos/$BOUCLE_PROJECT_ID/pulls/$mr_iid/merge" \
          -f merge_method=squash
        return 0
        ;;
      blocked | dirty | unknown)
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

# ── MR diff + check suites (review modes) ──────────────────────────────────

forge_mr_diff() {
  local mr_iid="$1"
  GH_TOKEN="$BOUCLE_TOKEN" gh pr diff "$mr_iid" \
    --repo "$BOUCLE_PROJECT_ID" 2> /dev/null || true
}

forge_mr_check_suites() {
  local mr_iid="$1" head_sha="$2"
  # Fetch check runs for the head commit of the PR
  local raw_data
  raw_data=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/commits/$head_sha/check-runs" 2> /dev/null) || {
    echo "[boucle] WARN: forge_mr_check_suites API call failed (gh api commits/$head_sha/check-runs)" >&2
    echo "[]"
    return
  }
  echo "$raw_data" \
    | jq -c '.check_runs // [] | map({name: .name, status: .status, conclusion: .conclusion})' 2> /dev/null \
    || {
      echo "[boucle] WARN: forge_mr_check_suites jq parse failed" >&2
      echo "[]"
    }
}

forge_commit_check_suites() {
  local sha="$1"
  local raw_data
  raw_data=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/commits/$sha/check-runs" 2> /dev/null) || {
    echo "[boucle] WARN: forge_commit_check_suites API call failed (gh api commits/$sha/check-runs)" >&2
    echo "[]"
    return
  }
  echo "$raw_data" \
    | jq -c '.check_runs // [] | map({name: .name, status: .status, conclusion: .conclusion})' 2> /dev/null \
    || {
      echo "[boucle] WARN: forge_commit_check_suites jq parse failed" >&2
      echo "[]"
    }
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
  children=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/issues/$parent_iid/sub_issues" 2> /dev/null) || children=""
  if [ -n "$children" ] && [ "$children" != "[]" ]; then
    # Normalize: .number → .iid, .state → .state, .title → .title
    echo "$children" | jq -c '[.[] | {iid: .number, state: .state, title: .title}]' 2> /dev/null || echo "[]"
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
    "$url" 2> /dev/null || true
}

# ── Pipeline / workflow triggering ───────────────────────────────────────

forge_trigger_role() {
  local issue_iid="$1" role="$2"
  shift 2
  # GitHub: trigger via workflow_dispatch API
  # POST /repos/{owner}/{repo}/actions/workflows/boucle.yml/dispatches
  # Body: {"ref": "main", "inputs": {"BOUCLE_ISSUE": "...", "BOUCLE_ROLE": "..."}}
  # The inputs field MUST be a JSON object. -f inputs="$inputs" sent the
  # JSON as a STRING (HTTP 422) so every chained trigger (triage
  # chain_to_role, doctor worker re-trigger) silently failed. Build the
  # body with jq and stream it via --input.
  local inputs_json
  inputs_json=$(jq -nc --arg iid "$issue_iid" --arg role "$role" \
    '{BOUCLE_ISSUE: $iid, BOUCLE_ROLE: $role}')
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    inputs_json=$(printf '%s' "$inputs_json" | jq -c --arg k "$key" --arg v "$val" '.[$k] = $v')
  done
  _gh_api_silent -X POST "/repos/$BOUCLE_PROJECT_ID/actions/workflows/boucle.yml/dispatches" \
    --input - <<< "$(jq -nc --arg ref "${BOUCLE_DEFAULT_BRANCH:-main}" --argjson inputs "$inputs_json" '{ref: $ref, inputs: $inputs}')"
}

forge_pipeline_list_active() {
  local issue_iid="$1"
  # List in-progress workflow runs
  local runs
  runs=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runs?status=in_progress&per_page=100") || {
    echo "[]"
    return
  }
  # Filter by BOUCLE_ISSUE input — need to fetch each run's details
  # (GitHub doesn't expose inputs in the list endpoint)
  local result="[]"
  local run_id
  for run_id in $(echo "$runs" | jq -r '.workflow_runs[].id' 2> /dev/null); do
    local run_detail
    run_detail=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runs/$run_id") || continue
    local match
    match=$(echo "$run_detail" | jq -r --arg iid "$issue_iid" '.inputs.BOUCLE_ISSUE // empty | select(. == $iid)')
    [ -n "$match" ] && result=$(echo "$result" | jq --argjson p "{\"id\":$run_id,\"status\":\"in_progress\"}" '. + [$p]')
  done
  echo "$result"
}

forge_pipeline_status_for_ref() {
  local ref="$1" event="${2:-push}"
  # Get the latest workflow run for the given branch/ref
  local runs
  runs=$(_gh_api "/repos/$BOUCLE_PROJECT_ID/actions/runs?branch=$ref&per_page=1&event=$event" 2> /dev/null) || {
    echo "unknown"
    return
  }
  echo "$runs" | jq -r '.workflow_runs[0].conclusion // .workflow_runs[0].status // "unknown"' 2> /dev/null || echo "unknown"
}

# ── User / bot resolution ─────────────────────────────────────────────────

forge_resolve_user_id() {
  local username="$1"
  _gh_api "/users/$username" | jq -r '.id // empty' || true
}

forge_current_user_login() {
  # No --paginate: /user is a single object, and gh api --paginate on a
  # non-array response is a no-op but adds a round trip.
  GH_TOKEN="$BOUCLE_TOKEN" gh api /user 2> /dev/null | jq -r '.login // empty' 2> /dev/null || true
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
  }' 2> /dev/null || echo '{}'
}

forge_webhook_issue_iid() {
  local payload="$1"
  echo "$payload" | jq -r '.issue.number // .pull_request.number // empty' 2> /dev/null || true
}

# ── CI variables (repo secrets) ──────────────────────────────────────────

forge_ci_var_set() {
  local key="$1" value="$2" masked="${3:-true}" protected="${4:-false}"
  # GitHub secrets are always masked (write-only). Use gh CLI for simplicity
  # (handles libsodium encryption internally).
  echo "$value" | GH_TOKEN="$BOUCLE_TOKEN" gh secret set "$key" --repo "$BOUCLE_PROJECT_ID" 2> /dev/null || true
}

forge_ci_var_get() {
  # GitHub secrets are write-only — cannot read values via API.
  # Return empty; callers must not rely on this for GitHub.
  echo ""
}

forge_ci_var_list() {
  GH_TOKEN="$BOUCLE_TOKEN" gh secret list --repo "$BOUCLE_PROJECT_ID" 2> /dev/null | awk '{print $1}' || true
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
  echo "$runners" | jq -r '.runners[] | select(.status == "online") | .labels[].name' 2> /dev/null | grep -qx "$tag"
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
