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
#   (GitLab: issue-level awards; GitHub: issue reactions API.)
#
# forge_issue_add_reaction <iid> <emoji_name>
#   Add an emoji reaction to an issue. Returns 0 on success.
#   (Used by spec-approval gate.)

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

# ── Backend sourcing ─────────────────────────────────────────────────────
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
