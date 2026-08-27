#!/usr/bin/env bats
# Engine symlink targets (bin/lib/engine-symlink.sh).
#
# LESSONS.yml, .jcode/skills/ and bin/ live in the engine dir but are
# referenced at the consumer root, so setup/update symlink them up. Both
# callers passed "<engine>/<path>" as the target — right when read from the
# repo root, wrong for any link that is not AT the root. `.jcode/skills`
# resolved to `.jcode/.boucle/.jcode/skills` and never existed.
#
# The failure is silent: ln -s succeeds on a dangling target, so the only
# symptom is skill loads failing later, which reads as a model problem
# rather than a filesystem one.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  # shellcheck source=/dev/null
  . "$REPO/bin/lib/engine-symlink.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

# ── target computation ────────────────────────────────────────────────

@test "target: a root-level link needs no ../" {
  run engine_symlink_target /repo/.boucle LESSONS.yml /repo
  assert_success
  assert_output ".boucle/LESSONS.yml"
}

@test "target: a link one level down gets exactly one ../" {
  # This is the bug. Without the ../, the link points at
  # .jcode/.boucle/.jcode/skills, which does not exist.
  run engine_symlink_target /repo/.boucle .jcode/skills /repo
  assert_success
  assert_output "../.boucle/.jcode/skills"
}

@test "target: depth is counted, not assumed" {
  run engine_symlink_target /repo/.boucle a/b/c /repo
  assert_success
  assert_output "../../.boucle/a/b/c"
}

@test "target: never absolute when the engine is inside the consumer root" {
  # Both callers derive the engine dir with \$(cd .. && pwd), which is
  # absolute. Writing that into a VERSIONED symlink bakes one machine's
  # checkout path into the repo and dangles everywhere else.
  run engine_symlink_target /repo/.boucle .jcode/skills /repo
  assert_success
  refute_output --partial "/repo"
}

@test "target: absolute only when the engine is genuinely outside the root" {
  run engine_symlink_target /elsewhere/engine .jcode/skills /repo
  assert_success
  assert_output "/elsewhere/engine/.jcode/skills"
}

@test "target: engine == consumer root returns non-zero and prints nothing" {
  # Dogfood layout: the target already lives where the link would go, so the
  # only link that could be written points at itself.
  run engine_symlink_target /repo .jcode/skills /repo
  assert_failure
  assert_output ""
}

# ── the links actually resolve ────────────────────────────────────────

@test "resolve: every engine symlink resolves on a real tree" {
  mkdir -p "$TMP/repo/.boucle/.jcode/skills/demo" "$TMP/repo/.boucle/bin"
  echo x > "$TMP/repo/.boucle/LESSONS.yml"
  echo '---' > "$TMP/repo/.boucle/.jcode/skills/demo/SKILL.md"

  run bash -c "cd '$TMP/repo' && . '$REPO/bin/lib/engine-symlink.sh' &&
    for lt in LESSONS.yml .jcode/skills bin; do
      t=\$(engine_symlink_target \"\$PWD/.boucle\" \"\$lt\" \"\$PWD\") || continue
      mkdir -p \"\$(dirname \"\$lt\")\"; ln -s \"\$t\" \"\$lt\"
      [ -e \"\$lt\" ] || { echo \"BROKEN \$lt -> \$t\"; exit 1; }
    done
    # The path jcode itself uses to load a skill.
    cat .jcode/skills/demo/SKILL.md > /dev/null || { echo 'SKILL UNREADABLE'; exit 1; }
    echo OK"
  assert_success
  assert_output "OK"
}

@test "resolve: the old target is the broken one (regression guard)" {
  # Guards the fix by demonstrating what it replaced.
  mkdir -p "$TMP/repo/.boucle/.jcode/skills" "$TMP/repo/.jcode"
  run bash -c "cd '$TMP/repo' && ln -s '.boucle/.jcode/skills' '.jcode/skills' && [ -e '.jcode/skills' ]"
  assert_failure
}

# ── callers are wired to the helper ───────────────────────────────────

@test "callers: setup and update both use the helper, not the raw engine path" {
  run grep -q 'engine_symlink_target' "$REPO/bin/setup"
  assert_success
  run grep -q 'engine_symlink_target' "$REPO/bin/update"
  assert_success
  # Neither may still hand the raw engine-rooted path to ln -s.
  run bash -c "grep -c 'ln -s \"\$engine_src\"' '$REPO/bin/setup' '$REPO/bin/update' | grep -v ':0' || true"
  assert_output ""
}

@test "callers: a dangling link is reported, never left in place silently" {
  run grep -q 'does not resolve' "$REPO/bin/setup"
  assert_success
  run grep -q 'does not resolve' "$REPO/bin/update"
  assert_success
}
