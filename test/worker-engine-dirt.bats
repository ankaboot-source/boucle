#!/usr/bin/env bats
# test/worker-engine-dirt.bats — worker must not commit bin/update's dirt.
#
# bin/update (self-update) runs BEFORE the worker and may dirty
# .github/workflows/boucle.yml at the consumer root (GitHub propagation).
# The worker MUST NOT commit that file — on GitHub the App token lacks
# the `workflows` permission, so a push that includes it is
# remote-rejected, stranding the issue at boucle:working with no branch.
# Regression for the incident on ankaboot-source/boucle.dev #71 (2026-08).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Source-grep tests (cheap, structural) ──────────────────────────────
# Use grep -F (fixed string) so $ {} etc. are literal, not regex.

@test "worker: new branch is created from origin/default, not local HEAD" {
  # The `git checkout -b "$BRANCH"` form (no start point) inherits local
  # HEAD, which may carry bin/update's unpushed commits. The fix pins the
  # start point to origin/$BOUCLE_DEFAULT_BRANCH (the clean remote ref).
  run grep -qF 'git checkout -b "$BRANCH" "origin/$BOUCLE_DEFAULT_BRANCH"' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker: engine-owned workflow file is restored from origin after checkout" {
  run grep -qF 'git checkout "origin/$BOUCLE_DEFAULT_BRANCH" -- ".github/workflows/boucle.yml"' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker: the workflow restore is GitHub-only (GitLab uses root .gitlab-ci.yml shim)" {
  run grep -qF 'if [ "${BOUCLE_FORGE:-gitlab}" = "github" ]; then' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker: the workflow restore is best-effort (|| true, never fatal)" {
  run grep -qF 'git checkout "origin/$BOUCLE_DEFAULT_BRANCH" -- ".github/workflows/boucle.yml" 2> /dev/null || true' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker: the workflow restore does NOT touch charter docs (worker may update them)" {
  # AGENTS.md, SKILL.md, ARCHITECTURE.md are engine-propagated but the
  # worker MAY legitimately update them (doc self-maintenance). The
  # restore must be scoped to the workflow file ONLY — restoring charter
  # docs would discard legitimate worker doc updates on existing branches.
  # Assert the restore block contains exactly ONE git checkout command
  # (the workflow file), and that command does NOT reference charter docs.
  run bash -c "awk '/# ── Restore engine-owned CI file/,/^  # ── Restore state cache/' lib/boucle-ci/worker.sh | grep -E '^[[:space:]]+git checkout' | wc -l | tr -d ' '"
  assert_success
  assert_output "1"
  run bash -c "awk '/# ── Restore engine-owned CI file/,/^  # ── Restore state cache/' lib/boucle-ci/worker.sh | grep -E '^[[:space:]]+git checkout' | grep -c -E 'AGENTS|SKILL|ARCHITECTURE' || true"
  assert_success
  assert_output "0"
}

# ── Functional test (real git repo) ───────────────────────────────────
# Drive the branch-creation + workflow-restore block in a real git repo
# and assert the workflow file is NOT in the worker's commit.

@test "worker: new branch does not include bin/update's workflow-file dirt" {
  local tmp
  tmp=$(mktemp -d)
  # Build a fake consumer repo with a default branch and a workflow file.
  git init -q -b main "$tmp/consumer"
  cd "$tmp/consumer" || exit 1
  git config user.email bot@boucle.local
  git config user.name up-bot
  mkdir -p .github/workflows
  printf '# workflow v1\n' > .github/workflows/boucle.yml
  printf '# project\n' > README.md
  git add .github/workflows/boucle.yml README.md
  git commit -qm "init"
  # Record the clean (pre-dirt) commit — this is what origin/main should be.
  clean_sha=$(git rev-parse HEAD)
  # Simulate bin/update dirtying the workflow file in the working tree
  # (and committing it locally — the self-update commit that GitHub's
  # App token rejects on push).
  printf '# workflow v2 (bin/update dirt)\n' > .github/workflows/boucle.yml
  git add .github/workflows/boucle.yml
  git commit -qm "chore(boucle): auto-update submodule to deadbeef"
  # The local main now has the dirt. Build origin as a bare clone, then
  # rewind origin/main to the clean (pre-dirt) commit — that is the
  # remote ref the worker fetches and branches from.
  git clone -q --bare "$tmp/consumer" "$tmp/origin.git"
  git --git-dir="$tmp/origin.git" branch -f main "$clean_sha"
  git remote remove origin 2>/dev/null || true
  git remote add origin "$tmp/origin.git"
  git fetch -q origin main
  # Sanity: origin/main is the clean commit, local HEAD has the dirt.
  [ "$(git rev-parse origin/main)" = "$clean_sha" ]
  # Now simulate the worker's branch-creation + restore block.
  BOUCLE_DEFAULT_BRANCH=main
  BOUCLE_FORGE=github
  BRANCH=boucle/42-test
  git checkout -q -b "$BRANCH" "origin/$BOUCLE_DEFAULT_BRANCH"
  git checkout "origin/$BOUCLE_DEFAULT_BRANCH" -- ".github/workflows/boucle.yml" 2>/dev/null || true
  # The worker's commit (simulated: only touch README, the "issue work").
  printf '# project (worker changes)\n' > README.md
  git add README.md
  git commit -qm "feat: worker changes for #42"
  # Assert: the worker's branch does NOT contain the workflow dirt.
  run git diff --name-only "origin/$BOUCLE_DEFAULT_BRANCH..HEAD"
  assert_success
  refute_output --partial ".github/workflows/boucle.yml"
  assert_output --partial "README.md"
  # And the workflow file on the branch matches origin (clean).
  run git show "HEAD:.github/workflows/boucle.yml"
  assert_success
  assert_output "# workflow v1"
  cd - >/dev/null || exit 1
  rm -rf "$tmp"
}
