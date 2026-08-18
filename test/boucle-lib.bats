#!/usr/bin/env bats
# test/boucle-lib.bats — tests for lib/boucle.sh shared helpers.
#
# Covers the cross-role invariants that were the root cause of the
# infinite-loop bugs (iteration forwarding, SHA matching) and the
# pure-function behavior of the extracted helpers.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "lib/boucle.sh parses without syntax error" {
  run bash -n lib/boucle.sh
  assert_success
}

@test "lib/boucle.sh passes shfmt -d" {
  run shfmt -d -i 2 -bn -ci -sr lib/boucle.sh
  assert_success
}

# ── Function definitions ───────────────────────────────────────────────

@test "defines set_boucle_label function" {
  run grep -E '^set_boucle_label\(\)' lib/boucle.sh
  assert_success
}

@test "defines resolve_reporter_id function" {
  run grep -E '^resolve_reporter_id\(\)' lib/boucle.sh
  assert_success
}

@test "defines get_work_item_global_id function" {
  run grep -E '^get_work_item_global_id\(\)' lib/boucle.sh
  assert_success
}

@test "defines get_work_item_children function" {
  run grep -E '^get_work_item_children\(\)' lib/boucle.sh
  assert_success
}

@test "defines close_issue function" {
  run grep -E '^close_issue\(\)' lib/boucle.sh
  assert_success
}

@test "defines maybe_close_parent function" {
  run grep -E '^maybe_close_parent\(\)' lib/boucle.sh
  assert_success
}

@test "defines preview_url_for_changed_files function" {
  run grep -E '^preview_url_for_changed_files\(\)' lib/boucle.sh
  assert_success
}

@test "defines chain_to_role function" {
  run grep -E '^chain_to_role\(\)' lib/boucle.sh
  assert_success
}

# ── chain_to_role: cross-role variable contract ───────────────────────
# These tests verify the invariants that were the root cause of the
# infinite-loop bugs. chain_to_role is the single contract point for
# forwarding state between roles; it must always forward BOUCLE_ISSUE
# and BOUCLE_ROLE, and must forward extra vars like BOUCLE_ITERATION.
#
# chain_to_role now delegates to forge_trigger_role (forge abstraction).
# We mock forge_trigger_role to capture its args, and mock forge_issue_get
# to prevent forge_init from sourcing the real backend.

# Helper: source lib/boucle.sh with mocked forge_* functions.
# Sets $CAPTURED_ARGS to the space-joined forge_trigger_role arguments.
source_with_mock_forge() {
  CAPTURED_ARGS=""
  export BOUCLE_FORGE_HOST="gitlab.example.com"
  export CI_PROJECT_ID="123"
  export BOUCLE_TRIGGER_TOKEN="tok123"
  # Mock forge_issue_get to prevent forge_init from sourcing the real backend
  forge_issue_get() { :; }
  # Mock forge_trigger_role: capture all args
  forge_trigger_role() { CAPTURED_ARGS="$*"; }
  source lib/boucle.sh
}

@test "chain_to_role always forwards BOUCLE_ISSUE" {
  source_with_mock_forge
  chain_to_role 42 worker
  [ -n "$CAPTURED_ARGS" ] || skip "forge_trigger_role not captured"
  # First arg is the issue IID
  local first="${CAPTURED_ARGS%% *}"
  [ "$first" = "42" ]
}

@test "chain_to_role forwards BOUCLE_ROLE when role is provided" {
  source_with_mock_forge
  chain_to_role 42 worker
  # Second arg is the role
  local second
  second=$(echo "$CAPTURED_ARGS" | awk '{print $2}')
  [ "$second" = "worker" ]
}

@test "chain_to_role does NOT forward BOUCLE_ROLE when role is empty" {
  source_with_mock_forge
  chain_to_role 42 ""
  # Second arg should be empty string
  local second
  second=$(echo "$CAPTURED_ARGS" | awk '{print $2}')
  [ -z "$second" ]
}

@test "chain_to_role forwards extra vars (BOUCLE_ITERATION)" {
  source_with_mock_forge
  chain_to_role 42 worker BOUCLE_ITERATION=2
  echo "$CAPTURED_ARGS" | grep -q 'BOUCLE_ITERATION=2'
}

@test "chain_to_role forwards multiple extra vars" {
  source_with_mock_forge
  chain_to_role 42 reviewer BOUCLE_ITERATION=3 BOUCLE_HEAD_SHA=abc1234
  echo "$CAPTURED_ARGS" | grep -q 'BOUCLE_ITERATION=3'
  echo "$CAPTURED_ARGS" | grep -q 'BOUCLE_HEAD_SHA=abc1234'
}

@test "chain_to_role delegates to forge_trigger_role" {
  source_with_mock_forge
  chain_to_role 42 worker
  # forge_trigger_role must have been called (CAPTURED_ARGS non-empty)
  [ -n "$CAPTURED_ARGS" ]
}

@test "chain_to_role passes issue_iid as first positional arg" {
  source_with_mock_forge
  chain_to_role 42 worker
  local first="${CAPTURED_ARGS%% *}"
  [ "$first" = "42" ]
}

@test "chain_to_role passes role as second positional arg" {
  source_with_mock_forge
  CI_DEFAULT_BRANCH=main chain_to_role 42 worker
  local second
  second=$(echo "$CAPTURED_ARGS" | awk '{print $2}')
  [ "$second" = "worker" ]
}

# ── preview_url_for_changed_files: route mapping ──────────────────────

@test "preview_url_for_changed_files returns empty for empty base_url" {
  # preview_url_for_changed_files uses global vars (base_url, changed, path)
  # so we source and call in a subshell with mocked git.
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    preview_url_for_changed_files ""
  '
  assert_success
  assert_output ""
}

@test "preview_url_for_changed_files returns base_url when no changed files" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    # Mock git diff to return empty
    git() { echo ""; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com"
}

@test "preview_url_for_changed_files maps src/pages/index.astro to root" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    git() { echo "src/pages/index.astro"; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com/"
}

@test "preview_url_for_changed_files maps src/pages/about.astro to /about" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    git() { echo "src/pages/about.astro"; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com/about"
}

@test "preview_url_for_changed_files maps nested src/pages/blog/post.astro to /blog/post" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    git() { echo "src/pages/blog/post.astro"; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com/blog/post"
}

@test "preview_url_for_changed_files falls back to parent for dynamic [slug].astro" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    git() { echo "src/pages/blog/[slug].astro"; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com/blog"
}

@test "preview_url_for_changed_files falls back to parent for [...slug].astro" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    git() { echo "src/pages/blog/[...slug].astro"; }
    BRANCH=feature preview_url_for_changed_files "https://preview.example.com"
  '
  assert_success
  assert_output "https://preview.example.com/blog"
}

# ── resolve_reporter_id: parent-chain walking ─────────────────────────
# Mock forge_issue_get to simulate bot-authored sub-issues with a human parent.
#
# Every test here pins BOUCLE_FORGE. resolve_reporter_id is forge-aware —
# it returns the numeric id on GitLab and the login on GitHub — so without
# the pin these assertions silently test whichever forge the environment
# happens to name. That is not hypothetical: the workflow exports
# BOUCLE_FORGE=github for every job, so unpinned they passed on a
# developer's machine (no variable → gitlab) and failed in CI.

@test "resolve_reporter_id returns author id when author is human" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: return a human-authored issue
    forge_issue_get() {
      printf "%s" "{\"author\":{\"id\":999,\"username\":\"human\"}}"
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

@test "resolve_reporter_id walks up to parent when author is bot" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: return different data based on IID
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"## Parent issue\n\n#10\"}"
          ;;
        10)
          printf "%s" "{\"author\":{\"id\":777,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "777" ]
  '
  assert_success
}

@test "resolve_reporter_id returns bot id when no parent found" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: bot-authored issue with no parent link
    forge_issue_get() {
      printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"No parent here\"}"
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "1" ]
  '
  assert_success
}

@test "resolve_reporter_id follows e2e-origin marker when bot follow-up has no parent" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: an E2E-fail follow-up (bot-authored, no parent
    # section, but with the qualified origin marker pointing to the
    # original issue whose author is the human).
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"E2E verification failed for issue #49.\n\n## Origin — E2E regression\n<!-- boucle:e2e-origin v=1 iid=49 -->\nFollow-up of #49: production E2E verification failed after its MR was merged (see Trace below). This is a qualified follow-up link — NOT a parent/child relationship.\n\n## Trace\n...\"}"
          ;;
        49)
          printf "%s" "{\"author\":{\"id\":999,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

@test "resolve_reporter_id prefers parent chain over e2e-origin marker" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: bot-authored issue carrying BOTH a parent
    # section and an e2e-origin marker — the parent chain must win
    # (the origin marker is only a fallback when no parent exists).
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"## Parent issue\n\n#10\n\n## Origin — E2E regression\n<!-- boucle:e2e-origin v=1 iid=49 -->\"}"
          ;;
        10)
          printf "%s" "{\"author\":{\"id\":777,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "777" ]
  '
  assert_success
}

@test "resolve_reporter_id falls back to prose line for legacy e2e follow-ups" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: legacy bot-authored follow-up created BEFORE the
    # origin marker existed — only the prose intro line references the
    # original issue; that original issue is human-authored.
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"E2E verification failed for issue #49.\n\n## Trace\n<!-- boucle:verdict v=1 role=e2e sha=abc -->\nVERDICT: FAIL\n...\"}"
          ;;
        49)
          printf "%s" "{\"author\":{\"id\":999,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

@test "resolve_reporter_id walks the full chain on legacy e2e follow-ups of follow-ups" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: follow-up of a follow-up, all bot-authored and
    # legacy (prose line only) — the walk must land on the ORIGINAL human
    # reporter (issue 42 -> 67 -> 49 -> human 999).
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"E2E verification failed for issue #67.\n\n## Trace\n...\"}"
          ;;
        67)
          printf "%s" "{\"author\":{\"id\":2,\"username\":\"up-bot\"},\"description\":\"E2E verification failed for issue #49.\n\n## Trace\n...\"}"
          ;;
        49)
          printf "%s" "{\"author\":{\"id\":999,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

@test "resolve_reporter_id walks multiple levels up parent chain" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    # Mock forge_issue_get: walk up multiple parent levels
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"## Parent issue\n\n#52\"}"
          ;;
        52)
          printf "%s" "{\"author\":{\"id\":2,\"username\":\"up-bot\"},\"description\":\"## Parent issue\n\n#55\"}"
          ;;
        55)
          printf "%s" "{\"author\":{\"id\":888,\"username\":\"human\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "888" ]
  '
  assert_success
}

# ── resolve_reporter_id: forge-appropriate assignment identifier ────────
# GitHub's assignees[] API rejects numeric user IDs (silent no-op) and
# requires the login. BOUCLE_BOT_ID is already documented as "login on
# GitHub, numeric on GitLab" (bin/forge/common.sh:34); the reporter-id
# resolver follows the same convention so its sole consumers
# (forge_issue_assign / forge_mr_assign) receive a value the forge
# accepts. Regression: PR !38 on boucle.dev was never assigned to the
# human after a reviewer PASS because the numeric author.id was sent to
# assignees[] and silently dropped.

@test "resolve_reporter_id returns login on GitHub (assignees[] needs a username)" {
  run bash -c '
    BOUCLE_FORGE=github BOUCLE_FORGE_HOST=github.com CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot
    forge_issue_get() {
      printf "%s" "{\"author\":{\"id\":999,\"username\":\"alice\"}}"
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "alice" ]
  '
  assert_success
}

@test "resolve_reporter_id still returns numeric id on GitLab (assignee_ids[])" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=framagit.org CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    forge_issue_get() {
      printf "%s" "{\"author\":{\"id\":999,\"username\":\"alice\"}}"
    }
    source lib/boucle.sh
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

# ── resolve_reporter_username: parent-chain walking (allow-list gate) ──
# Same walk semantics as resolve_reporter_id, but returns the username of
# the resolved human reporter. Used by check_allow_list_gate.

@test "resolve_reporter_username returns author username when author is human" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    forge_issue_get() {
      printf "%s" "{\"author\":{\"id\":999,\"username\":\"alice\"}}"
    }
    source lib/boucle.sh
    result=$(resolve_reporter_username 42)
    [ "$result" = "alice" ]
  '
  assert_success
}

@test "resolve_reporter_username walks up to parent when author is bot" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    forge_issue_get() {
      case "$1" in
        42)
          printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"## Parent issue\n\n#10\"}"
          ;;
        10)
          printf "%s" "{\"author\":{\"id\":777,\"username\":\"bob\"}}"
          ;;
        *) printf "%s" "{}" ;;
      esac
    }
    source lib/boucle.sh
    result=$(resolve_reporter_username 42)
    [ "$result" = "bob" ]
  '
  assert_success
}

@test "resolve_reporter_username returns empty on API failure" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot BOUCLE_FORGE=gitlab
    forge_issue_get() { return 1; }
    source lib/boucle.sh
    result=$(resolve_reporter_username 42)
    [ -z "$result" ]
  '
  assert_success
}

@test "defines resolve_reporter_username function" {
  run grep -E '^resolve_reporter_username\(\)' lib/boucle.sh
  assert_success
}

# ── get_work_item_children: array validation ──────────────────────────

@test "get_work_item_children returns empty array on API failure" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    # Mock forge_issue_get to prevent forge_init
    forge_issue_get() { :; }
    # Mock forge_work_item_children: return empty array on failure
    forge_work_item_children() { echo "[]"; }
    source lib/boucle.sh
    result=$(get_work_item_children 42)
    [ "$result" = "[]" ]
  '
  assert_success
}

@test "get_work_item_children passes through forge_work_item_children output" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    # Mock forge_issue_get to prevent forge_init
    forge_issue_get() { :; }
    # Mock forge_work_item_children: return an error object (pass-through)
    forge_work_item_children() { printf "%s" "{\"message\":\"403 Forbidden\"}"; }
    source lib/boucle.sh
    result=$(get_work_item_children 42)
    # get_work_item_children is a thin wrapper; passes through forge output
    echo "$result" | grep -q "403 Forbidden"
  '
  assert_success
}

@test "get_work_item_children passes through genuine array" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    # Mock forge_issue_get to prevent forge_init
    forge_issue_get() { :; }
    # Mock forge_work_item_children: return genuine array
    forge_work_item_children() { printf "%s" "[{\"iid\":1,\"state\":\"opened\"},{\"iid\":2,\"state\":\"closed\"}]"; }
    source lib/boucle.sh
    result=$(get_work_item_children 42)
    echo "$result" | grep -q "iid.*1"
    echo "$result" | grep -q "iid.*2"
  '
  assert_success
}

# ── get_work_item_global_id ───────────────────────────────────────────

@test "get_work_item_global_id returns id from valid work item" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    # Mock forge_issue_get to prevent forge_init
    forge_issue_get() { :; }
    # Mock forge_work_item_global_id: return a global ID
    forge_work_item_global_id() { printf "%s" "gid://gitlab/WorkItem/123"; }
    source lib/boucle.sh
    result=$(get_work_item_global_id 42)
    [ "$result" = "gid://gitlab/WorkItem/123" ]
  '
  assert_success
}

@test "get_work_item_global_id returns empty on API failure" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    glab() { return 1; }
    result=$(get_work_item_global_id 42)
    [ "$result" = "" ]
  '
  assert_success
}

@test "get_work_item_global_id returns empty for 403 error object" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    glab() { printf "%s" "{\"message\":\"403 Forbidden\"}"; }
    result=$(get_work_item_global_id 42)
    [ "$result" = "" ]
  '
  assert_success
}

# ── close_issue ───────────────────────────────────────────────────────

@test "close_issue calls forge_issue_close with the issue IID" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    # Mock forge_issue_get to prevent forge_init
    forge_issue_get() { :; }
    # Mock forge_issue_close: capture the IID
    CLOSED=""
    forge_issue_close() { CLOSED="$1"; }
    source lib/boucle.sh
    close_issue 42
    [ "$CLOSED" = "42" ]
  '
  assert_success
}

# ── New deploy/review mode helpers ────────────────────────────────────

@test "defines boucle_deploy_mode function" {
  run grep -E '^boucle_deploy_mode\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_review_mode function" {
  run grep -E '^boucle_review_mode\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_is_self_deploy function" {
  run grep -E '^boucle_is_self_deploy\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_is_external_deploy function" {
  run grep -E '^boucle_is_external_deploy\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_is_preview_review function" {
  run grep -E '^boucle_is_preview_review\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_is_diff_review function" {
  run grep -E '^boucle_is_diff_review\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_resolve_live_url function" {
  run grep -E '^boucle_resolve_live_url\(\)' lib/boucle.sh
  assert_success
}

@test "defines boucle_worker_should_deploy function" {
  run grep -E '^boucle_worker_should_deploy\(\)' lib/boucle.sh
  assert_success
}

@test "boucle_deploy_mode defaults to self" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=""
    source lib/boucle.sh
    boucle_deploy_mode
  '
  assert_success
  assert_output "self"
}

@test "boucle_deploy_mode returns external when set" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=external
    source lib/boucle.sh
    boucle_deploy_mode
  '
  assert_success
  assert_output "external"
}

@test "boucle_review_mode defaults to preview" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=""
    source lib/boucle.sh
    boucle_review_mode
  '
  assert_success
  assert_output "preview"
}

@test "boucle_review_mode returns diff when set" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=diff
    source lib/boucle.sh
    boucle_review_mode
  '
  assert_success
  assert_output "diff"
}

@test "boucle_is_self_deploy returns 0 for default self mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=""
    source lib/boucle.sh
    boucle_is_self_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "OK"
}

@test "boucle_is_external_deploy returns 0 for external mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=external
    source lib/boucle.sh
    boucle_is_external_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "OK"
}

@test "boucle_is_diff_review returns 0 for diff mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=diff
    source lib/boucle.sh
    boucle_is_diff_review && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "OK"
}

@test "boucle_worker_should_deploy returns 0 in default self+preview mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=""
    BOUCLE_REVIEW_MODE=""
    BOUCLE_DEPLOY_CMD="npx wrangler pages deploy public"
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "OK"
}

@test "boucle_worker_should_deploy returns 1 in external mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=external
    BOUCLE_REVIEW_MODE=preview
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_worker_should_deploy returns 1 in diff review mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=diff
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_worker_should_deploy returns 1 when BOUCLE_DEPLOY_CMD empty (GitLab Pages mode)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_CMD=""
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

# ── boucle_is_screenshot_review_effective (auto-fallback) ──────────────
# Screenshot mode is "effective" when explicitly requested OR when preview
# mode (the default) is used with a deploy provider that has no per-branch
# preview (github-pages, gitlab-pages). In the auto-fallback case, the
# worker captures screenshots locally instead of overwriting production,
# and the reviewer grades from those screenshots instead of degrading to
# blind diff review.

@test "defines boucle_is_screenshot_review_effective function" {
  run grep -E '^boucle_is_screenshot_review_effective\(\)' lib/boucle.sh
  assert_success
}

@test "boucle_is_screenshot_review_effective returns true for explicit screenshot mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=screenshot
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "TRUE"
}

@test "boucle_is_screenshot_review_effective returns true for preview + github-pages (auto-fallback)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_PROVIDER=github-pages
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "TRUE"
}

@test "boucle_is_screenshot_review_effective returns true for preview + gitlab-pages (auto-fallback)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_PROVIDER=gitlab-pages
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "TRUE"
}

@test "boucle_is_screenshot_review_effective returns false for preview + no provider (self mode has per-branch preview)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_PROVIDER=""
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "FALSE"
}

@test "boucle_is_screenshot_review_effective returns false for diff mode + github-pages" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=diff
    BOUCLE_DEPLOY_PROVIDER=github-pages
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "FALSE"
}

@test "boucle_is_screenshot_review_effective returns false for default mode + no provider" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_REVIEW_MODE=""
    BOUCLE_DEPLOY_PROVIDER=""
    source lib/boucle.sh
    boucle_is_screenshot_review_effective && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "FALSE"
}

# ── boucle_worker_should_deploy auto-fallback ──────────────────────────

@test "boucle_worker_should_deploy returns 1 for preview + github-pages (auto-screenshot, no production clobber)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_PROVIDER=github-pages
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_worker_should_deploy returns 1 for screenshot + github-pages (explicit screenshot, no push)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=screenshot
    BOUCLE_DEPLOY_PROVIDER=github-pages
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_worker_should_deploy returns 1 for screenshot + no provider (explicit screenshot, no deploy)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=screenshot
    BOUCLE_DEPLOY_CMD="npx wrangler pages deploy public"
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_worker_should_deploy returns 1 for preview + gitlab-pages (auto-screenshot)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_REVIEW_MODE=preview
    BOUCLE_DEPLOY_PROVIDER=gitlab-pages
    BOUCLE_DEPLOY_CMD=""
    source lib/boucle.sh
    boucle_worker_should_deploy && echo "OK" || echo "FAIL"
  '
  assert_success
  assert_output "FAIL"
}

@test "boucle_resolve_live_url returns CI_PAGES_URL in gitlab-pages provider mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL=""
    BOUCLE_DEPLOY_PROVIDER=gitlab-pages
    CI_PAGES_URL="https://user.example.gitlab.io/project"
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output "https://user.example.gitlab.io/project"
}

@test "boucle_resolve_live_url does not use CI_PAGES_URL without gitlab-pages provider" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL=""
    BOUCLE_DEPLOY_PROVIDER=""
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_DEPLOY_PROJECT=""
    CI_PAGES_URL="https://user.example.gitlab.io/project"
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output ""
}

@test "boucle_resolve_live_url returns BOUCLE_LIVE_URL when set" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_LIVE_URL="https://example.com"
    BOUCLE_PRODUCTION_URL=""
    BOUCLE_DEPLOY_PROJECT=""
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output "https://example.com"
}

@test "boucle_resolve_live_url falls back to BOUCLE_PRODUCTION_URL" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL="https://prod.example.com"
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output "https://prod.example.com"
}

@test "boucle_resolve_live_url returns pages.dev fallback in self mode" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL=""
    BOUCLE_DEPLOY_PROJECT="my-site"
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output "https://my-site.pages.dev"
}

@test "boucle_resolve_live_url returns empty in external mode without BOUCLE_LIVE_URL" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { :; }
    forge_issue_labels_get() { echo ""; }
    forge_issue_labels_set() { :; }
    BOUCLE_DEPLOY_MODE=external
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL=""
    source lib/boucle.sh
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output ""
}

# ── Regression: check-suite vocabulary mapping and pending detection ────

@test "gitlab forge_commit_check_suites maps pending→queued status" {
  run bash -c '
    BOUCLE_FORGE_HOST=gitlab.example.com BOUCLE_PROJECT_ID=1
    # Mock glab to return a pending GitLab status
    glab() {
      printf '"'"'[{"name":"test","status":"pending","ref":"main"}]'"'"'
    }
    # Source the forge file directly (not forge_init which needs common.sh)
    source bin/forge/gitlab.sh
    result=$(forge_commit_check_suites abc123)
    echo "$result" | jq -e ".[0].status == \"queued\"" > /dev/null
  '
  assert_success
}

@test "gitlab forge_commit_check_suites maps running→in_progress status" {
  run bash -c '
    BOUCLE_FORGE_HOST=gitlab.example.com BOUCLE_PROJECT_ID=1
    glab() {
      printf '"'"'[{"name":"test","status":"running","ref":"main"}]'"'"'
    }
    source bin/forge/gitlab.sh
    result=$(forge_commit_check_suites abc123)
    echo "$result" | jq -e ".[0].status == \"in_progress\"" > /dev/null
  '
  assert_success
}

@test "gitlab forge_commit_check_suites maps canceled→cancelled conclusion" {
  run bash -c '
    BOUCLE_FORGE_HOST=gitlab.example.com BOUCLE_PROJECT_ID=1
    glab() {
      printf '"'"'[{"name":"test","status":"canceled","ref":"main"}]'"'"'
    }
    source bin/forge/gitlab.sh
    result=$(forge_commit_check_suites abc123)
    echo "$result" | jq -e ".[0].conclusion == \"cancelled\"" > /dev/null
  '
  assert_success
}

@test "gitlab forge_commit_check_suites maps success→success conclusion" {
  run bash -c '
    BOUCLE_FORGE_HOST=gitlab.example.com BOUCLE_PROJECT_ID=1
    glab() {
      printf '"'"'[{"name":"test","status":"success","ref":"main"}]'"'"'
    }
    source bin/forge/gitlab.sh
    result=$(forge_commit_check_suites abc123)
    echo "$result" | jq -e ".[0].conclusion == \"success\"" > /dev/null
  '
  assert_success
}

@test "gitlab forge_commit_check_suites maps failed→failure conclusion" {
  run bash -c '
    BOUCLE_FORGE_HOST=gitlab.example.com BOUCLE_PROJECT_ID=1
    glab() {
      printf '"'"'[{"name":"test","status":"failed","ref":"main"}]'"'"'
    }
    source bin/forge/gitlab.sh
    result=$(forge_commit_check_suites abc123)
    echo "$result" | jq -e ".[0].conclusion == \"failure\"" > /dev/null
  '
  assert_success
}

@test "pending-query is vocabulary-agnostic: treats running conclusion as pending" {
  run bash -c '
    # Mock data with GitHub-style and GitLab-style mixed
    data='"'"'[{"name":"a","status":"completed","conclusion":"running"},{"name":"b","status":"completed","conclusion":"success"}]'"'"'
    count=$(echo "$data" | jq -r '"'"'
      def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
      [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))]
      | length
    '"'"')
    [ "$count" -eq 1 ]
  '
  assert_success
}

@test "pending-query is vocabulary-agnostic: treats pending status as pending" {
  run bash -c '
    data='"'"'[{"name":"a","status":"pending","conclusion":null},{"name":"b","status":"completed","conclusion":"success"}]'"'"'
    count=$(echo "$data" | jq -r '"'"'
      def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
      [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))]
      | length
    '"'"')
    [ "$count" -eq 1 ]
  '
  assert_success
}

@test "failure-detection query returns true on failure conclusion" {
  run bash -c '
    data='"'"'[{"name":"a","conclusion":"success"},{"name":"b","conclusion":"failure"},{"name":"c","conclusion":"cancelled"}]'"'"'
    count=$(echo "$data" | jq -r '"'"'[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length'"'"')
    [ "$count" -eq 2 ]
  '
  assert_success
}

@test "failure-detection query returns false on all success" {
  run bash -c '
    data='"'"'[{"name":"a","conclusion":"success"},{"name":"b","conclusion":"success"}]'"'"'
    count=$(echo "$data" | jq -r '"'"'[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length'"'"')
    [ "$count" -eq 0 ]
  '
  assert_success
}

@test "post-merge external timeout exits 1 when suites never conclude" {
  # Write a helper script to avoid nested quoting
  local helper_script
  helper_script=$(mktemp)
  cat > "$helper_script" << 'HELPER'
#!/usr/bin/env bash
BOUCLE_ISSUE=42
BOUCLE_LIVE_URL="https://example.com"
forge_commit_check_suites() {
  echo '[{"name":"test","status":"in_progress","conclusion":null}]'
}
forge_issue_note() { :; }
BOUCLE_FORGE_HOST=github.com
BOUCLE_PROJECT_ID=1
forge_issue_get() { :; }
forge_issue_labels_get() { echo ""; }
forge_issue_labels_set() { :; }
export BOUCLE_DEPLOY_MODE=external
export BOUCLE_EXTERNAL_DEPLOY_WAIT=20
source lib/boucle.sh
head_sha="abc123"
wait_sec="${BOUCLE_EXTERNAL_DEPLOY_WAIT:-600}"
wait_sec=$(echo "$wait_sec" | tr -cd '0-9')
[ -z "$wait_sec" ] || [ "$wait_sec" -eq 0 ] 2>/dev/null && wait_sec=600
max_attempts=$((wait_sec / 10))
[ "$max_attempts" -lt 1 ] && max_attempts=1
attempt=0
all_done=true
while [ "$attempt" -lt "$max_attempts" ]; do
  attempt=$((attempt + 1))
  check_data=$(forge_commit_check_suites "$head_sha")
  pending_count=$(echo "$check_data" | jq -r '
    def is_pending: . == "queued" or . == "in_progress" or . == "pending" or . == "running";
    [.[] | select(.conclusion == null or (.conclusion | is_pending) or (.status | is_pending))]
    | length' 2>/dev/null || echo 1)
  if [ "$pending_count" -eq 0 ]; then
    all_done=true
    break
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    all_done=false
    break
  fi
  sleep 1
done
if [ "$all_done" != "true" ]; then
  echo "TIMEOUT_REACHED"
  exit 1
fi
echo "SUCCESS"
HELPER
  chmod +x "$helper_script"
  run "$helper_script"
  rm -f "$helper_script"
  assert_failure
  assert_output --partial "TIMEOUT_REACHED"
}

@test "post-merge external failure detection exits 1 when suites fail" {
  local helper_script
  helper_script=$(mktemp)
  cat > "$helper_script" << 'HELPER'
#!/usr/bin/env bash
BOUCLE_ISSUE=42
BOUCLE_LIVE_URL="https://example.com"
forge_commit_check_suites() {
  echo '[{"name":"test","status":"completed","conclusion":"failure"}]'
}
forge_issue_note() { :; }
check_data=$(forge_commit_check_suites "abc123")
failed_count=$(echo "$check_data" | jq -r '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length')
if [ "$failed_count" -gt 0 ]; then
  echo "FAILURE_DETECTED"
  exit 1
fi
echo "SUCCESS"
HELPER
  chmod +x "$helper_script"
  run "$helper_script"
  rm -f "$helper_script"
  assert_failure
  assert_output --partial "FAILURE_DETECTED"
}

@test ".gitlab-ci.yml: forge backend sourced BEFORE lib/boucle.sh (before_script bootstrap)" {
  # Regression (consumer framagit, 2026-08): the before_script sourced
  # lib/boucle.sh without bin/forge/*, so set_boucle_label failed with
  # "forge_issue_labels_get: command not found" on every inline job
  # (merger/doctor). Each `source "…lib/boucle.sh"` must be preceded by
  # the forge prelude (common.sh + forge_init).
  line=""
  frozen=0
  while IFS= read -r l; do
    case "$l" in
      *'source "$BOUCLE_HOME/lib/boucle.sh"')
        [ "$frozen" -ge 2 ] || {
          echo "lib/boucle.sh sourced without forge prelude:$LINE" >&2
          return 1
        }
        frozen=0
        ;;
      *'source "$BOUCLE_HOME/bin/forge/common.sh"'*) frozen=1 ;;
      *forge_init*) frozen=2 ;;
      *) [ "$frozen" -ge 1 ] && frozen=$((frozen + 0)) ;;
    esac
    LINE=${LINE:-}
  done <<< "$(cat .gitlab-ci.yml | grep -n 'source \$BOUCLE_HOME/lib/boucle.sh\|source \$BOUCLE_HOME/bin/forge/common.sh\|forge_init')"
}

@test "forge_trigger_role falls back to CI_DEFAULT_BRANCH (never bare 'main')" {
  # Regression (consumer framagit, 2026-08): forge_trigger_role POSTed the
  # role-trigger pipeline with ref=${BOUCLE_DEFAULT_BRANCH:-main}; the var is
  # never set by GitLab CI, so consumers with master as default branch
  # triggered against a non-existent "main" ref — the curl error was swallowed
  # by `|| true` and the re-trigger silently died. The fallback MUST resolve
  # CI_DEFAULT_BRANCH (GitLab native) before degrading to master.
  run bash -c 'source bin/forge/gitlab.sh && grep -n "CI_DEFAULT_BRANCH" <(declare -f forge_trigger_role) || grep -n "CI_DEFAULT_BRANCH" bin/forge/gitlab.sh'
  assert_success
  assert_output --partial "CI_DEFAULT_BRANCH"
}

# ── S4: merge-conflict escalation ─────────────────────────────────────

@test "boucle_parse_merge_conflicts classifies modify/delete and content" {
  run bash -c 'source lib/boucle.sh; out=$(printf "CONFLICT (modify/delete): src/components/MobilisationBlock.astro deleted in a19ed86 and modified in HEAD.\nCONFLICT (content): Merge conflict in src/pages/index.astro\nOK line"); boucle_parse_merge_conflicts "$out"'
  assert_success
  assert_output --partial "- src/components/MobilisationBlock.astro (modify/delete)"
  assert_output --partial "- src/pages/index.astro (content (modify/modify))"
}

@test "boucle_parse_merge_conflicts returns empty on clean output" {
  run bash -c 'source lib/boucle.sh; boucle_parse_merge_conflicts "nothing to rebase"'
  assert_success
  assert_output ""
}

@test "boucle_deepen_rebase_fetch is a no-op on a full clone (no .git/shallow)" {
  run bash -c 'source lib/boucle.sh; [ -f .git/shallow ] && skip "repo is shallow"; boucle_deepen_rebase_fetch'
  assert_success
}

@test "merger detects S4 escalation helper exists (no blind worker retry)" {
  run bash -c 'source lib/boucle.sh; declare -F boucle_escalate_merge_conflict >/dev/null && declare -F boucle_parse_merge_conflicts >/dev/null && echo OK'
  assert_success
  assert_output "OK"
}

@test "boucle_escalate_merge_conflict re-triggers worker below the retry cap" {
  run bash -c '
    source lib/boucle.sh
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_DEFAULT_BRANCH=main
    BOUCLE_CONFLICT_RETRIES=3
    # forge mocks: no prior conflict-retry notes → retry 1 of 3
    forge_issue_notes() { echo "[]"; }
    forge_issue_note() { echo "note-posted:$1"; }
    set_boucle_label() { echo "label:$*"; }
    chain_to_role() { echo "chain:$*"; }
    boucle_escalate_merge_conflict 55 93 main "CONFLICT (content): Merge conflict in src/pages/index.astro"
  '
  assert_success
  assert_output --partial "chain:55 worker BOUCLE_ITERATION=1"
  assert_output --partial "BOUCLE_CONFLICT_FEEDBACK="
  assert_output --partial "label:55 boucle:todo boucle::status::bot"
}

@test "boucle_escalate_merge_conflict escalates to human at the retry cap" {
  run bash -c '
    source lib/boucle.sh
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_DEFAULT_BRANCH=main
    BOUCLE_CONFLICT_RETRIES=3
    # forge mocks: 3 prior conflict-retry notes → budget exhausted → human
    forge_issue_notes() { echo "[{\"body\":\"<!-- boucle:conflict-retry 1 -->\"},{\"body\":\"<!-- boucle:conflict-retry 2 -->\"},{\"body\":\"<!-- boucle:conflict-retry 3 -->\"}]"; }
    forge_issue_note() { echo "note-posted:$1|$2"; }
    set_boucle_label() { echo "label:$*"; }
    chain_to_role() { echo "chain:$*"; }
    boucle_escalate_merge_conflict 55 93 main "CONFLICT (content): Merge conflict in src/pages/index.astro"
  '
  assert_success
  assert_output --partial "label:55 boucle:human boucle::status::human"
  refute_output --partial "chain:55 worker"
  assert_output --partial "cannot be merged automatically"
}

@test "boucle_escalate_merge_conflict posts the conflict-retry note BEFORE re-triggering" {
  run bash -c '
    source lib/boucle.sh
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_DEFAULT_BRANCH=main
    BOUCLE_CONFLICT_RETRIES=3
    forge_issue_notes() { echo "[]"; }
    forge_issue_note() { echo "note:$1|$2"; }
    set_boucle_label() { echo "label:$*"; }
    chain_to_role() { echo "chain:$*"; }
    boucle_escalate_merge_conflict 55 93 main "CONFLICT (content): Merge conflict in src/pages/index.astro"
  '
  assert_success
  assert_output --partial "note:55|"
  assert_output --partial "boucle:conflict-retry 1"
}

# ── job_link (#33) ────────────────────────────────────────────────────
# Escalation comments state that the loop stopped, never why. job_link is
# the pointer to the transcript that makes them actionable.

extract_job_link() {
  awk '
    /^job_link\(\) \{/ { p = 1 }
    p { print }
    p && /^}/ { exit }
  ' lib/boucle.sh > "$1"
}

@test "job_link: prints nothing when the forge exposes no job URL" {
  TMPF=$(mktemp)
  extract_job_link "$TMPF"
  run bash -c "unset BOUCLE_JOB_URL; source '$TMPF'; job_link"
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

@test "job_link: emits a markdown link to the job when the URL is set" {
  TMPF=$(mktemp)
  extract_job_link "$TMPF"
  run bash -c "BOUCLE_JOB_URL='https://gitlab.example.com/g/p/-/jobs/42'; source '$TMPF'; job_link"
  assert_success
  assert_output --partial "https://gitlab.example.com/g/p/-/jobs/42"
  assert_output --partial "agent-output.log"
  rm -f "$TMPF"
}

@test "job_link: GitHub Actions run URL is derived when CI_JOB_URL is absent" {
  run bash -c "
    unset CI_JOB_URL BOUCLE_JOB_URL
    BOUCLE_JOB_URL=''
    GITHUB_RUN_ID=987
    GITHUB_SERVER_URL='https://github.com'
    GITHUB_REPOSITORY='ankaboot-source/boucle'
    $(sed -n '/^if \[ -z "\$BOUCLE_JOB_URL" \] && \[ -n "\${GITHUB_RUN_ID:-}" \]; then/,/^fi$/p' lib/boucle-ci.sh)
    echo \"\$BOUCLE_JOB_URL\"
  "
  assert_success
  assert_output "https://github.com/ankaboot-source/boucle/actions/runs/987"
}

@test "trigger payload falls back to GITHUB_EVENT_PATH when the workflow expression is empty" {
  # `${{ github.event_path }}` is not exposed to workflow expressions, so the
  # job env arrives with BOUCLE_TRIGGER_PAYLOAD='' and dispatch aborted on every
  # GitHub webhook. The runner variable names the same file.
  run bash -c "
    unset TRIGGER_PAYLOAD
    BOUCLE_TRIGGER_PAYLOAD=''
    GITHUB_EVENT_PATH='/home/runner/work/_temp/_github_workflow/event.json'
    $(grep '^: "\${BOUCLE_TRIGGER_PAYLOAD' lib/boucle-ci.sh)
    echo \"\$BOUCLE_TRIGGER_PAYLOAD\"
  "
  assert_success
  assert_output "/home/runner/work/_temp/_github_workflow/event.json"
}

@test "trigger payload keeps an explicit value over the GitHub fallback" {
  # GitLab passes the payload directly; the GitHub fallback must not clobber it.
  run bash -c "
    unset TRIGGER_PAYLOAD
    BOUCLE_TRIGGER_PAYLOAD='/builds/payload.json'
    GITHUB_EVENT_PATH='/home/runner/event.json'
    $(grep '^: "\${BOUCLE_TRIGGER_PAYLOAD' lib/boucle-ci.sh)
    echo \"\$BOUCLE_TRIGGER_PAYLOAD\"
  "
  assert_success
  assert_output "/builds/payload.json"
}

@test "escalation comments carry the job link" {
  # Every note that asks a human to act, or announces a re-run, must point
  # at the transcript — otherwise the human is told the loop stopped with
  # no way to find out why.
  run grep -c 'Human intervention needed.\$(job_link)' lib/boucle-ci/worker.sh
  assert_success
  run grep -q 'job_link' lib/boucle-ci/reviewer.sh
  assert_success
  run grep -q 'job_link' lib/boucle-ci/merger.sh
  assert_success
}

# ── Send-only notification webhook (#34) ──────────────────────────────
# The two gates that need a human (spec, MR) arrive in the forge's email
# stream with the same weight as a label tweak. This pushes them out.
# Send-only: boucle POSTs, nothing listens (CONTEXT.md §7 — no server).

extract_notify() {
  awk '
    /^boucle_notify\(\) \{/ { p = 1 }
    p { print }
    p && /^}/ { exit }
  ' lib/boucle.sh > "$1"
}

@test "notify: silent when BOUCLE_NOTIFY_URL is unset (default)" {
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  run bash -c "unset BOUCLE_NOTIFY_URL; source '$TMPF'; boucle_notify 42 'boucle:approval'"
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

@test "notify: an unreachable webhook warns and returns 0 (fail-open)" {
  # A dead webhook must never block the loop — same rule as auto-update.
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  run bash -c "set -e; export BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_DND_ENABLED=false; source '$TMPF'; boucle_notify 42 'boucle:approval' 2>&1"
  assert_success
  assert_output --partial "webhook POST failed"
  rm -f "$TMPF"
}

@test "notify: routine transitions are not notifiable" {
  # Notifying every state change gets the channel muted within a day.
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  for label in boucle:working boucle:review boucle:todo boucle:done boucle:merging; do
    run bash -c "export BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_DND_ENABLED=false; source '$TMPF'; boucle_notify 42 '$label' 2>&1"
    assert_success
    assert_output ""
  done
  rm -f "$TMPF"
}

@test "notify: BOUCLE_NOTIFY_EVENTS narrows which transitions fire" {
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  run bash -c "export BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_NOTIFY_EVENTS='approval' BOUCLE_DND_ENABLED=false; source '$TMPF'; boucle_notify 42 'boucle:spec-review' 2>&1"
  assert_success
  assert_output ""
  run bash -c "export BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_NOTIFY_EVENTS='approval' BOUCLE_DND_ENABLED=false; source '$TMPF'; boucle_notify 42 'boucle:approval' 2>&1"
  assert_success
  assert_output --partial "webhook POST failed"
  rm -f "$TMPF"
}

@test "notify: suppressed inside the DND window" {
  # The point of a quiet window is not being contacted during it.
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  # 23:00 UTC sits inside the default 22:00-07:00 window.
  NOW=$(date -u -d '2026-01-15 23:00:00' +%s 2> /dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-15 23:00:00' +%s)
  run bash -c "export BOUCLE_HOME='$PWD' BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=$NOW; source '$TMPF'; boucle_notify 42 'boucle:approval' 2>&1"
  assert_success
  assert_output --partial "inside the DND window"
  refute_output --partial "webhook POST failed"
  rm -f "$TMPF"
}

@test "notify: fires outside the DND window" {
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  NOW=$(date -u -d '2026-01-15 12:00:00' +%s 2> /dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-15 12:00:00' +%s)
  run bash -c "export BOUCLE_HOME='$PWD' BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=$NOW; source '$TMPF'; boucle_notify 42 'boucle:approval' 2>&1"
  assert_success
  assert_output --partial "webhook POST failed"
  rm -f "$TMPF"
}

@test "notify: an unknown format warns and falls back to slack" {
  TMPF=$(mktemp)
  extract_notify "$TMPF"
  run bash -c "export BOUCLE_NOTIFY_URL='http://127.0.0.1:9/dead' BOUCLE_NOTIFY_FORMAT=carrier-pigeon BOUCLE_DND_ENABLED=false; source '$TMPF'; boucle_notify 42 'boucle:approval' 2>&1"
  assert_success
  assert_output --partial "unknown BOUCLE_NOTIFY_FORMAT"
  rm -f "$TMPF"
}

@test "notify: hooked on the transition, not on the state" {
  # The doctor sweep re-applies labels that are already set. Notifying on
  # presence rather than on change would re-fire on every sweep.
  run grep -A3 'forge_issue_labels_set "\$iid" "\$merged"' lib/boucle.sh
  assert_success
  run bash -c "grep -B2 'boucle_notify \"\$iid\" \"\$new\"' lib/boucle.sh | grep -c 'grep -qx \"\$new\"'"
  assert_output "1"
}

# ── File-impact marker parsing (file gate, MR 1) ────────────────────────
# parse_files_marker <notes_json> is a pure parser (no forge calls) that
# extracts the comma-separated paths from the NEWEST `<!-- boucle:files
# v=1 paths=... -->` marker note. Fail-open by construction: absent /
# malformed / unreadable marker → empty (the caller treats empty as "no
# claim = no gate").

@test "parse_files_marker extracts paths from a single matching note" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    notes='"'"'[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- boucle:files v=1 paths=src/components/Card.astro,src/styles/base.css -->"}]'"'"'
    parse_files_marker "$notes"
  '
  assert_success
  assert_output "src/components/Card.astro,src/styles/base.css"
}

@test "parse_files_marker returns empty when no marker note exists" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    parse_files_marker "[]"
  '
  assert_success
  assert_output ""
}

@test "parse_files_marker picks the newest marker by created_at (F5)" {
  # Duplicate markers from a failed update: the NEWEST by created_at wins.
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    notes='"'"'[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- boucle:files v=1 paths=old.astro -->"},{"id":2,"created_at":"2026-01-02T00:00:00Z","body":"<!-- boucle:files v=1 paths=new.astro -->"}]'"'"'
    parse_files_marker "$notes"
  '
  assert_success
  assert_output "new.astro"
}

@test "parse_files_marker returns empty for a malformed marker (no paths=)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    notes='"'"'[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- boucle:files v=1 -->"}]'"'"'
    parse_files_marker "$notes"
  '
  assert_success
  assert_output ""
}

@test "parse_files_marker returns empty for empty input" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    parse_files_marker ""
  '
  assert_success
  assert_output ""
}

@test "parse_files_marker ignores non-marker notes in the same list" {
  # A list mixing ordinary bot/human notes with the marker must extract
  # only the marker note'"'"'s paths.
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    notes='"'"'[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"VERDICT: PASS"},{"id":2,"created_at":"2026-01-02T00:00:00Z","body":"<!-- boucle:files v=1 paths=src/pages/index.astro -->"}]'"'"'
    parse_files_marker "$notes"
  '
  assert_success
  assert_output "src/pages/index.astro"
}

# ── File-impact marker refresh (worker job, MR 1) — F1 guard ────────────
# The refresh is embedded in boucle_ci_worker() (lib/boucle-ci/worker.sh) —
# too integration-coupled to unit-test in bats without a real git repo +
# forge API. We assert the F1 guard condition (skip the refresh when the
# branch has no commits ahead, preserving the last non-empty marker) is
# present in the extracted worker.sh (the inline .gitlab-ci.yml copy was
# replaced by `bin/boucle-ci worker`, refactor 6fb09f7).

@test "worker refresh: F1 guard present in lib/boucle-ci/worker.sh" {
  # The refresh must be gated on a non-empty `git log origin/<default>..HEAD
  # --oneline` — after an adaptive reset the branch has no commits ahead and
  # the claim must NOT be cleared mid-flight.
  run grep -nE 'git log "origin/\$BOUCLE_DEFAULT_BRANCH\.\.HEAD" --oneline' lib/boucle-ci/worker.sh
  assert_success
  run grep -nE 'file-impact marker refresh SKIPPED' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker refresh: best-effort on forge API failure (fail-open)" {
  # A forge API failure during the refresh must log a warning and continue —
  # it must never fail the job (the gate falls back to the stale prediction).
  run grep -nE 'WARN: marker note (update|post) failed' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker refresh: marker note is human-visible (not an empty comment)" {
  # The marker note body is posted as a forge comment that humans see. A body
  # that is only HTML comments (<!-- boucle:files v=1 ... -->) renders as an
  # empty comment on GitHub/GitLab — looks like a glitch. The marker MUST
  # carry a human-visible label so the comment is legible, while keeping the
  # machine marker intact for parse_files_marker (jq contains() still matches).
  # Machine marker still present (single-line grep on the assignment region).
  run grep -nE 'boucle:files v=1 paths=\$refresh_paths' lib/boucle-ci/worker.sh
  assert_success
  # The marker_body assignment must NOT start with an HTML comment — it must
  # lead with visible text so the posted note is not an empty comment.
  run bash -c "awk '/marker_body=/{print; exit}' lib/boucle-ci/worker.sh"
  assert_success
  refute_output --partial 'marker_body="<!--'
}

@test "reviewer: approval message uses forge-aware MR/PR wording" {
  # The reviewer PASS note is posted as a forge comment that humans read.
  # Hardcoding "MR !<iid>" produces GitLab wording on GitHub, where the
  # forge-native reference is "PR #<iid>". The note MUST use forge_mr_ref /
  # forge_mr_term so the wording matches the forge (regression: boucle.dev
  # #69 comment talked about "MR !70" on a GitHub PR).
  # Grep the APPROVAL_MSG block (5 lines around the assignment).
  run bash -c "grep -n -B5 'APPROVAL_MSG=' lib/boucle-ci/reviewer.sh"
  assert_success
  refute_output --partial 'MR !%s'
  refute_output --partial 'MR !${MR_IID'
  assert_output --partial 'forge_mr_ref'
  assert_output --partial 'forge_mr_term'
  # The approval instruction must be forge-aware too (GitHub has no Approve
  # button — regression: boucle.dev #69 told the user to "click Approve").
  assert_output --partial 'forge_mr_approve_instruction'
  refute_output --partial 'click the **Approve** button'
}

@test "reviewer PASS: posts an approval-request note on the PR (not just the issue)" {
  # In mono-user mode on GitHub, self-review is blocked — the human approves
  # with a 👍 reaction on the PR. The reviewer MUST post a short note ON THE
  # PR (forge_mr_note) carrying the boucle:approval-request marker, so the
  # doctor can find it by marker and poll its reactions.
  run bash -c "grep -n -A3 'forge_mr_note \"\$MR_IID\"' lib/boucle-ci/reviewer.sh | grep -E 'approval-request'"
  assert_success
}

@test "doctor: mono-user approval polls reactions on the PR approval-request note (no auto-merge on VERDICT: PASS)" {
  # The old doctor auto-detected VERDICT: PASS in PR notes and merged — no
  # human signal. The new contract: poll for a 👍 reaction on the
  # boucle:approval-request note, and MUST NOT treat VERDICT: PASS alone
  # as an approval signal.
  # (1) No jq filter uses VERDICT: PASS as an approval trigger.
  run bash -c "grep -nE 'jq.*VERDICT: PASS|select.*VERDICT: PASS' lib/boucle-ci/doctor.sh"
  assert_failure
  # (2) The doctor has a helper that polls reactions on the approval-request note.
  run bash -c "awk '/doctor_mr_approval_emoji\\(\\) \\{/,/^  \\}/' lib/boucle-ci/doctor.sh | grep forge_note_reactions"
  assert_success
}

# ── Mono-user MR-approval gate (emoji-reaction) ───────────────────────
# Regression suite for boucle.dev #40 (2026-08-18): in mono-user mode the
# doctor auto-merged on the reviewer'"'"'s PASS verdict comment alone — no
# human ever approved. The human MR gate documented in LOOP.md ("MR approval
# stays human-gated") was silently removed. These tests pin the fix: the
# gate is a 👍 emoji on the reviewer'"'"s approval-request note on the PR,
# polled by the doctor — the same mechanism as the spec gate.

@test "reviewer: PASS message branches by mono-user mode (emoji vs Approve)" {
  # The PASS message MUST tell the human which action approves the merge:
  #  - mono-user: react with 👍 on the PASS comment (self-approval unreliable)
  #  - bot mode: click Approve / submit an approving review (native, works)
  run bash -c "grep -n 'boucle_mono_user' lib/boucle-ci/reviewer.sh"
  assert_success
  assert_output --partial 'boucle_mono_user'
}

@test "reviewer: race-condition recovery is skipped in mono-user mode" {
  # The race-recovery block polls forge_mr_approvals to catch a human who
  # approved the MR BEFORE the reviewer PASSed. In mono-user mode, native
  # self-approval is unreliable, so polling it is dead code AND would
  # short-circuit the new emoji gate. The block MUST be guarded by
  # `! boucle_mono_user` so it only runs in bot mode.
  run bash -c "grep -c 'boucle_mono_user' lib/boucle-ci/reviewer.sh || true"
  assert_success
  count=${output}
  [ "$count" -ge 2 ] || { echo "expected >=2 boucle_mono_user refs, got $count"; false; }
}

@test "reviewer: posts approval-request note on the PR in mono-user mode" {
  # The reviewer MUST post a note ON THE PR (forge_mr_note) carrying the
  # boucle:approval-request marker in mono-user mode, so the doctor can
  # find it by marker and poll its reactions for the 👍.
  run bash -c "grep -n 'boucle:approval-request' lib/boucle-ci/reviewer.sh"
  assert_success
  assert_output --partial 'boucle:approval-request'
  run bash -c "grep -n 'forge_mr_note' lib/boucle-ci/reviewer.sh"
  assert_success
}

@test "doctor: no VERDICT PASS auto-approve block remains" {
  # The old mono-user recovery treated the reviewer'"'"'s PASS verdict bot
  # comment as the approval signal and merged with no human action. The
  # string "VERDICT: PASS" must NOT appear anywhere in doctor.sh — not in
  # code, not in comments.
  run bash -c "grep -c 'VERDICT: PASS' lib/boucle-ci/doctor.sh || true"
  assert_success
  assert_output "0"
}

@test "doctor: doctor_mr_approval_emoji helper polls forge_note_reactions" {
  # The new human MR gate: the doctor polls the approval-request note on
  # the PR for a canonical approval emoji via forge_note_reactions.
  run bash -c "awk '/doctor_mr_approval_emoji\(\) \{/,/^  \}/' lib/boucle-ci/doctor.sh | grep forge_note_reactions"
  assert_success
  assert_output --partial 'forge_note_reactions'
}

@test "doctor: mono-user recovery calls doctor_mr_approval_emoji (not VERDICT detect)" {
  # Both recovery paths (boucle:working/review and boucle:human/approval)
  # MUST call doctor_mr_approval_emoji in mono-user mode, not the old
  # jq VERDICT: PASS detection.
  run bash -c "grep -n 'doctor_mr_approval_emoji' lib/boucle-ci/doctor.sh"
  assert_success
  # At least 3 lines: 1 definition + 2 call sites.
  count=$(/usr/bin/grep -c 'doctor_mr_approval_emoji' lib/boucle-ci/doctor.sh)
  [ "$count" -ge 3 ] || { echo "expected >=3, got $count"; false; }
# ── Quality gate on the loop's own commits (#51) ──────────────────────
# 37 of 40 consecutive commits reached the default branch unlinted because
# worker commits carried [skip ci], which disables the check job. The
# anti-feedback guard was never [skip ci] — it lives in bin/update.

@test "gate: the worker prompt does not ask for [skip ci]" {
  run bash -c "grep -c 'skip ci' bin/jc || true"
  assert_output "0"
}

@test "gate: the worker's commits do not carry [skip ci]" {
  run bash -c "grep -c 'skip ci' lib/boucle-ci/worker.sh || true"
  assert_output "0"
}

@test "gate: the worker agent is told NOT to add it, and why" {
  run grep -q 'Do NOT add `\[skip ci\]`' .jcode/agents/worker.md
  assert_success
  # The reason must travel with the rule, or the next edit restores it.
  run grep -q 'every loop job requires a pipeline trigger' .jcode/agents/worker.md
  assert_success
}

@test "gate: the anti-feedback guard is in bin/update, not in a commit marker" {
  run grep -q 'BOUCLE_PIPELINE_SOURCE:-}" = "push"' bin/update
  assert_success
}

@test "gate: no loop job can start from a push pipeline" {
  # This is what makes dropping [skip ci] safe: a worker push cannot begin
  # another iteration because every loop job requires a trigger.
  run python3 -c "
import yaml, sys
d = yaml.safe_load(open('.gitlab-ci.yml'))
loop = ['dispatch','triage','worker','reviewer','merger','post-merge','catchup','e2e']
bad = []
for name in loop:
    allow = [r.get('if','') for r in d[name].get('rules',[]) if r.get('when','on_success') != 'never']
    if not all('trigger' in c for c in allow):
        bad.append((name, allow))
print('OK' if not bad else 'LOOP JOB RUNNABLE ON PUSH: %s' % bad)
"
  assert_output "OK"
}

@test "gate: check runs on worker branches" {
  run python3 -c "
import yaml
d = yaml.safe_load(open('.gitlab-ci.yml'))
allow = [r.get('if','') for r in d['check'].get('rules',[]) if r.get('when','on_success') != 'never']
print('OK' if any('boucle' in c for c in allow) else 'MISSING: %s' % allow)
"
  assert_output "OK"
}
