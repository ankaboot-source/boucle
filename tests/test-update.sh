#!/usr/bin/env bash
# tests/test-update.sh — tests for bin/update pure functions.
# Run: bash tests/test-update.sh

set -euo pipefail

# Source bin/update (functions only — main not executed due to BASH_SOURCE guard).
source "$(dirname "$0")/../bin/update"

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $desc"
    PASS=$((PASS+1))
  else
    echo "  ✗ $desc (expected '$expected', got '$actual')" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_return() {
  local desc="$1" expected="$2"; shift 2
  if "$@"; then
    [ "$expected" = "0" ] && { echo "  ✓ $desc"; PASS=$((PASS+1)); } || { echo "  ✗ $desc (expected failure, got success)" >&2; FAIL=$((FAIL+1)); }
  else
    [ "$expected" = "1" ] && { echo "  ✓ $desc"; PASS=$((PASS+1)); } || { echo "  ✗ $desc (expected success, got failure)" >&2; FAIL=$((FAIL+1)); }
  fi
}

# ── Test get_mode ─────────────────────────────────────────────────────
echo "=== get_mode ==="
unset BOUCLE_UPDATE_MODE
assert_eq "defaults to release when unset" "release" "$(get_mode)"
BOUCLE_UPDATE_MODE="dev"
assert_eq "reads dev" "dev" "$(get_mode)"
BOUCLE_UPDATE_MODE="release"
assert_eq "reads release" "release" "$(get_mode)"

# ── Test get_current_version ──────────────────────────────────────────
echo "=== get_current_version ==="
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
# Override VERSION_FILE to point into the temp dir.
VERSION_FILE="$TMPDIR/.boucle-version"
assert_eq "empty when no file" "" "$(get_current_version)"
echo "abc123def456" > "$VERSION_FILE"
assert_eq "reads file content" "abc123def456" "$(get_current_version)"
rm -f "$VERSION_FILE"

# ── Test needs_update ─────────────────────────────────────────────────
echo "=== needs_update ==="
assert_return "empty upstream → no update" "1" needs_update "abc" ""
assert_return "same versions → no update" "1" needs_update "abc" "abc"
assert_return "different versions → update" "0" needs_update "abc" "def"
assert_return "empty current, non-empty upstream → update" "0" needs_update "" "def"

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
