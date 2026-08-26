#!/usr/bin/env bats
# Merge-gate approval (boucle_mr_is_approved) + manual-merge recovery.
#
# There were two definitions of "approved" and they disagreed. dispatch.sh
# accepts a human replying `approved` on the PR — the documented contract,
# because GitHub emoji reactions have no webhook. doctor.sh re-checked with
# forge_mr_approvals, which counts only NATIVE reviews, and escalated every
# issue that sat at boucle:merging long enough for a sweep with "no longer
# approved" — wording implying an approval was withdrawn when none existed.
#
# On a mono-user install the native check is not merely stricter, it is
# unsatisfiable: GitHub refuses to let the PR author approve their own PR.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

# Runs boucle_mr_is_approved with forge_* stubbed. $1 = forge_mr_approvals
# output, $2 = forge_mr_notes JSON.
gate() {
  bash -c "
    . '$REPO/lib/boucle.sh' 2>/dev/null
    export BOUCLE_AGENT_MARKER='<!-- boucle:agent -->'
    forge_mr_approvals() { echo '$1'; }
    forge_mr_notes() { cat <<'J'
$2
J
    }
    if boucle_mr_is_approved 1; then echo APPROVED; else echo REFUSED; fi"
}

@test "gate: a native review approval passes" {
  run gate true '[]'
  assert_output "APPROVED"
}

@test "gate: the magic word passes without any native review" {
  # The documented contract. This is the case that was being rejected.
  run gate false '[{"body":"approved","system":false}]'
  assert_output "APPROVED"
}

@test "gate: the magic word is matched case- and whitespace-insensitively" {
  run gate false '[{"body":"  Approved  ","system":false}]'
  assert_output "APPROVED"
}

@test "gate: only the FIRST line counts, exactly" {
  # "Any other comment at boucle:approval is feedback" — dispatch's rule.
  run gate false '[{"body":"looks approved to me","system":false}]'
  assert_output "REFUSED"
}

@test "gate: boucle's own write never approves the merge" {
  # Identified by the agent marker, not by actor identity — SKILL.md
  # invariant I7, and the only rule that holds in mono-user mode where the
  # bot posts as the human's account.
  run gate false '[{"body":"approved <!-- boucle:agent -->","system":false}]'
  assert_output "REFUSED"
}

@test "gate: a system note never approves the merge" {
  run gate false '[{"body":"approved","system":true}]'
  assert_output "REFUSED"
}

@test "gate: no signal at all is refused" {
  run gate false '[]'
  assert_output "REFUSED"
}

# ── the doctor uses the shared definition everywhere ──────────────────

@test "doctor: no approval check calls forge_mr_approvals directly" {
  # Three call sites drifted apart once. The shared resolver is the only
  # way they stay in step.
  run bash -c "grep -nE '^[^#]*forge_mr_approvals' '$REPO/lib/boucle-ci/doctor.sh' || true"
  assert_output ""
}

@test "doctor: the stuck-at-merging block uses the shared gate" {
  run bash -c "awk '/stuck at boucle:merging/,0' '$REPO/lib/boucle-ci/doctor.sh' | head -40 | grep -c 'boucle_mr_is_approved' || true"
  assert_success
  [ "$output" -ge 0 ]
  run grep -q 'boucle_mr_is_approved "$MR_IID"' "$REPO/lib/boucle-ci/doctor.sh"
  assert_success
}

@test "doctor: the magic word is no longer gated on mono-user" {
  # dispatch's gate is not gated on it either; gating them differently is
  # what let the two definitions drift.
  run bash -c "grep -c 'BOUCLE_MONO_USER:-false.*=.*true.*doctor_mr_approval_magic_word' '$REPO/lib/boucle-ci/doctor.sh' || true"
  assert_output "0"
}

# ── manual merge ──────────────────────────────────────────────────────

@test "manual merge: an already-merged PR resumes the loop, never escalates" {
  # No OPEN PR is not the same as no PR. Merging from the forge UI left the
  # doctor telling the human their completed merge had failed, and parked a
  # shipped issue at boucle:human.
  run bash -c "awk '/no open MR found|no open or merged MR found/,0' '$REPO/lib/boucle-ci/doctor.sh' | head -1"
  refute_output --partial "no open MR found"
}

@test "manual merge: the merged lookup happens BEFORE the escalation" {
  # Ordering is the whole fix: escalating first and checking after would
  # still park a shipped issue at boucle:human. Scoped to the
  # stuck-at-merging block — two other sweeps have their own merged
  # lookups and are not what this guards.
  run bash -c "awk '/no open or merged MR found/,0' '$REPO/lib/boucle-ci/doctor.sh' | head -1 | grep -c 'no open or merged'"
  assert_output "1"
  # Within the block, the merged lookup must precede the escalation note.
  block=$(awk '/MR_IID=\$\(forge_mr_lookup_by_branch "boucle\/\$IID" opened\)/,/^    fi$/' "$REPO/lib/boucle-ci/doctor.sh")
  lookup_line=$(printf '%s\n' "$block" | grep -n 'merged' | head -1 | cut -d: -f1)
  escalate_line=$(printf '%s\n' "$block" | grep -n 'Human intervention needed' | head -1 | cut -d: -f1)
  [ -n "$lookup_line" ] && [ -n "$escalate_line" ] && [ "$lookup_line" -lt "$escalate_line" ]
}

@test "manual merge: recovery chains to post-merge, not to boucle:human" {
  run bash -c "awk '/is already merged/,/continue/' '$REPO/lib/boucle-ci/doctor.sh'"
  assert_success
  assert_output --partial 'chain_to_role "$IID" "post-merge"'
  refute_output --partial 'boucle:human'
}
