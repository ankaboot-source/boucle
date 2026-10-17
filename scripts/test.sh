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
# Git-hook context guard: this script runs as the pre-push hook, and git exports
# its own context to hooks (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_PREFIX,
# plus the alternate-object/quarantine and push-option vars). Inherited by the
# suite, they redirect every fixture repo's git call at THIS repository instead
# of the temp repo the test built: the fixture commits fail, the real index gets
# polluted with staged fixtures, and dozens of tests report phantom failures.
# Unset them so the suite always runs against its own fixtures.
for _v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH; do
  unset "$_v"
done
for _v in $(env | grep -oE '^GIT_PUSH_OPTION_[A-Z0-9_]+'); do
  unset "$_v"
done
exec bats --formatter tap test/
