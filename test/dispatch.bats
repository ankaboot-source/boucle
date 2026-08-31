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

# ── dispatch_is_github_pr_comment: PR-comment routing discriminator ────

@test "dispatch_is_github_pr_comment is true for a PR comment" {
  echo '{"issue":{"number":8,"pull_request":{}}}' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_is_github_pr_comment
  assert_success
}

@test "dispatch_is_github_pr_comment is false for a plain-issue comment" {
  echo '{"issue":{"number":2}}' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_is_github_pr_comment
  assert_failure
}

@test "dispatch_is_github_pr_comment is false when the payload is unset" {
  BOUCLE_TRIGGER_PAYLOAD="" run dispatch_is_github_pr_comment
  assert_failure
}

@test "dispatch_is_github_pr_comment is false when the payload is not a file" {
  BOUCLE_TRIGGER_PAYLOAD='{"issue":{"pull_request":{}}}' run dispatch_is_github_pr_comment
  assert_failure
}

@test "dispatch_is_github_pr_comment is false for a malformed payload" {
  echo 'not json at all' > "$PAYLOAD"
  BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD" run dispatch_is_github_pr_comment
  assert_failure
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
    if [ "$actor" = "${BOUCLE_BOT_USERNAME:-}" ] && [ "$mr_action" != "merge" ]; then
      skipped=1
    fi
  fi
  echo "$skipped"
}

@test "bot mode: a bot-authored event is discarded" {
  unset BOUCLE_MONO_USER
  BOUCLE_BOT_USERNAME=up-bot run guard_decision "up-bot" "update" ""
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

# ── dispatch_human_actor: mono-user-aware human detection ─────────────
# The per-block actor checks (spec-review, needs-info, human routing)
# must not use a bare ACTOR != BOT_USERNAME test — in mono-user mode
# the human IS the bot account, so that test discards every human
# approval/reply and strands the issue at spec-review / needs-info /
# human forever (issue #35). The marker check at the top already
# filters boucle's own notes; dispatch_human_actor defers to it in
# mono-user mode.

@test "dispatch_human_actor is defined" {
  run grep -q '^dispatch_human_actor()' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "dispatch_human_actor: mono-user human routes (the #35 bug)" {
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME=alice \
    run dispatch_human_actor "alice"
  assert_success
}

@test "dispatch_human_actor: bot mode bot actor is filtered" {
  unset BOUCLE_MONO_USER
  BOUCLE_BOT_USERNAME=boucle-bot run dispatch_human_actor "boucle-bot"
  assert_failure
}

@test "dispatch_human_actor: bot mode human actor routes" {
  unset BOUCLE_MONO_USER
  BOUCLE_BOT_USERNAME=boucle-bot run dispatch_human_actor "alice"
  assert_success
}

@test "dispatch_human_actor: mono-user with empty BOUCLE_BOT_USERNAME routes" {
  # No consumer-specific default — if unset, it's unset.
  BOUCLE_MONO_USER=true BOUCLE_BOT_USERNAME="" \
    run dispatch_human_actor "alice"
  assert_success
}

@test "spec-review / needs-info / human routing use dispatch_human_actor" {
  # A bare [ "$ACTOR" != ... ] on these paths is the bug that stranded #35.
  # At least 3 call sites (needs-info, spec-review, human).
  count=$(grep -c 'dispatch_human_actor' lib/boucle-ci/dispatch.sh)
  [ "$count" -ge 3 ]
}

# ── Spec-gate approval contract (A2, lesson #83 + #89): three approval signals ─
# A human reply on a boucle:spec-review issue is an amendment UNLESS its first
# line is the magic word `approved` (case-insensitive, standalone). The magic
# word, the `boucle:approved` label, and an emoji reaction all approve the
# spec and trigger the worker. Any other reply re-triggers triage. See
# LESSONS.yml #83, #89.

extract_spec_review_block() {
  awk '
    /^  elif echo "\$LABELS" \| grep -q "boucle:spec-review"; then$/ { p = 1 }
    p == 1 { print }
    p == 1 && /^  elif echo "\$LABELS" \| grep -q "boucle:human"/ { exit }
    p == 1 && /^  else$/ { exit }
  ' lib/boucle-ci/dispatch.sh
}

@test "spec-review: a human EMOJI reaction approves and triggers the worker" {
  block=$(extract_spec_review_block)
  emoji_branch=$(echo "$block" | awk '/OBJECT_KIND" = "emoji"/{f=1} f&&/^[[:space:]]+fi$/{print; f=0} f')
  echo "$emoji_branch" | grep -q 'SHOULD_WORK=true'
}

@test "spec-review: the boucle:approved LABEL approves and triggers the worker" {
  block=$(extract_spec_review_block)
  label_branch=$(echo "$block" | awk '/OBJECT_KIND" = "issue" .* "labeled"/{f=1} f&&/^[[:space:]]+fi$/{print; f=0} f')
  echo "$label_branch" | grep -q 'boucle:approved'
  echo "$label_branch" | grep -q 'SHOULD_WORK=true'
}

@test "spec-review: the magic word Approved (case-insensitive) approves" {
  block=$(extract_spec_review_block)
  note_branch=$(echo "$block" | awk '/OBJECT_KIND" = "note"/{f=1} f&&/^[[:space:]]+fi$/{print; f=0} f')
  echo "$note_branch" | grep -q "tr .\[:upper:\]."
  echo "$note_branch" | grep -q "grep -qx"
  echo "$note_branch" | grep -q 'approved'
  echo "$note_branch" | grep -q 'SHOULD_WORK=true'
  echo "$note_branch" | grep -q 'SHOULD_TRIAGE=true'
}

@test "spec-review: a non-magic-word reply re-triggers triage (amendment)" {
  block=$(extract_spec_review_block)
  note_branch=$(echo "$block" | awk '/OBJECT_KIND" = "note"/{f=1} f&&/^[[:space:]]+fi$/{print; f=0} f')
  echo "$note_branch" | grep -q 'SHOULD_TRIAGE=true'
}

# ── Merge-gate approval contract (lesson #85 + #89): magic word on PR ──────
# A human comment on a PR whose issue is at boucle:approval is feedback
# (re-trigger worker) UNLESS its first line is the magic word `approved`
# (case-insensitive, standalone) — then it triggers the MERGER, not the
# worker. This mirrors the spec gate and rides on issue_comment: created
# (GitHub, where reaction webhooks do not fire). See LESSONS.yml #85, #89.

@test "merge-gate: PR comment 'approved' at boucle:approval triggers the merger" {
  # The MR-note dispatch path must check for boucle:approval + magic word
  # BEFORE the worker-feedback path. Extract the MR-note block and verify
  # it routes to the merger when the magic word is detected.
  block=$(awk '
    /MR_NOTE_IID.*OBJECT_KIND.*note/ { p = 1 }
    p == 1 { print }
    p == 1 && /^    IID=/ { exit }
  ' lib/boucle-ci/dispatch.sh)
  echo "$block" | grep -q 'boucle:approval'
  echo "$block" | grep -q 'approved'
  echo "$block" | grep -q 'forge_trigger_role.*merger'
}

@test "merge-gate: PR comment 'approved' transitions to boucle:merging" {
  block=$(awk '
    /MR_NOTE_IID.*OBJECT_KIND.*note/ { p = 1 }
    p == 1 { print }
    p == 1 && /^    IID=/ { exit }
  ' lib/boucle-ci/dispatch.sh)
  echo "$block" | grep -q 'boucle:merging'
}

@test "spec-review block documents the amendment-vs-approval contract" {
  block=$(extract_spec_review_block)
  echo "$block" | grep -qi 'amendment\|NOT an approval\|not.*approval'
}

@test "triage validation message lists all approval signals (forge-aware)" {
  # GitHub: magic word `approved` is the primary (reactions have no webhook).
  # GitLab: emoji reaction is the primary (emoji webhooks fire reliably).
  # Both: the `boucle:approved` label. The message is forge-aware — the
  # GitHub branch leads with "Reply with approved", the GitLab branch leads
  # with "React with". Both branches mention the label and the amendment path.
  run grep -E "React with .* to approve" lib/boucle-ci/triage.sh
  assert_success
  run grep -E "Reply with .approved." lib/boucle-ci/triage.sh
  assert_success
  run grep -E "to approve the spec" lib/boucle-ci/triage.sh
  assert_success
  run grep -E "boucle:approved.*label.*to approve" lib/boucle-ci/triage.sh
  assert_success
  run grep -Ei "reply.*amend|re-?trigger.*triage|A reply never approves|triage will re-run|never approves" lib/boucle-ci/triage.sh
  assert_success
}

@test "dispatch.sh has no up-bot default (consumer-specific name)" {
  run grep -n 'up-bot' lib/boucle-ci/dispatch.sh
  assert_failure
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

@test "the GitHub workflow runs comment dispatches in their own concurrency lane" {
  # Amend-in-flight (issue #2, boucle.dev #91): a human comment during a
  # worker run fires an issue_comment dispatch that must re-trigger the
  # worker. GitHub Actions de-duplicates QUEUED runs inside one
  # concurrency group even with cancel-in-progress: false — so if the
  # comment dispatch shares a group with the issues:labeled webhook of
  # the worker's OWN terminal transition, the still-queued comment
  # dispatch is cancelled and the amendment never reaches a worker.
  run grep 'boucle-dispatch-note-' .github/workflows/boucle.yml
  assert_success
  # The note lane is keyed on the comment events...
  assert_output --partial "github.event_name == 'issue_comment'"
  assert_output --partial "github.event_name == 'pull_request_review_comment'"
  # ...and sits on the same workflow-level group line as the other two
  # lanes (workflow_dispatch → boucle-issue-, other webhooks →
  # boucle-dispatch-), i.e. it is a third branch, not a rename.
  assert_output --partial "github.event_name == 'workflow_dispatch'"
  assert_output --partial 'boucle-issue-{0}'
  assert_output --partial 'boucle-dispatch-{0}'
}

@test "the GitHub workflow: the note lane is checked BEFORE the generic dispatch lane" {
  # GitHub expressions short-circuit: if the generic boucle-dispatch-{0}
  # branch came first, issue_comment events would never reach the note
  # lane and the race would return.
  run awk '
    /boucle-dispatch-note-\{0\}/ {
      note = index($0, "boucle-dispatch-note-{0}")
      # \047 = single quote: match the generic lane as a quoted format
      # argument so it cannot match inside boucle-dispatch-note-{0}.
      generic = index($0, "\047boucle-dispatch-{0}\047")
      ok = (note > 0 && generic > note)
      found = 1
    }
    END { exit !(found && ok) }
  ' .github/workflows/boucle.yml
  assert_success
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
# check_sibling_gate is defined in lib/boucle-ci/gates.sh (converged from
# the inline/nested def in dispatch.sh — the 2026-08 gate refactor). Extract
# it with an awk brace-counter (mirrors extract_func_body in jc.bats).

extract_sibling_gate() {
  awk '
    BEGIN { p = 0; depth = 0 }
    /^check_sibling_gate\(\) \{/ { p = 1; depth = 1; print; next }
    p == 1 {
      n = gsub(/\{/, "{"); depth += n
      n = gsub(/\}/, "}"); depth -= n
      print
      if (depth == 0) { p = 0 }
    }
  ' lib/boucle-ci/gates.sh
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

# ── check_allow_list_gate: allow-list safety net ───────────────────────
# Only issues whose resolved human reporter is in BOUCLE_ALLOWED_USERS are
# accepted. Fail-open when the variable is unset. On rejection an
# explanatory note is posted and the gate returns 1 (caller must NOT
# trigger any role).

@test "check_allow_list_gate fails open when BOUCLE_ALLOWED_USERS is unset" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    unset BOUCLE_ALLOWED_USERS
    resolve_reporter_username() { echo "alice"; }
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    check_allow_list_gate 42
  '
  assert_success
  refute_output --partial "note:"
}

@test "check_allow_list_gate fails open when BOUCLE_ALLOWED_USERS is empty" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS=""
    resolve_reporter_username() { echo "alice"; }
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    check_allow_list_gate 42
  '
  assert_success
  refute_output --partial "note:"
}

@test "check_allow_list_gate allows a listed author" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS="alice,bob"
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    resolve_reporter_username() { echo "alice"; }
    check_allow_list_gate 42
  '
  assert_success
  assert_output --partial "is allowed"
  refute_output --partial "note:"
}

@test "check_allow_list_gate rejects an unlisted author and posts the note" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS="alice,bob"
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    resolve_reporter_username() { echo "mallory"; }
    check_allow_list_gate 42
  '
  assert_failure
  assert_output --partial "NOT in BOUCLE_ALLOWED_USERS"
  assert_output --partial "note:42|"
  assert_output --partial "boucle:allow-list"
}

@test "check_allow_list_gate matches case-insensitively" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS="Alice,Bob"
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    resolve_reporter_username() { echo "alice"; }
    check_allow_list_gate 42
  '
  assert_success
  assert_output --partial "is allowed"
  refute_output --partial "note:"
}

@test "check_allow_list_gate trims whitespace around usernames" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS=" alice , bob "
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    resolve_reporter_username() { echo "bob"; }
    check_allow_list_gate 42
  '
  assert_success
  assert_output --partial "is allowed"
  refute_output --partial "note:"
}

@test "check_allow_list_gate fails open when the reporter cannot be resolved" {
  run bash -c '
    BOUCLE_FORGE_HOST=github.com BOUCLE_PROJECT_ID=1
    BOUCLE_ALLOWED_USERS="alice,bob"
    forge_issue_note() { echo "note:$1|$2"; }
    source lib/boucle.sh
    source lib/boucle-ci/dispatch.sh
    resolve_reporter_username() { echo ""; }
    check_allow_list_gate 42
  '
  assert_success
  assert_output --partial "failing OPEN"
  refute_output --partial "note:"
}

@test "lib defines check_allow_list_gate" {
  # The gate lives in lib/boucle.sh (not lib/boucle-ci/dispatch.sh) so it
  # is available to BOTH the extracted lib path (bin/boucle-ci) AND the
  # inline .gitlab-ci.yml jobs (which source only lib/boucle.sh).
  run grep -E '^check_allow_list_gate\(\)' lib/boucle.sh
  assert_success
}

# ── GitHub → GitLab MR action vocabulary ──────────────────────────────
# The router's case arms speak GitLab (open/update/close/reopen/approved/
# unapproved/merge). GitHub sends its own words, and passing them through
# untranslated matched no arm — every PR webhook fell through to skip.

gh_payload() {
  echo "$1" > "$PAYLOAD"
  export BOUCLE_TRIGGER_PAYLOAD="$PAYLOAD"
}

@test "github: synchronize maps to the GitLab update action" {
  # The event behind "push to boucle/<iid> → re-review" (SKILL.md §4.4).
  gh_payload '{"action":"synchronize","pull_request":{"number":7}}'
  run dispatch_github_mr_action pull_request
  assert_output "update"
}

@test "github: a merged PR maps to merge, not close" {
  # GitHub reports a merge as a close; only .pull_request.merged separates
  # them, and the difference decides catchup vs worker re-run.
  gh_payload '{"action":"closed","pull_request":{"number":7,"merged":true}}'
  run dispatch_github_mr_action pull_request
  assert_output "merge"
}

@test "github: a closed-unmerged PR maps to close" {
  gh_payload '{"action":"closed","pull_request":{"number":7,"merged":false}}'
  run dispatch_github_mr_action pull_request
  assert_output "close"
}

@test "github: opened and reopened map to the GitLab words" {
  gh_payload '{"action":"opened","pull_request":{"number":7}}'
  run dispatch_github_mr_action pull_request
  assert_output "open"
  gh_payload '{"action":"reopened","pull_request":{"number":7}}'
  run dispatch_github_mr_action pull_request
  assert_output "reopen"
}

@test "github: an approving review maps to approved" {
  gh_payload '{"action":"submitted","review":{"state":"approved"}}'
  run dispatch_github_mr_action pull_request_review
  assert_output "approved"
}

@test "github: a dismissed review maps to unapproved" {
  gh_payload '{"action":"dismissed","review":{"state":"dismissed"}}'
  run dispatch_github_mr_action pull_request_review
  assert_output "unapproved"
}

@test "github: a non-approving review stays on the note path" {
  # Review feedback must keep re-triggering the worker, so these map to
  # empty and the caller leaves OBJECT_KIND=note.
  gh_payload '{"action":"submitted","review":{"state":"changes_requested"}}'
  run dispatch_github_mr_action pull_request_review
  assert_output ""
  gh_payload '{"action":"submitted","review":{"state":"commented"}}'
  run dispatch_github_mr_action pull_request_review
  assert_output ""
}

@test "github: actions with no arm map to empty" {
  for act in ready_for_review review_requested edited; do
    gh_payload "{\"action\":\"$act\",\"pull_request\":{\"number\":7}}"
    run dispatch_github_mr_action pull_request
    assert_output ""
  done
}

@test "github: a GitLab payload is untouched by the translator" {
  # The translator only speaks for GitHub events; a GitLab MR webhook must
  # not be rewritten by it.
  gh_payload '{"object_kind":"merge_request","object_attributes":{"action":"merge"}}'
  run dispatch_github_mr_action merge_request
  assert_output ""
}

@test "dispatch_github_mr_action is silent on a missing payload" {
  BOUCLE_TRIGGER_PAYLOAD="$BATS_TEST_TMPDIR/nope.json" run dispatch_github_mr_action pull_request
  assert_success
  assert_output ""
}

# ── MR payload shape: both forges ─────────────────────────────────────

@test "the MR handler reads the branch and IID from both forge shapes" {
  # Reading only .object_attributes left every GitHub PR webhook with an
  # empty source branch, so it exited as "not a boucle branch".
  run grep -q 'object_attributes.source_branch // .pull_request.head.ref' lib/boucle-ci/dispatch.sh
  assert_success
  run grep -q 'object_attributes.iid // .pull_request.number' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "the GitHub workflow subscribes to PR synchronize" {
  # Without it, pushes to a PR run no CI: the check stays pinned to the SHA
  # the PR opened with.
  run grep -qE '^\s+types:.*synchronize' .github/workflows/boucle.yml
  assert_success
}

# ── Amend-in-flight (issue #2): human comment on boucle:working ──────────
# A human comment on an issue at boucle:working is a mid-implementation
# course correction. The dispatch must re-trigger the worker (secondary
# worker with the comment injected via BOUCLE_ISSUE_NOTES), not no-op.
# The worker's terminal transition to boucle:review is guarded against
# clobbering the boucle:todo this branch sets — see the terminal-transition
# guard tests below.

extract_working_amend_block() {
  awk '
    /^  elif echo "\$LABELS" \| grep -q "boucle:working"; then$/ { p = 1 }
    p == 1 { print }
    p == 1 && /^  elif \[ "\$ACTION" = "open" \] \|\| \[ "\$ACTION" = "opened" \]; then$/ { exit }
  ' lib/boucle-ci/dispatch.sh
}

@test "amend-in-flight: a human note on boucle:working sets SHOULD_WORK=true" {
  block=$(extract_working_amend_block)
  [ -n "$block" ] || { echo "boucle:working amend block not found"; false; }
  echo "$block" | grep -q 'OBJECT_KIND" = "note"'
  echo "$block" | grep -q 'dispatch_human_actor'
  echo "$block" | grep -q 'SHOULD_WORK=true'
}

@test "amend-in-flight: the branch is gated on dispatch_human_actor (mono-user-safe)" {
  block=$(extract_working_amend_block)
  # The human-actor guard must wrap the note path, same as boucle:human.
  echo "$block" | grep -q 'dispatch_human_actor'
  # Non-note events (emoji, issue updates) must NOT trigger the amend —
  # the note path is gated on OBJECT_KIND == "note" AND dispatch_human_actor.
  echo "$block" | grep -q 'OBJECT_KIND" = "note"'
  echo "$block" | grep -q 'dispatch_human_actor; then'
}

@test "amend-in-flight: the branch sits between boucle:human and the open-issue fallthrough" {
  # Ordering matters: boucle:working must be checked AFTER boucle:human
  # (an issue flipped to human by the worker's own escalation takes
  # precedence) and BEFORE the open-event fallthrough (#124: unlabeled
  # routes only on an explicit open/opened action).
  run awk '
    /elif echo "\$LABELS" \| grep -q "boucle:human"; then/ { human = NR }
    /elif echo "\$LABELS" \| grep -q "boucle:working"; then/ { working = NR }
    /elif \[ "\$ACTION" = "open" \] \|\| \[ "\$ACTION" = "opened" \]; then/ { open = NR }
    END { exit !(human > 0 && working > human && open > working) }
  ' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "amend-in-flight: the block documents the secondary-worker pattern + concurrency" {
  block=$(extract_working_amend_block)
  # The comment must explain the reuse of the MR-note secondary-worker pattern.
  echo "$block" | grep -qi 'secondary.worker\|secondary-worker'
  # The comment must reference resource_group serialization.
  echo "$block" | grep -qi 'resource_group'
  # The comment must reference the terminal-transition guard in worker.sh.
  echo "$block" | grep -qi 'terminal.transition\|terminal-transition guard'
}

# ── Worker terminal-transition guard (issue #2): don't clobber a queued amend ─
# If a human commented during the worker run, dispatch set boucle:todo to
# queue an amend-worker. The in-flight worker's terminal set_boucle_label
# boucle:review would clobber that boucle:todo. The guard detects the amend
# and skips the review transition + reviewer chain.

@test "worker: terminal-transition guard checks for boucle:todo before setting boucle:review" {
  # The guard must read the current labels and check for boucle:todo BEFORE
  # the set_boucle_label boucle:review call.
  run grep -n 'boucle:todo' lib/boucle-ci/worker.sh
  assert_success
  # The guard must be in the terminal section (after the push, near the
  # set_boucle_label boucle:review line).
  guard_line=$(grep -n 'terminal_labels' lib/boucle-ci/worker.sh | head -1 | cut -d: -f1)
  review_line=$(grep -n 'set_boucle_label.*boucle:review' lib/boucle-ci/worker.sh | head -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$review_line" ] && [ "$guard_line" -lt "$review_line" ] \
    || { echo "guard (line $guard_line) must precede boucle:review (line $review_line)"; false; }
}

@test "worker: the guard skips boucle:review AND the reviewer chain when an amend is queued" {
  # Extract the guard block and verify it returns 0 (skipping the rest)
  # when boucle:todo is detected, without calling set_boucle_label boucle:review
  # or chain_to_role reviewer. The awk exits BEFORE the set_boucle_label
  # boucle:review line (the guard's return 0 precedes it).
  guard_block=$(awk '
    /Amend-in-flight guard/ { p = 1 }
    p == 1 && /set_boucle_label "\$BOUCLE_ISSUE" "boucle:review"/ { exit }
    p == 1 { print }
  ' lib/boucle-ci/worker.sh)
  [ -n "$guard_block" ] || { echo "guard block not found"; false; }
  echo "$guard_block" | grep -q 'boucle:todo'
  echo "$guard_block" | grep -q 'return 0'
  # The guard must NOT itself call set_boucle_label boucle:review.
  ! echo "$guard_block" | grep -q 'set_boucle_label.*boucle:review'
}

@test "worker: the guard records a health outcome for the amended-in-flight run" {
  # The guard must call boucle_health_outcome so the run is classified
  # (not silently dropped from the health record).
  guard_block=$(awk '
    /Amend-in-flight guard/ { p = 1 }
    p == 1 && /set_boucle_label "\$BOUCLE_ISSUE" "boucle:review"/ { exit }
    p == 1 { print }
  ' lib/boucle-ci/worker.sh)
  echo "$guard_block" | grep -q 'boucle_health_outcome'
  echo "$guard_block" | grep -q 'amended-in-flight'
}

# ── Direct amend recheck (boucle.dev #91): the worker's own safety net ──
# The label guard above only fires when the amend-in-flight dispatch
# ALREADY ran and set boucle:todo. On GitHub Actions that dispatch can be
# cancelled before it runs: queued workflow runs are de-duplicated inside
# one concurrency group, and the issues:labeled webhook of the worker's
# own terminal transition enters the same group. Defense-in-depth: the
# worker snapshots the highest note id at job start (BOUCLE_MAX_NOTE_ID)
# and rechecks the issue notes before transitioning — if a NON-boucle
# note arrived during the run, skip boucle:review and re-trigger itself
# as an amend-worker.

extract_recheck_block() {
  awk '
    /Direct amend recheck \(defense-in-depth\)/ { p = 1 }
    p == 1 && /set_boucle_label "\$BOUCLE_ISSUE" "boucle:review"/ { exit }
    p == 1 { print }
  ' lib/boucle-ci/worker.sh
}

@test "worker: the note snapshot and the prompt injection share ONE fetch" {
  # Two separate forge_issue_notes calls would open a window where a
  # human comment lands in one snapshot but not the other.
  run awk '
    /notes_json=\$\(forge_issue_notes "\$BOUCLE_ISSUE"/ { fetch++ }
    /BOUCLE_ISSUE_NOTES=\$\(echo "\$notes_json"/ { notes = 1 }
    /BOUCLE_MAX_NOTE_ID=\$\(echo "\$notes_json"/ { max = 1 }
    END { exit !(fetch == 1 && notes == 1 && max == 1) }
  ' lib/boucle-ci/worker.sh
  assert_success
  run grep -q 'export BOUCLE_MAX_NOTE_ID' lib/boucle-ci/worker.sh
  assert_success
}

@test "worker: the recheck filters on note id > snapshot AND the boucle:agent marker" {
  block=$(extract_recheck_block)
  [ -n "$block" ] || { echo "recheck block not found"; false; }
  echo "$block" | grep -q 'BOUCLE_MAX_NOTE_ID'
  echo "$block" | grep -q '> \$max'
  # boucle's own notes (state, verdicts — all carry the agent marker)
  # must NOT count as amendments, or every run would amend itself.
  echo "$block" | grep -q 'boucle:agent'
  echo "$block" | grep -q '| not'
}

@test "worker: the recheck jq filter counts only new human notes (functional)" {
  # Extract the jq program straight from worker.sh and run it on a
  # fixture: one old human note, one NEW boucle note (agent marker), one
  # NEW human note, one system note. Only the new human note counts.
  filter=$(grep -- '--argjson max' lib/boucle-ci/worker.sh \
    | sed "s/.*BOUCLE_MAX_NOTE_ID\" '//; s/' 2>.*//")
  [ -n "$filter" ] || { echo "recheck jq program not found"; false; }
  fixture='[
    {"id":4,"system":false,"body":"new human amend: wrong SVG, use card-7"},
    {"id":3,"system":false,"body":"boucle state note <!-- boucle:agent -->"},
    {"id":2,"system":false,"body":"old human note"},
    {"id":5,"system":true,"body":"system event"}
  ]'
  run bash -c "printf '%s' '$fixture' | jq -r --argjson max 2 '$filter'"
  assert_success
  assert_output "1"
}

@test "worker: the recheck skips boucle:review and re-triggers the worker as amend" {
  block=$(extract_recheck_block)
  [ -n "$block" ] || { echo "recheck block not found"; false; }
  echo "$block" | grep -q 'set_boucle_label "$BOUCLE_ISSUE" "boucle:todo"'
  echo "$block" | grep -q 'chain_to_role "$BOUCLE_ISSUE" "worker"'
  echo "$block" | grep -q 'BOUCLE_ITERATION=\$((ITERATION + 1))'
  echo "$block" | grep -q 'return 0'
  echo "$block" | grep -q 'boucle_health_outcome'
  echo "$block" | grep -q 'amended-in-flight'
  # The recheck itself must NOT perform the review transition.
  ! echo "$block" | grep -q 'set_boucle_label.*boucle:review'
}

@test "worker: the recheck fails open on a fetch or jq failure" {
  block=$(extract_recheck_block)
  [ -n "$block" ] || { echo "recheck block not found"; false; }
  # A failed refetch yields an empty string; the case-normalization maps
  # anything non-numeric to 0, so the worker proceeds to review instead
  # of looping forever (the dispatch path stays the primary mechanism).
  echo "$block" | grep -q '\*\[!0-9\]\*) new_human_notes=0'
}

@test "worker: the recheck sits AFTER the boucle:todo label guard" {
  # The dispatch path takes precedence when it got there first.
  todo_guard_line=$(grep -n 'Amend-in-flight guard' lib/boucle-ci/worker.sh | head -1 | cut -d: -f1)
  recheck_line=$(grep -n 'Direct amend recheck (defense-in-depth)' lib/boucle-ci/worker.sh | head -1 | cut -d: -f1)
  [ -n "$todo_guard_line" ] && [ -n "$recheck_line" ] && [ "$todo_guard_line" -lt "$recheck_line" ] \
    || { echo "boucle:todo guard ($todo_guard_line) must precede the recheck ($recheck_line)"; false; }
}


# ── Closed-issue guard: merge exemption (GitHub auto-close race, #79) ──

@test "dispatch: merge webhook is NOT skipped on a closed issue (GitHub auto-close race)" {
  # The closed-issue guard must exempt MR_ACTION=merge so catchup can
  # reconcile the label when GitHub auto-closes the issue before the
  # pull_request webhook arrives.
  run grep -q 'ISSUE_STATE" = "closed" \] && \[ "$MR_ACTION" != "merge"' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "dispatch: non-merge MR webhooks ARE still skipped on a closed issue" {
  # The guard still blocks open/update/close/reopen/approved/unapproved
  # on a closed issue (lesson #44 — don't run the loop on a closed issue).
  run grep -q 'ISSUE_STATE" = "closed"' lib/boucle-ci/dispatch.sh
  assert_success
}

# ── new-issue routing: an empty label list is not a failure ───────────

@test "guard shape: an empty label list no longer aborts dispatch" {
  # Regression. dispatch used to run:
  #     LABELS=$(forge_issue_labels_get "$IID")
  #     if [ -z "$LABELS" ]; then echo "ABORT ... exit non-zero"; exit 1; fi
  # A freshly opened issue has no labels, so this aborted on exactly the case
  # the routing table handles as "new issue with no boucle label → triage",
  # making that branch unreachable and leaving every new issue to the doctor's
  # orphan scan minutes later. Observed on boucle.dev#84.
  #
  # The old message also lied: forge_issue_labels_get ends in `|| true`, so it
  # never exits non-zero. Its absence is the regression anchor.
  run grep -c 'ABORT — forge_issue_labels_get failed to fetch labels' lib/boucle-ci/dispatch.sh
  assert_output "0"
}

@test "guard shape: the empty-label path probes reachability before aborting" {
  # Empty output means either "no labels" or "the fetch failed" — stdout
  # cannot tell them apart, so the abort must be gated on the issue being
  # unreachable. Scoped to the block itself: an unrelated forge_issue_get
  # call elsewhere in the file (the closed-issue guard has one) must not
  # satisfy this.
  block=$(awk '/LABELS=\$\(forge_issue_labels_get "\$IID"\)/{f=1} f{print} /labels for #\$IID: \$LABELS/{if(f)exit}' lib/boucle-ci/dispatch.sh)
  echo "$block" | grep -q 'forge_issue_get' || {
    echo "no reachability probe inside the empty-label block:"
    echo "$block"
    return 1
  }
}

@test "guard shape: the new-issue-to-triage branch is still reachable" {
  # The branch the old guard made unreachable. Since #124 the catch-all is
  # gone: an unlabeled issue routes to triage ONLY on an explicit open
  # event (GitLab action=open / GitHub action=opened). Any other event
  # (note, update, label change) on an unlabeled issue must NOT re-triage.
  run grep -q 'elif \[ "\$ACTION" = "open" \] || \[ "\$ACTION" = "opened" \]; then' lib/boucle-ci/dispatch.sh
  assert_success
}

# ── Opt-out tombstone (#124): human label removal is NOT re-appropriation ──
# Removing the boucle: labels is the explicit "leave the loop" signal.
# Without the tombstone the removal webhook re-routed the unlabeled issue
# to triage, which re-applied boucle:triage + boucle::status::bot and
# re-assigned the bot — an inescapable ping-pong while any webhook kept
# arriving. The tombstone note is idempotent (posted once, verified against
# the existing notes) and the issue is NEVER re-labeled/re-assigned by the
# unlabeled route. The doctor's unlabeled scan skips tombstones.

# ── Opt-out predicate (pure): human label-removal detection ─────────────

@test "opt-out: GitLab previous-boucle-labels + empty live labels → removed" {
  # GitLab label-change webhook: .changes.labels.previous held boucle:
  # labels, the live label list no longer has any → human opt-out.
  echo "{\"changes\":{\"labels\":{\"previous\":[\"boucle:triage\",\"boucle::status::bot\",\"help-wanted\"]}}}" > "$BATS_TEST_TMPDIR/prev.json"
  run bash -c '
    LABELS=""
    BOUCLE_TRIGGER_PAYLOAD="$1"
    if [ -n "$(jq -r ".changes.labels.previous // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_HAD_BOUCLE=$(jq -r "[.changes.labels.previous[] | select(startswith(\"boucle:\"))] | length > 0" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      if [ "$PREV_HAD_BOUCLE" = "true" ] && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    fi
  ' _ "$BATS_TEST_TMPDIR/prev.json"
  assert_output "removed"
}

@test "opt-out: GitLab previous-boucle-labels + boucle:triage still alive → NOT removed" {
  echo "{\"changes\":{\"labels\":{\"previous\":[\"boucle:triage\"]}}}" > "$BATS_TEST_TMPDIR/prev.json"
  run bash -c '
    LABELS="boucle:triage,help-wanted"
    BOUCLE_TRIGGER_PAYLOAD="$1"
    if [ -n "$(jq -r ".changes.labels.previous // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_HAD_BOUCLE=$(jq -r "[.changes.labels.previous[] | select(startswith(\"boucle:\"))] | length > 0" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      if [ "$PREV_HAD_BOUCLE" = "true" ] && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    fi
  ' _ "$BATS_TEST_TMPDIR/prev.json"
  refute_output --partial "removed"
}

@test "opt-out: GitHub unlabeled event with a boucle: label and empty live → removed" {
  echo "{\"action\":\"unlabeled\",\"label\":{\"name\":\"boucle:triage\"}}" > "$BATS_TEST_TMPDIR/gh.json"
  run bash -c '
    LABELS=""
    ACTION="unlabeled"
    BOUCLE_TRIGGER_PAYLOAD="$1"
    if [ -n "$(jq -r ".changes.labels.previous // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_HAD_BOUCLE=$(jq -r "[.changes.labels.previous[] | select(startswith(\"boucle:\"))] | length > 0" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      if [ "$PREV_HAD_BOUCLE" = "true" ] && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    elif [ "$ACTION" = "unlabeled" ]; then
      REMOVED_LABEL=$(jq -r ".label.name // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
      if echo "$REMOVED_LABEL" | grep -q "^boucle:" && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    fi
  ' _ "$BATS_TEST_TMPDIR/gh.json"
  assert_output "removed"
}

@test "opt-out: GitHub unlabeled event with boucle:triage still alive → NOT removed" {
  echo "{\"action\":\"unlabeled\",\"label\":{\"name\":\"boucle:triage\"}}" > "$BATS_TEST_TMPDIR/gh.json"
  run bash -c '
    LABELS="boucle:triage"
    ACTION="unlabeled"
    BOUCLE_TRIGGER_PAYLOAD="$1"
    if [ -n "$(jq -r ".changes.labels.previous // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_HAD_BOUCLE=$(jq -r "[.changes.labels.previous[] | select(startswith(\"boucle:\"))] | length > 0" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      if [ "$PREV_HAD_BOUCLE" = "true" ] && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    elif [ "$ACTION" = "unlabeled" ]; then
      REMOVED_LABEL=$(jq -r ".label.name // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
      if echo "$REMOVED_LABEL" | grep -q "^boucle:" && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    fi
  ' _ "$BATS_TEST_TMPDIR/gh.json"
  refute_output --partial "removed"
}

@test "opt-out: GitLab note event on an unlabeled issue without label-change trace → NOT removed" {
  # A plain note (no .changes.labels.previous, no unlabeled action) on an
  # unlabeled issue must not be classified as an opt-out — the human may
  # simply be commenting on an issue that never had boucle labels.
  echo "{\"object_kind\":\"note\",\"object_attributes\":{\"note\":\"hello\"},\"issue\":{\"iid\":7}}" > "$BATS_TEST_TMPDIR/note.json"
  run bash -c '
    LABELS=""
    ACTION=""
    BOUCLE_TRIGGER_PAYLOAD="$1"
    if [ -n "$(jq -r ".changes.labels.previous // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)" ]; then
      PREV_HAD_BOUCLE=$(jq -r "[.changes.labels.previous[] | select(startswith(\"boucle:\"))] | length > 0" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null)
      if [ "$PREV_HAD_BOUCLE" = "true" ] && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    elif [ "$ACTION" = "unlabeled" ]; then
      REMOVED_LABEL=$(jq -r ".label.name // empty" "$BOUCLE_TRIGGER_PAYLOAD" 2> /dev/null) || true
      if echo "$REMOVED_LABEL" | grep -q "^boucle:" && ! echo "$LABELS" | grep -q "boucle:"; then
        echo removed
      fi
    fi
  ' _ "$BATS_TEST_TMPDIR/note.json"
  refute_output --partial "removed"
}

# ── Opt-out routing: the dispatch branch posts the tombstone once ──────

opt_out_routing() {
  local notes="$1"
  # Replicates the dispatch opt-out branch (posting side).
  if ! printf '%s' "$notes" | grep -q 'boucle:opt-out'; then
    forge_issue_note "$IID" "tombstone"
  fi
}

@test "opt-out: the tombstone note is posted when no marker exists yet" {
  # The posting side must be gated on the marker being absent from the
  # existing notes — otherwise every label-churn webhook posts another note.
  POSTED=""
  forge_issue_note() { POSTED="$1"; }
  IID=7
  opt_out_routing '[]'
  [ "$POSTED" = "7" ]
}

@test "opt-out: the tombstone note is NOT posted when the marker already exists (idempotent)" {
  POSTED=""
  forge_issue_note() { POSTED="$1"; }
  IID=7
  opt_out_routing '[{"body":"<!-- boucle:opt-out v=1 --> sortie de boucle"}]'
  [ -z "$POSTED" ]
}

# ── Unlabeled routing contract (#124): only open/opened events triage ──

unlabeled_decision() {
  local action="$1"
  if [ "$action" = "open" ] || [ "$action" = "opened" ]; then
    echo triage
  else
    echo noop
  fi
}

@test "unlabeled: GitLab open event on an unlabeled issue routes to triage" {
  run unlabeled_decision "open"
  assert_output "triage"
}

@test "unlabeled: GitHub opened event on an unlabeled issue routes to triage" {
  run unlabeled_decision "opened"
  assert_output "triage"
}

@test "unlabeled: a note event on an unlabeled issue does NOT triage (#124)" {
  run unlabeled_decision "note"
  assert_output "noop"
}

@test "unlabeled: an update event on an unlabeled issue does NOT triage (#124)" {
  run unlabeled_decision "update"
  assert_output "noop"
}

@test "unlabeled: a label event on an unlabeled issue does NOT triage (#124)" {
  run unlabeled_decision "labeled"
  assert_output "noop"
}

@test "unlabeled: the dispatch branch never re-labels or re-assigns on opt-out" {
  # The opt-out branch must exit via dispatch_noop before any
  # set_boucle_label / chain_to_role can fire.
  block=$(awk '/Human opt-out tombstone/{p=1} p{print} p && /^  if echo "\$LABELS" \| grep -q "boucle:triage"; then$/{exit}' lib/boucle-ci/dispatch.sh)
  echo "$block" | grep -q 'BOUCLE_LABELS_REMOVED'
  echo "$block" | grep -q 'dispatch_noop'
  # No re-label / no role chain inside the tombstone branch itself.
  run grep -q 'set_boucle_label' <<< "$block"
  assert_failure
  run grep -q 'chain_to_role' <<< "$block"
  assert_failure
  run grep -q '\.boucle-issue' <<< "$block"
  assert_failure
}

@test "unlabeled: the dispatch branch is reachable on unlabeled events" {
  # The tombstone must sit BEFORE the label routing (any unlabeled event
  # reaches it) and AFTER the board check. The routing anchor is the
  # boucle:triage branch that FOLLOWS the tombstone block (an earlier
  # grep in the BOT_JUST_ASSIGNED block precedes it — use tail).
  tombstone_line=$(grep -n 'Human opt-out tombstone' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  board_line=$(grep -n 'boucle status board' lib/boucle-ci/dispatch.sh | head -1 | cut -d: -f1)
  triage_line=$(grep -n 'grep -q "boucle:triage"' lib/boucle-ci/dispatch.sh | tail -1 | cut -d: -f1)
  [ -n "$tombstone_line" ] && [ -n "$board_line" ] && [ -n "$triage_line" ]
  [ "$board_line" -lt "$tombstone_line" ] && [ "$tombstone_line" -lt "$triage_line" ]
}

@test "unlabeled: GitHub label-change payloads carry the removed label in .label.name" {
  # The GitHub `issues: unlabeled` event shape the opt-out branch reads.
  run grep -q 'unlabeled' lib/boucle-ci/dispatch.sh
  assert_success
}
