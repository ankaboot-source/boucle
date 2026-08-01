#!/usr/bin/env bats
# test/oc.bats — smoke + pure-function tests for bin/oc.
#
# bin/oc has no BASH_SOURCE guard and executes its full body on source:
# it makes a state directory, calls opencode run, writes to iterations.md,
# etc. We can't source it directly. These tests cover what we can:
# syntax validity, function definitions, and the behavior of build_prompt
# (the role → prompt builder) which we extract and run in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract a multi-line function from bin/oc by name and write it to a
# temp file that can be sourced. Usage: extract_func <funcname> <outfile>
extract_func() {
  awk -v fn="$1" '
    BEGIN { p = 0 }
    $0 ~ "^"fn"\\(\\) \\{" { p = 1; print; next }
    p == 1 && /^}/ { print; p = 0; next }
    p == 1 { print }
  ' bin/oc > "$2"
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/oc parses without syntax error" {
  run bash -n bin/oc
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/oc defines build_prompt function" {
  run grep -E '^build_prompt\(\)' bin/oc
  assert_success
}

@test "bin/oc defines get_peak_rss_kb function" {
  run grep -E '^get_peak_rss_kb\(\)' bin/oc
  assert_success
}

@test "bin/oc defines print_metrics_line function" {
  run grep -E '^print_metrics_line\(\)' bin/oc
  assert_success
}

@test "bin/oc defines cleanup_metrics function" {
  run grep -E '^cleanup_metrics\(\)' bin/oc
  assert_success
}

@test "bin/oc defines start_rss_sampler function" {
  run grep -E '^start_rss_sampler\(\)' bin/oc
  assert_success
}

# ── build_prompt (extracted, run in isolation) ────────────────────────
# build_prompt takes a role and a global ISSUE; it returns the prompt
# text on stdout. We extract the function body and invoke it with
# different ISSUE values to verify each role branch.

@test "build_prompt: triage role mentions boucle:triage marker" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=42; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "issue #42"
  assert_output --partial "boucle:triage"
  rm -f "$TMPF"
}

@test "build_prompt: worker role mentions [skip ci] commit" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=99; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "issue #99"
  assert_output --partial "[skip ci]"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer role references BOUCLE_PREVIEW_URL" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=7; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "issue #7"
  assert_output --partial "BOUCLE_PREVIEW_URL"
  assert_output --partial "boucle:verdict"
  rm -f "$TMPF"
}

@test "build_prompt: e2e role references BOUCLE_LIVE_URL" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=3; source '$TMPF'; build_prompt e2e"
  assert_success
  assert_output --partial "issue #3"
  assert_output --partial "BOUCLE_LIVE_URL"
  rm -f "$TMPF"
}

@test "build_prompt: appends attachment paths when BOUCLE_ISSUE_ATTACHMENTS is set" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=5; BOUCLE_ISSUE_ATTACHMENTS='/tmp/a.png /tmp/b.jpg'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "/tmp/a.png"
  assert_output --partial "/tmp/b.jpg"
  assert_output --partial "Issue images"
  rm -f "$TMPF"
}

@test "build_prompt: no attachment footer when BOUCLE_ISSUE_ATTACHMENTS is empty" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=5; unset BOUCLE_ISSUE_ATTACHMENTS; source '$TMPF'; build_prompt triage"
  assert_success
  refute_output --partial "Issue images"
  rm -f "$TMPF"
}

# ── build_prompt: prior notes injection (triage) ───────────────────────
# Regression: the triage agent used to re-ask questions the author had
# already answered because prior issue notes were never injected into the
# prompt. BOUCLE_ISSUE_NOTES carries the chronological discussion so the
# agent can incorporate answers instead of re-asking them.

@test "build_prompt: triage includes prior notes when BOUCLE_ISSUE_NOTES is set" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend DESIGN.md'; BOUCLE_ISSUE_NOTES='[tahrir] The Bold Font .ttf is attached
[up-bot] Where is DESIGN.md?
[tahrir] DESIGN.md is at repo root'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "Prior discussion"
  assert_output --partial "The Bold Font .ttf is attached"
  assert_output --partial "DESIGN.md is at repo root"
  rm -f "$TMPF"
}

@test "build_prompt: no prior-notes section when BOUCLE_ISSUE_NOTES is empty" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend DESIGN.md'; unset BOUCLE_ISSUE_NOTES; source '$TMPF'; build_prompt triage"
  assert_success
  refute_output --partial "Prior discussion"
  rm -f "$TMPF"
}
