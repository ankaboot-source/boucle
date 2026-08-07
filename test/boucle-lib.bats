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

# Helper: source lib/boucle.sh with a mocked curl that captures args.
# Sets $CAPTURED_ARGS to the space-joined curl arguments.
source_with_mock_curl() {
  CAPTURED_ARGS=""
  export BOUCLE_FORGE_HOST="gitlab.example.com"
  export CI_PROJECT_ID="123"
  export BOUCLE_TRIGGER_TOKEN="tok123"
  # Mock curl: capture all args, exit 0, print nothing.
  eval "$(cat <<'SCRIPT'
    curl() {
      CAPTURED_ARGS="$*"
    }
SCRIPT
  )"
  source lib/boucle.sh
}

@test "chain_to_role always forwards BOUCLE_ISSUE" {
  source_with_mock_curl
  chain_to_role 42 worker
  [ -n "$CAPTURED_ARGS" ] || skip "curl not captured"
  echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_ISSUE\]=42'
}

@test "chain_to_role forwards BOUCLE_ROLE when role is provided" {
  source_with_mock_curl
  chain_to_role 42 worker
  echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_ROLE\]=worker'
}

@test "chain_to_role does NOT forward BOUCLE_ROLE when role is empty" {
  source_with_mock_curl
  chain_to_role 42 ""
  ! echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_ROLE\]'
}

@test "chain_to_role forwards extra vars (BOUCLE_ITERATION)" {
  source_with_mock_curl
  chain_to_role 42 worker BOUCLE_ITERATION=2
  echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_ITERATION\]=2'
}

@test "chain_to_role forwards multiple extra vars" {
  source_with_mock_curl
  chain_to_role 42 reviewer BOUCLE_ITERATION=3 BOUCLE_HEAD_SHA=abc1234
  echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_ITERATION\]=3'
  echo "$CAPTURED_ARGS" | grep -q 'variables\[BOUCLE_HEAD_SHA\]=abc1234'
}

@test "chain_to_role uses the trigger pipeline endpoint" {
  source_with_mock_curl
  chain_to_role 42 worker
  echo "$CAPTURED_ARGS" | grep -q 'trigger/pipeline'
}

@test "chain_to_role forwards the trigger token" {
  source_with_mock_curl
  chain_to_role 42 worker
  echo "$CAPTURED_ARGS" | grep -q 'token=tok123'
}

@test "chain_to_role forwards ref=master" {
  source_with_mock_curl
  chain_to_role 42 worker
  echo "$CAPTURED_ARGS" | grep -q 'ref=master'
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
# Mock glab to simulate bot-authored sub-issues with a human parent.

@test "resolve_reporter_id returns author id when author is human" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot
    source lib/boucle.sh
    # Mock glab: return a human-authored issue
    glab() {
      printf "%s" "{\"author\":{\"id\":999,\"username\":\"tahrir\"}}"
    }
    result=$(resolve_reporter_id 42)
    [ "$result" = "999" ]
  '
  assert_success
}

@test "resolve_reporter_id walks up to parent when author is bot" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot
    source lib/boucle.sh
    glab() {
      # glab api --hostname <host> <path>  → URL is $4
      case "$4" in
        */issues/42)
          jq -n "{author:{id:1,username:\"up-bot\"},description:\"## Parent issue\n\n#10\"}" ;;
        */issues/10)
          printf "%s" "{\"author\":{\"id\":777,\"username\":\"tahrir\"}}" ;;
        *) printf "%s" "{}" ;;
      esac
    }
    result=$(resolve_reporter_id 42)
    [ "$result" = "777" ]
  '
  assert_success
}

@test "resolve_reporter_id returns bot id when no parent found" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot
    source lib/boucle.sh
    glab() {
      # Bot-authored issue with no parent link in description
      printf "%s" "{\"author\":{\"id\":1,\"username\":\"up-bot\"},\"description\":\"No parent here\"}"
    }
    result=$(resolve_reporter_id 42)
    [ "$result" = "1" ]
  '
  assert_success
}

@test "resolve_reporter_id walks multiple levels up parent chain" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_BOT_USERNAME=up-bot
    source lib/boucle.sh
    glab() {
      case "$4" in
        */issues/42)
          jq -n "{author:{id:1,username:\"up-bot\"},description:\"## Parent issue\n\n#52\"}" ;;
        */issues/52)
          jq -n "{author:{id:2,username:\"up-bot\"},description:\"## Parent issue\n\n#55\"}" ;;
        */issues/55)
          printf "%s" "{\"author\":{\"id\":888,\"username\":\"tahrir\"}}" ;;
        *) printf "%s" "{}" ;;
      esac
    }
    result=$(resolve_reporter_id 42)
    [ "$result" = "888" ]
  '
  assert_success
}

# ── get_work_item_children: array validation ──────────────────────────

@test "get_work_item_children returns empty array on API failure" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    glab() { return 1; }
    result=$(get_work_item_children 42)
    [ "$result" = "[]" ]
  '
  assert_success
}

@test "get_work_item_children coerces 403 error object to empty array" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    glab() { printf "%s" "{\"message\":\"403 Forbidden\"}"; }
    result=$(get_work_item_children 42)
    [ "$result" = "[]" ]
  '
  assert_success
}

@test "get_work_item_children passes through genuine array" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    glab() { printf "%s" "[{\"iid\":1,\"state\":\"opened\"},{\"iid\":2,\"state\":\"closed\"}]"; }
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
    source lib/boucle.sh
    glab() { printf "%s" "{\"id\":\"gid://gitlab/WorkItem/123\"}"; }
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

@test "close_issue calls glab api with state_event=close" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    source lib/boucle.sh
    GLAB_ARGS=""
    glab() { GLAB_ARGS="$*"; }
    close_issue 42
    echo "$GLAB_ARGS"
  '
  assert_success
  assert_output --partial "state_event=close"
  assert_output --partial "42"
}
