#!/usr/bin/env bats
# test/jc.bats — smoke + pure-function tests for bin/jc.
#
# bin/jc has no BASH_SOURCE guard and executes its full body on source:
# it generates the jcode config, calls jcode run, writes to iterations.md,
# etc. We can't source it directly. These tests cover what we can:
# syntax validity, function definitions, and the behavior of build_prompt
# (the role → prompt builder) which we extract and run in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract a multi-line function from bin/jc by name and write it to a
# temp file that can be sourced. Usage: extract_func <funcname> <outfile>
extract_func() {
  awk -v fn="$1" '
    BEGIN { p = 0 }
    $0 ~ "^"fn"\\(\\) \\{" { p = 1; print; next }
    p == 1 && /^}/ { print; p = 0; next }
    p == 1 { print }
  ' bin/jc > "$2"
}

# Extract a multi-line function from bin/jc that uses compound blocks
# (like case/while). Usage: extract_func_body <funcname> <outfile>
# Reads from '{' to matching '}' using brace counting so nested { } are
# handled correctly. Used for functions where the simple single-line
# awk pattern would mis-terminate on a nested brace.
extract_func_body() {
  awk -v fn="$1" '
    BEGIN { p = 0; depth = 0 }
    $0 ~ "^"fn"\\(.*\\) \\{" { p = 1; depth = 1; print; next }
    p == 1 {
      n = gsub(/\{/, "{"); depth += n
      n = gsub(/\}/, "}"); depth -= n
      print
      if (depth == 0) { p = 0 }
    }
  ' bin/jc > "$2"
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/jc parses without syntax error" {
  run bash -n bin/jc
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/jc defines build_prompt function" {
  run grep -E '^build_prompt\(\)' bin/jc
  assert_success
}

@test "bin/jc defines get_peak_rss_kb function" {
  run grep -E '^get_peak_rss_kb\(\)' bin/jc
  assert_success
}

@test "bin/jc defines print_metrics_line function" {
  run grep -E '^print_metrics_line\(\)' bin/jc
  assert_success
}

@test "bin/jc defines cleanup_metrics function" {
  run grep -E '^cleanup_metrics\(\)' bin/jc
  assert_success
}

@test "bin/jc defines start_rss_sampler function" {
  run grep -E '^start_rss_sampler\(\)' bin/jc
  assert_success
}

@test "bin/jc defines ensure_jcode_config function" {
  run grep -E '^ensure_jcode_config\(\)' bin/jc
  assert_success
}

@test "bin/jc defines is_api_down function" {
  run grep -E '^is_api_down\(\)' bin/jc
  assert_success
}

@test "bin/jc defines run_with_retry function" {
  run grep -E '^run_with_retry\(\)' bin/jc
  assert_success
}

# ── build_prompt (extracted, run in isolation) ────────────────────────
# build_prompt takes a role and uses globals ISSUE + BOUCLE_* vars; it
# returns the prompt text on stdout. We extract the function body and
# invoke it with different ISSUE values to verify each role branch.

@test "build_prompt: triage role mentions boucle:triage marker" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=42; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "issue #42"
  assert_output --partial "boucle:triage"
  rm -f "$TMPF"
}

@test "build_prompt: worker role mentions [skip ci] commit" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=99; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "issue #99"
  assert_output --partial "[skip ci]"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer role references BOUCLE_PREVIEW_URL" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=7; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "issue #7"
  assert_output --partial "BOUCLE_PREVIEW_URL"
  assert_output --partial "boucle:verdict"
  rm -f "$TMPF"
}

@test "build_prompt: e2e role references BOUCLE_LIVE_URL" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=3; source '$TMPF'; build_prompt e2e"
  assert_success
  assert_output --partial "issue #3"
  assert_output --partial "BOUCLE_LIVE_URL"
  assert_output --partial "boucle:verdict"
  rm -f "$TMPF"
}

@test "build_prompt: appends attachment paths when BOUCLE_ISSUE_ATTACHMENTS is set" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=5; BOUCLE_ISSUE_ATTACHMENTS='/tmp/a.png /tmp/b.jpg'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "/tmp/a.png"
  assert_output --partial "/tmp/b.jpg"
  assert_output --partial "Issue attachments"
  rm -f "$TMPF"
}

@test "build_prompt: no attachment footer when BOUCLE_ISSUE_ATTACHMENTS is empty" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=5; unset BOUCLE_ISSUE_ATTACHMENTS; source '$TMPF'; build_prompt triage"
  assert_success
  refute_output --partial "Issue attachments"
  rm -f "$TMPF"
}

# ── build_prompt: prior notes injection (triage) ───────────────────────
# Regression: the triage agent used to re-ask questions the author had
# already answered because prior issue notes were never injected into the
# prompt. BOUCLE_ISSUE_NOTES carries the chronological discussion so the
# agent can incorporate answers instead of re-asking them.

@test "build_prompt: triage includes prior notes when BOUCLE_ISSUE_NOTES is set" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend DESIGN.md'; BOUCLE_ISSUE_NOTES='[tahrir] The Bold Font .ttf is attached
[up-bot] Where is DESIGN.md?
[tahrir] DESIGN.md is at repo root'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "Prior discussion"
  assert_output --partial "The Bold Font .ttf is attached"
  assert_output --partial "DESIGN.md is at repo root"
  rm -f "$TMPF"
}

@test "build_prompt: no prior-notes section when BOUCLE_ISSUE_NOTES is empty" {
  TMPF=$(mktemp)
  extract_func build_prompt "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend DESIGN.md'; unset BOUCLE_ISSUE_NOTES; source '$TMPF'; build_prompt triage"
  assert_success
  refute_output --partial "Prior discussion"
  rm -f "$TMPF"
}

# ── Empty-output guard (silent-failure detection) ─────────────────────
# bin/jc exits 3 when the agent produced NO posted comment AND NO drafted
# comment in its log. This breaks the doctor re-trigger loop (issue #27).
# We can't run the full bin/jc (it calls jcode), but we can verify the
# guard logic by simulating the grep checks it performs.

@test "empty-output guard: log with glab issue note call is NOT a silent failure" {
  # Simulate an agent log that contains a glab issue note call.
  LOG=$(mktemp)
  echo "> triage · minimax-m3
glab issue note 27 --repo up/urgence-palestine.fr --message \"$(cat <<'EOF'
<!-- boucle:triage v=1 -->
## TL;DR
test
## Disposition
READY
EOF
)\"" > "$LOG"
  # The guard greps for glab issue note / glab api POST / boucle:triage marker.
  # This log has both → not a silent failure.
  run grep -qiE 'glab (issue note|api .* -X POST|api .*/notes)' "$LOG"
  assert_success
  run grep -qiE '<!-- boucle:(triage|verdict)' "$LOG"
  assert_success
  rm -f "$LOG"
}

@test "empty-output guard: log with only jcode banner IS a silent failure" {
  # Simulate a dead-run log: only jcode banner output (e.g. `--help` text or
  # usage banner), no glab call, no boucle:triage marker. The guard must
  # detect this. Equivalent to the jcode-header case the old test covered.
  LOG=$(mktemp)
  cat > "$LOG" <<'EOF'
Usage: jcode [OPTIONS] <COMMAND>
Run a single prompt against the configured model provider.

Arguments:
  <PROMPT>  The prompt text to send to the model
EOF
  # Neither grep should match → silent failure.
  run grep -qiE 'glab (issue note|api .* -X POST|api .*/notes)' "$LOG"
  assert_failure
  run grep -qiE '<!-- boucle:(triage|verdict)' "$LOG"
  assert_failure
  rm -f "$LOG"
}

@test "empty-output guard: log with drafted-but-unposted triage marker is NOT silent failure" {
  # Simulate an agent that drafted a comment but hit the output cap before
  # calling glab. The boucle:triage marker is in the log text → the CI's
  # log-scraping fallback can recover it → not a silent failure.
  LOG=$(mktemp)
  echo "> triage · minimax-m3
<!-- boucle:triage v=1 -->
## TL;DR
test
## Disposition
NEEDS-SPLIT" > "$LOG"
  run grep -qiE 'glab (issue note|api .* -X POST|api .*/notes)' "$LOG"
  assert_failure
  run grep -qiE '<!-- boucle:(triage|verdict)' "$LOG"
  assert_success
  rm -f "$LOG"
}

# ── ensure_jcode_config (replaces strip_mcp_for_ci) ──────────────────
# bin/jc no longer mutates a jcode config to remove MCP (lesson #3:
# MCP is disabled via JCODE_RUN_MCP=0 env in CI). Instead, bin/jc
# generates a jcode config.toml on the runner from BOUCLE_LLM_BASE_URL +
# BOUCLE_LLM_API_KEY, so no config file needs to ship to the runner
# (security + provider-agnostic). These tests verify that generate-from-env
# path.

@test "ensure_jcode_config: generates config.toml from BOUCLE_LLM_BASE_URL + BOUCLE_LLM_API_KEY" {
  TMPF=$(mktemp)
  extract_func ensure_jcode_config "$TMPF"
  WORKDIR=$(mktemp -d)
  # shellcheck disable=SC1090
  run bash -c "
    export BOUCLE_LLM_BASE_URL='https://example.com/v1'
    export BOUCLE_LLM_API_KEY='sk-test'
    export JCODE_HOME='$WORKDIR'
    export MODEL='glm-5.2'
    export PROVIDER_PROFILE='boucle'
    source '$TMPF'
    ensure_jcode_config
    cat \"\$JCODE_HOME/config.toml\"
  "
  assert_success
  assert_output --partial 'base_url = "https://example.com/v1"'
  assert_output --partial 'api_key_env = "BOUCLE_LLM_API_KEY"'
  assert_output --partial 'default_model = "glm-5.2"'
  assert_output --partial '[providers.boucle]'
  rm -f "$TMPF"
  rm -rf "$WORKDIR"
}

@test "ensure_jcode_config: errors when no config and no env vars (no base_url)" {
  TMPF=$(mktemp)
  extract_func ensure_jcode_config "$TMPF"
  WORKDIR=$(mktemp -d)
  # shellcheck disable=SC1090
  run bash -c "
    unset BOUCLE_LLM_BASE_URL
    unset BOUCLE_LLM_API_KEY
    export JCODE_HOME='$WORKDIR'
    export HOME='$WORKDIR'
    source '$TMPF'
    ensure_jcode_config
  "
  assert_failure
  rm -f "$TMPF"
  rm -rf "$WORKDIR"
}

@test "ensure_jcode_config: errors when BOUCLE_LLM_BASE_URL is set but BOUCLE_LLM_API_KEY is not" {
  TMPF=$(mktemp)
  extract_func ensure_jcode_config "$TMPF"
  WORKDIR=$(mktemp -d)
  # shellcheck disable=SC1090
  run bash -c "
    export BOUCLE_LLM_BASE_URL='https://example.com/v1'
    unset BOUCLE_LLM_API_KEY
    export JCODE_HOME='$WORKDIR'
    export HOME='$WORKDIR'
    source '$TMPF'
    ensure_jcode_config
  "
  # Half-configured → must NOT write a config, must error out.
  assert_failure
  [ ! -f "$WORKDIR/config.toml" ]
  rm -f "$TMPF"
  rm -rf "$WORKDIR"
}

@test "ensure_jcode_config: respects pre-existing config.toml when no env vars set (local dev)" {
  # Local dev / backward compat: if the runner already has a config.toml
  # (installed via the package), bin/jc MUST use it instead of clobbering.
  TMPF=$(mktemp)
  extract_func ensure_jcode_config "$TMPF"
  WORKDIR=$(mktemp -d)
  cat > "$WORKDIR/config.toml" <<'EOF'
[provider]
default_provider = "legacy"

[providers.legacy]
base_url = "http://localhost:11434/v1"
auth = "bearer"
api_key_env = "OLLAMA_API_KEY"
default_model = "local-model"
EOF
  # shellcheck disable=SC1090
  run bash -c "
    unset BOUCLE_LLM_BASE_URL
    unset BOUCLE_LLM_API_KEY
    export JCODE_HOME='$WORKDIR'
    export HOME='$WORKDIR'
    source '$TMPF'
    ensure_jcode_config
    cat \"\$JCODE_HOME/config.toml\"
  "
  assert_success
  assert_output --partial 'default_provider = "legacy"'
  refute_output --partial '[providers.boucle]'
  # The pre-existing file MUST NOT be overwritten.
  grep -q 'default_model = "local-model"' "$WORKDIR/config.toml"
  rm -f "$TMPF"
  rm -rf "$WORKDIR"
}

# ── Model override (BOUCLE_MODEL_<ROLE>) ──────────────────────────────
# bin/jc lets CI swap models per-role without editing the agent files
# (e.g. BOUCLE_MODEL_TRIAGE=glm-5.2-flash for a cheaper triage).
# The block reads OVERRIDE_VAR="BOUCLE_MODEL_$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')".
# We test by sourcing bin/jc partially (the MODEL-extraction + override block)
# and asserting the right MODEL is set after the override application.

@test "model override: BOUCLE_MODEL_TRIAGE overrides default model from agent file" {
  # Use a temporary agent file so we control the default.
  AGENT_DIR=$(mktemp -d)/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/triage.md" <<'EOF'
---
model: ollama-cloud/glm-5.2
temperature: 0.3
---
triage agent body
EOF
  # Source the relevant block from bin/jc: AGENT_FILE lookup + MODEL extraction
  # + override application. We extract a slice from "AGENT_FILE=" to the
  # temperature line (the override is the last assignment before temperature).
  TMPF=$(mktemp)
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# Extract temperature/ { exit }
  ' bin/jc > "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$AGENT_DIR")'
    AGENT='triage'
    ROLE='triage'
    export BOUCLE_MODEL_TRIAGE='glm-5.2-flash'
    source '$TMPF'
    echo \"MODEL=\$MODEL\"
  "
  assert_success
  assert_output --partial "MODEL=glm-5.2-flash"
  rm -f "$TMPF"
  rm -rf "$(dirname "$AGENT_DIR")"
}

@test "model override: absent BOUCLE_MODEL_TRIAGE keeps default model" {
  AGENT_DIR=$(mktemp -d)/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/triage.md" <<'EOF'
---
model: ollama-cloud/glm-5.2
temperature: 0.3
---
triage agent body
EOF
  TMPF=$(mktemp)
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# Extract temperature/ { exit }
  ' bin/jc > "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$AGENT_DIR")'
    AGENT='triage'
    ROLE='triage'
    unset BOUCLE_MODEL_TRIAGE BOUCLE_MODEL_WORKER BOUCLE_MODEL_REVIEWER BOUCLE_MODEL_E2E
    source '$TMPF'
    echo \"MODEL=\$MODEL\"
  "
  assert_success
  assert_output --partial "MODEL=glm-5.2"
  # The provider prefix 'ollama-cloud/' must have been stripped.
  refute_output --partial 'ollama-cloud/'
  rm -f "$TMPF"
  rm -rf "$(dirname "$AGENT_DIR")"
}

@test "model override: BOUCLE_MODEL_WORKER overrides default worker model" {
  AGENT_DIR=$(mktemp -d)/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/worker.md" <<'EOF'
---
model: ollama-cloud/deepseek-v4-flash
---
worker agent body
EOF
  TMPF=$(mktemp)
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# Extract temperature/ { exit }
  ' bin/jc > "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$AGENT_DIR")'
    AGENT='worker'
    ROLE='worker'
    export BOUCLE_MODEL_WORKER='deepseek-v4-flash-fast'
    source '$TMPF'
    echo \"MODEL=\$MODEL\"
  "
  assert_success
  assert_output --partial "MODEL=deepseek-v4-flash-fast"
  rm -f "$TMPF"
  rm -rf "$(dirname "$AGENT_DIR")"
}

# ── run_with_retry (transient-failure handling) ───────────────────────
# Tests the retry math: max_retries + 1 total attempts, exponential backoff
# up to 60s cap, ±50% jitter. We can't sleep the test for 60s, so we
# override BOUCLE_LLM_RETRY_BASE_DELAY to 1 (so all delays fit under 1s).

@test "run_with_retry: succeeds on first try when command exits 0" {
  TMPF=$(mktemp)
  extract_func run_with_retry "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    export BOUCLE_LLM_MAX_RETRIES=3
    export BOUCLE_LLM_RETRY_BASE_DELAY=1
    source '$TMPF'
    run_with_retry -- true
    echo \"AGENT_EXIT=\$AGENT_EXIT\"
  "
  assert_success
  assert_output --partial "AGENT_EXIT=0"
  rm -f "$TMPF"
}

@test "run_with_retry: exits 130 propagates (SIGINT treated as terminal)" {
  TMPF=$(mktemp)
  extract_func run_with_retry "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    export BOUCLE_LLM_MAX_RETRIES=3
    export BOUCLE_LLM_RETRY_BASE_DELAY=1
    source '$TMPF'
    run_with_retry -- bash -c 'exit 130'
    echo \"AGENT_EXIT=\$AGENT_EXIT\"
  "
  assert_success
  assert_output --partial "AGENT_EXIT=130"
  rm -f "$TMPF"
}

@test "run_with_retry: retries transient failures and gives up after max_retries" {
  TMPF=$(mktemp)
  extract_func run_with_retry "$TMPF"
  COUNTER=$(mktemp)
  : > "$COUNTER"
  # shellcheck disable=SC1090
  run bash -c "
    export BOUCLE_LLM_MAX_RETRIES=2
    export BOUCLE_LLM_RETRY_BASE_DELAY=1
    source '$TMPF'
    run_with_retry -- bash -c 'echo \$((++n)) >> $COUNTER; exit 1'
    echo \"AGENT_EXIT=\$AGENT_EXIT\"
  "
  # Command is wrapped to redirect to COUNTER via a here-string-style escape.
  # bats `run` captures stdout from the bash -c call → must contain AGENT_EXIT=1.
  assert_success
  assert_output --partial "AGENT_EXIT=1"
  rm -f "$TMPF"
}
