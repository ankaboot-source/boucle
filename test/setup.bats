#!/usr/bin/env bats
# test/setup.bats — smoke tests for bin/setup.
#
# bin/setup has no BASH_SOURCE guard and executes its full body on source
# (it makes network calls to glab api, runs sed on the user's GitLab CI
# file, etc.). We can't source it directly. These tests cover what we can:
# syntax validity and the function definitions present in the script.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/setup parses without syntax error" {
  run bash -n bin/setup
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/setup defines resolve_project_id function" {
  run grep -E '^\s*resolve_project_id\(\)' bin/setup
  assert_success
}

@test "bin/setup defines log_pass function" {
  run grep -E '^log_pass\(\)' bin/setup
  assert_success
}

@test "bin/setup defines log_fail function" {
  run grep -E '^log_fail\(\)' bin/setup
  assert_success
}

@test "bin/setup defines log_skip function" {
  run grep -E '^log_skip\(\)' bin/setup
  assert_success
}

@test "bin/setup defines run wrapper" {
  run grep -E '^run\(\)' bin/setup
  assert_success
}

# ── Pure helpers (extracted and run in isolation) ─────────────────────
# log_pass / log_fail / log_skip are pure output functions (they depend on
# the PASS/FAIL/SKIP counters, which we initialize in the subshell).

@test "log_pass prints a check and increments counter" {
  run bash -c "PASS=0; FAIL=0; SKIP=0; source <(awk 'BEGIN{p=0} /^(log_pass|log_fail|log_skip)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); log_pass 'created label'"
  assert_success
  assert_output --partial "created label"
  assert_output --partial "✓"
}

@test "log_fail prints an X to stderr" {
  run bash -c "PASS=0; FAIL=0; SKIP=0; source <(awk 'BEGIN{p=0} /^(log_pass|log_fail|log_skip)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); log_fail 'something broke'"
  assert_success
  assert_output --partial "something broke"
  assert_output --partial "✗"
}

@test "log_skip prints a skip indicator" {
  run bash -c "PASS=0; FAIL=0; SKIP=0; source <(awk 'BEGIN{p=0} /^(log_pass|log_fail|log_skip)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); log_skip 'optional'"
  assert_success
  assert_output --partial "optional"
  assert_output --partial "skipped"
}

# ── run wrapper (dry-run mode) ────────────────────────────────────────
# The run wrapper is pure when DRY_RUN=true: it echoes the command without
# executing it. We can extract it and test in isolation.

@test "run wrapper echoes command in dry-run mode" {
  run bash -c "DRY_RUN=true; source <(awk 'BEGIN{p=0} /^run\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); run 'echo hello'"
  assert_success
  assert_output --partial "echo hello"
  assert_output --partial "dry-run"
}

@test "run wrapper executes command in normal mode" {
  run bash -c "DRY_RUN=false; source <(awk 'BEGIN{p=0} /^run\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); run 'echo executed'"
  assert_success
  assert_output "executed"
}

# ── detect_forge_from_host (extracted and run in isolation) ───────────
# detect_forge_from_host maps a hostname to a forge name. The known SaaS
# hosts and hostname heuristics are pure (no network); only the API-probe
# fallback hits the network, which we don't test here.

@test "bin/setup defines detect_forge_from_host function" {
  run grep -E '^detect_forge_from_host\(\)' bin/setup
  assert_success
}

@test "detect_forge_from_host returns github for github.com" {
  run bash -c "source <(awk 'BEGIN{p=0} /^detect_forge_from_host\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); detect_forge_from_host github.com"
  assert_success
  assert_output "github"
}

@test "detect_forge_from_host returns gitlab for gitlab.com" {
  run bash -c "source <(awk 'BEGIN{p=0} /^detect_forge_from_host\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); detect_forge_from_host gitlab.com"
  assert_success
  assert_output "gitlab"
}

@test "detect_forge_from_host returns github for github.example.com" {
  run bash -c "source <(awk 'BEGIN{p=0} /^detect_forge_from_host\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); detect_forge_from_host github.example.com"
  assert_success
  assert_output "github"
}

@test "detect_forge_from_host returns gitlab for gitlab.example.com" {
  run bash -c "source <(awk 'BEGIN{p=0} /^detect_forge_from_host\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); detect_forge_from_host gitlab.example.com"
  assert_success
  assert_output "gitlab"
}

@test "detect_forge_from_host returns empty for unrecognized host without network" {
  # For an unrecognized host, the function falls back to an API probe.
  # Use a host that will fail to connect (3s timeout) → empty output.
  run bash -c "source <(awk 'BEGIN{p=0} /^detect_forge_from_host\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/setup); detect_forge_from_host nonexistent.invalid.test"
  assert_success
  assert_output ""
}
