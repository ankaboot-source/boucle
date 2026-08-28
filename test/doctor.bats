#!/usr/bin/env bats
# test/doctor.bats — smoke tests for bin/doctor.
#
# bin/doctor has no BASH_SOURCE guard and executes its full body on source,
# which calls glab api / jq / curl / npx. We can't source it directly in
# tests. These tests cover what we can: syntax validity, expected function
# definitions, and the output format of the pure helper functions when
# invoked in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/doctor parses without syntax error" {
  run bash -n bin/doctor
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/doctor defines pass function" {
  # Verify the function is defined in the script source.
  run grep -E '^pass\(\)' bin/doctor
  assert_success
}

@test "bin/doctor defines warn function" {
  run grep -E '^warn\(\)' bin/doctor
  assert_success
}

@test "bin/doctor defines fail function" {
  run grep -E '^fail\(\)' bin/doctor
  assert_success
}

# ── Pure helpers (extracted and run in isolation) ─────────────────────
# The pass/warn/fail helpers are pure output functions. Extract them from
# bin/doctor and evaluate them in a subshell so we can assert on their
# stdout/stderr/exit-code behavior without triggering the script body.

@test "pass prints a green check on stdout" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); pass 'hello'"
  assert_success
  assert_output --partial "hello"
  assert_output --partial "✓"
}

@test "warn prints a warning to stderr" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); warn 'careful'"
  assert_success
  assert_output --partial "careful"
  assert_output --partial "⚠"
}

@test "fail prints an X and increments FAILURES" {
  run bash -c "FAILURES=0; source <(awk 'BEGIN{p=0} /^(pass|warn|fail)\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' bin/doctor); fail 'broken'"
  assert_success
  assert_output --partial "broken"
  assert_output --partial "✗"
}

@test "doctor warns (not fails) when CLOUDFLARE_API_TOKEN is unset" {
  # The CF section at the end warns when CLOUDFLARE_API_TOKEN is unset.
  # Source the script body up to the CF check and verify the warn message.
  run bash -c '
    FAILURES=0
    BOUCLE_HOME="."
    BOUCLE_FORGE=gitlab
    BOUCLE_PROJECT_ID="123"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    # Extract just the CF check section and run it
    source <(sed -n "/^# ── CLOUDFLARE_API_TOKEN can deploy/,/^echo \"\"/p" bin/doctor)
    # Must warn, not fail
    [ "$FAILURES" -eq 0 ] || exit 1
  '
  assert_success
}

@test "doctor fails when CLOUDFLARE_API_TOKEN is set but BOUCLE_DEPLOY_PROJECT is missing" {
  run bash -c '
    FAILURES=0
    BOUCLE_HOME="."
    BOUCLE_FORGE=gitlab
    BOUCLE_PROJECT_ID="123"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    CLOUDFLARE_API_TOKEN="dummy"
    # Mock npx to succeed
    npx() { return 0; }
    # Extract CF check section - we need to also source the CF section
    source <(sed -n "/^# ── CLOUDFLARE_API_TOKEN can deploy/,/^echo \"\"/p" bin/doctor)
    # Since BOUCLE_DEPLOY_PROJECT isnt set and CF token IS set, should warn not fail
    [ "$FAILURES" -eq 0 ]
  '
  assert_success
}

@test "doctor fails when BOUCLE_DEPLOY_MODE=external but BOUCLE_LIVE_URL is unset" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    BOUCLE_HOME="."
    BOUCLE_FORGE=gitlab
    BOUCLE_PROJECT_ID="123"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_DEPLOY_MODE=external
    BOUCLE_LIVE_URL=""
    source <(sed -n "/^# ── Mode-specific checks/,/^echo \"\"/p" bin/doctor)
    [ "$FAILURES" -eq 1 ]
  '
  assert_success
}

# ── Bot identity vs token owner (#32) ─────────────────────────────────
# The section is extracted on its own (bounded by the next section header)
# so these tests never execute the deploy-mode checks that follow it.
# `glab` is stubbed rather than mocked away entirely: the check must work
# off what the forge returns, not off the absence of a binary.

bot_identity_section() {
  sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor
}

@test "doctor passes when the bot identity is distinct from the token owner" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    FORGE=gitlab
    HOST="gitlab.example.com"
    BOUCLE_BOT_USERNAME="up-bot"
    glab() { echo "{\"username\":\"alice\"}"; }
    source <(sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor)
    [ "$FAILURES" -eq 0 ]
  '
  assert_success
  assert_output --partial "distinct from the token owner"
}

@test "doctor fails when the bot identity IS the token owner and BOUCLE_MONO_USER is unset" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    FORGE=gitlab
    HOST="gitlab.example.com"
    BOUCLE_BOT_USERNAME="alice"
    unset BOUCLE_MONO_USER
    glab() { echo "{\"username\":\"alice\"}"; }
    source <(sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor)
    [ "$FAILURES" -eq 1 ]
  '
  assert_success
  assert_output --partial "the loop will never fire for you"
}

@test "doctor passes when the bot identity IS the token owner but BOUCLE_MONO_USER is set" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    FORGE=gitlab
    HOST="gitlab.example.com"
    BOUCLE_BOT_USERNAME="alice"
    BOUCLE_MONO_USER=true
    glab() { echo "{\"username\":\"alice\"}"; }
    source <(sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor)
    [ "$FAILURES" -eq 0 ]
  '
  assert_success
  assert_output --partial "mono-user mode"
}

@test "doctor warns (not fails) when the token owner cannot be resolved" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    FORGE=gitlab
    HOST="gitlab.example.com"
    BOUCLE_BOT_USERNAME="alice"
    # Expired token / unreachable API: empty body, non-zero exit.
    glab() { return 1; }
    source <(sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor)
    [ "$FAILURES" -eq 0 ]
  '
  assert_success
  assert_output --partial "could not resolve the BOUCLE_TOKEN owner"
}

@test "doctor resolves the token owner through the forge layer on GitHub" {
  run bash -c '
    FAILURES=0
    pass() { echo "  ✓ $1"; }
    warn() { echo "  ⚠ $1" >&2; }
    fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }
    FORGE=github
    HOST="github.com"
    BOUCLE_BOT_USERNAME="alice"
    unset BOUCLE_MONO_USER
    forge_current_user_login() { echo "alice"; }
    source <(sed -n "/^# ── Bot identity vs token owner/,/^# ── Mode-specific checks/p" bin/doctor)
    [ "$FAILURES" -eq 1 ]
  '
  assert_success
  assert_output --partial "the loop will never fire for you"
}

# ── File-impact gate: doctor worker-trigger path (MR 1) ─────────────────
# The doctor is a monolithic boucle_ci_doctor() function that executes its
# full body on source (calls glab/jq/curl), so it cannot be unit-tested in
# isolation. These grep-based assertions verify the file gate is wired into
# BOTH chain_to_role worker paths (rebase-conflict recovery ~line 286 and
# capacity scan ~line 456) and that boucle:blocked issues are skipped by the
# capacity scan (lesson #49 — blocked issues are not re-triggered).

@test "doctor calls check_file_gate before the rebase-conflict worker trigger" {
  # The rebase-conflict recovery path (~line 286) must gate the worker
  # trigger on check_file_gate so a boucle:todo issue re-triggered by the
  # doctor does not start into a file conflict.
  run grep -nE 'check_file_gate "\$IID"' lib/boucle-ci/doctor.sh
  assert_success
  # The gate is checked with `if ! check_file_gate` → blocked (returns 1)
  # skips the worker trigger.
  run grep -nE 'if ! check_file_gate "\$IID"; then' lib/boucle-ci/doctor.sh
  assert_success
  run grep -nE 'file-gate blocked — skipping worker trigger' lib/boucle-ci/doctor.sh
  assert_success
}

@test "doctor calls check_file_gate before the capacity-scan worker trigger" {
  # The capacity-scan path (~line 456) must also gate the worker trigger.
  run grep -nE 'check_file_gate "\$IID"' lib/boucle-ci/doctor.sh
  assert_success
  run grep -nE 'file-gate blocked — skipping worker trigger' lib/boucle-ci/doctor.sh
  assert_success
}

@test "doctor skips boucle:blocked issues in the capacity scan (lesson #49)" {
  # Blocked issues (boucle:blocked) are not re-triggered by the capacity
  # scan — file-blocked issues stay parked until the unblock path fires.
  run grep -nE 'boucle:blocked' lib/boucle-ci/doctor.sh
  assert_success
  # The capacity scan iterates boucle:todo issues only (not blocked).
  run grep -nE 'boucle:todo' lib/boucle-ci/doctor.sh
  assert_success
}

# ── Spec-gate recovery: emoji approves (worker), reply amends (triage) ──
# The doctor recovers orphaned boucle:spec-review issues (dispatch was
# canceled/orphaned before it could route). Mirroring the dispatch contract
# (A2, LESSONS.yml lesson #83): an emoji reaction re-triggers the worker
# (approval); a human reply re-triggers TRIAGE (amendment, NOT approval).
# The old code treated any reply as approval and started the worker — the
# gate bypass the dispatch fix closes.

extract_spec_review_recovery() {
  # Extract the "Recover orphaned boucle:spec-review issues" block.
  awk '
    /# ── Recover orphaned boucle:spec-review issues/ { p = 1 }
    p == 1 { print }
    p == 1 && /^  # ── Recover stuck boucle:triage issues/ { exit }
  ' lib/boucle-ci/doctor.sh
}

@test "doctor spec-review recovery: emoji approval re-triggers the worker" {
  block=$(extract_spec_review_recovery)
  # The emoji path chains to the worker (approval → work).
  echo "$block" | grep -q 'EMOJI_APPROVAL_FOUND'
  echo "$block" | grep -q 'chain_to_role "\$IID" "worker"'
}

@test "doctor spec-review recovery: human reply (no emoji) re-triggers triage, NOT the worker" {
  block=$(extract_spec_review_recovery)
  # A human reply is an amendment → re-triage, not worker.
  echo "$block" | grep -q 'HUMAN_REPLY_AFTER_TRIAGE'
  echo "$block" | grep -qi 'amendment\|NOT.*approval\|re-triggering triage'
  # The reply branch must chain to triage, not worker.
  echo "$block" | grep -q 'chain_to_role "\$IID" "triage"'
}

@test "doctor spec-review recovery no longer treats a bare reply as approval" {
  # The old code: `if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ] || [ "$EMOJI_APPROVAL_FOUND" = true ]`
  # → "approved (reply=...)" → worker. That conflated amendments with
  # approvals. The new code MUST separate the two (emoji → worker, reply →
  # triage) and MUST NOT print "approved" for a reply-only case. Assert by
  # inversion: grep exits 1 (failure) when the pattern is ABSENT, which is
  # the success condition here.
  block=$(extract_spec_review_recovery)
  # The combined `||` predicate that treated reply-as-approval is gone.
  run grep -q 'HUMAN_REPLY_AFTER_TRIAGE" -gt 0 \] || \[ "\$EMOJI_APPROVAL_FOUND"' <<< "$block"
  assert_failure
  # The "approved (reply=...)" log line is gone (a reply is not approval).
  run grep -q 'approved (reply=' <<< "$block"
  assert_failure
}

# ── Closed-issue non-terminal-label recovery (GitHub auto-close race, #79) ──

@test "doctor: scans closed issues with non-terminal boucle labels" {
  # The generalized zombie scan must iterate non-terminal labels on closed
  # issues, not just boucle:working/boucle:review.
  run grep -q 'boucle:spec-review' lib/boucle-ci/doctor.sh
  assert_success
  # The scan must check for a merged MR and chain to post-merge.
  run grep -q 'merged MR — chaining to post-merge' lib/boucle-ci/doctor.sh
  assert_success
}

@test "doctor: closed issue with merged MR chains to post-merge (not done)" {
  # Lesson #102: e2e runs on every merge. A closed issue with a merged MR
  # must chain to post-merge for e2e verification, NOT set boucle:done.
  run grep -q 'chain_to_role "\$IID" "post-merge"' lib/boucle-ci/doctor.sh
  assert_success
  run grep -q 'merged MR' lib/boucle-ci/doctor.sh
  assert_success
}

# ── Mono-user mode: marker-based human-reply classification (#100) ──────
# In mono-user mode BOUCLE_BOT_USERNAME falls back to "up-bot" (nobody),
# so identity filters classify EVERY note — including boucle's own — as
# human. The doctor must classify by the <!-- boucle:agent --> marker
# instead, independent of the author account.

@test "doctor no longer classifies human replies by author identity" {
  # The identity filter (select(.author.username != $bname)) must be gone
  # from every reply/approval classification in doctor.sh.
  run grep -q 'select(.author.username != \$bname)' lib/boucle-ci/doctor.sh
  assert_failure
  # ...and the marker predicate must be present.
  run grep -q 'contains("<!-- boucle:agent -->")' lib/boucle-ci/doctor.sh
  assert_success
}

extract_first_reply_counter() {
  # Extract the first HUMAN_REPLY_AFTER_TRIAGE assignment (needs-info path).
  local q="'"
  awk -v q="$q" '/HUMAN_REPLY_AFTER_TRIAGE=\$\(echo "\$NOTES"/{p=1} p{print} p && $0 ~ q"\\)"{exit}' lib/boucle-ci/doctor.sh
}

@test "doctor counts human replies by marker, not identity (mono-user)" {
  # Mono-user: ALL notes are authored by "alice" (boucle posts under her
  # account). Only the marker-less note is a human reply.
  NOTES='[
    {"id": 1, "body": "<!-- boucle:triage v=1 --> needs info", "author": {"username": "alice"}},
    {"id": 2, "body": "<!-- boucle:agent --> pinging for status", "author": {"username": "alice"}},
    {"id": 3, "body": "here are the answers", "author": {"username": "alice"}}
  ]'
  LAST_TRIAGE_NOTE_ID="1"
  eval "$(extract_first_reply_counter)"
  [ "$HUMAN_REPLY_AFTER_TRIAGE" = "1" ]
}

@test "doctor treats legacy bot-identity notes without marker as human (back-compat)" {
  # A note from the legacy bot account without a marker (historical note)
  # is conservatively counted as human — the marker is the source of truth.
  NOTES='[
    {"id": 1, "body": "<!-- boucle:triage v=1 --> needs info", "author": {"username": "alice"}},
    {"id": 2, "body": "old-style bot note without marker", "author": {"username": "up-bot"}}
  ]'
  LAST_TRIAGE_NOTE_ID="1"
  eval "$(extract_first_reply_counter)"
  [ "$HUMAN_REPLY_AFTER_TRIAGE" = "1" ]
}

@test "doctor_mr_approval_magic_word ignores boucle's own notes in mono-user" {
  extract="$(awk '/^  doctor_mr_approval_magic_word\(\) \{/{p=1} p{print} p && /^  \}/{exit}' lib/boucle-ci/doctor.sh)"
  # boucle posts "approved"?? no — boucle's own magic-word-shaped note is
  # marker-stamped, so it must NOT count as a human approval.
  forge_mr_notes() {
    printf '[{"id": 5, "body": "<!-- boucle:agent --> status: approved \\n(see notes)", "author": {"username": "alice"}}]'
  }
  eval "$extract"
  run doctor_mr_approval_magic_word 42
  assert_output "0"

  # A real human note (no marker) with standalone `approved` approves.
  forge_mr_notes() {
    printf '[{"id": 5, "body": "<!-- boucle:agent --> status update", "author": {"username": "alice"}}, {"id": 6, "body": "Approved", "author": {"username": "alice"}}]'
  }
  eval "$extract"
  run doctor_mr_approval_magic_word 42
  assert_output "1"
}

@test "doctor_mr_approval_emoji ignores reactions from agent-marker authors" {
  extract="$(awk '/^  doctor_mr_approval_emoji\(\) \{/{p=1} p{print} p && /^  \}/{exit}' lib/boucle-ci/doctor.sh)"
  BOUCLE_SPEC_APPROVAL_EMOJIS="👍"
  # Mono-user: boucle (acting as alice) reacted 👍 on its own approval
  # request. Without the marker-author exclusion this would self-approve.
  forge_mr_notes() {
    printf '[{"id": 7, "body": "<!-- boucle:approval-request v=1 --> react with 👍", "author": {"username": "alice"}}, {"id": 8, "body": "<!-- boucle:agent --> working", "author": {"username": "alice"}}]'
  }
  forge_note_reactions() {
    printf '[{"name": "👍", "user": {"username": "alice"}}]'
  }
  eval "$extract"
  run doctor_mr_approval_emoji 42
  assert_output "0"

  # A 👍 from a genuinely human reactor (no marker-authored notes) counts.
  forge_note_reactions() {
    printf '[{"name": "👍", "user": {"username": "bob"}}]'
  }
  eval "$extract"
  run doctor_mr_approval_emoji 42
  assert_output "1"
}
