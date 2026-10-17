#!/usr/bin/env bash
# scripts/test.sh — run bats unit tests. Called by the pre-push hook.
set -euo pipefail
cd "$(dirname "$0")/.."
# Hermeticity guard (mirrors the Makefile `test` target): unit tests MUST run
# against boucle's defaults, never against live BOUCLE_* runtime config that
# happens to be exported in the environment (e.g. BOUCLE_DEPLOY_MODE=external
# in CI flips the post-merge self-mode test into external mode). Scrub all
# BOUCLE_* vars before the suite.
for _v in $(env | grep -oE '^BOUCLE_[A-Z0-9_]+'); do
  unset "$_v"
done
# Hermeticity guard, part 2 (#142): scrub ambient git repo context. Under
# `git push`'s pre-push hook, git exports GIT_DIR — an ABSOLUTE gitdir path
# in a linked worktree — to the hook and every child process. Fixtures that
# build throwaway repos (`git -C "$TMP_REPO" init/add/commit`) then hit the
# REAL repository instead of the throwaway: the checked-out branch advances
# with fixture commits and the worktree is left corrupted. Ambient GIT_*
# must never leak into the suite.
for _v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX; do
  unset "$_v"
done
exec bats --formatter tap test/
