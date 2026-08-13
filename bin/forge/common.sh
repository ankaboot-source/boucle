#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# bin/forge/common.sh — Forge abstraction contract for boucle.
#
# This file defines the COMMON CONTRACT that every forge backend MUST
# implement. It is sourced by lib/boucle.sh and bin/jc to get access to
# forge_* functions without knowing which forge (GitLab, GitHub, Gitea)
# is active.
#
# The active forge is selected by $BOUCLE_FORGE (default: gitlab).
# The corresponding implementation is sourced from
# $BOUCLE_HOME/bin/forge/${BOUCLE_FORGE}.sh.
#
# Contract conventions:
#   - All functions are best-effort (set +e, 2>/dev/null, || true) so
#     transient API errors never kill the loop.
#   - Functions return 0 on success, non-zero on hard failure.
#   - Output goes to stdout (captured by callers via $()).
#   - No function directly references glab, gh, curl, or any forge-specific
#     CLI. That is the job of the backend implementation.
#   - No function references CI_* or GITHUB_* predefined variables directly.
#     Project identity is passed via $BOUCLE_PROJECT_ID and
#     $BOUCLE_PROJECT_PATH (set by the CI wrapper from forge-specific vars).
#
# ── Project identity (set by CI wrapper, not by forge backends) ──────────
#   BOUCLE_PROJECT_ID    — numeric project ID (GitLab) or "owner/repo" (GitHub)
#   BOUCLE_PROJECT_PATH  — human-readable project path (e.g. "group/proj" or "owner/repo")
#   BOUCLE_FORGE_HOST    — API hostname (e.g. "framagit.org" or "github.com")
#   BOUCLE_DEFAULT_BRANCH — default branch name (e.g. "main" or "master")
#   BOUCLE_WORKSPACE     — checkout directory (CI_PROJECT_DIR or GITHUB_WORKSPACE)
#
# ── Bot identity ─────────────────────────────────────────────────────────
#   BOUCLE_BOT_ID        — bot user ID (numeric for GitLab, login for GitHub)
#   BOUCLE_BOT_USERNAME  — bot username (default "up-bot")
#   BOUCLE_TOKEN         — bot PAT (PRIVATE-TOKEN for GitLab, GH_TOKEN for GitHub)
#
# ── CI identity (set by CI wrapper) ─────────────────────────────────────
#   BOUCLE_PIPELINE_SOURCE — event source (trigger/webhook/push/etc.)
#   BOUCLE_JOB_ID          — unique job/run ID
#   BOUCLE_TRIGGER_PAYLOAD — raw webhook payload (JSON)
#   BOUCLE_TRIGGER_TOKEN   — pipeline trigger token (GitLab only; empty on GitHub)

# ── Contract: load the active forge backend ──────────────────────────────
#
# Source the backend implementation. This must be called once at startup
# (from lib/boucle.sh or the CI before_script) before any forge_* function
# is called.
forge_init() {
  local forge="${BOUCLE_FORGE:-gitlab}"
  local backend="$BOUCLE_HOME/bin/forge/${forge}.sh"
  if [ ! -f "$backend" ]; then
    echo "forge_init: backend not found: $backend (BOUCLE_FORGE=$forge)" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$backend"
}

# ── Agent marker (#8) ────────────────────────────────────────────────────
#
# Every comment the pipeline posts carries an invisible HTML marker. It lets
# dispatch recognise boucle's own writes WITHOUT asking who the actor was —
# which is what makes mono-user mode possible: when one account owns both
# the issues and the loop, identity discriminates nothing.
#
# It is also defense-in-depth in bot mode. Forges do not guarantee webhook
# delivery order, so a label-change webhook can overtake the note webhook
# that preceded it; the note then lands on the NEW (possibly paused) state
# and would route. The marker closes that race regardless of ordering.
#
# Kept deliberately dumb: a fixed, stable, invisible token. We test for its
# presence, never parse the body for intent.
BOUCLE_AGENT_MARKER='<!-- boucle:agent -->'

# stamp_agent_marker <body>
#   Emit <body> with the agent marker appended. Idempotent — agents re-post
#   and bin/collapse-duplicate-notes rewrites bodies onto existing notes, so
#   a body may already carry it; stamping twice would be noise in the DOM
#   and would break nothing, but exactness is cheap here.
stamp_agent_marker() {
  local body="$1"
  case "$body" in
    *"$BOUCLE_AGENT_MARKER"*) printf '%s' "$body" ;;
    *) printf '%s\n\n%s' "$body" "$BOUCLE_AGENT_MARKER" ;;
  esac
}

# has_agent_marker <body>
#   Return 0 when the body was written by the pipeline. Used by dispatch to
#   skip boucle's own comments in mono-user mode.
has_agent_marker() {
  case "$1" in
    *"$BOUCLE_AGENT_MARKER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Contract: reaction name normalization ────────────────────────────────
#
# forge_reaction_canonical <name>
#   Normalize a forge-specific reaction name to the canonical cross-forge
#   name. Echoes the canonical name on stdout, or NOTHING (empty) for names
#   outside the canonical set — callers MUST treat empty as "not a valid
#   reaction" and drop it. This is the SINGLE source of truth for which
#   reactions are valid: the spec-approval gate only counts "thumbsup".
#
#   Canonical set (the SAME on every forge):
#     thumbsup      (GitHub "+1",  GitLab "thumbsup")
#     thumbs_down   (GitHub "-1",  GitLab "thumbs_down")
#     smile         (GitHub "laugh", GitLab "smile")
#     confused      (GitHub "confused", GitLab "confused")
#     heart         (GitHub "heart", GitLab "heart")
#     tada          (GitHub "hooray", GitLab "tada")
#     rocket        (GitHub "rocket", GitLab "rocket")
#     eyes          (GitHub "eyes",  GitLab "eyes")
#   Emoji aliases (👍 👎 😄 😕 ❤ 🎉 🚀 👀) and the legacy names
#   (+1, -1, thumbs_up, laugh, love, hooray, party) are accepted for
#   forge_issue_add_reaction convenience; they map to the same canonical
#   names. Anything else (e.g. the old GitLab alpha approval codes) maps
#   to empty and is NOT a valid spec approval.
forge_reaction_canonical() {
  local name="$1"
  case "$name" in
    thumbsup | thumbs_up | "+1" | "👍") echo "thumbsup" ;;
    thumbs_down | "-1" | "👎") echo "thumbs_down" ;;
    smile | laugh | "😄") echo "smile" ;;
    confused | "😕") echo "confused" ;;
    heart | love | "❤") echo "heart" ;;
    tada | hooray | party | "🎉") echo "tada" ;;
    rocket | "🚀") echo "rocket" ;;
    eyes | "👀") echo "eyes" ;;
  esac
}

# ── Contract: issue operations ───────────────────────────────────────────
#
# forge_issue_get <iid>
#   Fetch an issue as JSON on stdout. Returns empty on failure.
#   The JSON MUST contain at minimum: .iid, .title, .description,
#   .state, .labels[], .author.id, .author.username, .assignees[].
#
# forge_issue_note <iid> <message>
#   Post a comment on an issue. Returns 0 on success.
#
# forge_issue_notes <iid>
#   Fetch all issue notes as JSON array on stdout. Returns [] on failure.
#   Each note MUST contain: .id, .body, .author.id, .author.username,
#   .system (boolean), .created_at.
#
# forge_issue_labels_get <iid>
#   Fetch issue labels as a comma-separated string on stdout.
#
# forge_issue_labels_set <iid> <labels_csv>
#   Set issue labels (replaces all labels). Idempotent: skip if all
#   labels already present. Returns 0 on success (or no-op).
#
# forge_issue_assign <iid> <user_id>
#   Assign an issue to a user. Returns 0 on success.
#
# forge_issue_close <iid>
#   Close an issue. Returns 0 on success.
#
# forge_issue_create <title> <description> [labels_csv]
#   Create a new issue. Returns the new issue IID on stdout.
#
# forge_issue_reactions <iid>
#   Fetch emoji reactions on an issue as JSON array on stdout.
#   Each reaction MUST contain: .name, .user.id, .user.username.
#   Only the canonical reaction set (see forge_reaction_canonical) is
#   returned — forge-specific names are normalized, out-of-set reactions
#   are dropped.
#   (GitLab: issue-level awards; GitHub: issue reactions API.)
#
# forge_issue_add_reaction <iid> <emoji_name>
#   Add an emoji reaction to an issue. Returns 0 on success.
#   Accepts canonical names, legacy names and emoji aliases (mapped by
#   forge_reaction_canonical). (Used by spec-approval gate.)

# ── Contract: MR / PR operations ─────────────────────────────────────────
#
# forge_mr_get <mr_iid>
#   Fetch a merge request / pull request as JSON on stdout.
#   The JSON MUST contain: .iid, .title, .description, .state,
#   .source_branch, .target_branch, .sha (head SHA),
#   .detailed_merge_status (or .mergeable), .labels[].
#
# forge_mr_note <mr_iid> <message>
#   Post a comment on a MR/PR. Returns 0 on success.
#
# forge_mr_notes <mr_iid>
#   Fetch all MR/PR notes as JSON array on stdout. Returns [] on failure.
#   Same structure as forge_issue_notes.
#
# forge_mr_create <source_branch> <target_branch> <title> <description>
#   Create a MR/PR. Returns the new MR/PR IID on stdout.
#
# forge_mr_update <mr_iid> <title> <description>
#   Update MR/PR title and description. Returns 0 on success.
#
# forge_mr_merge <mr_iid>
#   Merge a MR/PR. Polls for mergeable status if needed (up to 10 min).
#   Returns 0 on success, non-zero on hard failure.
#
# forge_mr_approve <mr_iid>
#   Approve a MR/PR (bot approval). Returns 0 on success.
#
# forge_mr_rebase <mr_iid>
#   Rebase a MR/PR onto target branch (force-push the rebased branch).
#   Returns 0 on success.

# ── Contract: hierarchy / parent-child ───────────────────────────────────
#
# forge_work_item_global_id <iid>
#   Convert an issue IID to a global work-item ID.
#   Returns empty on failure (API not available, 403, etc.).
#   (GitLab: work-items API; GitHub: no equivalent — returns empty,
#   parent-child is resolved via body parsing + REST links.)
#
# forge_work_item_children <parent_iid>
#   List child work items as JSON array on stdout. Returns [] on failure.
#   Each child MUST contain: .iid, .state, .title.
#   (GitLab: hierarchy API; GitHub: sub-issues API or body-marker fallback.)
#
# forge_work_item_link_parent <child_iid> <parent_iid>
#   Link a child issue to its parent. Returns 0 on success.
#   (GitLab: hierarchy PATCH or REST relates_to; GitHub: sub-issues API
#   or issue links.)

# ── Contract: attachments ─────────────────────────────────────────────────
#
# forge_attachments_extract <text>
#   Extract attachment URLs from a text (issue body, note body).
#   Returns one URL per line on stdout.
#   (GitLab: /uploads/... paths; GitHub: github.com/user-attachments/assets/...
#   and user-images.githubusercontent.com URLs.)
#
# forge_attachment_download <url> <dest_path>
#   Download an attachment to <dest_path>. Returns 0 on success.
#   (GitLab: uploads API with octet-stream; GitHub: authenticated curl.)

# ── Contract: pipeline / workflow triggering ─────────────────────────────
#
# forge_trigger_role <issue_iid> <role> [var=value ...]
#   Trigger the next CI job/role in the boucle loop.
#   Always forwards BOUCLE_ISSUE=<issue_iid> and BOUCLE_ROLE=<role>.
#   Extra variables passed as var=value pairs.
#   (GitLab: trigger/pipeline API with BOUCLE_TRIGGER_TOKEN;
#   GitHub: gh workflow run or workflow_dispatch API.)
#
# forge_pipeline_list_active <issue_iid>
#   List active pipelines/workflow runs for an issue.
#   Returns JSON array on stdout, each with: .id, .status, .variables
#   (or enough to match BOUCLE_ISSUE=<iid>).
#   Used by the doctor to check if a pipeline is already running.
#
# forge_pipeline_status_for_ref <ref> [event]
#   Get the status of the latest pipeline/workflow run for a ref.
#   Returns "success", "failed", "canceled", "running", "pending", or
#   "unknown" on stdout. Used by post-merge to wait for deploy.
#   (GitLab: /projects/:id/pipelines?ref=:ref&order_by=id&sort=desc;
#   GitHub: /repos/:owner/:repo/actions/runs?branch=:ref&per_page=1.)

# ── Contract: user / bot resolution ──────────────────────────────────────
#
# forge_resolve_user_id <username>
#   Resolve a username to a forge user ID. Returns empty on failure.
#   (GitLab: /users?username=...; GitHub: /users/{username}.)
#
# forge_resolve_reporter_id <iid>
#   Walk up the parent-issue chain until a non-bot author is found.
#   Returns the user ID of the original human reporter.
#   (Shared logic in lib/boucle.sh, calls forge_issue_get + parent parsing.)
#
# forge_current_user_login
#   Resolve the login of the account that owns $BOUCLE_TOKEN — "who is boucle
#   acting as?". Returns empty on failure (invalid/expired token, network
#   error); callers MUST treat empty as "unknown", never as a mismatch.
#   Used to detect the mono-user configuration, where the token owner and
#   BOUCLE_BOT_USERNAME are the same account.
#   (GitLab: /user; GitHub: /user.)

# ── Contract: webhook payload parsing ────────────────────────────────────
#
# forge_parse_webhook <payload_json>
#   Parse a webhook payload and emit a normalized JSON on stdout with:
#     .event_type    — "issue"|"note"|"merge_request"|"emoji"|"push"
#     .action        — "open"|"close"|"reopen"|"update"|"approve"|"merge"|"comment"
#     .object_iid    — issue/MR IID
#     .object_kind   — "issue"|"merge_request"
#     .is_system     — boolean (true for system notes)
#     .actor         — username of the triggering user
#     .body          — note body (for note events)
#     .branch        — source branch (for MR events)
#   (GitLab: parses TRIGGER_PAYLOAD with jq; GitHub: parses GITHUB_EVENT_PATH.)
#
# forge_webhook_issue_iid <payload_json>
#   Extract the issue IID from a webhook payload (for dispatch routing).
#   Returns empty if not an issue-related event.

# ── Contract: CI variable mapping ────────────────────────────────────────
#
# forge_ci_var_set <key> <value> [masked] [protected]
#   Set a CI variable (repo secret). Returns 0 on success.
#   (GitLab: /projects/:id/variables; GitHub: gh secret set.)
#
# forge_ci_var_get <key>
#   Get a CI variable value. Returns empty on failure.
#   (GitLab: /projects/:id/variables/:key; GitHub: secrets are write-only —
#   returns empty and callers must not rely on this for GitHub.)
#
# forge_ci_var_list
#   List CI variable names (one per line). Returns empty on failure.

# ── Contract: branch protection ──────────────────────────────────────────
#
# forge_branch_protect <branch> <push_level> <merge_level>
#   Protect a branch. push_level/merge_level are forge-specific
#   (GitLab: 30=Developer, 40=Maintainer; GitHub: "push"|"pull_request_review").
#   Returns 0 on success.

# ── Contract: runner / self-hosted ───────────────────────────────────────
#
# forge_runner_check <runner_tag>
#   Check if a runner with the given tag is online. Returns 0 if online.
#   (GitLab: /projects/:id/runners; GitHub: checks self-hosted runner via
#   /repos/:owner/:repo/actions/runners.)

# ── Contract: board / labels setup ───────────────────────────────────────
#
# forge_label_create <name> <color>
#   Create a label. Idempotent. Returns 0 on success.
#
# forge_label_list
#   List all labels as JSON array on stdout. Each: .name, .color.

# ── Contract: project setup ──────────────────────────────────────────────
#
# forge_project_get
#   Fetch project info as JSON. Must contain: .id, .path, .default_branch.
#
# forge_webhook_create <url> [events...]
#   Create a webhook. Returns 0 on success.
#   (GitLab: /projects/:id/hooks; GitHub: /repos/:owner/:repo/hooks —
#   but on GitHub the workflow IS the webhook receiver, so this may be
#   a no-op or only used for non-workflow events.)

# ── Contract: issue listing ──────────────────────────────────────────────
#
# forge_issue_list_by_label <label_csv> [state]
#   List issues filtered by label(s). Returns JSON array on stdout, [] on
#   failure. state defaults to "opened" (GitLab) / "open" (GitHub).
#   Accepts GitLab-style state values (opened/closed/all) and maps them
#   for GitHub.
#
# forge_issue_list_all [state]
#   List all issues, no label filter. Same return format.
#
# forge_issue_count_by_label <label_csv> <state>
#   Count issues matching label(s) and state. Returns integer on stdout.
#   Delegates to forge_issue_list_by_label + jq 'length'.

# ── Contract: issue update ───────────────────────────────────────────────
#
# forge_issue_update <iid> <key> <value>
#   Update a single issue field (e.g. description, title). Returns 0 on
#   success. Callers pass the correct body key for the forge
#   (GitLab: description/title; GitHub: body/title).

# ── Contract: issue links (parent-child REST fallback) ───────────────────
#
# forge_issue_links <iid>
#   List issue links (relates_to, blocks, etc.) as JSON array on stdout.
#   Returns [] on failure. (GitLab: /issues/:iid/links; GitHub: no
#   equivalent — returns [].)
#
# forge_issue_link_relates_to <child_iid> <parent_iid>
#   Create a relates_to issue link. Returns 0 on success.
#   (GitLab: POST /issues/:child/links; GitHub: no-op — sub-issues use
#   forge_work_item_link_parent.)

# ── Contract: note operations (read/update/delete) ───────────────────────
#
# forge_issue_note_get <iid> <note_id>
#   Fetch a single issue note as JSON on stdout. Returns empty on failure.
#   The JSON MUST contain: .id, .body, .author.id, .author.username,
#   .system (boolean), .created_at.
#
# forge_issue_note_update <iid> <note_id> <new_body>
#   Update an issue note body. Returns 0 on success.
#
# forge_mr_note_update <mr_iid> <note_id> <new_body>
#   Update a MR/PR note body. Returns 0 on success.
#
# forge_note_delete <kind> <object_iid> <note_id>
#   Delete a note. kind = "issue" or "mr". Best-effort, returns 0.
#   (GitLab: DELETE /issues|merge_requests/:object/notes/:note_id;
#   GitHub: DELETE /issues/comments/:note_id.)

# ── Contract: MR lookup + approvals + assign + close ─────────────────────
#
# forge_mr_lookup_by_branch <source_branch> [state]
#   Find MR/PR by source branch. Returns the MR/PR IID (number) on stdout,
#   empty on failure. state defaults to "opened" (GitLab) / "open" (GitHub).
#   Accepts GitLab-style state values and maps them for GitHub.
#   When <source_branch> is a bare protocol key matching "boucle/<digits>"
#   (no slug), the lookup PREFIX-matches: it first tries an exact match
#   (backward compat with legacy branches) and, if that is empty, lists MRs
#   in the requested state and returns the first whose source branch starts
#   with "boucle/<digits>". This keeps lookups stable even when the readable
#   worker branch slug changes because the issue title was edited.
#
# forge_branch_delete <branch>
#   Delete a branch from the remote. Best-effort: returns 0 on success,
#   non-zero on failure (callers MUST NOT fail the job on a failed deletion —
#   a stale branch is harmless). Used to clean up worker branches after a
#   successful merge.
#   (GitLab: DELETE /projects/:id/repository/branches/:branch;
#   GitHub: DELETE /repos/:owner/:repo/git/refs/heads/:branch.)
#
# forge_mr_merge_status <mr_iid>
#   Get mergeable status string on stdout. Returns "unknown" on failure.
#   (GitLab: detailed_merge_status; GitHub: mergeable_state.)
#
# forge_mr_approvals <mr_iid>
#   Check if MR/PR has at least one approval. Returns "true" or "false"
#   on stdout.
#   (GitLab: /merge_requests/:iid/approvals → .approved;
#   GitHub: /pulls/:iid/reviews → any .state=="APPROVED".)
#
# forge_mr_assign <mr_iid> <user_login>
#   Assign MR/PR to a user. Best-effort, returns 0.
#   (GitLab: uses curl with assignee_ids[]; GitHub: PATCH with assignees[].)
#
# forge_mr_close <mr_iid>
#   Close MR/PR. Returns 0 on success.

# ── Contract: MR diff + check suites (review modes) ──────────────────────
#
# forge_mr_diff <mr_iid>
#   Fetch the diff of a MR/PR as plain text on stdout. Returns empty on
#   failure. Used by the reviewer in diff mode (BOUCLE_REVIEW_MODE=diff).
#   (GitLab: glab mr diff <iid>; GitHub: gh pr diff <iid>.)
#
# forge_mr_check_suites <mr_iid> <head_sha>
#   Fetch check/CI suite status for a MR/PR head commit as JSON on stdout.
#   Returns [] on failure. Each entry MUST contain: .name, .status, .conclusion.
#   Used by the reviewer in diff mode to wait for the repo's own CI.
#   (GitLab: /projects/:id/merge_requests/:iid/pipelines; GitHub:
#   /repos/:owner/:repo/commits/:sha/check-runs.)
#
# forge_commit_check_suites <sha>
#   Fetch check/CI suite status for a specific commit SHA as JSON on stdout.
#   Returns [] on failure. Each entry MUST contain: .name, .status, .conclusion.
#   Used by post-merge in external mode to wait for the consumer's own CI
#   after merge.
#   (GitLab: /projects/:id/repository/commits/:sha/statuses; GitHub:
#   /repos/:owner/:repo/commits/:sha/check-runs.)

# ── Contract: note reactions (doctor spec-approval check) ────────────────
#
# forge_note_reactions <kind> <object_iid> <note_id>
#   List emoji reactions on a note as JSON array on stdout. Returns [] on
#   failure. Each reaction MUST contain: .name, .user.id, .user.username.
#   Only the canonical reaction set (see forge_reaction_canonical) is
#   returned — forge-specific names are normalized, out-of-set reactions
#   are dropped.
#   kind = "issue" or "mr".
#   (GitLab: award_emoji on note; GitHub: reactions on issue comment.)

# ── Contract: branch URL ─────────────────────────────────────────────────
#
# forge_branch_url <branch>
#   Build the forge web URL to view a branch (tree view / diff consultation).
#   Returns the URL on stdout, empty on failure (missing host/project).
#   (GitLab: https://<host>/<project>/-/tree/<branch>;
#    GitHub: https://<host>/<project>/tree/<branch>.)

# ── Contract: attachment upload (triage visual preview) ──────────────────
#
# forge_attachment_upload <iid> <file_path> <filename>
#   Upload a file to the issue. Returns the embeddable URL/path on stdout,
#   empty on failure.
#   (GitLab: POST /projects/:id/uploads; GitHub: no upload API — returns
#   empty, callers must handle gracefully.)
#
# The backend file (e.g. bin/forge/gitlab.sh) MUST define every function
# listed above. If a backend does not support a feature (e.g. GitHub has
# no project-level uploads API), it MUST define a stub that returns a
# safe default (empty stdout, return 0) and logs a warning to stderr.
#
# Backends MUST NOT:
#   - Source lib/boucle.sh (circular dependency).
#   - Define new functions not in this contract (use forge_ prefix only).
#   - Reference CI_* or GITHUB_* variables directly (use BOUCLE_* aliases).
