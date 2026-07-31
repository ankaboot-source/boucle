#!/usr/bin/env bash
# scripts/test.sh — run bats unit tests. Called by pre-commit hook and `make test`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bats --formatter tap test/
