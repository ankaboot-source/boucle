#!/usr/bin/env bats
# test/review-command.bats — BOUCLE_REVIEW_COMMAND, the reviewer-side analog
# of BOUCLE_E2E_COMMAND.
#
# The command runs against the deployed preview BEFORE the agent; its output
# is injected into the agent's prompt as evidence (bin/jc), never as work the
# agent redoes. Contract: fail-open on the STAGE (a crashing command never
# blocks the loop), fail-closed on the VERDICT (the status reaches the agent).

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
  source lib/boucle-ci/reviewer.sh
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "lib/boucle-ci/reviewer.sh parses without syntax error" {
  run bash -n lib/boucle-ci/reviewer.sh
  assert_success
}

# ── Status mapping ────────────────────────────────────────────────────

@test "exit 0 yields a PASS evidence block" {
  BOUCLE_REVIEW_COMMAND='echo "NAV: PASS — Le formulaire s'"'"'affiche"'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "PASS (exit 0)"
  assert_output --partial "NAV: PASS"
}

@test "a non-zero exit yields a FAIL evidence block" {
  BOUCLE_REVIEW_COMMAND='echo "NAV: FAIL — Le formulaire ne s'"'"'affiche pas"; exit 1'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success # fail-open on the stage
  assert_output --partial "FAIL (exit 1)"
  assert_output --partial "NAV: FAIL"
}

@test "a timeout is reported as TIMEOUT, not as FAIL" {
  BOUCLE_REVIEW_COMMAND='sleep 5'
  BOUCLE_REVIEW_COMMAND_TIMEOUT=1
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "TIMEOUT (exit 124)"
}

@test "a crashing command never fails the stage" {
  BOUCLE_REVIEW_COMMAND='this-binary-does-not-exist'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "FAIL (exit 127)"
}

# ── $BASE contract ────────────────────────────────────────────────────

@test "the command receives the preview URL as \$BASE" {
  BOUCLE_REVIEW_COMMAND='echo "base=$BASE"'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "base=https://preview.example.test"
}

@test "the command receives BOUCLE_HOME so it can source bin/nav-assert" {
  BOUCLE_REVIEW_COMMAND='test -r "$BOUCLE_HOME/bin/nav-assert" && echo "nav-assert reachable"'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "nav-assert reachable"
}

# ── Output hygiene ────────────────────────────────────────────────────

@test "progress messages go to stderr, never into the evidence block" {
  BOUCLE_REVIEW_COMMAND='echo "NAV: PASS — ok"'
  run bash -c "
    export BOUCLE_HOME='$BOUCLE_HOME' BOUCLE_FORGE=gitlab BOUCLE_FORGE_HOST=h BOUCLE_PROJECT_ID=1
    export BOUCLE_WORKSPACE='$BOUCLE_WORKSPACE'
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/reviewer.sh
    BOUCLE_REVIEW_COMMAND='echo \"NAV: PASS — ok\"'
    boucle_review_command_evidence 'https://preview.example.test' 2>/dev/null
  "
  assert_success
  refute_output --partial "[boucle] Running BOUCLE_REVIEW_COMMAND"
  assert_output --partial "NAV: PASS — ok"
}

@test "a malformed timeout falls back to the default instead of failing" {
  BOUCLE_REVIEW_COMMAND='echo ok'
  BOUCLE_REVIEW_COMMAND_TIMEOUT='not-a-number'
  run boucle_review_command_evidence "https://preview.example.test"
  assert_success
  assert_output --partial "PASS (exit 0)"
}
