#!/usr/bin/env bats
# test/catchup.bats — catchup stage tests (GitHub auto-close race, #79).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"
}

@test "lib/boucle-ci/catchup.sh parses without syntax error" {
  run bash -n lib/boucle-ci/catchup.sh
  assert_success
}

@test "catchup: no blanket closed-issue guard (removed for #79)" {
  # The blanket "if ISSUE_STATE=closed → exit 0" guard must be gone.
  # The label-based routing handles terminal states correctly.
  run grep -q 'ISSUE_STATE" = "closed"' lib/boucle-ci/catchup.sh
  assert_failure
}

@test "catchup: merging is in the skip group (idempotence on duplicate runs)" {
  # A duplicate catchup run on an issue already at boucle:merging must
  # skip, not re-chain to post-merge.
  run grep -q 'done | human | split | blocked | merging)' lib/boucle-ci/catchup.sh
  assert_success
}

@test "catchup: non-terminal labels still route to TARGET=human" {
  # spec-review, todo, working, etc. must still set TARGET=human.
  run grep -q 'triage | needs-info | spec-review | todo | working | review)' lib/boucle-ci/catchup.sh
  assert_success
}
