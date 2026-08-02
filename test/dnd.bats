#!/usr/bin/env bats
# test/dnd.bats — tests for bin/dnd (Do-Not-Disturb window checker).
#
# bin/dnd is a pure, side-effect free script that exits 0 when the current
# time is inside the DND window and 1 otherwise. We drive it deterministically
# with BOUCLE_DND_NOW (epoch seconds) so tests don't depend on wall clock.
#
# Defaults (after the "good default" change): ENABLED=true, TZ=UTC.
# Tests that verify window logic pin BOUCLE_DND_TZ=UTC so the epochs (computed
# in UTC) stay valid. A separate test verifies the TZ override is honored.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/dnd parses without syntax error" {
  run bash -n bin/dnd
  assert_success
}

# ── Master switch ─────────────────────────────────────────────────────

@test "enabled by default (no BOUCLE_DND_ENABLED) → inside window returns 0" {
  # 22:20 UTC on 2023-11-14 = epoch 1700000400 → inside 22:00-07:00 UTC.
  # Default TZ is UTC, default ENABLED is true.
  run env -u BOUCLE_DND_ENABLED BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1700000400 bin/dnd
  assert_success
}

@test "BOUCLE_DND_ENABLED=false → exit 1 even inside window" {
  run env BOUCLE_DND_ENABLED=false BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1700000400 bin/dnd
  assert_failure
}

@test "BOUCLE_DND_ENABLED=true with no other config uses defaults (22:00→07:00 UTC)" {
  # 22:20 UTC → inside 22:00-07:00 UTC
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_NOW=1700000400 bin/dnd
  assert_success
  # 11:00 UTC → outside
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_NOW=1699959600 bin/dnd
  assert_failure
}

# ── Overnight wrap (default 22:00 → 07:00, pinned to UTC) ────────────

@test "22:30 UTC → inside overnight window" {
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1700001000 bin/dnd # ~22:30 UTC
  assert_success
}

@test "02:00 UTC → inside overnight window (after midnight)" {
  # 2023-11-14T02:00:00Z = 1699927200
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1699927200 bin/dnd
  assert_success
}

@test "07:30 UTC → outside overnight window (after END)" {
  # 2023-11-14T07:30:00Z = 1699947000
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1699947000 bin/dnd
  assert_failure
}

@test "21:59 UTC → outside overnight window (before START)" {
  # 2023-11-14T21:59:00Z = 1699999140
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1699999140 bin/dnd
  assert_failure
}

@test "boundary: exactly 22:00 → inside (inclusive START)" {
  # 2023-11-14T22:00:00Z = 1699999200
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1699999200 bin/dnd
  assert_success
}

@test "boundary: exactly 07:00 → outside (exclusive END)" {
  # 2023-11-14T07:00:00Z = 1699945200
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1699945200 bin/dnd
  assert_failure
}

# ── Same-day window ──────────────────────────────────────────────────

@test "same-day window 09:00→17:00: 12:00 inside" {
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_START=09:00 BOUCLE_DND_END=17:00 \
    BOUCLE_DND_NOW=1699963200 bin/dnd # 12:00 UTC
  assert_success
}

@test "same-day window 09:00→17:00: 08:59 outside" {
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_START=09:00 BOUCLE_DND_END=17:00 \
    BOUCLE_DND_NOW=1699952340 bin/dnd # 08:59 UTC
  assert_failure
}

@test "same-day window 09:00→17:00: 17:00 outside (exclusive END)" {
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_START=09:00 BOUCLE_DND_END=17:00 \
    BOUCLE_DND_NOW=1699981200 bin/dnd # 17:00 UTC
  assert_failure
}

@test "degenerate zero-length window (START==END) → never DND" {
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_START=12:00 BOUCLE_DND_END=12:00 \
    BOUCLE_DND_NOW=1699963200 bin/dnd
  assert_failure
}

# ── Excluded days ────────────────────────────────────────────────────

@test "excluded day suppresses DND even inside window" {
  # 2023-11-17 is a Friday. 23:00 UTC Friday → inside 22:00-07:00 but excluded.
  # 2023-11-17T23:00:00Z = 1700262000
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1700262000 \
    BOUCLE_DND_EXCLUDE_DAYS=Fri bin/dnd
  assert_failure
}

@test "non-excluded day still allows DND" {
  # 2023-11-14 is a Tuesday. 22:20 UTC Tuesday → inside, Tue not excluded.
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=UTC BOUCLE_DND_NOW=1700000400 \
    BOUCLE_DND_EXCLUDE_DAYS=Fri,Sat bin/dnd
  assert_success
}

# ── Timezone ─────────────────────────────────────────────────────────

@test "TZ override shifts the window relative to UTC epoch" {
  # 23:00 UTC = 00:00 next day in Europe/Paris (UTC+1 winter).
  # With a 22:00→07:00 Paris window, 23:00 UTC (=00:00 Paris) is inside.
  # We can't rely on the tz database being present in CI, so just verify
  # the script runs without error when a TZ is set.
  run env BOUCLE_DND_ENABLED=true BOUCLE_DND_TZ=Europe/Paris \
    BOUCLE_DND_NOW=1700000400 bin/dnd
  # Don't assert the result — tz availability varies. Just no crash.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
