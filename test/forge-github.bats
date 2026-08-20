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

@test "forge_mr_approve_instruction: mono-user is forge-appropriate (approved on GitHub, 👍 on GitLab)" {
  # In mono-user mode the human IS the bot — the PR author is the approver.
  # Neither GitHub nor GitLab reliably counts an author'"'"'s own approval, so
  # a human signal on the PR is the ONLY reliable MR gate. The signal is
  # forge-appropriate: `approved` magic word on GitHub (issue_comment webhook
  # fires reliably; reactions have NO webhook on GitHub) or 👍 emoji on GitLab
  # (emoji webhook fires reliably). The instruction MUST point at the right
  # signal per forge.
  # Regression (boucle.dev #40, 2026-08-18): the doctor auto-merged on the
  # PASS verdict alone — the gate was decorative. The human gate is now mandatory.
  run bash -c 'export BOUCLE_FORGE=github BOUCLE_MONO_USER=true; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "approved"
  refute_output --partial "approving review"
  refute_output --partial "👍"

  run bash -c 'export BOUCLE_FORGE=gitlab BOUCLE_MONO_USER=true; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "👍"
  refute_output --partial "Approve** button"

  # Bot mode stays per-forge (native Approve / approving review works when
  # the approver is a distinct account from the author).
  run bash -c 'export BOUCLE_FORGE=github BOUCLE_MONO_USER=false; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "approving review"

  run bash -c 'export BOUCLE_FORGE=gitlab BOUCLE_MONO_USER=false; source bin/forge/common.sh; forge_mr_approve_instruction'
  assert_success
  assert_output --partial "Approve** button"
}

@test "github forge_ci_var_set uses gh variable set (not secret set)" {
  # The version needs to be READABLE (bin/update compares current vs upstream),
  # so it must be a GitHub Actions Variable (plaintext), NOT a Secret
  # (write-only). forge_ci_var_set MUST route through `gh variable set`.
  # NOTE: forge_ci_var_set pipes the value into gh (`echo | gh variable set`),
  # so gh runs in a subshell — the mock must echo its args to stdout rather
  # than capture into an array (functions/arrays don't propagate to subshells).
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      printf "%s " "$@"
    }
    source bin/forge/github.sh
    forge_ci_var_set "BOUCLE_VERSION" "abc123"
  '
  assert_success
  assert_output --partial "variable set"
  assert_output --partial "BOUCLE_VERSION"
  assert_output --partial "test/repo"
  refute_output --partial "secret set"
}

@test "github forge_ci_var_get uses gh variable get" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "variable" ] && [ "$2" = "get" ] || return 0
      printf "abc123"
    }
    source "$PWD/bin/forge/github.sh"
    forge_ci_var_get "BOUCLE_VERSION"
  '
  assert_success
  assert_output "abc123"
}

@test "github forge_ci_var_list uses gh variable list" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "variable" ] && [ "$2" = "list" ] || return 0
      printf "NAME  VALUE\nBOUCLE_VERSION  abc123\nOTHER  x\n"
    }
    source "$PWD/bin/forge/github.sh"
    forge_ci_var_list
  '
  assert_success
  assert_output --partial "BOUCLE_VERSION"
  assert_output --partial "OTHER"
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

@test "github forge_mr_merge waits out unstable, then merges once checks go clean" {
  # unstable = mergeable BUT non-required checks failing/pending. The merge
  # MUST wait for the checks to settle and merge on clean — not merge
  # immediately (2026-08: merging on unstable landed red code on main).
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    BOUCLE_MERGE_POLL_SLEEP=0
    cnt=$(mktemp)
    echo 0 > "$cnt"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        printf "%s" "{\"sha\":\"deadbeef\",\"merged\":true}"
      elif [[ " $* " == *"/pulls/"* ]]; then
        n=$(cat "$cnt")
        echo $((n + 1)) > "$cnt"
        if [ "$n" -eq 0 ]; then
          printf "%s" "{\"mergeable_state\":\"unstable\"}"
        else
          printf "%s" "{\"mergeable_state\":\"clean\"}"
        fi
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_success
  assert_output "deadbeef"
}

@test "github forge_mr_merge refuses to merge when checks stay red (unstable)" {
  # If the checks never go green, the merge MUST be refused — merging would
  # put code that fails the repo'"'"'s own gate on the default branch. The
  # merger treats the empty SHA as a failed merge and escalates.
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    BOUCLE_MERGE_POLL_MAX=2
    BOUCLE_MERGE_POLL_SLEEP=0
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        printf "%s" "{\"sha\":\"must-not-merge\",\"merged\":true}"
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"unstable\"}"
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_failure
  assert_output --partial "refusing to merge red checks"
  refute_output --partial "must-not-merge"
}

@test "github forge_mr_merge_status maps unstable to checking (never mergeable)" {
  # The merger polls forge_mr_merge_status before merging. Reporting
  # "mergeable" while checks are red let the merger merge PRs that fail the
  # check gate (2026-08: recurring shfmt failures merged through to main).
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      printf "%s" "{\"mergeable_state\":\"unstable\"}"
    }
    source bin/forge/github.sh
    forge_mr_merge_status 42
  '
  assert_success
  assert_output "checking"

  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      printf "%s" "{\"mergeable_state\":\"clean\"}"
    }
    source bin/forge/github.sh
    forge_mr_merge_status 42
  '
  assert_success
  assert_output "mergeable"
}

@test "github forge_mr_merge echoes nothing on stdout when the merge PUT fails" {
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        echo "gh: HTTP 409: Pull Request is not mergeable" >&2
        return 1
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"clean\"}"
      fi
    }
    source bin/forge/github.sh
    out=$(forge_mr_merge 42 2>/dev/null)
    echo "out=[$out]"
  '
  assert_success
  assert_output --partial "out=[]"
}

@test "github forge_mr_merge surfaces the gh api stderr when the PUT returns no SHA" {
  # Regression: _gh_api added --paginate to a PUT, gh rejected it on
  # stderr (which _gh_api discarded), resp was empty, and the merger
  # reported "merge API call failed" even though the PUT never ran.
  # The fix calls gh api directly and captures stderr so the failure is
  # diagnosable. See boucle.dev PR #72 (merge reported as failed, was
  # actually merged manually as a workaround).
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        echo "the \`--paginate\` option is not supported for non-GET requests" >&2
        return 1
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"clean\"}"
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42 >/dev/null
  '
  assert_success
  assert_output --partial "returned no SHA"
  assert_output --partial "--paginate"
}

@test "github forge_mr_merge never passes --paginate to a PUT (the silent-failure bug)" {
  # The root cause: _gh_api adds --paginate, which gh rejects for non-GET
  # requests. forge_mr_merge MUST call gh api directly for the PUT. This
  # test fails if the merge PUT is ever routed through _gh_api again.
  run bash -c '
    BOUCLE_PROJECT_ID="test/repo"
    gh() {
      [ "$1" = "api" ] || return 0
      if [[ " $* " == *"-X PUT"* && " $* " == *"/merge"* ]]; then
        # If --paginate ever leaks into the PUT, fail loudly.
        if [[ " $* " == *"--paginate"* ]]; then
          echo "BUG: --paginate reached the merge PUT" >&2
          return 1
        fi
        printf "%s" "{\"sha\":\"abc123\",\"merged\":true}"
      elif [[ " $* " == *"/pulls/"* ]]; then
        printf "%s" "{\"mergeable_state\":\"clean\"}"
      fi
    }
    source bin/forge/github.sh
    forge_mr_merge 42
  '
  assert_success
  assert_output "abc123"
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
