#!/usr/bin/env bats
# Conditional worktree reset (#44)

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# The classification is a case statement inside worker_main; extract just
# that block and drive it with the two inputs it reads.
classify() {
  local strategy="$1" prev="$2"
  bash -c "
    set -euo pipefail
    retry_strategy='$strategy'
    prev_outcome='$prev'
    want_reset=0
    case \"\$retry_strategy\" in
      preserve) want_reset=0 ;;
      reset) want_reset=1 ;;
      adaptive) [ \"\$prev_outcome\" = 'no-changes' ] && want_reset=1 ;;
      *) retry_strategy='preserve' ;;
    esac
    echo \"\$want_reset\"
  "
}

@test "reset: adaptive preserves after a reviewer FAIL (committed work)" {
  [ "$(classify adaptive committed)" = "0" ]
}

@test "reset: adaptive resets after a contamination failure (no changes shipped)" {
  [ "$(classify adaptive no-changes)" = "1" ]
}

@test "reset: adaptive preserves on a first iteration (no recorded outcome)" {
  # Conservative branch: preserving never destroys work.
  [ "$(classify adaptive '')" = "0" ]
}

@test "reset: preserve reproduces the previous behaviour" {
  [ "$(classify preserve no-changes)" = "0" ]
}

@test "reset: reset always starts clean" {
  [ "$(classify reset committed)" = "1" ]
}

@test "reset: an unknown strategy falls back to preserve" {
  [ "$(classify typo no-changes)" = "0" ]
}

@test "reset: the no-changes path records the outcome for the next iteration" {
  run grep -q 'echo "no-changes" > "$BOUCLE_WORKSPACE/.boucle-state/$BOUCLE_ISSUE/last-outcome"' lib/boucle-ci/worker.sh
  assert_success
}

@test "reset: a shipping iteration records committed" {
  run grep -q 'echo "committed" > ".boucle-state/$BOUCLE_ISSUE/last-outcome"' lib/boucle-ci/worker.sh
  assert_success
}

@test "reset: the discarded head is tagged and pushed before it can be lost" {
  # A reset that cannot be inspected afterwards is a data-loss bug.
  run grep -q 'git push -f origin "refs/tags/$DISCARDED_TAG"' lib/boucle-ci/worker.sh
  assert_success
  run grep -q 'The discarded work is kept at tag' lib/boucle-ci/worker.sh
  assert_success
}

@test "reset: the outcome file lives in the state cache so it survives checkout" {
  # .boucle-state/<issue>/ is restored from ISSUE_STATE_CACHE after checkout, and
  # saved back on EXIT — so the classification can read it next run.
  run grep -q 'ISSUE_STATE_CACHE/last-outcome' lib/boucle-ci/worker.sh
  assert_success
}

@test "reset: state and iteration notes survive a reset (only code is discarded)" {
  # The restore-from-cache block must still run after the checkout block.
  reset_line=$(grep -n 'Previous iteration shipped no code (contaminated tree)' lib/boucle-ci/worker.sh | cut -d: -f1)
  restore_line=$(grep -n 'Restoring .boucle/\$BOUCLE_ISSUE/ from' lib/boucle-ci/worker.sh | cut -d: -f1)
  [ -n "$reset_line" ]
  [ -n "$restore_line" ]
  [ "$reset_line" -lt "$restore_line" ]
}
