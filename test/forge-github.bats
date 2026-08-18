#!/usr/bin/env bats
# test/forge-github.bats — tests for bin/forge/github.sh.
#
# The GitHub forge backend translates the GitLab-style field names the
# engine's callers use (e.g. "description") into the GitHub REST API's
# field names (e.g. "body"). forge_issue_get already normalises body→
# description on read; forge_issue_update MUST normalise description→body
# on write, or every in-place board refresh and every depends-on marker
# write is a silent no-op (the PATCH returns 200, GitHub ignores the
# unknown field, nothing changes).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

@test "github forge_issue_update maps description→body (the board refresh bug)" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    captured=()
    gh() {
      [ "$1" = "api" ] || return 0
      shift
      captured+=("$@")
    }
    _gh_api_silent() { GH_TOKEN=x gh api "$@" > /dev/null 2>&1 || return $?; }
    source bin/forge/github.sh
    forge_issue_update 42 "description" "NEW BODY"
    printf "%s " "${captured[@]}"
  '
  assert_success
  refute_output --partial "description="
  assert_output --partial "body=NEW BODY"
}

@test "github forge_issue_update passes title through unchanged" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    captured=()
    gh() {
      [ "$1" = "api" ] || return 0
      shift
      captured+=("$@")
    }
    _gh_api_silent() { GH_TOKEN=x gh api "$@" > /dev/null 2>&1 || return $?; }
    source bin/forge/github.sh
    forge_issue_update 42 "title" "Hello"
    printf "%s " "${captured[@]}"
  '
  assert_success
  assert_output --partial "title=Hello"
}

@test "github forge_issue_get normalises .body into .description on read" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      printf '"'"'{"number":7,"body":"read me","title":"t"}'"'"'
    }
    _gh_api() { GH_TOKEN=x gh api --paginate "$@" 2> /dev/null; }
    source bin/forge/github.sh
    forge_issue_get 7 | jq -r ".description"
  '
  assert_success
  assert_output "read me"
}

@test "forge_mr_approve_instruction is forge-aware (GitHub has no Approve button)" {
  # GitHub has no "Approve" button — approval is via an approving code review.
  # GitLab has the Approve button. The instruction MUST match the forge.
  run bash -c 'export BOUCLE_FORGE=github; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "approving review"
  refute_output --partial "Approve button"

  run bash -c 'export BOUCLE_FORGE=gitlab; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "Approve** button"
}

# ── forge_mr_merge: MUST echo the merge commit SHA on success ────────────
# The merger (lib/boucle-ci/merger.sh) captures the output as MERGE_SHA and
# treats an empty value as "merge API call failed" → boucle:human escalation.
# forge_mr_merge used _gh_api_silent (discards the response) and returned 0
# without echoing anything, so EVERY successful GitHub merge was reported as
# a failure. The PR was actually merged, but the loop escalated to human and
# never chained to post-merge (merged code never deployed). Observed on the
# boucle.dev consumer: PR #51 and PR #44 both merged but reported as failed.

@test "github forge_mr_merge echoes the merge commit SHA on a clean merge" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        printf "%s" "{\"sha\":\"abc123def456789\",\"merged\":true,\"message\":\"ok\"}"
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"clean\"}"
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_success
  assert_output "abc123def456789"
}

@test "github forge_mr_merge echoes the SHA when unstable (checks running)" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        printf "%s" "{\"sha\":\"deadbeef\",\"merged\":true}"
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"unstable\"}"
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_success
  assert_output "deadbeef"
}

@test "github forge_mr_merge echoes nothing when the merge PUT fails" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        return 1
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"clean\"}"
      fi
    }
    source bin/forge/github.sh
    out=$(forge_mr_merge 42)
    echo "out=[$out]"
  '
  assert_success
  assert_output --partial "out=[]"
}

@test "github forge_mr_merge returns non-zero on a dirty (conflict) state" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      printf "%s" "{\"mergeable_state\":\"dirty\"}"
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_failure
  assert_output --partial "merge conflicts"
}
