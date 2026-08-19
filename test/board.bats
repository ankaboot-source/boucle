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
forge_issue_list_by_label() {
  case "$1" in
    boucle:approval) echo '[{"iid":12,"title":"Add a pricing page","updated_at":"2026-08-10T09:00:00Z"}]' ;;
    boucle:working)  echo '[{"iid":15,"title":"Fix the nav","updated_at":"2026-08-10T11:00:00Z"}]' ;;
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
    $(stub_forge)
    source '$TMPF'
    forge_issue_list_by_label() {
      case \"\$1\" in
        boucle:triage) echo '[{\"iid\":69,\"title\":\"Fix current step indicator\",\"updated_at\":\"2026-08-18T09:00:00Z\"}]' ;;
        boucle:todo)   echo '[{\"iid\":42,\"title\":\"Add a pricing page\",\"updated_at\":\"2026-08-18T08:00:00Z\"}]' ;;
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
