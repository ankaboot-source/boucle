#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
# Rétro stage + doctor hook + posting helpers (#139).
#
# The stage is the orchestration layer: it must be idempotent (threshold
# re-check), write-free in dry-run, fail-open on every unexpected error, and
# never lose the trigger state. The post helpers are the only place dry-run
# and anonymisation can be enforced IN CODE — a prompt cannot enforce either.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
  # Hermetic repository identity — see test/retro.bats: in CI the forge exports
  # the real checkout identity, which `_retro_is_upstream_repo` reads before
  # `origin`; a consumer fixture would resolve to the upstream and invert the
  # T2 gating assertions. Tests that need an identity export it explicitly.
  unset GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_API_URL \
    CI_PROJECT_ID CI_PROJECT_NAME CI_PROJECT_PATH CI_REPOSITORY_URL \
    BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH || true
  mkdir -p "$TMP/home/bin" "$TMP/ws"

  # The fake bin/jc: records how it was invoked, writes the agent log the
  # stage parses, and can emit a pinned summary tail / fail on demand.
  cat > "$TMP/home/bin/jc" << 'EOF'
#!/usr/bin/env bash
echo "JC:$*" >> "$CAPTURE"
echo "JC-ROLE:${BOUCLE_ROLE:-unset}" >> "$CAPTURE"
echo "JC-DIGEST:${BOUCLE_RETRO_DIGEST:-unset}" >> "$CAPTURE"
if [ -n "${BOUCLE_MOCK_JC_SUMMARY:-}" ]; then
  mkdir -p "$BOUCLE_WORKSPACE/.boucle-state" 2> /dev/null || true
  printf '%s\n' "$BOUCLE_MOCK_JC_SUMMARY" > "$BOUCLE_WORKSPACE/.boucle-state/agent-output.log"
  printf '%s\n' "$BOUCLE_MOCK_JC_SUMMARY"
fi
exit "${BOUCLE_MOCK_JC_RC:-0}"
EOF
  chmod +x "$TMP/home/bin/jc"
}

teardown() {
  cd "$BATS_TEST_DIRNAME" 2> /dev/null || cd / || true
  rm -rf "$TMP"
}

# stage [setup-snippet]
#
# Run boucle_ci_retro in a controlled shell: the real toggles/scrub from
# lib/boucle.sh, a stubbed threshold/window/digest/bookkeeping, and the fake
# BOUCLE_HOME/bin/jc. The setup snippet overrides any of them.
stage() {
  local setup="${1:-:}"
  bash -c "
    set -euo pipefail
    export BOUCLE_HOME='$TMP/home'
    export BOUCLE_WORKSPACE='$TMP/ws'
    export BOUCLE_FORGE=github
    export BOUCLE_ENABLED=true
    export BOUCLE_RETRO_ENABLED=true
    export BOUCLE_UPSTREAM_TOKEN=tok
    export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
    export BOUCLE_PROJECT_PATH=someone/consumer
    export GITHUB_REPOSITORY=someone/consumer
    export CAPTURE='$TMP/capture'
    export TMP='$TMP'
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_threshold_reached() { return 0; }
    retro_last_run_read() { echo '2026-10-01T00:00:00Z'; }
    _retro_build_digest() { printf '# digest\n' > \"\$1\"; }
    retro_record_run() { echo \"RECORD:\$1\" >> \"\$CAPTURE\"; }
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_close() { echo \"CLOSE:\$1\" >> \"\$CAPTURE\"; }
    _retro_t2_chain() { echo \"T2:\$1\" >> \"\$CAPTURE\"; }
    retro_contribute_enabled() { return 1; }
    $setup
    boucle_ci_retro
  "
}

# ── Guards ──────────────────────────────────────────────────────────────

@test "stage: BOUCLE_ENABLED other than true skips without invoking the agent" {
  run stage "export BOUCLE_ENABLED=false"
  assert_success
  assert_output --partial "BOUCLE_ENABLED is not 'true'"
  [ ! -e "$TMP/capture" ]
}

@test "stage: retro disabled by toggle skips without invoking the agent" {
  run stage "export BOUCLE_RETRO_ENABLED=false"
  assert_success
  assert_output --partial "retro disabled"
  [ ! -e "$TMP/capture" ]
}

@test "stage: enabled without an upstream token skips cleanly (audit carries the advisory)" {
  run stage "export BOUCLE_UPSTREAM_TOKEN="
  assert_success
  assert_output --partial "no upstream token"
  [ ! -e "$TMP/capture" ]
}

@test "stage: threshold false is a no-op — the doctor's pre-check cannot double-fire" {
  run stage "retro_threshold_reached() { return 1; }"
  assert_success
  assert_output --partial "threshold not reached"
  [ ! -e "$TMP/capture" ]
}

# ── Happy path ──────────────────────────────────────────────────────────

@test "stage: runs the agent, records the run, closes the previous report" {
  cat > "$TMP/reports.json" << 'EOF'
[{"iid":"99","state":"opened","created_at":"2026-09-01T00:00:00Z"},
 {"iid":"100","state":"opened","created_at":"2026-10-01T00:00:00Z"}]
EOF
  run stage "export BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=101 created=102 enriched=42 report=100 implementable=101'; forge_issue_list_by_label() { cat \$TMP/reports.json; }"
  assert_success

  run cat "$TMP/capture"
  assert_output --partial "JC:retro"
  assert_output --partial "JC-ROLE:retro"
  assert_output --partial "JC-DIGEST:$TMP/ws/.boucle-state/retro/digest.md"
  # The record carries the counts and the window, and dry_run=false.
  assert_output --partial "RECORD:{"
  assert_output --partial '"created":2'
  assert_output --partial '"enriched":1'
  assert_output --partial '"report":"100"'
  assert_output --partial '"implementable":"101"'
  assert_output --partial '"dry_run":false'
  assert_output --partial '"window":"2026-10-01T00:00:00Z"'
  # The report just created is kept; the previous ones are closed.
  assert_output --partial "CLOSE:99"
  refute_output --partial "CLOSE:100"
  # T2 is off on a consumer (contribute=false by default in the stub).
  refute_output --partial "T2:"
}

@test "stage: the summary parser tolerates no created/enriched and none-values" {
  run stage "export BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=7 implementable=none'"
  assert_success
  assert_output --partial "[retro] result: created=none enriched=none report=7 implementable=none"
  run cat "$TMP/capture"
  assert_output --partial '"created":0'
  assert_output --partial '"enriched":0'
}

# ── Dry-run ─────────────────────────────────────────────────────────────

@test "stage: dry-run invokes the agent but writes nothing (no record, no close, no T2)" {
  run stage "export BOUCLE_RETRO_DRY_RUN=true BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=none implementable=none'"
  assert_success
  assert_output --partial "dry-run: analysis only"
  assert_output --partial "dry-run: skip retros.jsonl record"
  assert_output --partial "dry-run: skip closing the previous report"
  assert_output --partial "dry-run: skip T2 contribution"

  run cat "$TMP/capture"
  assert_output --partial "JC:retro"
  refute_output --partial "RECORD:"
  refute_output --partial "CLOSE:"
  refute_output --partial "T2:"
}

# ── Fail-open / exit semantics ───────────────────────────────────────────

@test "stage: an agent exit 3/4 propagates (bin/jc's silent-failure contract)" {
  run stage "export BOUCLE_MOCK_JC_RC=3"
  assert_failure 3
  assert_output --partial "silent-failure/provider contract"
  run cat "$TMP/capture"
  refute_output --partial "RECORD:"
}

@test "stage: a digest build failure is fail-open — exit 0, no agent" {
  run stage "_retro_build_digest() { return 1; }"
  assert_success
  assert_output --partial "could not build the window digest"
  [ ! -e "$TMP/capture" ]
}

# ── T2 gating ───────────────────────────────────────────────────────────

@test "stage: T2 runs only when contribution is enabled AND implementable is parsed" {
  run stage "retro_contribute_enabled() { return 0; }; export BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=7 implementable=101'"
  assert_success
  run cat "$TMP/capture"
  assert_output --partial "T2:101"
}

@test "stage: T2 is not run for implementable=none, even when contribution is enabled" {
  run stage "retro_contribute_enabled() { return 0; }; export BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=7 implementable=none'"
  assert_success
  assert_output --partial "no implementable proposal"
  run cat "$TMP/capture"
  refute_output --partial "T2:"
}

@test "stage: T2 disabled leaves the upstream issue+plan as the only output" {
  run stage "export BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=7 implementable=101'"
  assert_success
  assert_output --partial "T2 disabled for this repo"
  run cat "$TMP/capture"
  refute_output --partial "T2:"
}

# ── Doctor hook ─────────────────────────────────────────────────────────

@test "doctor hook: chains the retro stage when the threshold is reached" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    BOUCLE_ENABLED=true
    retro_enabled() { return 0; }
    retro_upstream_ready() { return 0; }
    retro_threshold_reached() { return 0; }
    chain_to_role() { echo \"CHAIN:\$1:\$2\"; }
    boucle_retro_doctor_chain
  "
  assert_success
  assert_output --partial "rétro due"
  assert_output --partial "CHAIN:retro:retro"
}

@test "doctor hook: quiet when the threshold is not reached, disabled or token-less" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    BOUCLE_ENABLED=true
    retro_enabled() { return 0; }
    retro_upstream_ready() { return 0; }
    retro_threshold_reached() { return 1; }
    chain_to_role() { echo \"CHAIN:\$1:\$2\"; }
    boucle_retro_doctor_chain
  "
  assert_success
  refute_output --partial "CHAIN:"

  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    BOUCLE_ENABLED=
    retro_enabled() { return 0; }
    retro_upstream_ready() { return 0; }
    retro_threshold_reached() { return 0; }
    chain_to_role() { echo \"CHAIN:\$1:\$2\"; }
    boucle_retro_doctor_chain
  "
  assert_success
  refute_output --partial "CHAIN:"
}

@test "doctor hook: quiet without a usable token, even when due" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    BOUCLE_ENABLED=true
    retro_enabled() { return 0; }
    retro_upstream_ready() { return 1; }
    retro_threshold_reached() { return 0; }
    chain_to_role() { echo \"CHAIN:\$1:\$2\"; }
    boucle_retro_doctor_chain
  "
  assert_success
  refute_output --partial "CHAIN:"
}

# ── Post helpers (dry-run + scrub, enforced in code) ─────────────────────

@test "post helpers: dry-run no-ops all four write paths and says so" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_scrub() { cat; }
    retro_dry_run() { return 0; }
    BOUCLE_UPSTREAM_REPO=owner/upstream
    forge_issue_create() { echo FORGE-LOCAL; }
    forge_issue_create_in() { echo FORGE-CREATE; }
    forge_issue_note_in() { echo FORGE-NOTE; }
    forge_pr_create_in() { echo FORGE-PR; }
    retro_post_report title body
    retro_post_create title body
    retro_post_enrich 5 body
    retro_post_pr title head main body
  "
  assert_success
  assert_output --partial "[retro] dry-run: skip local report issue"
  assert_output --partial "[retro] dry-run: skip upstream proposal issue"
  assert_output --partial "[retro] dry-run: skip upstream enrichment comment on #5"
  assert_output --partial "[retro] dry-run: skip upstream pull request"
  refute_output --partial "FORGE-"
}

@test "post helpers: every body is scrubbed before it leaves, and the ids are printed" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_scrub() { sed 's/CONSUMER/[consumer]/g'; }
    retro_dry_run() { return 1; }
    export BOUCLE_UPSTREAM_TOKEN=tok BOUCLE_UPSTREAM_REPO=owner/upstream
    forge_label_create() { :; }
    forge_label_create_in() { :; }
    forge_issue_create() { printf '%s' \"\$2\" > '$TMP/local-body.txt'; echo 7; }
    forge_issue_create_in() { echo \"CREATE-BODY:\$4\" >&2; echo 42; }
    forge_issue_note_in() { echo \"NOTE-BODY:\$4\" >&2; return 0; }
    forge_pr_create_in() { echo \"PR-BODY:\$6\" >&2; echo 9; }
    retro_post_report title 'body CONSUMER'
    retro_post_create title 'body CONSUMER'
    retro_post_enrich 5 'body CONSUMER'
    retro_post_pr title retro/slug main 'body CONSUMER'
  "
  assert_success
  assert_output --partial "report=7"
  assert_output --partial "created=42"
  assert_output --partial "enriched=5"
  assert_output --partial "pr=9"
  assert_output --partial "CREATE-BODY:body [consumer]"
  assert_output --partial "NOTE-BODY:body [consumer]"
  assert_output --partial "PR-BODY:body [consumer]"
  refute_output --partial "CONSUMER"
  # The local report body is scrubbed too (captured by the stub).
  run cat "$TMP/local-body.txt"
  assert_output "body [consumer]"
}

@test "post helpers: a missing upstream token fails loud, never posts" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_scrub() { cat; }
    retro_dry_run() { return 1; }
    retro_upstream_token() { return 1; }
    forge_issue_create_in() { echo FORGE-CREATE; }
    retro_post_create title body
  "
  assert_failure
  assert_output --partial "no upstream token"
  refute_output --partial "FORGE-CREATE"
}

@test "post helpers: on a GitLab consumer the upstream call loads the GitHub backend in a subshell" {
  mkdir -p "$TMP/home/bin/forge"
  cat > "$TMP/home/bin/forge/github.sh" << 'EOF'
forge_label_create_in() { :; }
forge_issue_create_in() { echo 99; }
EOF
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_scrub() { cat; }
    retro_dry_run() { return 1; }
    export BOUCLE_UPSTREAM_TOKEN=tok BOUCLE_UPSTREAM_REPO=owner/upstream BOUCLE_HOME='$TMP/home'
    retro_post_create title body
  "
  assert_success
  assert_output "created=99"
}

# ── Doctor advisory: the engine's self-targeting token ──────────────────

@test "doctor --audit: the engine's self-targeting token suppresses the retro advisory" {
  cd "$REPO" || return 1
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_FORGE=github BOUCLE_TOKEN=ghp_self bash bin/doctor --audit
  assert_success
  refute_output --partial "without BOUCLE_UPSTREAM_TOKEN"

  # A GitHub consumer is NOT the upstream: the fallback must not apply, and
  # the advisory must still be reported. Run from a scratch checkout whose
  # origin is a consumer repo — the engine checkout's own origin IS the
  # upstream, so in-place would silently test the wrong branch.
  SCRATCH="$TMP/consumer"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin https://gitlab.example.com/asso/site.git
  cd "$SCRATCH" || return 1
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_FORGE=github BOUCLE_TOKEN=ghp_consumer BOUCLE_PROJECT_ID=someone/consumer bash "$REPO/bin/doctor" --audit
  assert_success
  assert_output --partial "BOUCLE_RETRO_ENABLED=true without BOUCLE_UPSTREAM_TOKEN"
}
