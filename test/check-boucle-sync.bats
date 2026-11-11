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
  run bash -c "cd '$TMP_REPO' && LC_ALL=C '$CHECK'"
}

# Helper: run the guard in push mode with an arbitrary before-SHA (after-SHA is
# always HEAD). A before-SHA that is a different root, or that does not exist
# in this clone, is exactly what a force-push (rebase) leaves behind in a
# shallow CI clone.
#   run_guard_push_from <before_sha>
run_guard_push_from() {
  run bash -c "cd '$TMP_REPO' && LC_ALL=C CI_COMMIT_BEFORE_SHA='$1' CI_COMMIT_SHA='$(git -C "$TMP_REPO" rev-parse HEAD)' '$CHECK'"
}

# Helper: run the guard in push-to-default-branch mode, checking the full
# range from the base commit (CI_COMMIT_BEFORE_SHA) to HEAD (CI_COMMIT_SHA).
run_guard_push() {
  run_guard_push_from "$BASE_SHA"
}

# Helper: start a disjoint (second root) history and empty its index, so the
# next make_commit lands on a root commit with no merge base against main.
#   start_orphan_root <branch_name>
start_orphan_root() {
  git -C "$TMP_REPO" checkout -q --orphan "$1"
  git -C "$TMP_REPO" rm -rfq .
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

# ── Push range resolution: no merge base (force-push / shallow clone) ────
#
# Observed on a consumer: after a lane was rebased and force-pushed, the branch
# pipeline died with `fatal: <A>...<B>: no merge base` (a shallow clone has no
# merge base for the orphaned before-SHA) — a red pipeline unrelated to
# .boucle/. The range is now resolved from an explicit base with documented
# fallbacks (merge base → one bounded deepen → trunk-relative → fail closed),
# and both the file list and the commit list use two-dot forms.

@test "push mode: before-SHA with no merge base (disjoint root) → trunk fallback, no .boucle/ change → pass" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: add src file" "src/app.txt"
  start_orphan_root root-one
  make_commit "feat: unrelated root one" "one.txt"
  before="$(git -C "$TMP_REPO" rev-parse HEAD)"
  start_orphan_root root-two
  make_commit "feat: unrelated root two" "two.txt"
  run_guard_push_from "$before"
  assert_success
  assert_output --partial "range main.."
  assert_output --partial "no changes under .boucle/"
  refute_output --partial "fatal"
  refute_output --partial "no merge base"
}

@test "push mode: before-SHA with no merge base + a new .boucle/ violation → fail, no fatal" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: add src file" "src/app.txt"
  start_orphan_root root-one
  make_commit "feat: unrelated root one" "one.txt"
  before="$(git -C "$TMP_REPO" rev-parse HEAD)"
  start_orphan_root root-two
  make_commit "feat: meddle with the engine" ".boucle/.gitlab-ci.yml"
  run_guard_push_from "$before"
  assert_failure
  assert_output --partial "range main.."
  assert_output --partial "modified .boucle/ without authorization"
  assert_output --partial "feat: meddle with the engine"
  refute_output --partial "fatal"
}

@test "push mode: unreachable before-SHA → no fatal, trunk fallback, still fails on .boucle/" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: meddle with the engine" ".boucle/.gitlab-ci.yml"
  run_guard_push_from "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_failure
  assert_output --partial "range main.."
  assert_output --partial "modified .boucle/ without authorization"
  refute_output --partial "fatal"
  refute_output --partial "no merge base"
}

@test "push mode: unreachable before-SHA, clean lane → trunk fallback, pass" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: add src file" "src/app.txt"
  run_guard_push_from "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_success
  assert_output --partial "range main.."
  assert_output --partial "no changes under .boucle/"
  refute_output --partial "fatal"
}

@test "push mode: rebased lane — pre-rebase .boucle/ commit is not blamed, the new one is" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: old unauthorized engine edit" ".boucle/bin/old"
  old_head="$(git -C "$TMP_REPO" rev-parse HEAD)"
  # Force-push: the lane is rebuilt on the trunk base, producing new SHAs.
  git -C "$TMP_REPO" reset -q --hard "$BASE_SHA"
  make_commit "feat: rebased engine edit" ".boucle/bin/rebased"
  make_commit "feat: new unauthorized engine edit" ".boucle/bin/new"
  run_guard_push_from "$old_head"
  assert_failure
  assert_output --partial "modified .boucle/ without authorization"
  assert_output --partial "feat: new unauthorized engine edit"
  refute_output --partial "old unauthorized engine edit"
  refute_output --partial "fatal"
}

@test "push mode: rebased lane — pre-rebase .boucle/ commit is not blamed and nothing else is → pass" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: old unauthorized engine edit" ".boucle/bin/old"
  old_head="$(git -C "$TMP_REPO" rev-parse HEAD)"
  git -C "$TMP_REPO" reset -q --hard "$BASE_SHA"
  make_commit "feat: rebased src change" "src/app.txt"
  run_guard_push_from "$old_head"
  assert_success
  assert_output --partial "no changes under .boucle/"
  refute_output --partial "old unauthorized engine edit"
  refute_output --partial "fatal"
}

@test "unresolvable range (no trunk ref, unreachable before-SHA) → fail closed, exit 1" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: add src file" "src/app.txt"
  # No base left: no origin, no local main, no usable before-SHA.
  git -C "$TMP_REPO" branch -q -D main
  run_guard_push_from "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  assert_failure 1
  assert_output --partial "cannot resolve a commit range"
  assert_output --partial "FAILING CLOSED"
  assert_output --partial "GIT_DEPTH"
  refute_output --partial "no changes under .boucle/"
}

@test "merge-request mode: still diffed against the target branch → pass" {
  git -C "$TMP_REPO" checkout -q -b lane
  make_commit "feat: add src file" "src/app.txt"
  run bash -c "cd '$TMP_REPO' && LC_ALL=C CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main '$CHECK'"
  assert_success
  assert_output --partial "no changes under .boucle/"
}
