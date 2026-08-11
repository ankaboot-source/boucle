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

# build_prompt calls trim_notes, so both must be extracted together or the
# sourced snippet hits "command not found" and silently drops the notes.
# Usage: extract_prompt_funcs <outfile>
extract_prompt_funcs() {
  local tmp tmp2
  tmp=$(mktemp)
  tmp2=$(mktemp)
  extract_func_body trim_notes "$1"
  # filter_mr_discussion embeds a multi-line awk program whose { } braces
  # break extract_func_body's brace counting — use the simple extractor
  # (it stops at the first column-0 `}`; the awk body is indented).
  # Each extractor TRUNCATES its target, so append via tmp + cat.
  extract_func filter_mr_discussion "$tmp2"
  cat "$tmp2" >> "$1"
  rm -f "$tmp2"
  extract_func build_prompt "$tmp"
  cat "$tmp" >> "$1"
  rm -f "$tmp"
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

@test "bin/jc defines is_quota_exhausted function" {
  run grep -E '^is_quota_exhausted\(\)' bin/jc
  assert_success
}

# ── is_quota_exhausted (extracted, run in isolation) ──────────────────
# is_quota_exhausted detects persistent quota errors (HTTP 429/402) in the
# agent log — the provider-down condition (AGENTS.md lesson #30) that
# is_api_down misses because a quota error leaves activity traces.
# Callers gate on a non-zero AGENT_EXIT; the function itself only
# inspects the log.

@test "is_quota_exhausted: HTTP 429 in log is quota-exhausted" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func is_quota_exhausted "$TMPF"
  printf 'HTTP/1.1 429 Too Many Requests\nretrying...\n' > "$LOGF"
  run bash -c "source '$TMPF'; is_quota_exhausted '$LOGF'"
  assert_success
  rm -f "$TMPF" "$LOGF"
}

@test "is_quota_exhausted: weekly usage limit message is quota-exhausted" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func is_quota_exhausted "$TMPF"
  printf 'Error: you have reached your weekly usage limit\n' > "$LOGF"
  run bash -c "source '$TMPF'; is_quota_exhausted '$LOGF'"
  assert_success
  rm -f "$TMPF" "$LOGF"
}

@test "is_quota_exhausted: insufficient credits message is quota-exhausted" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func is_quota_exhausted "$TMPF"
  printf 'insufficient credits\n' > "$LOGF"
  run bash -c "source '$TMPF'; is_quota_exhausted '$LOGF'"
  assert_success
  rm -f "$TMPF" "$LOGF"
}

@test "is_quota_exhausted: clean activity log is not quota-exhausted" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func is_quota_exhausted "$TMPF"
  printf 'glab issue note 5 --message "done"\nread src/app.ts\n' > "$LOGF"
  run bash -c "source '$TMPF'; is_quota_exhausted '$LOGF'"
  assert_failure
  rm -f "$TMPF" "$LOGF"
}

@test "is_quota_exhausted: empty log is not quota-exhausted" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func is_quota_exhausted "$TMPF"
  : > "$LOGF"
  run bash -c "source '$TMPF'; is_quota_exhausted '$LOGF'"
  assert_failure
  rm -f "$TMPF" "$LOGF"
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
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "issue #42"
  assert_output --partial "boucle:triage"
  rm -f "$TMPF"
}

@test "build_prompt: worker role mentions [skip ci] commit" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=99; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "issue #99"
  assert_output --partial "[skip ci]"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer role references BOUCLE_PREVIEW_URL" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "issue #7"
  assert_output --partial "BOUCLE_PREVIEW_URL"
  assert_output --partial "boucle:verdict"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer prompt requires verifying each human amendment is addressed" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; BOUCLE_REVIEWER_FEEDBACK='[tahrir] no letter-based logos'; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "Prior MR discussion"
  assert_output --partial "human comments AMEND the spec"
  assert_output --partial "enumerate every human amendment"
  assert_output --partial "any human amendment NOT addressed is a FAIL"
  assert_output --partial "[tahrir] no letter-based logos"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer prompt includes issue notes when BOUCLE_ISSUE_NOTES is set" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; BOUCLE_ISSUE_NOTES='[tahrir] embed Instagram 3 latest posts'; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "Prior issue discussion"
  assert_output --partial "human comments here AMEND the spec"
  assert_output --partial "[tahrir] embed Instagram 3 latest posts"
  rm -f "$TMPF"
}

@test "build_prompt: e2e role references BOUCLE_LIVE_URL" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=3; source '$TMPF'; build_prompt e2e"
  assert_success
  assert_output --partial "issue #3"
  assert_output --partial "BOUCLE_LIVE_URL"
  assert_output --partial "boucle:verdict"
  rm -f "$TMPF"
}

@test "build_prompt: appends attachment paths when BOUCLE_ISSUE_ATTACHMENTS is set" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=5; BOUCLE_ISSUE_ATTACHMENTS='/tmp/a.png /tmp/b.jpg'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "/tmp/a.png"
  assert_output --partial "/tmp/b.jpg"
  assert_output --partial "Issue attachments"
  rm -f "$TMPF"
}

@test "build_prompt: no attachment footer when BOUCLE_ISSUE_ATTACHMENTS is empty" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
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
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend the README'; BOUCLE_ISSUE_NOTES='[human] The Bold Font .ttf is attached
[up-bot] Where is the README?
[human] README.md is at repo root'; source '$TMPF'; build_prompt triage"
  assert_success
  assert_output --partial "Prior discussion"
  assert_output --partial "The Bold Font .ttf is attached"
  assert_output --partial "README.md is at repo root"
  rm -f "$TMPF"
}

@test "build_prompt: no prior-notes section when BOUCLE_ISSUE_NOTES is empty" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=27; BOUCLE_ISSUE_BODY='Amend the README'; unset BOUCLE_ISSUE_NOTES; source '$TMPF'; build_prompt triage"
  assert_success
  refute_output --partial "Prior discussion"
  rm -f "$TMPF"
}

# ── trim_notes (token-cost control) ───────────────────────────────────
# Injected note threads are re-billed as input on every iteration: the
# agents themselves write the bulkiest entries (triage analyses, reviewer
# verdicts). trim_notes caps each note, never dropping one — dropping the
# oldest would discard the early preservation instructions the worker
# relies on (lib/boucle-ci/worker.sh).

@test "trim_notes: short notes pass through unchanged" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  run bash -c "source '$TMPF'; trim_notes t '[human] short note'"
  assert_success
  assert_output --partial "[human] short note"
  refute_output --partial "elided by boucle"
}

@test "trim_notes: a note longer than the cap is truncated with an elision marker" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'x%.0s' $(seq 1 3000))
  run bash -c "source '$TMPF'; BOUCLE_MAX_NOTE_CHARS=100 trim_notes t '[bot] $BIG'" 2> /dev/null
  assert_success
  assert_output --partial "elided by boucle"
  # Output must be far smaller than the 3000-char input.
  [ "${#output}" -lt 400 ]
  rm -f "$TMPF"
}

@test "trim_notes: EVERY note survives — the oldest is never dropped" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'y%.0s' $(seq 1 2000))
  # Oldest note carries a preservation instruction; later notes are bulky.
  run bash -c "source '$TMPF'; BOUCLE_MAX_NOTE_CHARS=50 trim_notes t '[human] KEEP-THIS-URL https://example.org/video
[bot] $BIG
[bot] $BIG'" 2> /dev/null
  assert_success
  assert_output --partial "KEEP-THIS-URL"
  rm -f "$TMPF"
}

@test "trim_notes: multi-line note bodies stay attached to their author line" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  run bash -c "source '$TMPF'; BOUCLE_MAX_NOTE_CHARS=5000 trim_notes t '[human] line one
line two continues the same note
[bot] second note'" 2> /dev/null
  assert_success
  assert_output --partial "line two continues the same note"
  assert_output --partial "[bot] second note"
  rm -f "$TMPF"
}

@test "trim_notes: BOUCLE_MAX_NOTE_CHARS=0 disables trimming (escape hatch)" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'z%.0s' $(seq 1 3000))
  run bash -c "source '$TMPF'; BOUCLE_MAX_NOTE_CHARS=0 trim_notes t '[bot] $BIG'" 2> /dev/null
  assert_success
  refute_output --partial "elided by boucle"
  [ "${#output}" -gt 2900 ]
  rm -f "$TMPF"
}

@test "trim_notes: empty input produces empty output" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  run bash -c "source '$TMPF'; trim_notes t ''" 2> /dev/null
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

@test "trim_notes: reports before/after sizes on stderr for CI measurement" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'w%.0s' $(seq 1 3000))
  run bash -c "source '$TMPF'; BOUCLE_MAX_NOTE_CHARS=100 trim_notes issue_notes '[bot] $BIG' > /dev/null"
  assert_success
  assert_output --partial "[boucle:prompt]"
  assert_output --partial "issue_notes"
  assert_output --partial "chars_before="
  assert_output --partial "chars_after="
  rm -f "$TMPF"
}

@test "build_prompt: worker trims bulky prior notes but keeps the earliest instruction" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  BIG=$(printf 'q%.0s' $(seq 1 4000))
  run bash -c "ISSUE=42; BOUCLE_MAX_NOTE_CHARS=80; BOUCLE_ISSUE_BODY='Build the page'; BOUCLE_ISSUE_NOTES='[human] Use the EXACT video URL https://example.org/v
[bot] $BIG'; source '$TMPF'; build_prompt worker" 2> /dev/null
  assert_success
  assert_output --partial "Use the EXACT video URL"
  assert_output --partial "elided by boucle"
  refute_output --partial "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
  rm -f "$TMPF"
}

# ── Thread-level prompt budget (#45) ──────────────────────────────────
# trim_notes bounds the worst NOTE; it does not bound the assembled PROMPT.
# The ceiling degrades bot notes only — human comments amend the spec and
# must reach the agent in full at every setting, and no note is ever
# dropped outright (same invariant trim_notes protects).

# build_prompt_within_budget calls build_prompt, which calls trim_notes.
# All three plus the ladder must be extracted together.
extract_budget_funcs() {
  local tmp
  tmp=$(mktemp)
  extract_prompt_funcs "$1"
  echo 'BOT_NOTE_LADDER="750 300 120"' >> "$1"
  extract_func build_prompt_within_budget "$tmp"
  cat "$tmp" >> "$1"
  extract_func report_prompt_size "$tmp"
  cat "$tmp" >> "$1"
  rm -f "$tmp"
}

@test "prompt budget: disabled by default — the prompt is byte-identical" {
  TMPF=$(mktemp)
  extract_budget_funcs "$TMPF"
  BIG=$(printf 'z%.0s' $(seq 1 4000))
  ENV="ISSUE=42; BOUCLE_BOT_USERNAME=up-bot; BOUCLE_ISSUE_BODY='Build it'; BOUCLE_ISSUE_NOTES='[human] keep me
[up-bot] $BIG'"
  plain=$(bash -c "$ENV; source '$TMPF'; build_prompt worker" 2> /dev/null)
  budgeted=$(bash -c "$ENV; source '$TMPF'; build_prompt_within_budget worker" 2> /dev/null)
  [ "$plain" = "$budgeted" ]
  rm -f "$TMPF"
}

@test "prompt budget: over the ceiling, human comments survive in full" {
  TMPF=$(mktemp)
  extract_budget_funcs "$TMPF"
  BIG=$(printf 'z%.0s' $(seq 1 6000))
  HUMAN="KEEP-THIS-AMENDMENT use https://example.org/exact-video and do not substitute it"
  run bash -c "ISSUE=42; BOUCLE_BOT_USERNAME=up-bot; BOUCLE_MAX_PROMPT_CHARS=2000; BOUCLE_ISSUE_BODY='Build it'; BOUCLE_ISSUE_NOTES='[human] $HUMAN
[up-bot] $BIG
[up-bot] $BIG'; source '$TMPF'; build_prompt_within_budget worker" 2> /dev/null
  assert_success
  # The whole human amendment, not a truncated head of it.
  assert_output --partial "$HUMAN"
  # Bot notes were squeezed instead.
  assert_output --partial "elided by boucle"
  rm -f "$TMPF"
}

@test "prompt budget: no note disappears under an aggressive ceiling" {
  TMPF=$(mktemp)
  extract_budget_funcs "$TMPF"
  BIG=$(printf 'z%.0s' $(seq 1 6000))
  run bash -c "ISSUE=42; BOUCLE_BOT_USERNAME=up-bot; BOUCLE_MAX_PROMPT_CHARS=500; BOUCLE_ISSUE_BODY='Build it'; BOUCLE_ISSUE_NOTES='[human] OLDEST-INSTRUCTION
[up-bot] FIRST-BOT-NOTE $BIG
[up-bot] SECOND-BOT-NOTE $BIG'; source '$TMPF'; build_prompt_within_budget worker" 2> /dev/null
  assert_success
  assert_output --partial "OLDEST-INSTRUCTION"
  assert_output --partial "FIRST-BOT-NOTE"
  assert_output --partial "SECOND-BOT-NOTE"
  rm -f "$TMPF"
}

@test "prompt budget: bot cap tightens bot notes only, humans keep the global cap" {
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'h%.0s' $(seq 1 600))
  run bash -c "source '$TMPF'; BOUCLE_BOT_USERNAME=up-bot; BOUCLE_MAX_NOTE_CHARS=1000; BOUCLE_BOT_NOTE_CHARS=50 trim_notes t '[human] $BIG
[up-bot] $BIG'" 2> /dev/null
  assert_success
  # The 600-char human note is under the 1000 global cap → untouched.
  assert_output --partial "$BIG"
  # The bot note is over the 50-char bot cap → elided.
  assert_output --partial "elided by boucle (cap=50)"
  rm -f "$TMPF"
}

@test "report_prompt_size: emits a total line with size and estimated tokens" {
  TMPF=$(mktemp)
  extract_budget_funcs "$TMPF"
  run bash -c "ITERATION=2; source '$TMPF'; report_prompt_size worker 'hello world' 2>&1"
  assert_success
  assert_output --partial "[boucle:prompt] total"
  assert_output --partial "role=worker"
  assert_output --partial "total_chars=11"
  assert_output --partial "est_tokens="
  rm -f "$TMPF"
}

@test "report_prompt_size: warns above BOUCLE_PROMPT_WARN_CHARS without altering anything" {
  TMPF=$(mktemp)
  extract_budget_funcs "$TMPF"
  run bash -c "ITERATION=1; BOUCLE_PROMPT_WARN_CHARS=5; source '$TMPF'; report_prompt_size worker 'well over five chars' 2>&1"
  assert_success
  assert_output --partial "WARN: assembled prompt is"
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
glab issue note 27 --repo up/consumer-test --message \"$(cat <<'EOF'
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

# ── Image path stripping (lesson: text-only model 400s on image input) ─
# When bin/describe-images has described the attachments as TEXT, bin/jc
# strips image extensions (png/jpg/...) from BOUCLE_ISSUE_ATTACHMENTS and
# BOUCLE_MR_ATTACHMENTS so the agent CANNOT Read the raw binaries (a
# text-only model like deepseek-v4-flash 400s on image input, killing the
# worker run with zero commits — consumer 2026-08, issue #55: 3 iterations
# shipped nothing because the agent kept Reading the PNGs despite the
# prompt instruction).
# SVG is EXCLUDED from stripping: it is text/XML, not a raster image, so
# the agent must be able to Read and embed its markup (consumer issue #36:
# shared SVG icons were described + stripped, forcing the triage preview
# to render placeholder icons instead of the real assets).
@test "strip_image_paths: strips image extensions when descriptions exist (SVG kept)" {
  run bash -c '
    strip_image_paths() {
      local paths="${1:-}"
      local kept=""
      local p
      for p in $paths; do
        case "$p" in
          *.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.bmp)
            : ;;
          *.svg)
            kept="$kept $p" ;;
          *)
            kept="$kept $p" ;;
        esac
      done
      echo "$kept" | sed "s/^ //"
    }
    strip_image_paths "/x/1_hero_full.png /x/2_plan.pdf /x/3_hero_without_object.png /x/mockup.jpg /x/archive.zip /x/4_icon.svg"
  '
  assert_success
  assert_output "/x/2_plan.pdf /x/archive.zip /x/4_icon.svg"
}

@test "strip_image_paths: keeps all paths when no descriptions (no-op)" {
  run bash -c '
    # No BOUCLE_IMAGE_DESCRIPTIONS → the strip block is not executed, so
    # the attachment variables pass through untouched. This mirrors the
    # `if [ -n "$BOUCLE_IMAGE_DESCRIPTIONS" ]` guard in bin/jc.
    strip_image_paths() {
      local paths="${1:-}"
      local kept=""
      local p
      for p in $paths; do
        case "$p" in
          *.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.bmp)
            : ;;
          *.svg)
            kept="$kept $p" ;;
          *)
            kept="$kept $p" ;;
        esac
      done
      echo "$kept" | sed "s/^ //"
    }
    # Descriptions empty → block skipped → full list kept.
    BOUCLE_IMAGE_DESCRIPTIONS=""
    if [ -z "$BOUCLE_IMAGE_DESCRIPTIONS" ]; then
      echo "/x/a.png /x/b.pdf /x/c.svg"
    else
      strip_image_paths "/x/a.png /x/b.pdf /x/c.svg"
    fi
  '
  assert_success
  assert_output "/x/a.png /x/b.pdf /x/c.svg"
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
  AGENT_DIR=$(mktemp -d)/.jcode/agents
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
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
    AGENT='triage'
    ROLE='triage'
    export BOUCLE_MODEL_TRIAGE='glm-5.2-flash'
    source '$TMPF'
    echo \"MODEL=\$MODEL\"
  "
  assert_success
  assert_output --partial "MODEL=glm-5.2-flash"
  rm -f "$TMPF"
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

@test "model override: absent BOUCLE_MODEL_TRIAGE keeps default model" {
  AGENT_DIR=$(mktemp -d)/.jcode/agents
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
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
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
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

@test "model override: BOUCLE_MODEL_WORKER overrides default worker model" {
  AGENT_DIR=$(mktemp -d)/.jcode/agents
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
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
    AGENT='worker'
    ROLE='worker'
    export BOUCLE_MODEL_WORKER='deepseek-v4-flash-fast'
    source '$TMPF'
    echo \"MODEL=\$MODEL\"
  "
  assert_success
  assert_output --partial "MODEL=deepseek-v4-flash-fast"
  rm -f "$TMPF"
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

# ── Reasoning effort (frontmatter → JCODE_OPENAI_REASONING_EFFORT) ─────
# bin/jc reads reasoning_effort from the agent file frontmatter and exports
# it as JCODE_OPENAI_REASONING_EFFORT for jcode v0.73.0+ (sent verbatim as
# reasoning_effort in the OpenAI request body). The value lives in the agent
# file — worker.md/reviewer.md ship deepseek-v4-flash:0731 with max.

@test "reasoning effort: frontmatter value extracted" {
  AGENT_DIR=$(mktemp -d)/.jcode/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/worker.md" <<'EOF'
---
model: ollama-cloud/deepseek-v4-flash:0731
reasoning_effort: max
---
worker agent body
EOF
  TMPF=$(mktemp)
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# ── Provider fallback config/ { exit }
  ' bin/jc > "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
    AGENT='worker'
    ROLE='worker'
    BOUCLE_WORKSPACE='$(dirname "$(dirname "$AGENT_DIR")")'
    source '$TMPF'
    echo \"REASONING_EFFORT=\$REASONING_EFFORT\"
  "
  assert_success
  assert_output --partial "REASONING_EFFORT=max"
  rm -f "$TMPF"
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

@test "reasoning effort: absent frontmatter key leaves empty (jcode default)" {
  AGENT_DIR=$(mktemp -d)/.jcode/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/triage.md" <<'EOF'
---
model: ollama-cloud/glm-5.2
temperature: 0.5
---
triage agent body
EOF
  TMPF=$(mktemp)
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# ── Provider fallback config/ { exit }
  ' bin/jc > "$TMPF"
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
    AGENT='triage'
    ROLE='triage'
    BOUCLE_WORKSPACE='$(dirname "$(dirname "$AGENT_DIR")")'
    source '$TMPF'
    echo \"REASONING_EFFORT=[\$REASONING_EFFORT]\"
  "
  assert_success
  assert_output --partial "REASONING_EFFORT=[]"
  rm -f "$TMPF"
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

@test "reasoning effort: exported as JCODE_OPENAI_REASONING_EFFORT" {
  AGENT_DIR=$(mktemp -d)/.jcode/agents
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/worker.md" <<'EOF'
---
model: ollama-cloud/deepseek-v4-flash:0731
reasoning_effort: max
---
worker agent body
EOF
  TMPF=$(mktemp)
  # Slice through the export block (ends before Do-Not-Disturb).
  awk '
    /^AGENT_FILE=""/ { p = 1 }
    p { print }
    p && /^# ── Do-Not-Disturb/ { exit }
  ' bin/jc > "$TMPF"
  JCODE_HOME=$(mktemp -d)
  # shellcheck disable=SC1090
  run bash -c "
    CI_PROJECT_DIR='$(dirname "$(dirname "$AGENT_DIR")")'
    AGENT='worker'
    ROLE='worker'
    PROVIDER_PROFILE='test-profile'
    BOUCLE_WORKSPACE='$(dirname "$(dirname "$AGENT_DIR")")'
    export BOUCLE_LLM_BASE_URL='https://llm.test/v1'
    export BOUCLE_LLM_API_KEY='dummy'
    export JCODE_HOME='$JCODE_HOME'
    source '$TMPF'
    echo \"JCODE_OPENAI_REASONING_EFFORT=\$JCODE_OPENAI_REASONING_EFFORT\"
  "
  assert_success
  assert_output --partial "JCODE_OPENAI_REASONING_EFFORT=max"
  rm -f "$TMPF"
  rm -rf "$JCODE_HOME"
  rm -rf "$(dirname "$(dirname "$AGENT_DIR")")"
}

@test "reasoning effort: every shipped agent declares one, and max stays deepseek-only" {
  # The contract: every shipped agent file declares reasoning_effort, because
  # jcode's own default is "low" and would silently apply to agents that
  # never asked for it.
  #
  # "max" is part of jcode's DEEPSEEK ladder (bin/jc:270). The value is sent
  # verbatim in the request body, so putting it on a non-deepseek model risks
  # a 400 that takes the role out entirely — or a silent ignore, which reads
  # as "effort changes nothing" when nothing was ever sent.
  for agent in triage worker reviewer e2e; do
    model_line=$(awk '/^model:/{sub(/^model:[[:space:]]*/,""); print; exit}' ".jcode/agents/$agent.md")
    [[ -n "$model_line" ]]
    effort_line=$(awk '/^reasoning_effort:/{sub(/^reasoning_effort:[[:space:]]*/,""); print; exit}' ".jcode/agents/$agent.md")
    [[ -n "$effort_line" ]]
    case "$effort_line" in
      none | minimal | low | medium | high | xhigh | max | off) ;;
      *) echo "agent $agent declares an effort outside jcode's ladder: $effort_line"; false ;;
    esac
    if [[ "$model_line" != *"deepseek"* ]]; then
      [[ "$effort_line" != "max" ]] || {
        echo "agent $agent is not deepseek but declares max"
        false
      }
    fi
  done
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

# ── Agent log secret scrub (#33) ──────────────────────────────────────
# The log leaves the runner as a CI artifact. Section 2 of bin/jc removes
# CLOUDFLARE_API_TOKEN from the agent's ENVIRONMENT — a different
# guarantee that does not cover log CONTENT. The LLM key cannot be unset
# at all (jcode reads it via api_key_env), so this redaction is the only
# barrier between it and the artifact.

extract_scrub() {
  extract_func_body scrub_agent_log "$1"
}

@test "scrub: the LLM API key value never survives in the log" {
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_scrub "$TMPF"
  printf 'calling provider with key supersecretvalue123 now\n' > "$LOG"
  run bash -c "BOUCLE_LLM_API_KEY=supersecretvalue123 SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log '$LOG'\"; cat '$LOG'"
  assert_success
  refute_output --partial "supersecretvalue123"
  assert_output --partial "[REDACTED:BOUCLE_LLM_API_KEY]"
  rm -f "$TMPF" "$LOG"
}

@test "scrub: forge token shapes are redacted whatever their source" {
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_scrub "$TMPF"
  printf 'glpat-AbCdEf1234567890 ghp_ZZZZ1111YYYY2222 sk-abc123DEF456ghi\n' > "$LOG"
  run bash -c "SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log '$LOG'\"; cat '$LOG'"
  assert_success
  refute_output --partial "glpat-AbCdEf1234567890"
  refute_output --partial "ghp_ZZZZ1111YYYY2222"
  refute_output --partial "sk-abc123DEF456ghi"
  rm -f "$TMPF" "$LOG"
}

@test "scrub: a key containing regex metacharacters is still redacted" {
  # Literal replacement, not regex — a key like 'a+b.c*d' must not be
  # treated as a pattern, or it silently fails to match itself.
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_scrub "$TMPF"
  printf 'key=a+b.c*d[ef]g here\n' > "$LOG"
  run bash -c "BOUCLE_LLM_API_KEY='a+b.c*d[ef]g' SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log '$LOG'\"; cat '$LOG'"
  assert_success
  refute_output --partial "a+b.c*d[ef]g"
  rm -f "$TMPF" "$LOG"
}

@test "scrub: ordinary agent output is left intact" {
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_scrub "$TMPF"
  printf 'wrote src/pages/index.astro and ran npm run build\n' > "$LOG"
  run bash -c "BOUCLE_LLM_API_KEY=supersecretvalue123 SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log '$LOG'\"; cat '$LOG'"
  assert_success
  assert_output --partial "wrote src/pages/index.astro and ran npm run build"
  rm -f "$TMPF" "$LOG"
}

@test "scrub: a short secret value is not redacted (would shred the log)" {
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_scrub "$TMPF"
  printf 'the build is ok and the value is ok\n' > "$LOG"
  run bash -c "BOUCLE_LLM_API_KEY=ok SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log '$LOG'\"; cat '$LOG'"
  assert_success
  assert_output --partial "the build is ok and the value is ok"
  rm -f "$TMPF" "$LOG"
}

@test "scrub: a missing log file is a no-op, never an error" {
  TMPF=$(mktemp)
  extract_scrub "$TMPF"
  run bash -c "SCRUBBED_CF_TOKEN='' bash -c \"source '$TMPF'; scrub_agent_log /nonexistent/path.log\""
  assert_success
  rm -f "$TMPF"
}

@test "scrub: runs before every exit path, not only on success" {
  # A failed run is exactly the one whose transcript gets read. If the
  # scrub sat after the exit-3/exit-4 guards it would protect nothing.
  scrub_line=$(grep -n '^scrub_agent_log "\$AGENT_LOG"' bin/jc | cut -d: -f1)
  guard_line=$(grep -n '5a. Empty-output guard' bin/jc | cut -d: -f1)
  [ -n "$scrub_line" ]
  [ -n "$guard_line" ]
  [ "$scrub_line" -lt "$guard_line" ]
}

# ── Anti-anchored re-review (#43) ─────────────────────────────────────
# On iteration N the reviewer reads its own N-1 verdict, which invites
# ratification (re-endorsing the prior reasoning, missing a regression the
# fix introduced) and tunnel vision (re-checking only what failed before).

extract_anchor() {
  extract_func_body filter_mr_discussion "$1"
}

# A realistic MR thread: a human amendment, a bot verdict, a bot status note.
anchor_fixture() {
  printf '%s' '[human] AMENDMENT-KEEP-ME use https://example.org/v — do not substitute
[up-bot] <!-- boucle:verdict v=1 role=reviewer sha=abc -->
VERDICT: FAIL
- [x] Header renders — verified via curl
- [ ] Footer link present — RATIONALE-ANCHOR relative path 404s
[up-bot] Master advanced since this branch was created.'
}

@test "anchoring: a prior verdict is reduced to its unmet criteria" {
  TMPF=$(mktemp)
  extract_anchor "$TMPF"
  run bash -c "BOUCLE_BOT_USERNAME=up-bot; source '$TMPF'; filter_mr_discussion \"\$(cat)\"" <<< "$(anchor_fixture)"
  assert_success
  assert_output --partial "VERDICT: FAIL"
  assert_output --partial "- [ ] Footer link present"
  # The rationale is the anchor — it must not survive.
  refute_output --partial "RATIONALE-ANCHOR"
  # Met criteria are not re-listed either: the reviewer re-checks all of
  # them from state.md, it is not handed a shortlist.
  refute_output --partial "- [x] Header renders"
  rm -f "$TMPF"
}

@test "anchoring: there is no way to configure it back to a worse behaviour" {
  # Keeping the rationale re-anchors the reviewer; withholding the criterion
  # lets the verdict flip-flop. Neither is offered.
  run bash -c "grep -c BOUCLE_REVIEW_ANCHORING bin/jc || true"
  assert_output "0"
  run bash -c "grep -c BOUCLE_REVIEW_ANCHORING LOOP.md || true"
  assert_output "0"
}

@test "anchoring: human comments reach the reviewer in full" {
  # Human comments amend the spec and outrank the frozen criteria in
  # state.md. Filtering one would be a spec regression, not a saving.
  TMPF=$(mktemp)
  extract_anchor "$TMPF"
  run bash -c "BOUCLE_BOT_USERNAME=up-bot; source '$TMPF'; filter_mr_discussion \"\$1\"" _ "$(anchor_fixture)"
  assert_success
  assert_output --partial "AMENDMENT-KEEP-ME use https://example.org/v — do not substitute"
  rm -f "$TMPF"
}

@test "anchoring: bot notes that are not verdicts pass through untouched" {
  TMPF=$(mktemp)
  extract_anchor "$TMPF"
  run bash -c "BOUCLE_BOT_USERNAME=up-bot; source '$TMPF'; filter_mr_discussion \"\$(cat)\"" <<< "$(anchor_fixture)"
  assert_success
  assert_output --partial "Master advanced since this branch was created."
  rm -f "$TMPF"
}

@test "anchoring: the worker still receives full verdict reasoning" {
  # The worker must act on a FAIL, so it needs the why. Only the reviewer
  # branch of build_prompt is filtered.
  run bash -c "awk '/^    worker\\)/,/^    reviewer\\)/' bin/jc | grep -c filter_mr_discussion || true"
  assert_output "0"
}

@test "anchoring: the reviewer prompt requires re-checking every criterion" {
  run grep -q "Re-check EVERY acceptance criterion on every iteration" .jcode/agents/reviewer.md
  assert_success
}

# ── Pre-flight provider probe (#42) ───────────────────────────────────
# The reactive path (section 5b) discovers an exhausted quota only after
# provisioning a runner, cloning, building the prompt and burning the retry
# budget. With BOUCLE_MAX_PARALLEL_ISSUES=5 that waste is multiplied by five.
# The probe asks first. It never replaces 5b — a quota can die mid-run.

extract_probe() {
  extract_func_body probe_provider "$1"
}

# Shadow curl so classification is tested hermetically, with no server.
probe_with_code() {
  local code="$1" tmpf="$2"
  bash -c "
    source '$tmpf'
    curl() { echo '$code'; }
    probe_provider 'https://api.example.com/v1' 'key123'
  "
}

@test "probe: 429 and 402 are quota exhaustion" {
  TMPF=$(mktemp); extract_probe "$TMPF"
  [ "$(probe_with_code 429 "$TMPF")" = "quota" ]
  [ "$(probe_with_code 402 "$TMPF")" = "quota" ]
  rm -f "$TMPF"
}

@test "probe: 5xx is provider-down" {
  TMPF=$(mktemp); extract_probe "$TMPF"
  [ "$(probe_with_code 500 "$TMPF")" = "down" ]
  [ "$(probe_with_code 503 "$TMPF")" = "down" ]
  rm -f "$TMPF"
}

@test "probe: 401 and 403 are an auth problem, not a quota one" {
  TMPF=$(mktemp); extract_probe "$TMPF"
  [ "$(probe_with_code 401 "$TMPF")" = "auth" ]
  [ "$(probe_with_code 403 "$TMPF")" = "auth" ]
  rm -f "$TMPF"
}

@test "probe: 200 is ok" {
  TMPF=$(mktemp); extract_probe "$TMPF"
  [ "$(probe_with_code 200 "$TMPF")" = "ok" ]
  rm -f "$TMPF"
}

@test "probe: an unreachable endpoint is ok, not down (fail-open)" {
  # A runner with flaky egress must not stop the loop. The probe is an
  # optimisation; it must never become a new failure mode.
  TMPF=$(mktemp); extract_probe "$TMPF"
  [ "$(probe_with_code 000 "$TMPF")" = "ok" ]
  run bash -c "source '$TMPF'; probe_provider 'http://127.0.0.1:9/v1' 'key123'"
  assert_success
  assert_output "ok"
  rm -f "$TMPF"
}

@test "probe: no base URL or no key configured is ok (nothing to probe)" {
  TMPF=$(mktemp); extract_probe "$TMPF"
  run bash -c "source '$TMPF'; probe_provider '' 'key123'"
  assert_output "ok"
  run bash -c "source '$TMPF'; probe_provider 'https://api.example.com/v1' ''"
  assert_output "ok"
  rm -f "$TMPF"
}

@test "probe: results are cached within the TTL so parallel jobs probe once" {
  TMPF=$(mktemp)
  extract_func_body probe_provider "$TMPF"
  extract_func_body probe_cached "$TMPF.c"
  cat "$TMPF.c" >> "$TMPF"
  CACHEDIR=$(mktemp -d)
  # First call records 429; a second call with a would-be-200 curl must
  # still read the cached value.
  run bash -c "
    export TMPDIR='$CACHEDIR'
    source '$TMPF'
    curl() { echo 429; }
    probe_cached testprov 'https://api.example.com/v1' 'key123'
    curl() { echo 200; }
    probe_cached testprov 'https://api.example.com/v1' 'key123'
  "
  assert_success
  assert_line --index 0 "quota"
  assert_line --index 1 "quota"
  rm -rf "$TMPF" "$TMPF.c" "$CACHEDIR"
}

@test "probe: BOUCLE_QUOTA_PROBE=false removes the probe entirely" {
  run grep -q 'if \[ "${BOUCLE_QUOTA_PROBE:-true}" = "true" \]' bin/jc
  assert_success
}

@test "probe: exits 4 (provider-down contract) rather than starting the agent" {
  # Starting the agent when no provider can answer burns a runner to
  # produce nothing. Exit 4 is the established contract: CI posts a
  # diagnostic and escalates instead of blaming the step budget.
  run bash -c "awk '/4c. Pre-flight provider probe/,/^fi$/' bin/jc | grep -cE '^ +exit 4$'"
  assert_output "2"
}

@test "probe: the reactive fallback path is still present" {
  # A quota can be exhausted mid-run; only section 5b catches that.
  run grep -q "5b. Provider fallback" bin/jc
  assert_success
}

# ── Evidence pack (build-evidence-pack integration) ──────────────────
# bin/build-evidence-pack produces .evidence-pack.md (charter docs at the
# base branch + diff brief). bin/jc loads it (3c) and injects it into the
# reviewer prompt. Recovered from the orphaned feat/reviewer-obligations
# branch (commits ddc9594/dc99c99 — boucle dogfooding) that referenced the
# script from reviewer.sh without ever committing it.

@test "jc loads the evidence pack file when present" {
  run bash -c '
    STATE_DIR=$(mktemp -d)
    printf "## DESIGN.md (main)\n- sharp corners\n" > "$STATE_DIR/.evidence-pack.md"
    EVIDENCE_PACK_FILE="$STATE_DIR/.evidence-pack.md"
    BOUCLE_EVIDENCE_PACK=""
    if [ -f "$EVIDENCE_PACK_FILE" ]; then
      BOUCLE_EVIDENCE_PACK="$(cat "$EVIDENCE_PACK_FILE")"
    fi
    echo "$BOUCLE_EVIDENCE_PACK"
    rm -rf "$STATE_DIR"
  '
  assert_success
  assert_output --partial "sharp corners"
}

@test "jc leaves BOUCLE_EVIDENCE_PACK empty when no evidence pack file" {
  run bash -c '
    STATE_DIR=$(mktemp -d)
    EVIDENCE_PACK_FILE="$STATE_DIR/.evidence-pack.md"
    BOUCLE_EVIDENCE_PACK=""
    if [ -f "$EVIDENCE_PACK_FILE" ]; then
      BOUCLE_EVIDENCE_PACK="$(cat "$EVIDENCE_PACK_FILE")"
    fi
    echo "pack=[$BOUCLE_EVIDENCE_PACK]"
    rm -rf "$STATE_DIR"
  '
  assert_success
  assert_output "pack=[]"
}

@test "build-evidence-pack script is present and executable" {
  run bash -n bin/build-evidence-pack
  assert_success
  [ -x bin/build-evidence-pack ]
}

@test "reviewer.sh references build-evidence-pack (dangling ref is now satisfied)" {
  run grep -q 'build-evidence-pack' lib/boucle-ci/reviewer.sh
  assert_success
}


# ── Evidence pack (build-evidence-pack integration) ──────────────────
# bin/build-evidence-pack produces .evidence-pack.md (charter docs at the
# base branch + diff brief). bin/jc loads it (3c) and injects it into the
