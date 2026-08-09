#!/usr/bin/env bats
# test/forge-reactions.bats — tests for the canonical reaction-name table
# (bin/forge/common.sh) and the spec-approval emoji constants.
#
# The canonical set (thumbsup/thumbs_down/smile/confused/heart/tada/rocket/
# eyes) is the SINGLE source of truth for which reactions count as spec
# approval on every forge. The old GitLab alpha codes (white_check_mark,
# ballot_box_with_check, heavy_check_mark, ok, ok_hand) MUST map to empty.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # Sourcing common.sh is side-effect-free (defines forge_init +
  # forge_reaction_canonical; the backend is loaded via forge_init only).
  # shellcheck source=../bin/forge/common.sh
  # shellcheck disable=SC2154 # BATS_TEST_FILENAME is provided by bats
  . "$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/bin/forge/common.sh"
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "common.sh parses without syntax error" {
  run bash -n bin/forge/common.sh
  assert_success
}

# ── Canonical name mapping ────────────────────────────────────────────

@test "canonical names map to identity" {
  run forge_reaction_canonical "thumbsup"
  assert_output "thumbsup"
  run forge_reaction_canonical "thumbs_down"
  assert_output "thumbs_down"
  run forge_reaction_canonical "smile"
  assert_output "smile"
  run forge_reaction_canonical "confused"
  assert_output "confused"
  run forge_reaction_canonical "heart"
  assert_output "heart"
  run forge_reaction_canonical "tada"
  assert_output "tada"
  run forge_reaction_canonical "rocket"
  assert_output "rocket"
  run forge_reaction_canonical "eyes"
  assert_output "eyes"
}

@test "GitHub content names map to canonical" {
  run forge_reaction_canonical "+1"
  assert_output "thumbsup"
  run forge_reaction_canonical "-1"
  assert_output "thumbs_down"
  run forge_reaction_canonical "laugh"
  assert_output "smile"
  run forge_reaction_canonical "hooray"
  assert_output "tada"
}

@test "emoji aliases map to canonical" {
  run forge_reaction_canonical "👍"
  assert_output "thumbsup"
  run forge_reaction_canonical "👎"
  assert_output "thumbs_down"
  run forge_reaction_canonical "😄"
  assert_output "smile"
  run forge_reaction_canonical "😕"
  assert_output "confused"
  run forge_reaction_canonical "❤"
  assert_output "heart"
  run forge_reaction_canonical "🎉"
  assert_output "tada"
  run forge_reaction_canonical "🚀"
  assert_output "rocket"
  run forge_reaction_canonical "👀"
  assert_output "eyes"
}

@test "legacy aliases map to canonical" {
  run forge_reaction_canonical "thumbs_up"
  assert_output "thumbsup"
  run forge_reaction_canonical "love"
  assert_output "heart"
  run forge_reaction_canonical "party"
  assert_output "tada"
}

@test "old approval emoji names map to empty (not valid)" {
  run forge_reaction_canonical "white_check_mark"
  assert_output ""
  run forge_reaction_canonical "ballot_box_with_check"
  assert_output ""
  run forge_reaction_canonical "heavy_check_mark"
  assert_output ""
  run forge_reaction_canonical "ok"
  assert_output ""
  run forge_reaction_canonical "ok_hand"
  assert_output ""
}

# ── Spec-approval constants (doctor + dispatch) ───────────────────────

@test "doctor spec-approval constant is thumbsup only" {
  run grep -E '^  BOUCLE_SPEC_APPROVAL_EMOJIS=' lib/boucle-ci/doctor.sh
  assert_success
  assert_output '  BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup"'
}

@test "dispatch spec-approval constant is thumbsup only" {
  run grep -E '^    BOUCLE_SPEC_APPROVAL_EMOJIS=' lib/boucle-ci/dispatch.sh
  assert_success
  assert_output '    BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup"'
}

@test "old approval emoji names are gone from lib/boucle-ci and bin/forge" {
  run bash -c 'grep -rnE "white_check_mark|ballot_box_with_check|heavy_check_mark|ok_hand" lib/boucle-ci bin/forge || true'
  assert_output ""
}
