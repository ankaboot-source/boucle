#!/usr/bin/env bats
# test/e2e-command.bats — command-mode e2e (BOUCLE_E2E_COMMAND).
#
# When BOUCLE_E2E_COMMAND is set, the e2e stage runs the consumer's verify
# command instead of the URL-probing agent. Exit 0=PASS, non-zero=FAIL,
# 124=timeout. This is the analog of autonomous-dev-team's E2E_COMMAND
# contract, for non-static repos (Docker-compose backends, Ansible playbook
# repos, CLI tools) where verification is a build+test command, not a URL probe.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"
  export BOUCLE_FORGE=gitlab
  export BOUCLE_FORGE_HOST=gitlab.example.com
  export BOUCLE_PROJECT_ID=1
  # shellcheck disable=SC2154 # BATS_TEST_TMPDIR is provided by bats
  export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
  # shellcheck disable=SC1091
  source bin/forge/common.sh
  # shellcheck disable=SC1091
  source lib/boucle.sh
  # shellcheck disable=SC1091
  source lib/boucle-ci/e2e.sh
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "lib/boucle-ci/e2e.sh parses without syntax error" {
  run bash -n lib/boucle-ci/e2e.sh
  assert_success
}

# ── Command-mode smoke test (no issue context) ────────────────────────
# The deploy-triggered smoke test has no BOUCLE_ISSUE: command-mode exits
# 0 on PASS and 1 on FAIL, mirroring the HTTP smoke test it replaces.

@test "command-mode PASS: BOUCLE_E2E_COMMAND=true exits 0" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/e2e.sh
    BOUCLE_E2E_COMMAND="true"
    boucle_ci_e2e
  '
  assert_success
  assert_output --partial "Command-mode e2e"
  assert_output --partial "PASS"
}

@test "command-mode FAIL: BOUCLE_E2E_COMMAND='exit 1' exits 1" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/e2e.sh
    BOUCLE_E2E_COMMAND="exit 1"
    boucle_ci_e2e
  '
  assert_failure
  assert_output --partial "FAIL"
}

@test "command-mode timeout: BOUCLE_E2E_COMMAND='sleep 10' with timeout 1 exits 1" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/e2e.sh
    BOUCLE_E2E_COMMAND="sleep 10"
    BOUCLE_E2E_COMMAND_TIMEOUT=1
    boucle_ci_e2e
  '
  assert_failure
  assert_output --partial "FAIL"
}

@test "command-mode with real command: echo + test exits 0" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/e2e.sh
    BOUCLE_E2E_COMMAND="echo hello && test -f /etc/hostname"
    boucle_ci_e2e
  '
  assert_success
  assert_output --partial "PASS"
}

# ── Evidence parser (issue-triggered path) ────────────────────────────
# The evidence block is only surfaced in the issue-triggered path (posted in
# the verdict comment). Mock forge_issue_note to capture the comment and
# assert the custom evidence parser output is present.

@test "evidence parser is invoked and its output lands in the verdict comment" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE="$BATS_TEST_TMPDIR"
    export BOUCLE_ISSUE=42
    export MR_HEAD=abcdef123456
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/e2e.sh
    # Mock the forge layer used by the shared verdict routing.
    forge_issue_note() { echo "NOTE:$1|$2"; }
    forge_issue_get() { echo "{\"title\":\"t\",\"description\":\"\"}"; }
    forge_issue_create() { echo "99"; }
    forge_issue_assign() { :; }
    set_boucle_label() { :; }
    close_issue() { :; }
    maybe_close_parent() { :; }
    maybe_unblock_dependents() { :; }
    forge_pipeline_list_active() { echo "[]"; }
    # A custom evidence parser: reads the log as $1, emits custom markdown.
    BOUCLE_E2E_COMMAND="echo verify-output"
    BOUCLE_E2E_COMMAND_EVIDENCE_PARSER="cat \$1 | sed \"s/verify-output/CUSTOM-EVIDENCE/\""
    boucle_ci_e2e
  '
  assert_success
  assert_output --partial "CUSTOM-EVIDENCE"
  assert_output --partial "VERDICT: PASS"
}

# ── boucle_is_command_e2e helper ─────────────────────────────────────

@test "boucle_is_command_e2e returns true when BOUCLE_E2E_COMMAND is set" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    BOUCLE_E2E_COMMAND="true"
    boucle_is_command_e2e && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "TRUE"
}

@test "boucle_is_command_e2e returns false when BOUCLE_E2E_COMMAND is unset" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    unset BOUCLE_E2E_COMMAND
    boucle_is_command_e2e && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "FALSE"
}

@test "boucle_is_command_e2e returns false when BOUCLE_E2E_COMMAND is empty" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    BOUCLE_E2E_COMMAND=""
    boucle_is_command_e2e && echo "TRUE" || echo "FALSE"
  '
  assert_success
  assert_output "FALSE"
}

# ── boucle_resolve_live_url: no pages.dev fallback in command-mode ────

@test "boucle_resolve_live_url returns empty (no pages.dev fallback) when command-mode active" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    BOUCLE_E2E_COMMAND="true"
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_LIVE_URL=""
    BOUCLE_PRODUCTION_URL=""
    BOUCLE_DEPLOY_PROJECT="my-site"
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output ""
}

@test "boucle_resolve_live_url still returns an explicit BOUCLE_LIVE_URL in command-mode" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    BOUCLE_E2E_COMMAND="true"
    BOUCLE_LIVE_URL="https://example.com"
    boucle_resolve_live_url ""
  '
  assert_success
  assert_output "https://example.com"
}

# ── post-merge external mode guard ───────────────────────────────────
# In external deploy mode, BOUCLE_LIVE_URL is only required when command-mode
# e2e is NOT active. When BOUCLE_E2E_COMMAND is set, the guard must not fail.

@test "post-merge external mode does not require BOUCLE_LIVE_URL when command-mode active" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    BOUCLE_E2E_COMMAND="true"
    BOUCLE_LIVE_URL=""
    # The external-mode guard condition from post-merge.sh:
    if [ -z "${BOUCLE_LIVE_URL:-}" ] && [ -z "${BOUCLE_E2E_COMMAND:-}" ]; then
      echo "GUARD_FAIL"
      exit 1
    fi
    echo "GUARD_OK"
  '
  assert_success
  assert_output "GUARD_OK"
}

@test "post-merge external mode still requires BOUCLE_LIVE_URL when command-mode inactive" {
  run bash -c '
    export BOUCLE_HOME="$PWD" BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    source bin/forge/common.sh
    source lib/boucle.sh
    unset BOUCLE_E2E_COMMAND
    BOUCLE_LIVE_URL=""
    if [ -z "${BOUCLE_LIVE_URL:-}" ] && [ -z "${BOUCLE_E2E_COMMAND:-}" ]; then
      echo "GUARD_FAIL"
      exit 1
    fi
    echo "GUARD_OK"
  '
  assert_failure
  assert_output "GUARD_FAIL"
}
