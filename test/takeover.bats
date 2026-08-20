#!/usr/bin/env bats
# Interactive takeover — jcode session capture + resume instructions (#54 item 2)

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract boucle_escalation_diagnostic + boucle_cost_summary from lib/boucle.sh.
takeover_funcs() {
  awk '/^boucle_escalation_diagnostic\(\) \{/,/^}/' lib/boucle.sh > "${1}"
  awk '/^boucle_cost_summary\(\) \{/,/^}/' lib/boucle.sh >> "${1}"
}

@test "takeover: diagnostic appends resume instructions when a session-id file exists" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "${T}/.boucle-state/7"
  takeover_funcs "${TMPF}"
  printf '%s\n' '{"role":"worker","outcome":"no-changes"}' > "${T}/.boucle-state/7/health.jsonl"
  echo "session_test_1234_abc" > "${T}/.boucle-state/7/session-id"
  run bash -c "BOUCLE_WORKSPACE='${T}'; source '${TMPF}'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  assert_output --partial "Interactive takeover (optional)"
  assert_output --partial "jcode --resume session_test_1234_abc"
  assert_output --partial "cp .boucle-state/7/session/session.json ~/.jcode/sessions/session_test_1234_abc.json"
  assert_output --partial "boucle resume 7"
  rm -rf "${TMPF}" "${T}"
}

@test "takeover: diagnostic omits resume instructions when no session was captured (fail-open)" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "${T}/.boucle-state/7"
  takeover_funcs "${TMPF}"
  printf '%s\n' '{"role":"worker","outcome":"no-changes"}' > "${T}/.boucle-state/7/health.jsonl"
  # No session-id file — ephemeral runner / cleaned ~/.jcode.
  run bash -c "BOUCLE_WORKSPACE='${T}'; source '${TMPF}'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  assert_output --partial "class=step-budget-exhaustion"
  refute_output --partial "Interactive takeover"
  refute_output --partial "jcode --resume"
  rm -rf "${TMPF}" "${T}"
}

@test "takeover: diagnostic omits resume instructions when session-id file is empty" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "${T}/.boucle-state/7"
  takeover_funcs "${TMPF}"
  printf '%s\n' '{"role":"worker","outcome":"no-changes"}' > "${T}/.boucle-state/7/health.jsonl"
  : > "${T}/.boucle-state/7/session-id" # empty file
  run bash -c "BOUCLE_WORKSPACE='${T}'; source '${TMPF}'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  refute_output --partial "Interactive takeover"
  rm -rf "${TMPF}" "${T}"
}

@test "takeover: bin/boucle takeover prints the resume command when a session-id exists" {
  T=$(mktemp -d)
  mkdir -p "${T}/.boucle-state/7/session"
  echo "session_test_5678_def" > "${T}/.boucle-state/7/session-id"
  # bin/boucle reads .boucle-state relative to CWD; run it from $T.
  # Resolve the script path from BATS_TEST_DIRNAME (test/) before env -i
  # strips the environment — OLDPWD is unset under env -i, so the old
  # '${OLDPWD}/bin/boucle' collapsed to /bin/boucle and exited 127 in CI.
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  BOUCLE_BIN="${BATS_TEST_DIRNAME}/../bin/boucle"
  run env -i PATH="${PATH}" HOME="${HOME}" BOUCLE_BIN="${BOUCLE_BIN}" bash -c "cd '${T}' && \"\${BOUCLE_BIN}\" takeover 7"
  assert_success
  assert_output --partial "Captured jcode session: session_test_5678_def"
  assert_output --partial "jcode --resume session_test_5678_def"
  assert_output --partial "jcode run --resume session_test_5678_def"
  assert_output --partial "boucle resume 7"
  assert_output --partial "boucle restart 7"
  rm -rf "${T}"
}

@test "takeover: bin/boucle takeover fails open with a fallback when no session-id exists" {
  T=$(mktemp -d)
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  BOUCLE_BIN="${BATS_TEST_DIRNAME}/../bin/boucle"
  run env -i PATH="${PATH}" HOME="${HOME}" BOUCLE_BIN="${BOUCLE_BIN}" bash -c "cd '${T}' && \"\${BOUCLE_BIN}\" takeover 7"
  assert_failure
  assert_output --partial "No captured jcode session for issue #7"
  assert_output --partial "boucle restart 7"
  rm -rf "${T}"
}
