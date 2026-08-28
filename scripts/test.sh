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
exec bats --formatter tap test/
