#!/usr/bin/env bats
# test/update.bats — unit tests for bin/update pure functions.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # Source bin/update (functions only — main guarded by BASH_SOURCE check).
  source bin/update
}

# ── get_mode ──────────────────────────────────────────────────────────

@test "get_mode defaults to release when BOUCLE_UPDATE_MODE unset" {
  unset BOUCLE_UPDATE_MODE
  run get_mode
  assert_success
  assert_output "release"
}

@test "get_mode reads dev" {
  BOUCLE_UPDATE_MODE="dev"
  run get_mode
  assert_success
  assert_output "dev"
}

@test "get_mode reads release" {
  BOUCLE_UPDATE_MODE="release"
  run get_mode
  assert_success
  assert_output "release"
}

# ── get_current_version ───────────────────────────────────────────────

@test "get_current_version returns empty when no version file" {
  VERSION_FILE="$(mktemp -u)"
  run get_current_version
  assert_success
  assert_output ""
  rm -f "$VERSION_FILE"
}

@test "get_current_version reads file content" {
  VERSION_FILE="$(mktemp)"
  echo "abc123def456" > "$VERSION_FILE"
  run get_current_version
  assert_success
  assert_output "abc123def456"
  rm -f "$VERSION_FILE"
}

# ── needs_update ──────────────────────────────────────────────────────

@test "needs_update: empty upstream → no update (returns 1)" {
  run needs_update "abc" ""
  assert_failure
}

@test "needs_update: same versions → no update (returns 1)" {
  run needs_update "abc" "abc"
  assert_failure
}

@test "needs_update: different versions → update (returns 0)" {
  run needs_update "abc" "def"
  assert_success
}

@test "needs_update: empty current, non-empty upstream → update (returns 0)" {
  run needs_update "" "def"
  assert_success
}

# ── SYNC_PATHS ────────────────────────────────────────────────────────

@test "SYNC_PATHS includes .jcode/agents (agent prompt propagation)" {
  # Agent prompts (triage.md, worker.md, reviewer.md, e2e.md) must propagate
  # to consumers on update, otherwise prompt fixes never reach CI.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial ".jcode/agents"
}

@test "SYNC_PATHS includes .jcode/skills (skill propagation)" {
  # Skills must propagate to consumers on update, otherwise skill fixes
  # never reach CI.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial ".jcode/skills"
}

@test "SYNC_PATHS includes lib (boucle-ci pipeline libraries)" {
  # lib/boucle-ci.sh + lib/boucle-ci/ must propagate to consumers on update,
  # otherwise bin/boucle-ci cannot source its stage functions and every
  # pipeline job fails on the consumer (comment in bin/update promises
  # "lib/ is always synced" — the variable list must honor it).
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial "lib"
}
