#!/usr/bin/env bats
# test/dispatch.bats — the anti-loop guard.
#
# This is the highest-risk surface in boucle: a regression here does not
# produce a wrong answer, it produces an infinite loop that saturates the
# runner. The guard had no test harness before #8.
#
# boucle_ci_dispatch() is a long function that talks to the forge, so these
# tests do not run it end to end. They exercise the two pure pieces the
# guard is built from — dispatch_note_body and the marker/mono-user
# predicates — plus the guard's decision table, reconstructed from the same
# conditions the function uses. The reconstruction is asserted against the
# real source in "guard shape" tests below, so it cannot silently drift.

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

# ── Syntax / formatting ───────────────────────────────────────────────

@test "lib/boucle-ci/dispatch.sh parses without syntax error" {
  run bash -n lib/boucle-ci/dispatch.sh
  assert_success
}

@test "lib/boucle-ci/dispatch.sh passes shfmt -d" {
  if ! command -v shfmt > /dev/null 2>&1; then skip "shfmt not installed"; fi
  run shfmt -d -i 2 -bn -ci -sr lib/boucle-ci/dispatch.sh
  assert_success
}

# ── dispatch_note_body: forge-agnostic comment extraction ─────────────

@test "dispatch_note_body reads a GitLab note payload" {
  echo '{"object_kind":"note","object_attributes":{"note":"human reply"}}' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_note_body
  assert_success
  assert_output "human reply"
}

@test "dispatch_note_body reads a GitHub issue_comment payload" {
  echo '{"action":"created","comment":{"body":"human reply"}}' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_note_body
  assert_success
  assert_output "human reply"
}

@test "dispatch_note_body is empty for a non-comment event" {
  echo '{"object_kind":"issue","object_attributes":{"action":"open"}}' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_note_body
  assert_success
  assert_output ""
}

@test "dispatch_note_body is empty when the payload is not a file" {
  # The GitHub workflow used to pass the JSON itself instead of a path.
  # That must degrade to "not a comment", never to a jq error.
  BOUCLE_TRIGGER_PAYLOAD='{"comment":{"body":"x"}}' run dispatch_note_body
  assert_success
  assert_output ""
}

@test "dispatch_note_body is empty when the payload is unset" {
  BOUCLE_TRIGGER_PAYLOAD="" run dispatch_note_body
  assert_success
  assert_output ""
}

@test "dispatch_note_body survives a malformed payload" {
  echo 'not json at all' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_note_body
  assert_success
  assert_output ""
}

# ── Marker round-trip: what forge_issue_note writes, dispatch detects ──

@test "a comment stamped by the forge layer is detected as boucle's own" {
  body="$(stamp_agent_marker 'triage analysis')"
  run has_agent_marker "$body"
  assert_success
}

@test "a plain human comment is not detected as boucle's own" {
  run has_agent_marker "looks good to me, ship it"
  assert_failure
}

@test "a human quoting boucle's rendered comment is still not boucle" {
  # The marker is an HTML comment: it does not survive a copy-paste of the
  # rendered text, only of the raw source. Quoting the visible body must
  # not make a human reply look like a bot write.
  run has_agent_marker "you said: triage analysis — I disagree"
  assert_failure
}

# ── mono-user predicate ───────────────────────────────────────────────

@test "boucle_mono_user is false when BOUCLE_MONO_USER is unset" {
  unset BOUCLE_MONO_USER
  run boucle_mono_user
  assert_failure
}

@test "boucle_mono_user is false when BOUCLE_MONO_USER=false" {
  BOUCLE_MONO_USER=false run boucle_mono_user
  assert_failure
}

@test "boucle_mono_user is true when BOUCLE_MONO_USER=true" {
  BOUCLE_MONO_USER=true run boucle_mono_user
  assert_success
}

# ── Guard decision table ──────────────────────────────────────────────
# Reconstructs the guard from dispatch.sh's own conditions. `skipped` is
# the observable outcome: 1 means the event is discarded before routing.

guard_decision() {
  local actor="$1" mr_action="$2" note_body="$3"
  local skipped=0
  if [ -n "$note_body" ] && has_agent_marker "$note_body"; then
    skipped=1
  elif ! boucle_mono_user; then
    if [ "$actor" = "${BOUCLE_BOT_USERNAME:-up-bot}" ] && [ "$mr_action" != "merge" ]; then
      skipped=1
    fi
  fi
  echo "$skipped"
}

@test "bot mode: a bot-authored event is discarded" {
  unset BOUCLE_MONO_USER
  run guard_decision "up-bot" "update" ""
  assert_output "1"
}

@test "bot mode: a human-authored event routes" {
  unset BOUCLE_MONO_USER
  run guard_decision "alice" "update" ""
  assert_output "0"
}

@test "bot mode: the MR merge webhook survives the bot filter" {
  # The merger runs as the bot, so its merge webhook is bot-authored and
  # would be discarded like any other. Without this exception the catchup
  # never runs and the issue stays at boucle:merging forever.
  unset BOUCLE_MONO_USER
  BOUCLE_BOT_USERNAME=up-bot run guard_decision "up-bot" "merge" ""
  assert_output "0"
}

@test "mono-user: the human's own action routes (this is the whole point)" {
  # With the actor guard still in force this returned 1, and the loop
  # never fired for the account that owned the token.
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME=alice run guard_decision "alice" "update" ""
  assert_output "0"
}

@test "mono-user: the human's own comment routes" {
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME=alice \
    run guard_decision "alice" "" "please add a dark mode"
  assert_output "0"
}

@test "mono-user: boucle's own comment is discarded by the marker" {
  body="$(stamp_agent_marker 'reviewer verdict: FAIL')"
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME=alice \
    run guard_decision "alice" "" "$body"
  assert_output "1"
}

@test "bot mode: boucle's own comment is discarded by the marker too" {
  # Defense-in-depth: the marker must fire even when the actor guard would
  # have caught it anyway, because webhook reordering can defeat the actor
  # path (the note lands on the new state after the label change).
  unset BOUCLE_MONO_USER
  body="$(stamp_agent_marker 'triage: spec ready for review')"
  run guard_decision "alice" "" "$body"
  assert_output "1"
}

@test "mono-user: a marked comment on a paused state is still discarded" {
  # The spec-review race: triage posts the spec, the label webhook
  # overtakes it, and the comment lands on boucle:spec-review. Routing it
  # would start the worker BEFORE the human approved.
  body="$(stamp_agent_marker 'Spec\n\n## Acceptance criteria')"
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME=alice \
    run guard_decision "alice" "" "$body"
  assert_output "1"
}

# ── Guard shape: the reconstruction above must match the real source ───
# These pin the conditions so guard_decision cannot drift from dispatch.sh
# without a test failing.

@test "dispatch gates the actor check on mono-user" {
  run grep -A2 'if ! boucle_mono_user; then' lib/boucle-ci/dispatch.sh
  assert_success
  assert_output --partial 'BOUCLE_BOT_USERNAME'
}

@test "dispatch checks the agent marker before the actor check" {
  marker_line=$(grep -n 'has_agent_marker "\$NOTE_BODY"' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  actor_line=$(grep -n 'if ! boucle_mono_user; then' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  [ -n "$marker_line" ]
  [ -n "$actor_line" ]
  [ "$marker_line" -lt "$actor_line" ]
}

@test "dispatch preserves the MR merge exception" {
  run grep -q 'MR_ACTION" != "merge"' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "the inline .gitlab-ci.yml copy carries the same guard" {
  # The routing exists in two copies until they converge (#8, open Q5).
  # If one gains the guard and the other does not, mono-user silently
  # breaks on that path.
  run grep -q 'has_agent_marker "\$NOTE_BODY"' .gitlab-ci.yml
  assert_success
  run grep -q 'if ! boucle_mono_user; then' .gitlab-ci.yml
  assert_success
  run grep -q 'MR_ACTION" != "merge"' .gitlab-ci.yml
  assert_success
}

# ── Marker plumbing: every posting path stamps ────────────────────────

@test "every note-posting forge function stamps the agent marker" {
  for backend in bin/forge/gitlab.sh bin/forge/github.sh; do
    for fn in forge_issue_note forge_issue_note_update forge_mr_note forge_mr_note_update; do
      body=$(sed -n "/^$fn() {/,/^}/p" "$backend")
      echo "$body" | grep -q 'stamp_agent_marker' \
        || {
          echo "$backend: $fn does not stamp the agent marker"
          return 1
        }
    done
  done
}

@test "the GitHub workflow no longer subscribes to comment edits" {
  # boucle rewrites its own comments (triage, collapse-duplicate-notes),
  # and each edit used to fire a dispatch run with nothing to do.
  run grep -A1 'issue_comment:' .github/workflows/boucle.yml
  assert_success
  refute_output --partial 'edited'
}

@test "the GitHub workflow passes a payload PATH, not the payload itself" {
  # toJSON(github.event) made jq treat the whole JSON as a filename and
  # abort dispatch on every GitHub webhook.
  run grep 'BOUCLE_TRIGGER_PAYLOAD:' .github/workflows/boucle.yml
  assert_success
  assert_output --partial 'github.event_path'
  refute_output --partial 'toJSON'
}

# ── Escalation note contract (lesson #59) ────────────────────────────────
# A terminal transition (boucle:human / boucle:done) without its explanation
# note is a silent failure: the human sees a state, no message. The note
# helpers MUST fail loud (real exit code, stderr WARN) and every escalation
# site MUST post the note BEFORE the label and abort if the POST fails.

@test "forge_issue_note returns the real POST exit code, not 0" {
  # Contract (bin/forge/common.sh): "Returns 0 on success." The GitLab
  # helper used to swallow failures with `|| true` — the label flipped to
  # boucle:human while the explanation note was silently dropped (observed
  # on a consumer work item, 2026-08). gitlab.sh must propagate the rc.
  run sed -n "/^forge_issue_note() {/,/^}/p" bin/forge/gitlab.sh
  assert_success
  assert_output --partial 'rc=$?'
  refute_output --partial '|| true'
  # Same for the MR variant.
  run sed -n "/^forge_mr_note() {/,/^}/p" bin/forge/gitlab.sh
  assert_success
  refute_output --partial '|| true'
  # GitHub backend: the silent wrapper must no longer swallow failures.
  run sed -n "/^_gh_api_silent() {/,/^}/p" bin/forge/github.sh
  assert_success
  assert_output --partial 'rc=$?'
  refute_output --partial '|| true'
}

@test "escalation sites post the note BEFORE the terminal label, in both copies" {
  # Worker + reviewer + merger + e2e + catchup + triage + dispatch.
  # Pattern: `if ! forge_issue_note ...; then FAIL; exit 1; fi`
  # BEFORE `set_boucle_label ... boucle:human`. A label-then-swallowed-note
  # ordering is the exact bug from lesson #59.
  local files=(
    lib/boucle-ci/worker.sh
    lib/boucle-ci/reviewer.sh
    lib/boucle-ci/merger.sh
    lib/boucle-ci/e2e.sh
    lib/boucle-ci/catchup.sh
    lib/boucle-ci/dispatch.sh
    lib/boucle-ci/triage.sh
    lib/boucle.sh
  )
  local f line
  for f in "${files[@]}"; do
    # Every set_boucle_label ... boucle:human must be preceded (within the
    # same block) by a checked forge_issue_note. Extract each label site and
    # look backwards for `if ! forge_issue_note` before it.
    while read -r line; do
      ln=${line%%:*}
      # Look at the 12 lines before the label write for a checked note.
      prev=$(sed -n "$((ln - 12)),$((ln - 1))p" "$f")
      if ! echo "$prev" | grep -q 'if ! forge_issue_note'; then
        # Legitimate exceptions: labels already terminal-skip elsewhere, or
        # the label is part of the doc-comment list. Allow explicit markers.
        if echo "$prev" | grep -q 'retry instead of muting'; then
          continue
        fi
        echo "$f:$ln: set_boucle_label boucle:human WITHOUT a checked forge_issue_note in the preceding 12 lines"
        return 1
      fi
    done < <(grep -n '"boucle:human" "boucle::status::human"' "$f")
  done
  # The inline .gitlab-ci.yml copy must follow the same ordering.
  while read -r line; do
    ln=${line%%:*}
    prev=$(sed -n "$((ln - 12)),$((ln - 1))p" .gitlab-ci.yml)
    if ! echo "$prev" | grep -q 'if ! forge_issue_note'; then
      echo ".gitlab-ci.yml:$ln: set_boucle_label boucle:human WITHOUT a checked forge_issue_note in the preceding 12 lines"
      return 1
    fi
  done < <(grep -n '"boucle:human" "boucle::status::human"' .gitlab-ci.yml)
}

# ── check_sibling_gate: a priori serialization between siblings ───────
# Two sub-issues of the SAME parent run serially (one active at a time).
# This prevents the most frequent class of merge conflicts: siblings of
# the same domain diverging on the same components (consumer 2026-08:
# #69/#71 diverged on RightToResistBlock.astro, merger escalated).
#
# check_sibling_gate is defined INSIDE boucle_ci_dispatch() (nested), so
# sourcing dispatch.sh does not expose it. Extract the nested function
# with an awk brace-counter (mirrors extract_func_body in jc.bats).

extract_sibling_gate() {
  awk '
    BEGIN { p = 0; depth = 0 }
    /^  check_sibling_gate\(\) \{/ { p = 1; depth = 1; print; next }
    p == 1 {
      n = gsub(/\{/, "{"); depth += n
      n = gsub(/\}/, "}"); depth -= n
      print
      if (depth == 0) { p = 0 }
    }
  ' lib/boucle-ci/dispatch.sh
}

@test "check_sibling_gate blocks when a sibling is active" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    # Mock: this issue (#71) has parent #61 with an active child #69 (opened, working)
    forge_issue_get() { echo "{\"description\":\"## Parent issue\\n#61\",\"labels\":[\"boucle:todo\"]}"; }
    get_work_item_children() { echo "[{\"iid\":69,\"state\":\"opened\"}]"; }
    forge_issue_labels_get() { echo "boucle:working,boucle::status::bot"; }
    set_boucle_label() { echo "label:$*"; }
    forge_issue_note() { echo "note:$1"; }
    '"$(extract_sibling_gate)"'
    check_sibling_gate 71
  '
  # return 1 = blocked (caller must NOT trigger the worker) — expected failure.
  assert_failure
  assert_output --partial "boucle:blocked"
  assert_output --partial "sibling #69 is active"
}

@test "check_sibling_gate passes when no sibling is active" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { echo "{\"description\":\"## Parent issue\\n#61\",\"labels\":[\"boucle:todo\"]}"; }
    get_work_item_children() { echo "[]"; }
    forge_issue_labels_get() { echo ""; }
    set_boucle_label() { echo "label:$*"; }
    forge_issue_note() { echo "note:$1"; }
    '"$(extract_sibling_gate)"'
    check_sibling_gate 71
  '
  assert_success
  assert_output ""
}

@test "check_sibling_gate passes for a non-sub-issue (no parent)" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    forge_issue_get() { echo "{\"description\":\"Standalone issue\",\"labels\":[\"boucle:todo\"]}"; }
    get_work_item_children() { echo "[]"; }
    '"$(extract_sibling_gate)"'
    check_sibling_gate 42
  '
  assert_success
  assert_output ""
}
