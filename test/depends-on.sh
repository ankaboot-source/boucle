#!/usr/bin/env bash
# test/depends-on.sh — unit tests for bin/lib/depends-on.sh
#
# Pure bash test harness (no bats dependency). Sources the lib and runs
# test cases from §9.1 of the design spec. Exits non-zero on any failure.
#
# Usage: bash test/depends-on.sh

set -euo pipefail

# ── Test helpers ────────────────────────────────────────────────────────
PASS=0
FAIL=0

assert_equal() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        expected exit: $expected"
    echo "        actual exit:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Source the library ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../bin/lib/depends-on.sh"
if [ ! -f "$LIB" ]; then
  echo "FATAL: $LIB not found"
  exit 1
fi
source "$LIB"

echo "=== parse_depends_on ==="

# 1. Empty desc → empty output
result=$(parse_depends_on "")
assert_equal "empty desc → empty" "" "$result"

# 2. Marker only
result=$(parse_depends_on '<!-- boucle:depends-on iids=42,43 -->')
assert_equal "marker only → 42,43" "42,43" "$result"

# 3. Section only
result=$(parse_depends_on $'## Depends on\n#42, #43')
assert_equal "section only → 42,43" "42,43" "$result"

# 4. Both (normal case — marker wins, but both agree)
result=$(parse_depends_on $'## Depends on\n#42, #43\n<!-- boucle:depends-on iids=42,43 -->')
assert_equal "both (marker wins) → 42,43" "42,43" "$result"

# 5. Malformed marker (iids=42,abc → 42, trailing comma is harmless)
result=$(parse_depends_on '<!-- boucle:depends-on iids=42,abc -->')
assert_equal "malformed marker → 42," "42," "$result"

# 6. Full realistic body with ## Parent issue AND ## Depends on sections
BODY=$'## Summary\n\nDo the thing.\n\n## Parent issue\n#99 — https://example.com\n\n## Depends on\n#42, #43\n<!-- boucle:depends-on iids=42,43 -->\n\n## Acceptance criteria\n- [ ] Works'
result=$(parse_depends_on "$BODY")
assert_equal "full body with parent + deps → 42,43" "42,43" "$result"

# 7. Section only with multiple deps on separate lines
result=$(parse_depends_on $'## Depends on\n#42\n#43')
assert_equal "section multi-line → 42,43" "42,43" "$result"

# 8. Section only with single dep
result=$(parse_depends_on $'## Depends on\n#42')
assert_equal "section single dep → 42" "42" "$result"

# 9. No Depends on section at all (but has other sections)
result=$(parse_depends_on $'## Summary\nHello\n## Acceptance criteria\n- [ ] Works')
assert_equal "no deps section → empty" "" "$result"

echo ""
echo "=== detect_cycle ==="

# 1. No deps → no cycle
rc=0
detect_cycle "" || rc=$?
assert_exit_code "empty graph → no cycle" 1 "$rc"

# 2. A→B, B→A → cycle
rc=0
detect_cycle "0:1;1:0" || rc=$?
assert_exit_code "A→B, B→A → cycle" 0 "$rc"

# 3. A→B→C, C→A → cycle
rc=0
detect_cycle "0:1;1:2;2:0" || rc=$?
assert_exit_code "A→B→C, C→A → cycle" 0 "$rc"

# 4. A→B, A→C (DAG) → no cycle
rc=0
detect_cycle "0:1 2;1:;2:" || rc=$?
assert_exit_code "A→B, A→C (DAG) → no cycle" 1 "$rc"

# 5. Single node self-loop A→A → cycle
rc=0
detect_cycle "0:0" || rc=$?
assert_exit_code "self-loop A→A → cycle" 0 "$rc"

# 6. Linear chain A→B→C (no cycle)
rc=0
detect_cycle "0:1;1:2;2:" || rc=$?
assert_exit_code "linear A→B→C → no cycle" 1 "$rc"

# 7. Diamond DAG A→B, A→C, B→D, C→D (no cycle)
rc=0
detect_cycle "0:1 2;1:3;2:3;3:" || rc=$?
assert_exit_code "diamond DAG → no cycle" 1 "$rc"

# 8. Two disconnected cycles
rc=0
detect_cycle "0:1;1:0;2:3;3:2" || rc=$?
assert_exit_code "two disconnected cycles → cycle" 0 "$rc"

echo ""
echo "=== resolve_dep_indices ==="

# 1. Index 2 → IID 42
result=$(resolve_dep_indices "2" "41,42,43")
assert_equal "index 2 → 42" "42" "$result"

# 2. Indices 1,3 → IIDs 41,43
result=$(resolve_dep_indices "1,3" "41,42,43")
assert_equal "indices 1,3 → 41,43" "41,43" "$result"

# 3. Index 5 out of range → empty + warning
result=$(resolve_dep_indices "5" "41,42,43" 2> /dev/null)
assert_equal "index 5 out of range → empty" "" "$result"

# 4. Empty raw indices → empty
result=$(resolve_dep_indices "" "41,42,43")
assert_equal "empty raw → empty" "" "$result"

# 5. Single element array, index 1
result=$(resolve_dep_indices "1" "99")
assert_equal "single element, index 1 → 99" "99" "$result"

# 6. Index 0 (invalid, 1-based) → empty + warning
result=$(resolve_dep_indices "0" "41,42,43" 2> /dev/null)
assert_equal "index 0 (invalid 1-based) → empty" "" "$result"

# 7. Mixed valid and invalid
result=$(resolve_dep_indices "1,5,3" "41,42,43" 2> /dev/null)
assert_equal "mixed valid+invalid → 41,43" "41,43" "$result"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  RESULT: FAILED"
  exit 1
else
  echo "  RESULT: ALL PASSED"
  exit 0
fi
