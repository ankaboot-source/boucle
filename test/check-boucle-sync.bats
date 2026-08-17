#!/usr/bin/env bats

# test/check-boucle-sync.bats — tests for bin/check-boucle-sync
#
# The guard rejects any commit that modifies .boucle/ without an authorized
# bot subject (chore(boucle): ...). Each test builds a throwaway git repo,
# makes commits, and runs bin/check-boucle-sync with the appropriate env vars.

# Resolve repo root from the test file location
# shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/bin/check-boucle-sync"

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # Throwaway git repo for each test.
  TMP_REPO="$(mktemp -d)"
  git -C "$TMP_REPO" init -q -b main
  git -C "$TMP_REPO" config user.email "test@example.com"
  git -C "$TMP_REPO" config user.name "Test"
  # A base commit so HEAD~1 exists for the local/manual range.
  echo "base" > "$TMP_REPO/base.txt"
  git -C "$TMP_REPO" add base.txt
  git -C "$TMP_REPO" commit -q -m "chore: base commit"
  # Capture the base SHA for push-mode range checks (before any test commits).
  BASE_SHA="$(git -C "$TMP_REPO" rev-parse HEAD)"
}

teardown() {
  rm -rf "$TMP_REPO"
}

# Helper: make a commit in the temp repo touching the given path.
#   make_commit <subject> <path>
make_commit() {
  local subject="$1"
  local path="$2"
  mkdir -p "$(dirname "$TMP_REPO/$path")"
  echo "change" >> "$TMP_REPO/$path"
  git -C "$TMP_REPO" add "$path"
  git -C "$TMP_REPO" commit -q -m "$subject"
}

# Helper: run the guard in the temp repo (local/manual mode, HEAD~1...HEAD).
run_guard() {
  run bash -c "cd '$TMP_REPO' && '$CHECK'"
}

# Helper: run the guard in push-to-default-branch mode, checking the full
# range from the base commit (CI_COMMIT_BEFORE_SHA) to HEAD (CI_COMMIT_SHA).
run_guard_push() {
  run bash -c "cd '$TMP_REPO' && CI_COMMIT_BEFORE_SHA='$BASE_SHA' CI_COMMIT_SHA='$(git -C "$TMP_REPO" rev-parse HEAD)' '$CHECK'"
}

# ── No .boucle/ changes → pass ─────────────────────────────────────────

@test "no .boucle/ changes → pass (exit 0)" {
  make_commit "feat: add src file" "src/app.txt"
  run_guard
  assert_success
  assert_output --partial "no changes under .boucle/"
}

# ── Authorized bot commits → pass ────────────────────────────────────────

@test "authorized 'chore(boucle): auto-update to abc123' → pass" {
  make_commit "chore(boucle): auto-update to abc123" ".boucle/.gitlab-ci.yml"
  run_guard
  assert_success
  assert_output --partial "authorized bot update"
}

@test "authorized 'chore(boucle): sync upstream — foo' → pass" {
  make_commit "chore(boucle): sync upstream — foo" ".boucle/bin/update"
  run_guard
  assert_success
  assert_output --partial "authorized bot update"
}

# ── Unauthorized commits → fail ─────────────────────────────────────────

@test "unauthorized 'feat: switch deploy to GitLab Pages' → fail, mentions remediation" {
  make_commit "feat: switch deploy to GitLab Pages" ".boucle/.gitlab-ci.yml"
  run_guard
  assert_failure
  assert_output --partial "modified .boucle/ without authorization"
  assert_output --partial "CI variables"
  assert_output --partial "root .gitlab-ci.yml"
  assert_output --partial "upstream boucle repo"
}

@test "unauthorized 'fix: something' → fail" {
  make_commit "fix: something" ".boucle/bin/update"
  run_guard
  assert_failure
  assert_output --partial "modified .boucle/ without authorization"
}

# ── Mixed commits → fail on the unauthorized one ───────────────────────

@test "mixed authorized + unauthorized both touching .boucle/ → fail" {
  make_commit "chore(boucle): auto-update to def456" ".boucle/.gitlab-ci.yml"
  make_commit "feat: tweak engine" ".boucle/bin/update"
  run_guard_push
  assert_failure
  assert_output --partial "modified .boucle/ without authorization"
  assert_output --partial "feat: tweak engine"
}

@test "mixed: authorized touches .boucle/, unauthorized touches src/ only → pass" {
  make_commit "chore(boucle): auto-update to abc123" ".boucle/.gitlab-ci.yml"
  make_commit "feat: add src file" "src/app.txt"
  run_guard_push
  assert_success
  assert_output --partial "authorized bot update"
  refute_output --partial "without authorization"
}
