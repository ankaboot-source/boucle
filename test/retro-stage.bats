#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
# Retro stage + doctor hook + posting helpers (#139).
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
  assert_output --partial "retro stage disabled"
  [ ! -e "$TMP/capture" ]
}

@test "stage: an absent or empty BOUCLE_ENABLED (GitHub env reality) does not disable — the agent runs" {
  # GitHub's workflow env block does not export BOUCLE_ENABLED: the repo
  # Variable only reaches the job `if:` gate, so by the time a shell runs the
  # variable is absent. The stage relies on that gate.
  run stage "unset BOUCLE_ENABLED"
  assert_success
  run cat "$TMP/capture"
  assert_output --partial "JC-ROLE:retro"

  rm -f "$TMP/capture"
  run stage "export BOUCLE_ENABLED="
  assert_success
  run cat "$TMP/capture"
  assert_output --partial "JC-ROLE:retro"
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

@test "stage: dry-run posts nothing but advances the cadence with a dry_run record (S5)" {
  run stage "export BOUCLE_RETRO_DRY_RUN=true BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=none implementable=none'"
  assert_success
  assert_output --partial "dry-run: analysis only"
  assert_output --partial "dry-run: recorded the run"
  assert_output --partial "dry-run: skip closing the previous report"
  assert_output --partial "dry-run: skip T2 contribution"

  run cat "$TMP/capture"
  assert_output --partial "JC:retro"
  # The record advances the cadence; without it every sweep looks like a
  # first run and the doctor re-chains a 30-step retro each time.
  assert_output --partial "RECORD:"
  assert_output --partial '"dry_run":true'
  refute_output --partial "CLOSE:"
  refute_output --partial "T2:"
}

@test "stage: BOUCLE_RETRO_FORCE skips the threshold re-check (S5)" {
  run stage "export BOUCLE_RETRO_FORCE=true BOUCLE_MOCK_JC_SUMMARY='[boucle:retro] summary: created=none enriched=none report=7 implementable=none'; retro_threshold_reached() { return 1; }"
  assert_success
  assert_output --partial "BOUCLE_RETRO_FORCE=true"
  assert_output --partial "threshold re-check skipped"
  run cat "$TMP/capture"
  assert_output --partial "JC:retro"
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

# ── T2 workspace lifecycle (B2) + transcript preservation (N3) ─────────

@test "T2: the tokenized workspace is cleaned on exit and the retro transcript is preserved" {
  mkdir -p "$TMP/ws/.boucle-state"
  printf 'RETRO-TRANSCRIPT\n' > "$TMP/ws/.boucle-state/agent-output.log"
  mkdir -p "$TMP/home/bin"
  cat > "$TMP/home/bin/jc" << 'EOF'
#!/usr/bin/env bash
printf 'IMPL-TRANSCRIPT\n' > "$BOUCLE_WORKSPACE/.boucle-state/agent-output.log"
echo "JC:$*"
EOF
  chmod +x "$TMP/home/bin/jc"

  run bash -c "
    set -euo pipefail
    export BOUCLE_HOME='$TMP/home' BOUCLE_WORKSPACE='$TMP/ws'
    export BOUCLE_UPSTREAM_REPO=owner/upstream BOUCLE_UPSTREAM_TOKEN=tok
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_contribute_enabled() { return 0; }
    _retro_upstream() { echo '{\"title\":\"Fix the thing\",\"description\":\"do it\"}'; }
    _retro_prepare_workspace() {
      mkdir -p '$TMP/ws/.boucle-state/retro-workspace'
      echo '$TMP/ws/.boucle-state/retro-workspace'
    }
    _retro_t2_chain 42
  "
  assert_success
  assert_output --partial "T2: implementing #42"
  # B2: the cleanup target survives the command substitution — before the
  # fix, _RETRO_T2_WORKSPACE was set in the subshell and this dir stayed.
  [ ! -e "$TMP/ws/.boucle-state/retro-workspace" ]
  # N3: both transcripts survive bin/jc truncating the per-run log.
  run cat "$TMP/ws/.boucle-state/retro-agent-output.log"
  assert_output --partial "RETRO-TRANSCRIPT"
  run cat "$TMP/ws/.boucle-state/agent-output.log"
  assert_output --partial "IMPL-TRANSCRIPT"
}

@test "T2: the cleanup trap covers the 45m job's TERM and INT, not only EXIT" {
  run grep -Fq "trap '_retro_t2_cleanup' EXIT" "$REPO/lib/boucle-ci/retro.sh"
  assert_success
  run grep -Fq "trap '_retro_t2_cleanup; exit 143' TERM" "$REPO/lib/boucle-ci/retro.sh"
  assert_success
  run grep -Fq "trap '_retro_t2_cleanup; exit 130' INT" "$REPO/lib/boucle-ci/retro.sh"
  assert_success
}

@test "artifacts: the depth-1 retro logs are explicitly listed on both forges (N6)" {
  run grep -Fq '.boucle-state/retro-agent-output.log' "$REPO/.gitlab-ci.yml"
  assert_success
  run grep -Fq '.boucle-state/agent-output.log' "$REPO/.gitlab-ci.yml"
  assert_success
  # Exactly one GitHub job carries them — the retro job's upload.
  run grep -Fc '.boucle-state/retro-agent-output.log' "$REPO/.github/workflows/boucle.yml"
  assert_output "1"
  run grep -Fq '.boucle-state/agent-output.log' "$REPO/.github/workflows/boucle.yml"
  assert_success
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
  assert_output --partial "retro due"
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

  # An absent or empty BOUCLE_ENABLED is the GitHub env reality: the workflow
  # env block never exports it, only the job `if:` gate reads it. The hook
  # must still chain (the job gate has already handled the opt-out).
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
  assert_output --partial "CHAIN:retro:retro"
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

@test "doctor hook: BOUCLE_RETRO_FORCE can never make the periodic trigger fire (S5)" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    BOUCLE_ENABLED=true BOUCLE_RETRO_FORCE=true
    retro_enabled() { return 0; }
    retro_upstream_ready() { return 0; }
    retro_threshold_reached() { return 1; }
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
    forge_issue_create() { printf '%s' \"\$1\" > '$TMP/local-title.txt'; printf '%s' \"\$2\" > '$TMP/local-body.txt'; echo 7; }
    forge_issue_create_in() { echo \"CREATE-TITLE:\$3\" >&2; echo \"CREATE-BODY:\$4\" >&2; echo 42; }
    forge_issue_note_in() { echo \"NOTE-BODY:\$4\" >&2; return 0; }
    forge_pr_create_in() { echo \"PR-TITLE:\$3|HEAD:\$4|BASE:\$5\" >&2; echo \"PR-BODY:\$6\" >&2; echo 9; }
    retro_post_report 'title CONSUMER' 'body CONSUMER'
    retro_post_create 'title CONSUMER' 'body CONSUMER'
    retro_post_enrich 5 'body CONSUMER'
    retro_post_pr 'title CONSUMER' retro/slug main 'body CONSUMER'
  "
  assert_success
  assert_output --partial "[retro-post] report=7"
  assert_output --partial "[retro-post] created=42"
  assert_output --partial "[retro-post] enriched=5"
  assert_output --partial "[retro-post] pr=9"
  assert_output --partial "CREATE-TITLE:title [consumer]"
  assert_output --partial "CREATE-BODY:body [consumer]"
  assert_output --partial "NOTE-BODY:body [consumer]"
  assert_output --partial "PR-TITLE:title [consumer]|HEAD:retro/slug|BASE:main"
  assert_output --partial "PR-BODY:body [consumer]"
  refute_output --partial "CONSUMER"
  # The local report title AND body are scrubbed too (captured by the stub).
  run cat "$TMP/local-title.txt"
  assert_output "title [consumer]"
  run cat "$TMP/local-body.txt"
  assert_output "body [consumer]"
}

@test "post helpers: a title carrying a live-URL host is scrubbed (B3)" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    export BOUCLE_LIVE_URL='https://site-urgence.pages.dev'
    SCRATCH='$TMP/live';
    mkdir -p \"\$SCRATCH\"
    cd \"\$SCRATCH\"
    export BOUCLE_UPSTREAM_TOKEN=tok BOUCLE_UPSTREAM_REPO=owner/upstream
    forge_label_create_in() { :; }
    forge_issue_create_in() { echo \"CREATE-TITLE:\$3\" >&2; echo 42; }
    retro_post_create 'failure on site-urgence.pages.dev' 'body'
  "
  assert_success
  assert_output --partial "CREATE-TITLE:failure on [consumer-host]"
}

@test "post helpers: a head branch that is not a branch name is rejected (B3)" {
  run bash -c "
    set -euo pipefail
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    retro_scrub() { cat; }
    retro_dry_run() { return 1; }
    export BOUCLE_UPSTREAM_TOKEN=tok BOUCLE_UPSTREAM_REPO=owner/upstream
    forge_pr_create_in() { echo FORGE-PR; }
    retro_post_pr title 'bad head!' main body
  "
  assert_failure
  assert_output --partial "invalid head branch"
  refute_output --partial "FORGE-PR"
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
  assert_output "[retro-post] created=99"
}

# ── Helpers: renumber map + value counting (N2/S3) ─────────────────────

@test "renumber map: deterministic #1..#N in order of first appearance (S3)" {
  run bash -c "source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true; printf '4242\n777\n4242\n999\n' | _retro_renumber_map"
  assert_success
  assert_output "$(printf '4242\t#1\n777\t#2\n999\t#3')"
}

@test "count_values: a no-match grep does not append a second zero (N2)" {
  # grep -c prints 0 AND exits 1; `|| echo 0` produced "0\n0" and the
  # record's jq --argjson refused it.
  run bash -c "source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true; _retro_count_values '101,102'"
  assert_output "2"
  run bash -c "source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true; _retro_count_values ''"
  assert_output "0"
  run bash -c "source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true; _retro_count_values none"
  assert_output "0"
}

@test "digest: consumer IIDs are renumbered — no raw issue number survives (S3)" {
  REMOTE="$TMP/remote.git"
  WORK="$TMP/digest-work"
  git init -q --bare "$REMOTE"
  git init -q "$WORK"
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$WORK" push -q origin HEAD:main
  git -C "$WORK" checkout -q --orphan boucle/metrics
  mkdir -p "$WORK/raw"
  printf '%s\n' \
    '{"schema":2,"timestamp":"2026-10-01T10:00:00Z","issue":"4242","terminal":"done"}' \
    '{"schema":2,"timestamp":"2026-10-02T10:00:00Z","issue":"777","terminal":"human"}' \
    > "$WORK/metrics.jsonl"
  printf '%s\n' '{"timestamp":"2026-10-01T09:00:00Z","role":"worker","iteration":1,"outcome":"committed"}' > "$WORK/raw/4242.jsonl"
  printf '%s\n' '{"timestamp":"2026-10-02T09:00:00Z","role":"worker","iteration":1,"outcome":"build-fail"}' > "$WORK/raw/777.jsonl"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.email=a@b -c user.name=a commit -q -m metrics
  git -C "$WORK" push -q origin boucle/metrics

  run bash -c "
    set -euo pipefail
    unset GITHUB_REPOSITORY BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH || true
    export BOUCLE_WORKSPACE='$WORK' BOUCLE_HOME='$REPO'
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    cd '$WORK'
    forge_issue_list_all() { echo '[{\"iid\":999,\"title\":\"Closed leak\",\"closed_at\":\"2026-10-03T00:00:00Z\"}]'; }
    retro_upstream_ready() { return 1; }
    _retro_build_digest '$TMP/digest.md' '2026-09-15T00:00:00Z'
  "
  assert_success
  run cat "$TMP/digest.md"
  refute_output --partial "4242"
  refute_output --partial "777"
  refute_output --partial "999"
  assert_output --partial '"issue":"#1"'
  assert_output --partial '"issue":"#2"'
  assert_output --partial "- #3 Closed leak"
}

# ── Digest: completeness cross-check (metrics blackout) ─────────────────
# A window with closed issues but ZERO metrics rows is a hollow retro: it
# renders clean while the primary evidence layer is absent. The digest MUST
# warn on it, MUST name a failed fetch differently from an empty one, and MUST
# stay silent when the window is genuinely quiet or the rows are present.

# digest_work <work-dir> [metrics-lines-file]
# Bare origin + work clone whose `boucle/metrics` branch carries the given
# metrics.jsonl and one raw run row per issue it names. Without a file the
# branch is never created — the fetch-failure path.
digest_work() {
  local work="$1" metrics="${2:-}"
  git init -q --bare "$TMP/remote.git"
  git init -q "$work"
  git -C "$work" remote add origin "$TMP/remote.git"
  git -C "$work" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$work" push -q origin HEAD:main
  [ -n "$metrics" ] || return 0
  git -C "$work" checkout -q --orphan boucle/metrics
  cp "$metrics" "$work/metrics.jsonl"
  mkdir -p "$work/raw"
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' '{"timestamp":"2026-10-01T09:00:00Z","role":"worker","iteration":1,"outcome":"committed"}' \
      > "$work/raw/$id.jsonl"
  done < <(jq -r '.issue // empty' "$work/metrics.jsonl" 2> /dev/null || true)
  git -C "$work" add -A
  git -C "$work" -c user.email=a@b -c user.name=a commit -q -m metrics
  git -C "$work" push -q origin boucle/metrics
}

# digest_run <work-dir> <out-file> <closed-issues-json>
digest_run() {
  local work="$1" out="$2" closed="$3"
  bash -c "
    set -euo pipefail
    unset GITHUB_REPOSITORY BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH || true
    export BOUCLE_WORKSPACE='$work' BOUCLE_HOME='$REPO'
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    cd '$work'
    forge_issue_list_all() { echo '$closed'; }
    retro_upstream_ready() { return 1; }
    _retro_build_digest '$out' '2026-09-15T00:00:00Z'
  "
}

@test "digest: closed issues with zero metrics rows warn — blackout, never a clean empty window" {
  WORK="$TMP/blackout-work"
  : > "$TMP/empty-metrics.jsonl"
  digest_work "$WORK" "$TMP/empty-metrics.jsonl"

  run digest_run "$WORK" "$TMP/blackout.md" \
    '[{"id":11,"title":"One","closed_at":"2026-10-03T00:00:00Z"},{"id":12,"title":"Two","closed_at":"2026-10-04T00:00:00Z"},{"id":13,"title":"Old","closed_at":"2026-08-01T00:00:00Z"}]'
  assert_success
  run cat "$TMP/blackout.md"
  # The count is window-scoped (the August issue is out) and names the two
  # fault modes apart: fetched-but-empty is NOT a failed fetch.
  assert_output --partial "WARNING: metrics blackout — 0 metrics rows for 2 closed issue(s) in window; the retro evidence layer is missing (collector unwired, or its rows dropped before the window query)."
  assert_output --partial "fetched: yes, 0 rows on the branch — collector unwired or never ran"
  assert_output --partial "metrics rows: 0 in window, 0 on branch"
  assert_output --partial "last metrics row: never"
  assert_output --partial "list: raw file names (metrics-window list empty)"
  # The per-issue section must not read as "no data"; it points at the finding.
  assert_output --partial "metrics blackout"
  refute_output --partial "no metrics data in this window"
}

@test "digest: metrics rows present render as today — no warning, no noise" {
  WORK="$TMP/present-work"
  printf '%s\n' \
    '{"schema":2,"timestamp":"2026-10-01T10:00:00Z","issue":"4242","terminal":"done"}' \
    '{"schema":2,"timestamp":"2026-10-02T10:00:00Z","issue":"777","terminal":"human"}' \
    > "$TMP/present-metrics.jsonl"
  digest_work "$WORK" "$TMP/present-metrics.jsonl"

  run digest_run "$WORK" "$TMP/present.md" \
    '[{"id":42,"title":"Closed","closed_at":"2026-10-03T00:00:00Z"}]'
  assert_success
  run cat "$TMP/present.md"
  # The banner prefix and the word "blackout" are unique to a real banner: no
  # other digest line carries them, so a grep for either cannot false-positive.
  refute_output --partial "WARNING: metrics blackout"
  refute_output --partial "blackout"
  assert_output --partial "fetched: yes;"
  assert_output --partial "metrics rows: 2 in window, 2 on branch"
  assert_output --partial "issue rows: 2, bounded to 40"
  assert_output --partial "last metrics row: 2026-10-02T10:00:00Z"
}

@test "digest: a genuinely quiet window stays silent — no closed issues, no metrics rows" {
  WORK="$TMP/quiet-work"
  : > "$TMP/empty-metrics.jsonl"
  digest_work "$WORK" "$TMP/empty-metrics.jsonl"

  run digest_run "$WORK" "$TMP/quiet.md" '[{"id":7,"title":"Long closed","closed_at":"2026-01-01T00:00:00Z"}]'
  assert_success
  run cat "$TMP/quiet.md"
  refute_output --partial "WARNING: metrics blackout"
  refute_output --partial "blackout"
  assert_output --partial "fetched: yes, 0 rows on the branch"
}

@test "digest: a failed fetch is named as such, and a closed-issue window still warns" {
  WORK="$TMP/nofetch-work"
  digest_work "$WORK"

  run digest_run "$WORK" "$TMP/nofetch.md" \
    '[{"id":9,"title":"Closed","closed_at":"2026-10-03T00:00:00Z"}]'
  assert_success
  run cat "$TMP/nofetch.md"
  assert_output --partial "fetch failed — boucle/metrics unavailable (branch, credential or remote missing)"
  assert_output --partial "WARNING: metrics blackout — 0 metrics rows for 1 closed issue(s) in window"
  refute_output --partial "fetched: yes, 0 rows"
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
