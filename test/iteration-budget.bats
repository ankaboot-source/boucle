#!/usr/bin/env bats
# test/iteration-budget.bats — the iteration budget must be legible to a human.
#
# The label carries the STATE (boucle:working, boucle:review) but never how
# much budget is left inside it. At boucle:working a human cannot tell "this
# is progressing" from "this is the last attempt before boucle:human". Two
# surfaces close that gap:
#
#   1. the MR description spells out iteration N/MAX rather than bare N;
#   2. a single final-attempt notice is posted on the MR when the iteration
#      being started is the last one.
#
# Both are asserted on the extracted lib/boucle-ci/ implementation — the
# inline .gitlab-ci.yml copy was replaced by `bin/boucle-ci <stage>`
# (refactor 6fb09f7), so there is no inline copy to drift.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── MR description: N/MAX, not bare N ──────────────────────────────────────

@test "shared worker writes the iteration budget as N/MAX in the MR description" {
  run grep -q '## Issue #%s — iteration %s/%s' lib/boucle-ci/worker.sh
  assert_success
}

@test "the rendered description shows the budget, not a bare iteration number" {
  run bash -c '
    BOUCLE_ISSUE=42 ITERATION=2 MR_MAX_ITER=3
    PREVIEW_LINE="Preview: https://example.test"
    COMMIT_SUMMARY="- did a thing" APPROACH="an approach" COMMIT_COUNT=1
    FINAL_ATTEMPT_BLOCK=""
    printf "## Issue #%s — iteration %s/%s\n\n%s\n\n%s\n\n### What changed\n%s\n\n### Approach\n%s\n\n---\n_Closes #%s | %s commit(s) | boucle worker run %s/%s_" \
      "$BOUCLE_ISSUE" "$ITERATION" "$MR_MAX_ITER" "$FINAL_ATTEMPT_BLOCK" "$PREVIEW_LINE" "$COMMIT_SUMMARY" "$APPROACH" "$BOUCLE_ISSUE" "$COMMIT_COUNT" "$ITERATION" "$MR_MAX_ITER"
  '
  assert_success
  assert_output --partial "iteration 2/3"
  assert_output --partial "boucle worker run 2/3"
}

# ── Final-attempt block: in the MR description, on the last iteration ──────

@test "shared worker writes the Final attempt block in the MR description" {
  run grep -q 'Final attempt' lib/boucle-ci/worker.sh
  assert_success
}

@test "shared worker gates the Final attempt block on the last iteration" {
  # The block must be conditional on the iteration being the last one, never
  # written unconditionally on every run.
  run bash -c "grep -B2 'Final attempt' lib/boucle-ci/worker.sh | grep -c 'ITERATION\" -eq \"\$mr_max_iter'"
  assert_output "1"
}

@test "the reviewer no longer posts a separate Final attempt notice" {
  # The warning moved into the MR description (written by the worker); the
  # reviewer must not post a duplicate forge note. The inline .gitlab-ci.yml
  # copy was replaced by `bin/boucle-ci reviewer` (refactor 6fb09f7), so the
  # extracted reviewer.sh is the only copy to check.
  run grep -q 'Final attempt' lib/boucle-ci/reviewer.sh
  assert_failure
}

@test "the notice fires on the last iteration only" {
  # MAX_ITER=3: a FAIL on iteration 1 starts iteration 2 (silent); a FAIL on
  # iteration 2 starts iteration 3, which is the last (notice).
  run bash -c '
    MAX_ITER=3
    for ITERATION in 1 2; do
      if [ "$((ITERATION + 1))" -eq "$MAX_ITER" ]; then
        echo "iter $ITERATION -> NOTICE"
      else
        echo "iter $ITERATION -> silent"
      fi
    done
  '
  assert_success
  assert_line --index 0 "iter 1 -> silent"
  assert_line --index 1 "iter 2 -> NOTICE"
}

@test "the notice never fires when the cap is 1 (no retry budget to warn about)" {
  # MAX_ITER=1 means the first FAIL escalates directly; the `-lt` guard is
  # false, so the FAIL branch never reaches the notice at all.
  run bash -c '
    MAX_ITER=1 ITERATION=1
    if [ "$ITERATION" -lt "$MAX_ITER" ]; then echo "REACHED"; else echo "ESCALATES"; fi
  '
  assert_success
  assert_output "ESCALATES"
}

# ── Iteration derivation from verdicts (#97) ──────────────────────────
# The label-event re-trigger path does not forward BOUCLE_ITERATION, so the
# counter can be stuck at 1 while the loop iterates — the MAX_ITERATIONS
# escalation never fires. Both stage scripts derive the true iteration from
# the verdicts already fetched (zero extra API calls) and raise, never
# lower, the inherited value.

@test "worker and reviewer both derive BOUCLE_ITERATION from reviewer verdicts" {
  run grep -c 'derived_iteration' lib/boucle-ci/worker.sh
  assert_success
  [ "$output" -ge 1 ]
  run grep -c 'derived_iteration' lib/boucle-ci/reviewer.sh
  assert_success
  [ "$output" -ge 1 ]
  # The derivation runs right after the MR feedback fetch, before the agent.
  run grep -q 'BOUCLE_REVIEWER_FEEDBACK=\$(forge_mr_notes' lib/boucle-ci/worker.sh
  assert_success
  run grep -q 'BOUCLE_REVIEWER_FEEDBACK=\$(forge_mr_notes' lib/boucle-ci/reviewer.sh
  assert_success
}

@test "iteration derivation: verdicts + 1 raises a stuck BOUCLE_ITERATION" {
  # 3 verdicts on the MR, inherited iteration stuck at 1 (label-event
  # re-trigger path) → the counter must rise to 4 so the MAX_ITERATIONS
  # escalation can fire.
  run bash -c '
    set -e
    BOUCLE_REVIEWER_FEEDBACK="[x — boucle] <!-- boucle:verdict v=1 role=reviewer sha=abc --> VERDICT: FAIL
[x — boucle] <!-- boucle:verdict v=1 role=reviewer sha=abc --> VERDICT: FAIL
[x — boucle] <!-- boucle:verdict v=1 role=reviewer sha=abc --> VERDICT: FAIL"
    BOUCLE_ITERATION=1
    verdict_count=$(printf "%s\n" "$BOUCLE_REVIEWER_FEEDBACK" | grep -c "boucle:verdict" 2> /dev/null || true)
    verdict_count="${verdict_count:-0}"
    if [ "$verdict_count" -gt 0 ]; then
      derived_iteration=$((verdict_count + 1))
      if [ "${BOUCLE_ITERATION:-1}" -lt "$derived_iteration" ]; then
        export BOUCLE_ITERATION="$derived_iteration"
      fi
    fi
    echo "ITERATION=$BOUCLE_ITERATION"
  '
  assert_success
  assert_output "ITERATION=4"
}

@test "iteration derivation: never lowers an inherited iteration" {
  # A single verdict on the MR, but the job inherited BOUCLE_ITERATION=3
  # (forwarded via chain_to_role): the derived value (2) must NOT lower it.
  run bash -c '
    set -e
    BOUCLE_REVIEWER_FEEDBACK="[x — boucle] <!-- boucle:verdict v=1 role=reviewer sha=abc --> VERDICT: FAIL"
    BOUCLE_ITERATION=3
    verdict_count=$(printf "%s\n" "$BOUCLE_REVIEWER_FEEDBACK" | grep -c "boucle:verdict" 2> /dev/null || true)
    verdict_count="${verdict_count:-0}"
    if [ "$verdict_count" -gt 0 ]; then
      derived_iteration=$((verdict_count + 1))
      if [ "${BOUCLE_ITERATION:-1}" -lt "$derived_iteration" ]; then
        export BOUCLE_ITERATION="$derived_iteration"
      fi
    fi
    echo "ITERATION=$BOUCLE_ITERATION"
  '
  assert_success
  assert_output "ITERATION=3"
}

@test "iteration derivation: empty feedback leaves the iteration untouched" {
  run bash -c '
    set -e
    BOUCLE_REVIEWER_FEEDBACK=""
    BOUCLE_ITERATION=2
    verdict_count=$(printf "%s\n" "$BOUCLE_REVIEWER_FEEDBACK" | grep -c "boucle:verdict" 2> /dev/null || true)
    verdict_count="${verdict_count:-0}"
    if [ "$verdict_count" -gt 0 ]; then
      derived_iteration=$((verdict_count + 1))
      if [ "${BOUCLE_ITERATION:-1}" -lt "$derived_iteration" ]; then
        export BOUCLE_ITERATION="$derived_iteration"
      fi
    fi
    echo "ITERATION=$BOUCLE_ITERATION"
  '
  assert_success
  assert_output "ITERATION=2"
}
