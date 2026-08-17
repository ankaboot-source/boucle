#!/usr/bin/env bats
# Per-issue state on the forge (#3, from nexu-io/looper)
#
# Boucle's per-issue memory lived only in $BOUCLE_STATE_CACHE on the runner.
# That cache survives a shell-executor runner and NEVER survives an ephemeral
# one, so on GitHub-hosted runners the worker re-discovers the codebase every
# iteration and repeats approaches it already rejected — and #44's failure
# classification, which reads last-outcome, always saw "no previous outcome".

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

state_funcs() {
  {
    echo 'BOUCLE_STATE_MARKER="<!-- boucle:state v=1 -->"'
    for fn in boucle_state_payload boucle_state_note_id boucle_state_save boucle_state_restore; do
      awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' lib/boucle.sh
    done
  } > "$1"
}

seed_state() {
  local ws="$1"
  mkdir -p "$ws/.boucle/7" "$ws/.boucle-state/7"
  cat > "$ws/.boucle-state/7/state.md" <<'EOF'
# Issue #7
## Goal
GOAL-SHOULD-NOT-BE-PERSISTED
## Acceptance criteria
- [ ] CRITERION-SHOULD-NOT-BE-PERSISTED
## Approach
Astro component + Tailwind
## Tried and rejected
- CSS grid: broke on mobile
## Awaiting human
nothing
EOF
  printf '## 2026-08-11T10:00:00Z — worker — iteration 1\n- Files touched: src/pages/pricing.astro\n' > "$ws/.boucle/7/iterations.md"
  echo "no-changes" > "$ws/.boucle/7/last-outcome"
}

@test "state note: carries what cannot be recomputed" {
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  run bash -c "BOUCLE_WORKSPACE='$WS'; source '$TMPF'; boucle_state_payload 7"
  assert_success
  assert_output --partial "Tried and rejected"
  assert_output --partial "CSS grid: broke on mobile"
  assert_output --partial "iteration 1"
  assert_output --partial "no-changes"
  rm -rf "$TMPF" "$WS"
}

@test "state note: does NOT duplicate what the triage comment already holds" {
  # Goal and acceptance criteria are re-derived from the triage comment,
  # which is on the same issue. Persisting them would put the issue's
  # content back on the issue.
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  run bash -c "BOUCLE_WORKSPACE='$WS'; source '$TMPF'; boucle_state_payload 7"
  assert_success
  refute_output --partial "GOAL-SHOULD-NOT-BE-PERSISTED"
  refute_output --partial "CRITERION-SHOULD-NOT-BE-PERSISTED"
  rm -rf "$TMPF" "$WS"
}

@test "state note: collapsed, so the issue page shows one line" {
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  run bash -c "BOUCLE_WORKSPACE='$WS'; source '$TMPF'; boucle_state_payload 7"
  assert_output --partial "<details><summary>"
  assert_output --partial "</details>"
  assert_output --partial "<!-- boucle:state v=1 -->"
  rm -rf "$TMPF" "$WS"
}

@test "state note: stays small on a realistic issue" {
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  size=$(bash -c "BOUCLE_WORKSPACE='$WS'; source '$TMPF'; boucle_state_payload 7" | wc -c)
  [ "$size" -lt 2000 ]
  rm -rf "$TMPF" "$WS"
}

@test "state note: nothing to persist produces no note" {
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$WS'; source '$TMPF'; boucle_state_payload 7"
  assert_success
  assert_output ""
  rm -rf "$TMPF" "$WS"
}

@test "state note: over the cap, the TAIL is kept" {
  # The most recent iterations are the ones the next run needs, and a note
  # body rejected by the forge for size would lose the state entirely.
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  {
    printf '## OLDEST-ENTRY\n'
    for i in $(seq 1 400); do printf -- '- filler line %s\n' "$i"; done
    printf '## NEWEST-ENTRY\n'
  } > "$WS/.boucle/7/iterations.md"
  run bash -c "BOUCLE_WORKSPACE='$WS'; BOUCLE_STATE_NOTE_CHARS=800; source '$TMPF'; boucle_state_payload 7"
  assert_success
  assert_output --partial "NEWEST-ENTRY"
  assert_output --partial "older state elided by boucle"
  refute_output --partial "OLDEST-ENTRY"
  rm -rf "$TMPF" "$WS"
}

@test "state note: a cold runner recovers iterations and last-outcome" {
  TMPF=$(mktemp); SRC=$(mktemp -d); DST=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$SRC"
  PAYLOAD=$(bash -c "BOUCLE_WORKSPACE='$SRC'; source '$TMPF'; boucle_state_payload 7")
  run bash -c "
    BOUCLE_WORKSPACE='$DST'
    source '$TMPF'
    forge_issue_notes() { printf '[{\"id\":11,\"created_at\":\"2026-01-01\",\"body\":'; jq -Rs . <<'EOB'
$PAYLOAD
EOB
    printf '}]'; }
    forge_issue_note_get() { printf '{\"body\":'; jq -Rs . <<'EOB'
$PAYLOAD
EOB
    printf '}'; }
    boucle_state_restore 7
  "
  assert_success
  grep -q "iteration 1" "$DST/.boucle/7/iterations.md"
  grep -q "no-changes" "$DST/.boucle/7/last-outcome"
  rm -rf "$TMPF" "$SRC" "$DST"
}

@test "state note: restore never clobbers local files that already exist" {
  # The cache is the fast path; when it is warm the note said the same
  # thing, so there is nothing to reconcile.
  TMPF=$(mktemp); SRC=$(mktemp -d); DST=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$SRC"
  PAYLOAD=$(bash -c "BOUCLE_WORKSPACE='$SRC'; source '$TMPF'; boucle_state_payload 7")
  mkdir -p "$DST/.boucle/7"; echo "LOCAL-WINS" > "$DST/.boucle/7/iterations.md"
  bash -c "
    BOUCLE_WORKSPACE='$DST'
    source '$TMPF'
    forge_issue_notes() { printf '[{\"id\":11,\"created_at\":\"2026-01-01\",\"body\":'; jq -Rs . <<'EOB'
$PAYLOAD
EOB
    printf '}]'; }
    forge_issue_note_get() { printf '{\"body\":'; jq -Rs . <<'EOB'
$PAYLOAD
EOB
    printf '}'; }
    boucle_state_restore 7
  " > /dev/null 2>&1
  run cat "$DST/.boucle/7/iterations.md"
  assert_output "LOCAL-WINS"
  rm -rf "$TMPF" "$SRC" "$DST"
}

@test "state note: BOUCLE_STATE_NOTE_ENABLED=false disables it entirely" {
  TMPF=$(mktemp); WS=$(mktemp -d)
  state_funcs "$TMPF"; seed_state "$WS"
  run bash -c "
    BOUCLE_WORKSPACE='$WS' BOUCLE_STATE_NOTE_ENABLED=false
    source '$TMPF'
    forge_issue_notes() { echo 'UNEXPECTED'; }
    boucle_state_save 7
  "
  assert_success
  refute_output --partial "UNEXPECTED"
  rm -rf "$TMPF" "$WS"
}

@test "state note: excluded from the notes injected into prompts" {
  # Without this the note is re-billed as prompt input on every run, growing
  # with every iteration it records.
  for f in lib/boucle-ci/triage.sh lib/boucle-ci/worker.sh lib/boucle-ci/reviewer.sh; do
    run bash -c "grep -c 'contains(\"<!-- boucle:state\") | not' '$f' || true"
    [ "$output" -ge 1 ]
  done
}

@test "state note: the worker saves it on exit and restores on a cold cache" {
  run grep -q 'boucle_state_save "$BOUCLE_ISSUE"' lib/boucle-ci/worker.sh
  assert_success
  run grep -q 'boucle_state_restore "$BOUCLE_ISSUE"' lib/boucle-ci/worker.sh
  assert_success
  # Restore must happen before anything reads last-outcome (#44's classifier).
  restore_line=$(grep -n 'boucle_state_restore' lib/boucle-ci/worker.sh | head -1 | cut -d: -f1)
  read_line=$(grep -n 'ISSUE_STATE_CACHE/last-outcome' lib/boucle-ci/worker.sh | tail -1 | cut -d: -f1)
  [ "$restore_line" -lt "$read_line" ]
}
