#!/usr/bin/env bats
# test/ack-pickup.bats — the 👀 pickup acknowledgement.
#
# When triage takes an issue it awards 👀 on it, so the human knows the
# loop picked their issue up without waiting minutes for the triage
# comment. Two properties matter and are both load-bearing:
#
#   1. The ack is best-effort and idempotent — a cosmetic reaction must
#      never break the loop, and a re-triage must not re-award (a second
#      award would fire a second webhook).
#   2. The ack must NOT route back into the loop. It fires an emoji
#      webhook on an issue still labelled boucle:triage, and that label
#      routes to triage unconditionally — so dispatch has to discard it.
#      The bot-identity guard cannot: in mono-user mode ACTOR is the
#      human on every event, boucle's own writes included.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"
  export BOUCLE_FORGE=gitlab
  # shellcheck disable=SC1091
  source bin/forge/common.sh
  # shellcheck disable=SC1091
  source lib/boucle.sh
  # shellcheck disable=SC1091
  source lib/boucle-ci/dispatch.sh
  # shellcheck disable=SC2154 # BATS_TEST_TMPDIR is provided by bats
  PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "lib/boucle.sh parses without syntax error" {
  run bash -n lib/boucle.sh
  assert_success
}

@test "lib/boucle-ci/triage.sh parses without syntax error" {
  run bash -n lib/boucle-ci/triage.sh
  assert_success
}

# ── The emoji itself ──────────────────────────────────────────────────

@test "the ack emoji is a canonical cross-forge reaction" {
  # An out-of-set name is dropped by both backends — the award would be a
  # silent no-op on every issue.
  run forge_reaction_canonical "$BOUCLE_ACK_EMOJI"
  assert_output "eyes"
}

@test "the ack emoji is NOT a spec-approval emoji" {
  # If the ack were in the approval set, boucle acknowledging an issue
  # would read as boucle approving its own spec. Read the real constant
  # out of the source rather than restating it — and split on either
  # separator, so this asserts the PROPERTY and not today's formatting
  # (the constant has been both space- and pipe-separated).
  local approval
  approval=$(grep -hoE 'BOUCLE_SPEC_APPROVAL_EMOJIS="[^"]*"' lib/boucle-ci/dispatch.sh lib/boucle-ci/doctor.sh \
    | head -1 | sed 's/.*="//; s/"$//')
  [ -n "$approval" ]
  run bash -c "printf '%s' \"$approval\" | tr '|' ' ' | tr ' ' '\n' | grep -qx '$BOUCLE_ACK_EMOJI'"
  assert_failure
}

@test "dispatch and doctor agree on the spec-approval set" {
  # The two constants are separate shells and must not drift apart; each
  # CI job runs its own copy.
  local d1 d2
  d1=$(grep -hoE 'BOUCLE_SPEC_APPROVAL_EMOJIS="[^"]*"' lib/boucle-ci/dispatch.sh | head -1)
  d2=$(grep -hoE 'BOUCLE_SPEC_APPROVAL_EMOJIS="[^"]*"' lib/boucle-ci/doctor.sh | head -1)
  [ -n "$d1" ]
  [ "$d1" = "$d2" ]
}

# ── ack_issue_taken ───────────────────────────────────────────────────

@test "ack_issue_taken awards the ack emoji on the issue" {
  forge_issue_add_reaction() { echo "react:$1:$2"; }
  run ack_issue_taken 42
  assert_success
  assert_output "react:42:eyes"
}

@test "ack_issue_taken survives a forge failure (cosmetic, never blocking)" {
  forge_issue_add_reaction() { return 1; }
  run ack_issue_taken 42
  assert_success
}

@test "ack_issue_taken is a no-op without an iid" {
  forge_issue_add_reaction() { echo "react:$1:$2"; }
  run ack_issue_taken ""
  assert_success
  assert_output ""
}

@test "ack_issue_taken is a no-op when the forge layer is not loaded" {
  # Local dev / partial sourcing: the helper must not abort the caller
  # under set -e just because the backend is absent.
  run bash -c '
    source lib/boucle.sh
    unset -f forge_issue_add_reaction 2>/dev/null || true
    set -e
    ack_issue_taken 42
    echo survived
  '
  assert_success
  assert_output --partial "survived"
}

# ── Triage wiring ─────────────────────────────────────────────────────

@test "triage acks the pickup" {
  run grep -q 'ack_issue_taken "\$IID"' lib/boucle-ci/triage.sh
  assert_success
}

@test "triage acks BEFORE the slow work (attachments, agent run)" {
  # The whole point is immediate feedback. Acking after the agent run
  # would tell the human nothing the triage comment doesn't already say.
  ack_line=$(grep -n 'ack_issue_taken "\$IID"' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  slow_line=$(grep -n 'fetch-issue-attachments' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  [ -n "$ack_line" ]
  [ -n "$slow_line" ]
  [ "$ack_line" -lt "$slow_line" ]
}

@test "triage acks even on the no-key path" {
  # The no-key branch exits early. Acking before it means an issue opened
  # on a keyless repo still shows that boucle saw it.
  ack_line=$(grep -n 'ack_issue_taken "\$IID"' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  nokey_line=$(grep -n 'if ! has_llm_config' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  [ -n "$ack_line" ]
  [ -n "$nokey_line" ]
  [ "$ack_line" -lt "$nokey_line" ]
}

# ── Dispatch anti-loop guard ──────────────────────────────────────────
# Reconstructs the guard from dispatch.sh's own conditions. `skipped` is
# the observable outcome: 1 means the event is discarded before routing.

ack_guard_decision() {
  local object_kind="$1" awardable="$2" name="$3"
  local skipped=0
  if [ "$object_kind" = "emoji" ]; then
    if [ "$awardable" = "Issue" ] \
      && [ "$(forge_reaction_canonical "$name")" = "${BOUCLE_ACK_EMOJI:-eyes}" ]; then
      skipped=1
    fi
  fi
  echo "$skipped"
}

@test "mono-user: boucle's own 👀 on the issue is discarded" {
  # Without this the loop re-triages its own acknowledgement: the issue
  # is still at boucle:triage, and that label routes unconditionally.
  BOUCLE_MONO_USER=true run ack_guard_decision "emoji" "Issue" "eyes"
  assert_output "1"
}

@test "a human 👀 on the issue is discarded too (it means nothing to route)" {
  run ack_guard_decision "emoji" "Issue" "eyes"
  assert_output "1"
}

@test "the spec-approval 👍 on a note still routes" {
  run ack_guard_decision "emoji" "Note" "thumbsup"
  assert_output "0"
}

@test "👀 on a note still routes (the guard is issue-scoped)" {
  run ack_guard_decision "emoji" "Note" "eyes"
  assert_output "0"
}

@test "non-emoji events are untouched by the guard" {
  run ack_guard_decision "issue" "" ""
  assert_output "0"
  run ack_guard_decision "note" "" ""
  assert_output "0"
}

# ── Guard shape: the reconstruction above must match the real source ───

@test "dispatch discards the ack emoji on an Issue" {
  run grep -q 'EMOJI_AWARDABLE" = "Issue"' lib/boucle-ci/dispatch.sh
  assert_success
  run grep -q 'BOUCLE_ACK_EMOJI:-eyes' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "dispatch checks the ack guard before any label routing" {
  # boucle:triage routes unconditionally, so the guard is only effective
  # ahead of the routing block.
  guard_line=$(grep -n 'EMOJI_AWARDABLE" = "Issue"' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  route_line=$(grep -n 'SHOULD_TRIAGE=false' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ -n "$route_line" ]
  [ "$guard_line" -lt "$route_line" ]
}

@test "dispatch canonicalizes the awarded name before comparing" {
  # GitLab sends "eyes", a raw payload could carry "👀" — both must hit
  # the guard, so the comparison goes through forge_reaction_canonical.
  run grep -q 'forge_reaction_canonical "\$EMOJI_AWARDED"' lib/boucle-ci/dispatch.sh
  assert_success
}

# ── Protocol doc sync ─────────────────────────────────────────────────

@test "SKILL.md documents the ack emoji and its anti-loop filter" {
  run grep -q 'BOUCLE_ACK_EMOJI' SKILL.md
  assert_success
  run grep -q "boucle's own 👀 ack" SKILL.md
  assert_success
}
