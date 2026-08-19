#!/usr/bin/env bats
# Status board (#36)
#
# Boucle's state is fully legible — it lives in labels — but only if you
# know which labels to filter on and you go looking. Nothing answered
# "what is waiting on me?".

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

board_funcs() {
  awk '/^boucle_board_render\(\) \{/,/^}/' lib/boucle.sh > "$1"
  awk '/^boucle_board_upsert\(\) \{/,/^}/' lib/boucle.sh >> "$1"
}

stub_forge() {
  cat <<'STUB'
# The board reads a SINGLE atomic snapshot (forge_issue_list_all) and
# partitions it client-side, so a transition between two per-label queries
# can no longer split one issue across two sections (boucle.dev #34).
forge_issue_list_all() {
  case "$1" in
    opened)
      echo '[
        {"iid":12,"title":"Add a pricing page","updated_at":"2026-08-10T09:00:00Z","labels":[{"name":"boucle:approval"}]},
        {"iid":15,"title":"Fix the nav","updated_at":"2026-08-10T11:00:00Z","labels":[{"name":"boucle:working"}]}
      ]'
      ;;
    *) echo '[]' ;;
  esac
}
STUB
}

@test "board: groups issues under the four sections" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "$(stub_forge); source '$TMPF'; boucle_board_render"
  assert_success
  assert_output --partial "Waiting on you"
  assert_output --partial "| #12 | Add a pricing page | approval |"
  assert_output --partial "In flight"
  assert_output --partial "| #15 | Fix the nav | working |"
  rm -f "$TMPF"
}

@test "board: triage and todo issues appear in In flight" {
  # An issue boucle has acknowledged (boucle:triage) or queued for the worker
  # (boucle:todo) is in flight from the human's perspective — boucle has it.
  # Omitting them makes the board silently hide active work (#69 regression).
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    source '$TMPF'
    forge_issue_list_all() {
      case \"\$1\" in
        opened)
          echo '[{\"iid\":69,\"title\":\"Fix current step indicator\",\"updated_at\":\"2026-08-18T09:00:00Z\",\"labels\":[{\"name\":\"boucle:triage\"}]},{\"iid\":42,\"title\":\"Add a pricing page\",\"updated_at\":\"2026-08-18T08:00:00Z\",\"labels\":[{\"name\":\"boucle:todo\"}]}]'
          ;;
        *) echo '[]' ;;
      esac
    }
    boucle_board_render
  "
  assert_success
  assert_output --partial "| #69 | Fix current step indicator | triage |"
  assert_output --partial "| #42 | Add a pricing page | todo |"
  rm -f "$TMPF"
}

@test "board: an empty section says so instead of rendering an empty table" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "$(stub_forge); source '$TMPF'; boucle_board_render"
  assert_success
  assert_output --partial "_Nothing._"
  rm -f "$TMPF"
}

@test "board: carries a machine-readable marker" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "$(stub_forge); source '$TMPF'; boucle_board_render"
  assert_output --partial "<!-- boucle:board v=1 -->"
  rm -f "$TMPF"
}

@test "board: an unchanged body produces zero writes" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    $(stub_forge)
    source '$TMPF'
    forge_issue_get() { jq -n --arg d \"\$(boucle_board_render)\" '{description:\$d}'; }
    forge_issue_update() { echo 'UNEXPECTED WRITE'; }
    forge_issue_create() { echo 'UNEXPECTED CREATE'; }
    forge_issue_list_by_label() {
      if [ \"\$1\" = 'boucle:board' ]; then echo '[{\"iid\":99}]'; else echo '[]'; fi
    }
    boucle_board_upsert
  "
  assert_success
  assert_output --partial "unchanged — no write"
  refute_output --partial "UNEXPECTED"
  rm -f "$TMPF"
}

@test "board: a changed body is written in place, never commented" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    $(stub_forge)
    source '$TMPF'
    forge_issue_get() { echo '{\"description\":\"stale\"}'; }
    forge_issue_update() { echo \"UPDATE \$1 \$2\"; }
    forge_issue_list_by_label() {
      if [ \"\$1\" = 'boucle:board' ]; then echo '[{\"iid\":99}]'; else echo '[]'; fi
    }
    boucle_board_upsert
  "
  assert_success
  assert_output --partial "UPDATE 99 description"
  rm -f "$TMPF"
}

@test "board: created on first run, then reused (idempotent)" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    $(stub_forge)
    source '$TMPF'
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_create() { echo 77; }
    boucle_board_upsert
  "
  assert_success
  assert_output --partial "status board created as #77"
  rm -f "$TMPF"
}

@test "board: BOUCLE_BOARD_ENABLED=false disables it entirely" {
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    source '$TMPF'
    forge_issue_list_all() { echo 'UNEXPECTED'; }
    forge_issue_list_by_label() { echo 'UNEXPECTED'; }
    BOUCLE_BOARD_ENABLED=false boucle_board_upsert
  "
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

@test "board: never posts a comment" {
  # CONTEXT.md §8 already warns that no-op label writes pollute the event
  # history; a board that comments would be worse.
  run bash -c "awk '/^boucle_board_upsert\(\) \{/,/^}/' lib/boucle.sh | grep -c forge_issue_note"
  assert_output "0"
}

@test "board: the board issue is never dispatched" {
  # Creating it fires an issue webhook like any other; without the guard
  # the loop would start working on itself.
  run grep -q 'never dispatched' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "board: the doctor refreshes it at the end of the sweep" {
  run grep -q 'boucle_board_upsert || true' lib/boucle-ci/doctor.sh
  assert_success
}

@test "board: bin/setup registers the boucle:board label" {
  run grep -q 'merging board; do' bin/setup
  assert_success
}

@test "board: set_boucle_label refreshes the board on a real transition" {
  # The board must refresh on the TRANSITION (webhook-reliable), not only on
  # the doctor sweep (lesson #97). set_boucle_label is the single transition
  # function, so hooking it there covers every future transition by
  # construction. This test asserts the board is refreshed when the label
  # actually changes.
  TMPF=$(mktemp); board_funcs "$TMPF"
  awk '/^set_boucle_label\(\) \{/,/^}/' lib/boucle.sh >> "$TMPF"
  run bash -c "
    source '$TMPF'
    # Current labels do NOT contain the new label → the transition guard fires.
    forge_issue_labels_get() { echo 'boucle:todo,boucle::status::bot'; }
    forge_issue_labels_set() { echo \"SET \$1 \$2\"; }
    forge_issue_list_all() { echo '[]'; }
    forge_issue_list_by_label() {
      if [ \"\$1\" = 'boucle:board' ]; then echo '[]'; else echo '[]'; fi
    }
    forge_issue_create() { echo 99; }
    forge_issue_get() { echo '{\"description\":\"stale\"}'; }
    forge_issue_update() { echo \"UPDATE \$1 \$2\"; }
    boucle_notify() { :; }
    forge_issue_assign() { :; }
    resolve_reporter_id() { echo ''; }
    boucle_mono_user() { return 1; }
    set_boucle_label 42 'boucle:working' 'boucle::status::bot'
  "
  assert_success
  assert_output --partial "status board created as #99"
  rm -f "$TMPF"
}

@test "board: set_boucle_label does NOT refresh the board when the label is unchanged" {
  # A no-op label write (comment, edit, doctor re-apply) must NOT trigger a
  # board refresh — the guard is "did the label actually change?". This test
  # asserts the board is left untouched when the new label is already present.
  TMPF=$(mktemp); board_funcs "$TMPF"
  awk '/^set_boucle_label\(\) \{/,/^}/' lib/boucle.sh >> "$TMPF"
  run bash -c "
    source '$TMPF'
    # Current labels ALREADY contain the new label → the transition guard does
    # not fire, so no board refresh.
    forge_issue_labels_get() { echo 'boucle:working,boucle::status::bot'; }
    forge_issue_labels_set() { echo \"SET \$1 \$2\"; }
    forge_issue_list_all() { echo 'UNEXPECTED'; }
    forge_issue_list_by_label() { echo 'UNEXPECTED'; }
    forge_issue_create() { echo 'UNEXPECTED CREATE'; }
    forge_issue_update() { echo 'UNEXPECTED UPDATE'; }
    boucle_notify() { :; }
    forge_issue_assign() { :; }
    resolve_reporter_id() { echo ''; }
    boucle_mono_user() { return 1; }
    set_boucle_label 42 'boucle:working' 'boucle::status::bot'
  "
  assert_success
  refute_output --partial "status board"
  refute_output --partial "UNEXPECTED"
  rm -f "$TMPF"
}

@test "board: an issue appears in only ONE section even with two state labels" {
  # Regression guard for boucle.dev #34: issue #73 appeared in BOTH
  # "Waiting on you" (boucle:approval) and "In flight" (boucle:merging)
  # because the old render issued one forge call per label and a transition
  # fired between two calls. The single-snapshot render partitions
  # client-side and deduplicates: an issue carrying two state labels lands
  # in the FIRST matching section only (human-waiting > in-flight).
  TMPF=$(mktemp); board_funcs "$TMPF"
  run bash -c "
    source '$TMPF'
    # Issue #73 carries BOTH boucle:approval AND boucle:merging — the
    # contradictory state the old race produced. It must appear in
    # \"Waiting on you\" (approval) only, never in \"In flight\".
    forge_issue_list_all() {
      echo '[{\"iid\":73,\"title\":\"Enhance How boucle works messages\",\"updated_at\":\"2026-08-19T12:00:00Z\",\"labels\":[{\"name\":\"boucle:approval\"},{\"name\":\"boucle:merging\"}]}]'
    }
    boucle_board_render
  "
  assert_success
  assert_output --partial "| #73 | Enhance How boucle works messages | approval |"
  refute_output --partial "| #73 | Enhance How boucle works messages | merging |"
  rm -f "$TMPF"
}
