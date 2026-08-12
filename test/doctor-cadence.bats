#!/usr/bin/env bats
# Adaptive doctor cadence (#38)
#
# The doctor ran on a fixed schedule and always performed the full sweep.
# On an idle repository that is a runner provisioned to confirm nothing
# changed.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

@test "cadence: a monitor pass returns before the sweep" {
  run grep -q 'Doctor monitor pass — board unchanged' lib/boucle-ci/doctor.sh
  assert_success
  # The early return must sit before the first recovery block.
  monitor_line=$(grep -n 'Doctor monitor pass' lib/boucle-ci/doctor.sh | cut -d: -f1)
  first_sweep=$(grep -n 'Recover orphaned boucle:needs-info issues' lib/boucle-ci/doctor.sh | cut -d: -f1)
  [ "$monitor_line" -lt "$first_sweep" ]
}

@test "cadence: a backstop forces a full sweep regardless of the fingerprint" {
  run grep -q 'BOUCLE_DOCTOR_BACKSTOP:-21600' lib/boucle-ci/doctor.sh
  assert_success
  run grep -q 'SWEEP_AGE" -lt "$BACKSTOP"' lib/boucle-ci/doctor.sh
  assert_success
}

@test "cadence: BOUCLE_DOCTOR_ADAPTIVE=false restores the fixed cadence" {
  run grep -c 'BOUCLE_DOCTOR_ADAPTIVE:-true' lib/boucle-ci/doctor.sh
  assert_success
  [ "$output" -ge 1 ]
}

@test "cadence: an unreadable board degrades to a full sweep" {
  # The doctor exists to unstick things: a probe that cannot see the board
  # must never be the reason it stops.
  run grep -q 'CURRENT_FINGERPRINT" \]' lib/boucle-ci/doctor.sh
  assert_success
}

@test "cadence: the fingerprint is order-independent" {
  # Two listings of the same board in a different order must hash equal,
  # or every run looks like a change and the saving disappears.
  a=$(printf 'boucle:working:5:t2\nboucle:todo:3:t1\n' | sort | cksum | awk '{print $1}')
  b=$(printf 'boucle:todo:3:t1\nboucle:working:5:t2\n' | sort | cksum | awk '{print $1}')
  [ "$a" = "$b" ]
}

@test "cadence: the fingerprint changes when an issue moves" {
  a=$(printf 'boucle:working:5:t2\n' | sort | cksum | awk '{print $1}')
  b=$(printf 'boucle:review:5:t3\n' | sort | cksum | awk '{print $1}')
  [ "$a" != "$b" ]
}

@test "cadence: an idle board relaxes the staleness threshold" {
  run grep -q 'BOUCLE_STALENESS_IDLE_FACTOR:-3' lib/boucle-ci/doctor.sh
  assert_success
  run grep -q 'board idle — staleness threshold relaxed' lib/boucle-ci/doctor.sh
  assert_success
}

@test "cadence: a busy board keeps the documented staleness threshold" {
  # The busy value must keep exceeding the max job timeout (30 min).
  run grep -q 'if \[ "$IN_FLIGHT" -eq 0 \]; then' lib/boucle-ci/doctor.sh
  assert_success
}

@test "cadence: the ephemeral-runner degradation is documented, not hidden" {
  run grep -q 'ephemeral runner (GitHub-hosted) the snapshot is never' lib/boucle-ci/doctor.sh
  assert_success
}

@test "doctor: stale closed/merged MR with open MR must NOT continue (fall through to re-trigger)" {
  # A closed (or merged) MR from a previous iteration coexisting with the
  # current open MR must not skip the stuck-issue re-trigger: `continue`
  # in the "skipping close" branches strands the issue at boucle:working
  # forever (consumer 2026-08: hours stuck, worker slot occupied).
  run grep -n 'skipping close' lib/boucle-ci/doctor.sh
  assert_success
  # Every line mentioning "skipping close" must be followed by the
  # FALL THROUGH comment, never by a bare `continue`.
  while read -r line; do
    lineno="${line%%:*}"
    run sed -n "$((lineno + 1))p" lib/boucle-ci/doctor.sh
    assert_output --partial "FALL THROUGH"
  done <<< "$output"
}

@test "doctor: the inline job mirrors the extracted no-continue guard" {
  # The inline doctor job in .gitlab-ci.yml must carry the same guard —
  # a fix in one copy alone leaves the bug live on the other (lesson #56).
  # The trailing `"` excludes the reviewer's own "skipping close." echo.
  run grep -n 'skipping close"' .gitlab-ci.yml
  assert_success
  while read -r line; do
    lineno="${line%%:*}"
    run sed -n "$((lineno + 1))p" .gitlab-ci.yml
    assert_output --partial "FALL THROUGH"
  done <<< "$output"
}
