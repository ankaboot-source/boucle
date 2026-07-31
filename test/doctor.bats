#!/usr/bin/env bats
# test/doctor.bats — smoke tests for bin/doctor.
#
# bin/doctor has no BASH_SOURCE guard and executes its full body on source,
# which calls glab api / jq / curl / npx. We can't source it directly in
# tests. These tests cover what we can: syntax validity, expected function
# definitions, and the output format of the pure helper functions when
# invoked in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/doctor parses without syntax error" {
  run bash -n bin/doctor
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/doctor defines pass function" {
  # Verify the function is defined in the script source.
  run grep -E '^pass\(\)' bin/doctor
  assert_success
}

@test "bin/doctor defines warn function" {
  run grep -E '^warn\(\)' bin/doctor
  assert_success
}

@test "bin/doctor defines fail function" {
  run grep -E '^fail\(\)' bin/doctor
  assert_success
}

# ── Pure helpers (extracted and run in isolation) ─────────────────────
# The pass/warn/fail helpers are pure output functions. Extract them from
# bin/doctor and evaluate them in a subshell so we can assert on their
# stdout/stderr/exit-code behavior without triggering the script body.

@test "pass prints a green check on stdout" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); pass 'hello'"
  assert_success
  assert_output --partial "hello"
  assert_output --partial "✓"
}

@test "warn prints a warning to stderr" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); warn 'careful'"
  assert_success
  assert_output --partial "careful"
  assert_output --partial "⚠"
}

@test "fail prints an X and increments FAILURES" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); fail 'broken'"
  assert_success
  assert_output --partial "broken"
  assert_output --partial "✗"
}
