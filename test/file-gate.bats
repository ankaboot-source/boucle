# test/file-gate.bats — tests for the file-impact gate (MR 1).
#
# Covers:
#   - check_file_gate (lib/boucle-ci/gates.sh) — the declared file gate that
#     defers a worker whose issue claims files already claimed by an in-flight
#     issue. Fail-open everywhere: disabled, missing own marker, missing other
#     marker, forge API error → return 0 (pass).
#   - maybe_unblock_dependents file-blocked branch (F4) — a file-blocked issue
#     unblocks directly when the named blocker (on=N) closes.
#   - Engine-copy convergence (F3) — the inline .gitlab-ci.yml no longer
#     redefines the gate functions; it sources lib/boucle-ci/gates.sh.
#
# The forge_* helpers are mocked as stub functions (matching the
# test/boucle-lib.bats style) so the gate logic runs without a real forge.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Helper: source lib/boucle.sh + lib/boucle-ci/gates.sh with the forge_*
# helpers mocked. The mock functions are defined in the caller's subshell
# BEFORE sourcing so the gate functions resolve them at call time.
source_gates() {
  BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
  forge_issue_get() { :; }
  source lib/boucle.sh
  source lib/boucle-ci/gates.sh
}

# ── check_file_gate: declared gate ─────────────────────────────────────

@test "check_file_gate blocks on file overlap (returns 1, sets boucle:blocked, posts marker note)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Own issue 10 and active issue 20 both claim src/Card.astro.
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        20) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":20}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=1"
  assert_output --partial "LABEL:10:boucle:blocked"
  assert_output --partial "NOTE:10:"
  assert_output --partial "<!-- boucle:file-blocked v=1 on=20 paths=src/Card.astro -->"
}

@test "check_file_gate passes on no overlap (returns 0)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Own issue 10 claims Card.astro; active issue 20 claims Other.astro.
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        20) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Other.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":20}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

@test "check_file_gate passes on absent own marker (fail-open)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Own issue 10 has no files marker → no claim → pass.
    forge_issue_notes() {
      case "$1" in
        10) echo "[]" ;;
        20) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":20}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

@test "check_file_gate passes on absent other marker (fail-open)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Own issue 10 claims Card.astro; active issue 20 has no marker.
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        20) echo "[]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":20}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

@test "check_file_gate self-excludes (own marker does not block against itself)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # The active-issues list contains ONLY issue 10 itself (self) — the gate
    # must exclude self so a re-trigger of the same issue never blocks.
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":10}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

@test "check_file_gate respects BOUCLE_FILE_GATE=false (no-op, returns 0)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    BOUCLE_FILE_GATE=false
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Even with overlapping markers, the gate is disabled → pass.
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        20) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:files v=1 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    forge_issue_list_by_label() { echo "[{\"iid\":20}]"; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

@test "check_file_gate fails open on forge API error (returns 0)" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # forge_issue_notes fails (returns non-zero / empty) → own marker unreadable
    # → fail-open pass. A flaky forge must never block the loop.
    forge_issue_notes() { return 1; }
    forge_issue_list_by_label() { return 1; }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    check_file_gate 10
    echo "RC=$?"
  '
  assert_success
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:10:boucle:blocked"
}

# ── maybe_unblock_dependents: file-blocked unblock (F4) ────────────────

@test "maybe_unblock_dependents unblocks a file-blocked issue when the named blocker closes" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Closed issue 20 is the blocker. Sibling 10 is boucle:blocked and carries
    # a file-blocked marker naming 20 as the blocker.
    forge_issue_get() {
      case "$1" in
        20) echo "{\"description\":\"## Parent issue\n\n#5\",\"state\":\"closed\"}" ;;
        10) echo "{\"description\":\"## Parent issue\n\n#5\",\"labels\":[\"boucle:blocked\"],\"state\":\"opened\"}" ;;
        5)  echo "{\"description\":\"parent\",\"state\":\"opened\"}" ;;
        *) echo "{}" ;;
      esac
    }
    forge_work_item_children() { echo "[{\"iid\":10,\"state\":\"opened\"},{\"iid\":20,\"state\":\"closed\"}]"; }
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:file-blocked v=1 on=20 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    issue_has_active_pipeline() { return 1; }  # no active pipeline → trigger
    chain_to_role() { echo "CHAIN:$1:$2"; }
    maybe_unblock_dependents 20
  '
  assert_success
  assert_output --partial "LABEL:10:boucle:todo"
  assert_output --partial "NOTE:10:"
  assert_output --partial "<!-- boucle:unblocked v=1 by=20 -->"
  assert_output --partial "CHAIN:10:worker"
}

@test "maybe_unblock_dependents does NOT unblock when the closed issue is not the named blocker" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    # Closed issue 30 is NOT the blocker named in sibling 10'"'"'s marker (on=20).
    forge_issue_get() {
      case "$1" in
        30) echo "{\"description\":\"## Parent issue\n\n#5\",\"state\":\"closed\"}" ;;
        10) echo "{\"description\":\"## Parent issue\n\n#5\",\"labels\":[\"boucle:blocked\"],\"state\":\"opened\"}" ;;
        5)  echo "{\"description\":\"parent\",\"state\":\"opened\"}" ;;
        *) echo "{}" ;;
      esac
    }
    forge_work_item_children() { echo "[{\"iid\":10,\"state\":\"opened\"},{\"iid\":30,\"state\":\"closed\"}]"; }
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:file-blocked v=1 on=20 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    issue_has_active_pipeline() { return 1; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    maybe_unblock_dependents 30
  '
  assert_success
  refute_output --partial "LABEL:10:boucle:todo"
  refute_output --partial "CHAIN:10:worker"
}

@test "maybe_unblock_dependents issue_has_active_pipeline guard prevents double-trigger" {
  run bash -c '
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    forge_issue_get() {
      case "$1" in
        20) echo "{\"description\":\"## Parent issue\n\n#5\",\"state\":\"closed\"}" ;;
        10) echo "{\"description\":\"## Parent issue\n\n#5\",\"labels\":[\"boucle:blocked\"],\"state\":\"opened\"}" ;;
        5)  echo "{\"description\":\"parent\",\"state\":\"opened\"}" ;;
        *) echo "{}" ;;
      esac
    }
    forge_work_item_children() { echo "[{\"iid\":10,\"state\":\"opened\"},{\"iid\":20,\"state\":\"closed\"}]"; }
    forge_issue_notes() {
      case "$1" in
        10) echo "[{\"id\":1,\"created_at\":\"2026-01-01T00:00:00Z\",\"body\":\"<!-- boucle:file-blocked v=1 on=20 paths=src/Card.astro -->\"}]" ;;
        *) echo "[]" ;;
      esac
    }
    set_boucle_label() { echo "LABEL:$1:$2"; }
    forge_issue_note() { echo "NOTE:$1:$2"; }
    issue_has_active_pipeline() { return 0; }  # active pipeline → no trigger
    chain_to_role() { echo "CHAIN:$1:$2"; }
    maybe_unblock_dependents 20
  '
  assert_success
  assert_output --partial "LABEL:10:boucle:todo"
  refute_output --partial "CHAIN:10:worker"
}

# ── Engine-copy convergence (F3) ────────────────────────────────────────
# After the pre-refactor, the inline .gitlab-ci.yml must NOT redefine the
# gate functions — it sources lib/boucle-ci/gates.sh (the single source of
# truth). This keeps the file gate wired once, not three times.

@test "convergence: .gitlab-ci.yml has ZERO inline gate function definitions" {
  run grep -nE '^check_sibling_gate\(\)|^maybe_unblock_dependents\(\)|^check_dependencies_and_gate\(\)|^check_file_gate\(\)' .gitlab-ci.yml
  assert_failure
}

@test "convergence: .gitlab-ci.yml sources lib/boucle-ci/gates.sh" {
  run grep -nE 'source .*lib/boucle-ci/gates\.sh' .gitlab-ci.yml
  assert_success
}

@test "convergence: lib/boucle-ci/gates.sh defines the gate functions at top-level" {
  run grep -nE '^check_sibling_gate\(\)' lib/boucle-ci/gates.sh
  assert_success
  run grep -nE '^check_file_gate\(\)' lib/boucle-ci/gates.sh
  assert_success
  run grep -nE '^maybe_unblock_dependents\(\)' lib/boucle-ci/gates.sh
  assert_success
}
