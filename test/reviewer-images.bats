#!/usr/bin/env bats
# test/reviewer-images.bats — tests for boucle_collect_mr_images
# (lib/boucle-ci/reviewer.sh), the PR-changed raster image collection
# added for #98.
#
# The helper extracts images added/modified between MR_BASE and MR_HEAD
# from the MR head into .boucle-state/$ISSUE/repo-images/ so the vision
# pipeline can describe them. Tests use a real temp git repo (house style:
# self-contained bash snippets, no mocks for git).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  bats_require_minimum_version 1.5.0

  # Temp git repo: commit A (base) then commit B (head) on a branch.
  # The repo IS the reviewer workspace: CI_PROJECT_DIR points at it (the
  # function runs git in CI_PROJECT_DIR and writes state under it).
  REPO_DIR="$(mktemp -d)"
  git -C "$REPO_DIR" init -q -b main
  git -C "$REPO_DIR" config user.email test@example.com
  git -C "$REPO_DIR" config user.name test
  echo "base text" > "$REPO_DIR/readme.md"
  git -C "$REPO_DIR" add readme.md
  git -C "$REPO_DIR" commit -qm "base"
  MR_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
  export MR_BASE

  export CI_PROJECT_DIR="$REPO_DIR"
  export BOUCLE_ISSUE="42"
  STATE_DIR="$CI_PROJECT_DIR/.boucle-state/$BOUCLE_ISSUE"
}

teardown() {
  rm -rf "$REPO_DIR"
}

# Write a minimal real 1x1 red PNG at the given path (dirs created as needed).
write_png() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
    | base64 -d > "$path"
}

# Commit the current worktree as the MR head and export MR_HEAD.
commit_head() {
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -qm "head"
  MR_HEAD="$(git -C "$REPO_DIR" rev-parse HEAD)"
  export MR_HEAD
}

# Source the helper (reviewer.sh is function-only — safe to source).
load_helper() {
  source lib/boucle-ci/reviewer.sh
}

@test "collect: added raster image is extracted from MR head, svg/text excluded" {
  write_png "$REPO_DIR/public/og-image.png"
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' > "$REPO_DIR/icon.svg"
  echo "note" > "$REPO_DIR/note.md"
  commit_head
  load_helper

  run boucle_collect_mr_images
  assert_success
  assert_output "public/og-image.png"
  # Extracted at MR_HEAD content, under repo-images/ with subdirs preserved.
  assert [ -f "$STATE_DIR/repo-images/public/og-image.png" ]
  # svg and text files are NOT extracted.
  assert [ ! -e "$STATE_DIR/repo-images/icon.svg" ]
  assert [ ! -e "$STATE_DIR/repo-images/note.md" ]
}

@test "collect: modified raster image is extracted at MR_HEAD content" {
  write_png "$REPO_DIR/img.png"
  git -C "$REPO_DIR" add img.png
  git -C "$REPO_DIR" commit -qm "add img"
  MR_BASE="$(git -C "$REPO_DIR" rev-parse HEAD)"
  export MR_BASE
  # Modify the image in a second commit (different bytes).
  printf 'PNG-MODIFIED-CONTENT' > "$REPO_DIR/img.png"
  commit_head
  load_helper

  run boucle_collect_mr_images
  assert_success
  assert_output "img.png"
  # Content is the MR_HEAD version, not the base version.
  run cmp -s "$STATE_DIR/repo-images/img.png" <(printf 'PNG-MODIFIED-CONTENT')
  assert_success
}

@test "collect: caps at 8 images and logs skips" {
  for i in $(seq 1 9); do
    write_png "$REPO_DIR/img$i.png"
  done
  commit_head
  load_helper

  run --separate-stderr boucle_collect_mr_images
  assert_success
  # The skip is logged to stderr with the [boucle] prefix (assert BEFORE
  # the next run clobbers $stderr).
  assert_stderr --partial "[boucle] SKIP: img9.png"
  # Only 8 of 9 extracted.
  run find "$STATE_DIR/repo-images" -type f
  assert_equal "${#lines[@]}" "8"
}

@test "collect: empty MR_BASE fails open with empty output" {
  load_helper
  unset MR_BASE
  run --separate-stderr boucle_collect_mr_images
  assert_success
  assert_output ""
  assert_stderr --partial "[boucle] WARN: MR_BASE/MR_HEAD empty"
}

@test "collect: no images changed yields empty output and no repo-images dir" {
  echo "note" > "$REPO_DIR/note.md"
  commit_head
  load_helper

  run boucle_collect_mr_images
  assert_success
  assert_output ""
  assert [ ! -e "$STATE_DIR/repo-images" ]
}
