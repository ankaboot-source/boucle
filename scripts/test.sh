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
# Hermeticity guard, part 2 (#140/#142): scrub ambient git repo context. Under
# `git push`'s pre-push hook, git exports GIT_DIR — an ABSOLUTE gitdir path
# in a linked worktree — to the hook and every child process. Fixtures that
# build throwaway repos (`git -C "$TMP_REPO" init/add/commit`) then hit the
# REAL repository instead of the throwaway: the checked-out branch advances
# with fixture commits and the worktree is left corrupted. Ambient GIT_*
# must never leak into the suite. The quarantine and push-option vars ride the
# same hook context — same class, same scrub.
for _v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
  GIT_QUARANTINE_PATH; do
  unset "$_v"
done
for _v in $(env | grep -oE '^GIT_PUSH_OPTION_[A-Z0-9_]+'); do
  unset "$_v"
done
# Forge-identity guard: CI exports the identity of the checkout itself
# (GITHUB_REPOSITORY on Actions, CI_PROJECT_* on GitLab). A test asserting
# "this repository is a consumer, not the upstream" then inverts in CI while
# staying green on a dev machine where those vars are unset. Scrub the ambient
# identity so results never depend on the host — the same rationale as the
# BOUCLE_* scrub above. Tests that need an identity export it explicitly.
for _v in GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_API_URL \
  CI_PROJECT_ID CI_PROJECT_NAME CI_PROJECT_PATH CI_REPOSITORY_URL; do
  unset "$_v"
done
exec bats --formatter tap test/
