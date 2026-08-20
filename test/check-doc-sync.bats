#!/usr/bin/env bats

# test/check-doc-sync.bats — tests for bin/check-doc-sync lint

# Resolve repo root from the test file location
# shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  # Backup bin/setup before each test that might modify it
  if [ -f "$REPO_ROOT/bin/setup" ]; then
    cp "$REPO_ROOT/bin/setup" "$REPO_ROOT/bin/setup.test-bak"
  fi
}

teardown() {
  # Restore bin/setup after each test
  if [ -f "$REPO_ROOT/bin/setup.test-bak" ]; then
    cp "$REPO_ROOT/bin/setup.test-bak" "$REPO_ROOT/bin/setup"
    rm -f "$REPO_ROOT/bin/setup.test-bak"
  fi
  # Clean up any temp marker files
  rm -f "$REPO_ROOT/lib/boucle-ci/test-marker-tmp.sh"
}

@test "check-doc-sync passes on the current codebase (in sync with SKILL.md)" {
  run "$REPO_ROOT/bin/check-doc-sync"
  [ "$status" -eq 0 ]
  [[ "$output" == *"doc-sync OK"* ]]
}

@test "check-doc-sync fails when a label is in setup but not in SKILL.md" {
  sed -i 's/for label in triage/for label in nonexistent-label triage/' "$REPO_ROOT/bin/setup"

  run "$REPO_ROOT/bin/check-doc-sync"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boucle:nonexistent-label"* ]]
}

@test "check-doc-sync fails when a marker is in code but not in SKILL.md" {
  echo '# <!-- boucle:nonexistent-marker v=1 -->' > "$REPO_ROOT/lib/boucle-ci/test-marker-tmp.sh"

  run "$REPO_ROOT/bin/check-doc-sync"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boucle:nonexistent-marker"* ]]
}

@test "check-doc-sync catches markers with digits (e2e-fail style)" {
  echo '# <!-- boucle:e2e-nonexistent v=1 -->' > "$REPO_ROOT/lib/boucle-ci/test-marker-tmp.sh"

  run "$REPO_ROOT/bin/check-doc-sync"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boucle:e2e-nonexistent"* ]]
}

@test "check-doc-sync fails when .jcode SKILL.md symlink is broken" {
  mv "$REPO_ROOT/.jcode/skills/boucle/SKILL.md" "$REPO_ROOT/.jcode/skills/boucle/SKILL.md.test-bak"
  ln -s NONEXISTENT.md "$REPO_ROOT/.jcode/skills/boucle/SKILL.md"

  run "$REPO_ROOT/bin/check-doc-sync"

  # Restore symlink immediately (before assertions, so teardown is clean)
  rm -f "$REPO_ROOT/.jcode/skills/boucle/SKILL.md"
  mv "$REPO_ROOT/.jcode/skills/boucle/SKILL.md.test-bak" "$REPO_ROOT/.jcode/skills/boucle/SKILL.md"

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink is broken"* ]]
}

@test "check-doc-sync fails when a pruned label is re-added to setup" {
  sed -i 's/for label in triage/for label in spec-approved triage/' "$REPO_ROOT/bin/setup"

  run "$REPO_ROOT/bin/check-doc-sync"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boucle:spec-approved"* ]]
  [[ "$output" == *"pruned"* ]]
}
