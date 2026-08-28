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

# build_prompt calls trim_notes, forge_aware_prompt (bin/jc) and
# boucle_review_mode (lib/boucle.sh), so all must be extracted together
# or the sourced snippet hits "command not found" and silently drops
# output. boucle_review_mode is stubbed (it just echoes BOUCLE_REVIEW_MODE)
# because the extractor reads bin/jc, not lib/boucle.sh.
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
  extract_func forge_aware_prompt "$tmp2"
  cat "$tmp2" >> "$1"
  rm -f "$tmp2"
  # select_lessons / select_default_lessons are called by build_prompt's
  # lessons injection. Without them the sourced snippet hits "command not
  # found" and drops the whole block silently — no lessons, no error.
  extract_func select_lessons "$tmp2"
  cat "$tmp2" >> "$1"
  rm -f "$tmp2"
  extract_func select_default_lessons "$tmp2"
  cat "$tmp2" >> "$1"
  rm -f "$tmp2"
  extract_func build_prompt "$tmp"
  cat "$tmp" >> "$1"
  rm -f "$tmp"
  # Stub: boucle_review_mode lives in lib/boucle.sh, not bin/jc.
  printf 'boucle_review_mode() { echo "${BOUCLE_REVIEW_MODE:-preview}"; }\n' >> "$1"
}

# Extract the resolution block with a test-controlled ENGINE_DIR (the
# real one is derived from $0, which points at bash inside `run`).
extract_agent_resolution() { # $1 = outfile, $2 = engine dir, $3 = end regex
  awk -v stop="${3:-^# Extract model}" '
    /^ENGINE_DIR=/ { p = 1 }
    p { print }
    p && $0 ~ stop { exit }
  ' bin/jc \
    | sed "s|^ENGINE_DIR=.*|ENGINE_DIR='$2'|" > "$1"
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

@test "build_prompt: worker role asks for a commit, WITHOUT [skip ci]" {
  # Inverted by issue #51. The marker disabled the check job, so 37 of 40
  # consecutive commits reached the default branch unlinted and untested.
  # The anti-feedback guard was never this marker — it lives in bin/update.
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=99; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "issue #99"
  assert_output --partial "Commit your changes."
  refute_output --partial "[skip ci]"
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
  # Pin the forge: forge_aware_prompt rewrites MR -> PR on GitHub, and CI runs
  # with BOUCLE_FORGE=github, so an unpinned "Prior MR discussion" assertion
  # passes locally and fails in CI.
  run bash -c "ISSUE=7; BOUCLE_FORGE=gitlab; BOUCLE_REVIEWER_FEEDBACK='[tahrir] no letter-based logos'; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "Prior MR discussion"
  assert_output --partial "human comments AMEND the spec"
  assert_output --partial "enumerate every human amendment"
  assert_output --partial "any human amendment NOT addressed is a FAIL"
  assert_output --partial "[tahrir] no letter-based logos"
  rm -f "$TMPF"
}

@test "build_prompt: the discussion heading follows the forge's vocabulary" {
  # The same section is "Prior MR discussion" on GitLab and "Prior PR
  # discussion" on GitHub — forge_aware_prompt does the rewrite, and a
  # reviewer told to read a section that does not exist ignores the
  # amendments in it.
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; BOUCLE_FORGE=github; BOUCLE_REVIEWER_FEEDBACK='x'; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "Prior PR discussion"
  refute_output --partial "Prior MR discussion"
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

@test "build_prompt: reviewer prompt includes MR/PR number when BOUCLE_MR_IID is set" {
  # Bug fix (boucle.dev #73): the reviewer agent posted its verdict on the
  # issue instead of the PR because the prompt never told it the PR number.
  # BOUCLE_MR_IID is exported by reviewer.sh; bin/jc must inject it into the
  # prompt so the agent posts on the MR/PR, not the issue.
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; BOUCLE_MR_IID=74; BOUCLE_FORGE=github; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "PR #74"
  assert_output --partial "number 74"
  assert_output --partial "NEVER on the issue"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer prompt uses MR terminology on GitLab when BOUCLE_MR_IID is set" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; BOUCLE_MR_IID=74; BOUCLE_FORGE=gitlab; source '$TMPF'; build_prompt reviewer"
  assert_success
  assert_output --partial "MR !74"
  assert_output --partial "number 74"
  assert_output --partial "NEVER on the issue"
  rm -f "$TMPF"
}

@test "build_prompt: reviewer prompt omits MR/PR number when BOUCLE_MR_IID is unset" {
  # No MR exists yet (first run) — the prompt must not reference a number
  # that does not exist. The agent posts on the issue in that case, which
  # is acceptable because there is no MR to post on yet.
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=7; source '$TMPF'; build_prompt reviewer"
  assert_success
  refute_output --partial "NEVER on the issue"
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

@test "prompt budget: the — boucle tag tightens the cap even in mono-user mode" {
  # In mono-user mode BOUCLE_BOT_USERNAME matches nobody — every note is
  # posted under the human's account. The tightened bot cap must still apply
  # to notes tagged `— boucle` (marker-derived at injection), while a
  # `— human` note on the same account keeps the global cap.
  TMPF=$(mktemp)
  extract_func_body trim_notes "$TMPF"
  BIG=$(printf 'h%.0s' $(seq 1 600))
  run bash -c "source '$TMPF'; BOUCLE_BOT_USERNAME=up-bot; BOUCLE_MAX_NOTE_CHARS=1000; BOUCLE_BOT_NOTE_CHARS=50 trim_notes t '[x — human] $BIG
[x — boucle] $BIG'" 2> /dev/null
  assert_success
  # The human-tagged note is under the 1000 global cap → untouched.
  assert_output --partial "$BIG"
  # The boucle-tagged note is over the 50-char bot cap → elided.
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

# ── agent_posted_note (extracted, run in isolation) ──────────────────
# agent_posted_note detects whether the agent already posted a forge note
# during the current run. Used by the fallback guard to prevent duplicate
# verdicts and by the empty-output guard to detect silent failures.

@test "bin/jc defines agent_posted_note function" {
  run grep -E '^agent_posted_note\(\)' bin/jc
  assert_success
}

@test "agent_posted_note: [forge-note] output is detected (regression: false exit 3)" {
  # The forge-note script outputs "[forge-note]" on success, NOT
  # "bin/forge-note". The old grep pattern matched only "bin/forge-note",
  # causing a false exit 3 (silent failure) even when the agent posted
  # a verdict. This test ensures the [forge-note] prefix is detected.
  LOG=$(mktemp)
  echo "[forge-note] Rewrote draft note 5332795256 in place (role=reviewer)." > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_success
  rm -f "$LOG" "$TMPF"
}

@test "agent_posted_note: gh api comment call is detected (GitHub)" {
  LOG=$(mktemp)
  echo "gh api repos/owner/repo/issues/70/comments -X POST -f body=verdict" > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_success
  rm -f "$LOG" "$TMPF"
}

@test "agent_posted_note: boucle:verdict marker in log is detected" {
  LOG=$(mktemp)
  echo "<!-- boucle:verdict v=1 role=reviewer sha=abc123def -->" > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_success
  rm -f "$LOG" "$TMPF"
}

@test "agent_posted_note: boucle:draft marker in log is detected" {
  LOG=$(mktemp)
  echo "<!-- boucle:draft role=reviewer -->" > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_success
  rm -f "$LOG" "$TMPF"
}

@test "agent_posted_note: plain jcode banner is NOT detected (silent failure)" {
  LOG=$(mktemp)
  echo "Usage: jcode [OPTIONS] <COMMAND>" > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_failure
  rm -f "$LOG" "$TMPF"
}

@test "agent_posted_note: empty log is NOT detected" {
  LOG=$(mktemp)
  : > "$LOG"
  TMPF=$(mktemp)
  extract_func agent_posted_note "$TMPF"
  run bash -c "source '$TMPF'; agent_posted_note '$LOG'"
  assert_failure
  rm -f "$LOG" "$TMPF"
}

# ── Fallback duplicate-verdict guard ────────────────────────────────
# The fallback guard prevents a provider fallback retry when the agent
# already posted a note, avoiding duplicate verdicts on the MR.

@test "fallback guard: bin/jc has the agent_posted_note guard before fallback" {
  # The guard must appear after FALLBACK_REASON determination and before
  # the freeride/legacy fallback blocks.
  run grep -q 'agent_posted_note.*AGENT_LOG.*FALLBACK_REASON\|FALLBACK_REASON.*agent_posted_note.*AGENT_LOG' bin/jc
  assert_success
}

@test "fallback guard: guard clears FALLBACK_REASON when agent posted a note" {
  # When agent_posted_note returns true, FALLBACK_REASON must be cleared
  # so the fallback blocks (which check -n "$FALLBACK_REASON") skip.
  run grep -A2 'agent_posted_note "\$AGENT_LOG"' bin/jc
  assert_output --partial 'FALLBACK_REASON=""'
}


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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# Extract temperature"
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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# Extract temperature"
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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# Extract temperature"
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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# ── Provider fallback config"
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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# ── Provider fallback config"
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
  extract_agent_resolution "$TMPF" "$(dirname "$(dirname "$AGENT_DIR")")" "^# ── Do-Not-Disturb"
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

@test "anchoring: mono-user verdicts are detected by the — boucle tag, not the account" {
  # In mono-user mode EVERY note is posted under the human's own account
  # (BOUCLE_BOT_USERNAME=up-bot matches nobody). The bot verdict must still
  # be reduced to its unmet criteria — detected via the `— boucle` tag that
  # CI derives from the <!-- boucle:agent --> marker at injection time —
  # while the human amendment on the SAME account passes through intact.
  TMPF=$(mktemp)
  extract_anchor "$TMPF"
  run bash -c "BOUCLE_BOT_USERNAME=up-bot; source '$TMPF'; filter_mr_discussion \"\$(cat)\"" <<'EOF'
[baderdean — boucle] <!-- boucle:verdict v=1 role=reviewer sha=abc -->
VERDICT: FAIL
- [x] Header renders — verified via curl
- [ ] Footer link present — RATIONALE-ANCHOR relative path 404s
[baderdean — human] AMENDMENT-KEEP-ME use card-7.svg — do not substitute
EOF
  assert_success
  assert_output --partial "VERDICT: FAIL"
  assert_output --partial "- [ ] Footer link present"
  # The rationale is the anchor — it must not survive.
  refute_output --partial "RATIONALE-ANCHOR"
  # Met criteria are not re-listed either.
  refute_output --partial "- [x] Header renders"
  # The human amendment on the SAME account is never filtered.
  assert_output --partial "[baderdean — human] AMENDMENT-KEEP-ME use card-7.svg — do not substitute"
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

# ── extract_swarm_spawns (A2) ─────────────────────────────────────────
# worker.md tells the worker to fan out with the `swarm` tool and nothing
# has ever recorded whether it does. The pattern must be STRICT: unlike a
# skill name, `swarm` has no on-disk backstop, so a loose match would count
# the prompt's own instructions and every prose mention as a spawn.

@test "extract_swarm_spawns counts call shapes and ignores prose" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func extract_swarm_spawns "$TMPF"
  cat > "$LOGF" <<'LOG'
You have the swarm tool available. Use swarm when the task has independent parts.
I could use swarm here but the task is small.
  swarm(prompt="review the auth module", name="auth")
{"tool_call": {"name": "swarm", "arguments": {}}}
Considering a swarm of agents would be overkill.
  swarm spawn researcher
LOG
  run bash -c "source '$TMPF'; extract_swarm_spawns '$LOGF'"
  assert_success
  assert_output "3"
  rm -f "$TMPF" "$LOGF"
}

@test "extract_swarm_spawns returns 0 when the transcript only mentions swarm in prose" {
  TMPF=$(mktemp)
  LOGF=$(mktemp)
  extract_func extract_swarm_spawns "$TMPF"
  printf 'The swarm tool is available but this task has no independent parts.\n' > "$LOGF"
  run bash -c "source '$TMPF'; extract_swarm_spawns '$LOGF'"
  assert_success
  assert_output "0"
  rm -f "$TMPF" "$LOGF"
}

@test "extract_swarm_spawns is silent on a missing transcript" {
  TMPF=$(mktemp)
  extract_func extract_swarm_spawns "$TMPF"
  run bash -c "source '$TMPF'; extract_swarm_spawns /nonexistent.log"
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

# ── select_lessons / select_default_lessons (A6) ──────────────────────
# The two LESSONS.yml (engine under .boucle/, consumer at the repo root)
# are MERGED, never overridden: the previous first-match-wins fallback made
# a consumer that wrote its own lessons lose every engine lesson.

lessons_fixture() {
  cat > "$1" <<'YAML'
1:
  title: Seed the fixture volume first
  ✅: 'DO: run the seed task before invoking any browser suite.'
  ❌: DO NOT invoke the browser suite against an unseeded fixture volume.
2:
  title: Something unrelated
  ✅: 'DO: keep the deploy pipeline serial.'
  ❌: DO NOT parallelize the deploy pipeline.
5:
  title: Another one
  ✅: 'DO: name the authority.'
  ❌: DO NOT enforce an unnamed authority.
7:
  title: Outside the critical set
  ✅: 'DO: nothing in particular.'
  ❌: DO NOT expect this one in the default injection.
6:
  title: Yet another
  ✅: 'DO: post before refining.'
  ❌: DO NOT refine before posting.
99:
  title: The last one
  ✅: 'DO: post a real draft.'
  ❌: DO NOT post an empty placeholder draft.
YAML
}

@test "select_lessons returns only the lessons matching the keywords" {
  TMPF=$(mktemp)
  FIX=$(mktemp)
  extract_func select_lessons "$TMPF"
  lessons_fixture "$FIX"
  run bash -c "source '$TMPF'; select_lessons '$FIX' 'browser|fixture' 80 | grep -cE '^[0-9]+:'"
  assert_success
  assert_output "1"
  rm -f "$TMPF" "$FIX"
}

@test "select_lessons returns nothing when no keyword matches" {
  TMPF=$(mktemp)
  FIX=$(mktemp)
  extract_func select_lessons "$TMPF"
  lessons_fixture "$FIX"
  run bash -c "source '$TMPF'; select_lessons '$FIX' 'zzznomatch' 80"
  assert_success
  assert_output ""
  rm -f "$TMPF" "$FIX"
}

@test "select_lessons is silent on a missing file or empty keywords" {
  TMPF=$(mktemp)
  FIX=$(mktemp)
  extract_func select_lessons "$TMPF"
  lessons_fixture "$FIX"
  run bash -c "source '$TMPF'; select_lessons /nonexistent.yml 'browser' 80"
  assert_success
  assert_output ""
  run bash -c "source '$TMPF'; select_lessons '$FIX' '' 80"
  assert_success
  assert_output ""
  rm -f "$TMPF" "$FIX"
}

@test "select_default_lessons returns the critical set when nothing matched" {
  TMPF=$(mktemp)
  FIX=$(mktemp)
  extract_func select_default_lessons "$TMPF"
  lessons_fixture "$FIX"
  run bash -c "source '$TMPF'; select_default_lessons '$FIX' | grep -cE '^[0-9]+:'"
  assert_success
  assert_output "5"
  rm -f "$TMPF" "$FIX"
}

@test "select_default_lessons returns whole entries, not bare numbers" {
  # The regression: the keep flag was reset on the header line itself, so
  # the body was never accumulated and this injected five bare numbers
  # (21 bytes) under a heading calling them mandatory operating principles.
  TMPF=$(mktemp)
  FIX=$(mktemp)
  extract_func select_default_lessons "$TMPF"
  lessons_fixture "$FIX"
  run bash -c "source '$TMPF'; select_default_lessons '$FIX'"
  assert_success
  assert_output --partial "title: Seed the fixture volume first"
  assert_output --partial "DO NOT invoke the browser suite"
  assert_output --partial "title: The last one"
  # And nothing outside the critical set leaks in.
  refute_output --partial "Outside the critical set"
  rm -f "$TMPF" "$FIX"
}

@test "bin/jc no longer symlinks LESSONS.yml into the engine directory" {
  # The root LESSONS.yml belongs to the CONSUMER. Symlinking it into
  # .boucle/ is what made an agent-written lesson evaporate: the write
  # landed in the submodule and check-boucle-sync rejected it.
  run grep -n 'for lt in ".jcode/skills" "bin"' bin/jc
  assert_success
  run grep -c 'for lt in "LESSONS.yml"' bin/jc
  assert_output "0"
}

# ── refinement on a recovered run (B2) ────────────────────────────────
# Boucle used to distil a lesson only at escalation, so 100% of what it has
# ever learned came from runs that failed — a pool measured as producing
# artifacts worse than no artifact. The trajectory worth distilling is the
# RECOVERED one, and iteration >= 2 is exactly where the worker stands in
# it. A first-pass success must ask for nothing.

@test "build_prompt: a first-pass worker run is asked for no lesson" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ITERATION=1; source '$TMPF'; build_prompt worker"
  assert_success
  refute_output --partial "Refinement (you are recovering"
  rm -f "$TMPF"
}

@test "build_prompt: a worker recovering a failed iteration is asked for a lesson" {
  TMPF=$(mktemp)
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ITERATION=2; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Refinement (you are recovering a failed iteration)"
  assert_output --partial "four-point admission test"
  # Silence must stay the expected outcome, or the file fills with
  # restatements of the charter.
  assert_output --partial "emit NOTHING"
  rm -f "$TMPF"
}

@test "build_prompt: in a consumer, the refinement names the repo file and refuses the engine's" {
  TMPF=$(mktemp)
  W=$(mktemp -d)
  H=$(mktemp -d)
  printf '1:\n  title: x\n' > "$W/LESSONS.yml"
  printf '1:\n  title: y\n' > "$H/LESSONS.yml"
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ITERATION=3; BOUCLE_WORKSPACE='$W'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Specific to this repository"
  assert_output --partial "--against $H/LESSONS.yml"
  assert_output --partial "do NOT commit it here"
  rm -rf "$TMPF" "$W" "$H"
}

@test "build_prompt: in the engine repo, the refinement does not offer a second file" {
  # Dogfood: BOUCLE_WORKSPACE == BOUCLE_HOME, so both paths are one file
  # and the consumer/engine routing would be nonsense.
  TMPF=$(mktemp)
  H=$(mktemp -d)
  printf '1:\n  title: y\n' > "$H/LESSONS.yml"
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ITERATION=2; BOUCLE_WORKSPACE='$H'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Refinement (you are recovering a failed iteration)"
  refute_output --partial "Specific to this repository"
  rm -rf "$TMPF" "$H"
}

# ── the two lesson files are merged, never overridden (A6) ────────────

@test "build_prompt: both lesson files reach the prompt, engine block first" {
  TMPF=$(mktemp)
  W=$(mktemp -d)
  H=$(mktemp -d)
  cat > "$H/LESSONS.yml" <<'YAML'
1:
  title: Engine rule about labels
  ✅: 'DO: check the label first.'
  ❌: DO NOT PUT a label that is already present.
YAML
  cat > "$W/LESSONS.yml" <<'YAML'
1:
  title: Repo rule about fixtures
  ✅: 'DO: seed the fixture volume first.'
  ❌: DO NOT run the suite against an unseeded label fixture.
YAML
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ISSUE_BODY='the label fixture is wrong'; BOUCLE_WORKSPACE='$W'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Engine lessons — universal"
  assert_output --partial "This repository's own lessons"
  assert_output --partial "Engine rule about labels"
  assert_output --partial "Repo rule about fixtures"
  assert_output --partial "the ENGINE lesson wins"
  rm -rf "$TMPF" "$W" "$H"
}

@test "build_prompt: a consumer with its own lessons does NOT lose the engine's" {
  # The regression this guards: the old first-match-wins fallback read the
  # workspace file and never looked at the engine's, so writing a single
  # local lesson silently dropped all 107.
  TMPF=$(mktemp)
  W=$(mktemp -d)
  H=$(mktemp -d)
  cat > "$H/LESSONS.yml" <<'YAML'
1:
  title: Engine rule about labels
  ✅: 'DO: check the label first.'
  ❌: DO NOT PUT a label that is already present.
YAML
  printf '1:\n  title: Repo rule\n  ✅: %s\n  ❌: %s\n' "'DO: something unrelated.'" "DO NOT do something unrelated." > "$W/LESSONS.yml"
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ISSUE_BODY='a label is present'; BOUCLE_WORKSPACE='$W'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Engine rule about labels"
  rm -rf "$TMPF" "$W" "$H"
}

@test "build_prompt: one file is never injected twice when both paths resolve to it" {
  TMPF=$(mktemp)
  H=$(mktemp -d)
  cat > "$H/LESSONS.yml" <<'YAML'
1:
  title: Engine rule about labels
  ✅: 'DO: check the label first.'
  ❌: DO NOT PUT a label that is already present.
YAML
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ISSUE_BODY='a label is present'; BOUCLE_WORKSPACE='$H'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  count=$(printf '%s' "$output" | grep -c "Engine rule about labels")
  [ "$count" -eq 1 ]
  refute_output --partial "This repository's own lessons"
  rm -rf "$TMPF" "$H"
}

@test "build_prompt: with nothing matching, the engine's critical set is still injected" {
  TMPF=$(mktemp)
  W=$(mktemp -d)
  H=$(mktemp -d)
  cat > "$H/LESSONS.yml" <<'YAML'
1:
  title: Post before refining
  ✅: 'DO: post first.'
  ❌: DO NOT refine before posting.
YAML
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_ISSUE_BODY='zzzznomatch'; BOUCLE_WORKSPACE='$W'; BOUCLE_HOME='$H'; source '$TMPF'; build_prompt worker"
  assert_success
  assert_output --partial "Post before refining"
  rm -rf "$TMPF" "$W" "$H"
}

@test "build_prompt: arm=none still withholds both lesson files" {
  TMPF=$(mktemp)
  W=$(mktemp -d)
  H=$(mktemp -d)
  printf '1:\n  title: Engine rule about labels\n  ✅: %s\n  ❌: %s\n' "'DO: check.'" "DO NOT PUT a label present." > "$H/LESSONS.yml"
  printf '1:\n  title: Repo rule about labels\n  ✅: %s\n  ❌: %s\n' "'DO: seed.'" "DO NOT skip the label seed." > "$W/LESSONS.yml"
  extract_prompt_funcs "$TMPF"
  run bash -c "ISSUE=42; BOUCLE_EXPERIMENT=on; BOUCLE_ISSUE_BODY='a label is present'; BOUCLE_WORKSPACE='$W'; BOUCLE_HOME='$H'; boucle_experiment_arm() { echo none; }; source '$TMPF'; build_prompt worker"
  assert_success
  refute_output --partial "Engine rule about labels"
  refute_output --partial "Repo rule about labels"
  rm -rf "$TMPF" "$W" "$H"
}

# ── Agent-prompt resolution: the engine's copy wins ───────────────────
# `.jcode/` is engine-owned (bin/update syncs it as a whole). A copy in
# the consumer's workspace is a mirror, and on a submodule install that
# mirror never moves again — bin/update can only bump the submodule
# pointer. A workspace-first lookup froze such a consumer on a months-old
# triage prompt while the engine's parser moved on, so every spec it
# produced was missing the sections the engine expects.

# Build a .jcode/agents/<role>.md tree; echoes the root.
make_agent_tree() { # $1 = body marker
  local root
  root=$(mktemp -d)
  mkdir -p "$root/.jcode/agents"
  printf -- '---\nmodel: ollama-cloud/glm-5.2\ntemperature: 0.3\n---\n%s\n' "$1" \
    > "$root/.jcode/agents/triage.md"
  echo "$root"
}

@test "agent prompt: the engine's copy wins over a stale workspace copy" {
  ENGINE=$(make_agent_tree "current engine prompt")
  WS=$(make_agent_tree "stale consumer prompt")
  TMPF=$(mktemp)
  extract_agent_resolution "$TMPF" "$ENGINE"
  run bash -c "AGENT='triage'; BOUCLE_WORKSPACE='$WS'; BOUCLE_HOME=''; source '$TMPF'; echo \"PICKED=\$AGENT_FILE\"; grep -c 'current engine prompt' \"\$AGENT_FILE\""
  assert_success
  assert_output --partial "PICKED=$ENGINE/.jcode/agents/triage.md"
  refute_output --partial "$WS/.jcode/agents/triage.md
PICKED"
  rm -rf "$TMPF" "$ENGINE" "$WS"
}

@test "agent prompt: a divergent workspace copy is reported, not silently ignored" {
  ENGINE=$(make_agent_tree "current engine prompt")
  WS=$(make_agent_tree "stale consumer prompt")
  TMPF=$(mktemp)
  extract_agent_resolution "$TMPF" "$ENGINE"
  run bash -c "AGENT='triage'; BOUCLE_WORKSPACE='$WS'; BOUCLE_HOME=''; source '$TMPF' 2>&1"
  assert_success
  assert_output --partial "differs from the engine's"
  assert_output --partial ".jcode/ is engine-owned"
  rm -rf "$TMPF" "$ENGINE" "$WS"
}

@test "agent prompt: an in-sync workspace copy warns about nothing" {
  # A tarball install: the workspace copy IS the engine's copy.
  ENGINE=$(make_agent_tree "current engine prompt")
  WS=$(make_agent_tree "current engine prompt")
  TMPF=$(mktemp)
  extract_agent_resolution "$TMPF" "$ENGINE"
  run bash -c "AGENT='triage'; BOUCLE_WORKSPACE='$WS'; BOUCLE_HOME=''; source '$TMPF' 2>&1"
  assert_success
  refute_output --partial "WARN"
  rm -rf "$TMPF" "$ENGINE" "$WS"
}

@test "agent prompt: the workspace copy is still used when the engine has none" {
  # A consumer carrying a role the engine does not ship must keep working.
  ENGINE=$(mktemp -d)
  WS=$(make_agent_tree "consumer-only prompt")
  TMPF=$(mktemp)
  extract_agent_resolution "$TMPF" "$ENGINE"
  run bash -c "AGENT='triage'; BOUCLE_WORKSPACE='$WS'; BOUCLE_HOME=''; source '$TMPF' 2>&1; echo \"PICKED=\$AGENT_FILE\""
  assert_success
  assert_output --partial "PICKED=$WS/.jcode/agents/triage.md"
  refute_output --partial "WARN"
  rm -rf "$TMPF" "$ENGINE" "$WS"
}

@test "agent prompt: BOUCLE_HOME is consulted before the workspace" {
  # bin/jc invoked from outside the engine tree: BOUCLE_HOME names it.
  HOME_DIR=$(make_agent_tree "engine via BOUCLE_HOME")
  WS=$(make_agent_tree "stale consumer prompt")
  TMPF=$(mktemp)
  extract_agent_resolution "$TMPF" "$(mktemp -d)"
  run bash -c "AGENT='triage'; BOUCLE_WORKSPACE='$WS'; BOUCLE_HOME='$HOME_DIR'; source '$TMPF' 2>&1; echo \"PICKED=\$AGENT_FILE\""
  assert_success
  assert_output --partial "PICKED=$HOME_DIR/.jcode/agents/triage.md"
  rm -rf "$TMPF" "$HOME_DIR" "$WS"
}

@test "agent prompt: the candidate order puts the engine ahead of the workspace" {
  # Regression guard on the order itself, independent of the behaviour
  # tests above: engine dir, then BOUCLE_HOME, then the workspace mirror.
  run bash -c "awk '/^AGENT_FILE=\"\"/,/^done/' bin/jc | grep -n 'agents/' | cut -d: -f1,2 | paste -sd' ' -"
  assert_success
  [[ "$output" =~ ENGINE_DIR.*BOUCLE_HOME.*BOUCLE_WORKSPACE ]]
}
