#!/usr/bin/env bats
# test/oc.bats — smoke + pure-function tests for bin/oc.
#
# bin/oc has no BASH_SOURCE guard and executes its full body on source:
# it makes a state directory, calls opencode run, writes to iterations.md,
# etc. We can't source it directly. These tests cover what we can:
# syntax validity, function definitions, and the behavior of build_prompt
# (the role → prompt builder) which we extract and run in isolation.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract a multi-line function from bin/oc by name and write it to a
# temp file that can be sourced. Usage: extract_func <funcname> <outfile>
extract_func() {
  awk -v fn="$1" '
    BEGIN { p = 0 }
    $0 ~ "^"fn"\\(\\) \\{" { p = 1; print; next }
    p == 1 && /^}/ { print; p = 0; next }
    p == 1 { print }
  ' bin/oc > "$2"
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/oc parses without syntax error" {
  run bash -n bin/oc
  assert_success
}

# ── Function definitions ──────────────────────────────────────────────

@test "bin/oc defines build_prompt function" {
  run grep -E '^build_prompt\(\)' bin/oc
  assert_success
}

@test "bin/oc defines get_peak_rss_kb function" {
  run grep -E '^get_peak_rss_kb\(\)' bin/oc
  assert_success
}

@test "bin/oc defines print_metrics_line function" {
  run grep -E '^print_metrics_line\(\)' bin/oc
  assert_success
}

@test "bin/oc defines cleanup_metrics function" {
  run grep -E '^cleanup_metrics\(\)' bin/oc
  assert_success
}

@test "bin/oc defines start_rss_sampler function" {
  run grep -E '^start_rss_sampler\(\)' bin/oc
  assert_success
}

# ── build_prompt (extracted, run in isolation) ────────────────────────
# build_prompt takes a role and a global ISSUE; it returns the prompt
# text on stdout. We extract the function body and invoke it with
# different ISSUE values to verify each role branch.

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
# bin/oc exits 3 when the agent produced NO posted comment AND NO drafted
# comment in its log. This breaks the doctor re-trigger loop (issue #27).
# We can't run the full bin/oc (it calls opencode), but we can verify the
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

@test "empty-output guard: log with only opencode header IS a silent failure" {
  # Simulate the exact issue #27 failure: only the opencode header, no
  # glab call, no boucle:triage marker. The guard should detect this.
  LOG=$(mktemp)
  echo "> triage · minimax-m3
" > "$LOG"
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

# ── OUTPUT_TOKEN_MAX regression ───────────────────────────────────────
# 1200 was too small for triage (agent hit the cap mid-comment on issue
# #27 and never reached the glab tool call). Verify the new value.

@test "bin/oc: triage OUTPUT_TOKEN_MAX is 4000 (not the old 1200)" {
  # 1200 was too small for triage (agent hit the cap mid-comment on issue
  # #27 and never reached the glab tool call). Verify the new value.
  run grep -E 'OUTPUT_TOKEN_MAX="4000"' bin/oc
  assert_success
  assert_output --partial 'OUTPUT_TOKEN_MAX="4000"'
  # Ensure the old 1200 value is gone from the triage block.
  # grep -c exits 1 when count is 0 (no matches) — that's what we want.
  run bash -c "grep -c 'OUTPUT_TOKEN_MAX=\"1200\"' bin/oc || true"
  [ "$output" = "0" ]
}

# ── MCP stripping for CI (silent-hang fix) ─────────────────────────────
# opencode hangs at boot when codebase-memory-mcp fails the MCP initialize
# handshake within the 30s default timeout (issue #27 job 3826534: 36s
# wall-clock, 4096b db, zero output). The successful run proved the agent
# ignores MCP entirely, so we strip the `mcp` key from the config in CI via
# OPENCODE_CONFIG pointing at a temp copy. These tests verify the logic.

@test "bin/oc defines strip_mcp_for_ci function" {
  run grep -E '^strip_mcp_for_ci\(\)' bin/oc
  assert_success
}

@test "strip_mcp_for_ci: no-op without CI_PROJECT_DIR (local dev keeps MCP)" {
  # Local dev (no CI_PROJECT_DIR) must keep the full config — MCP stays.
  TMPF=$(mktemp)
  cat > "$TMPF" <<'EOF'
{"mcp": {"codebase-memory-mcp": {"type": "local", "command": ["x"]}}, "agent": {}}
EOF
  # Simulate: no CI_PROJECT_DIR set → function returns 0 without exporting.
  # We extract and call the function in a clean shell.
  extract_func strip_mcp_for_ci "$TMPF.func"
  # shellcheck disable=SC1090
  ( unset CI_PROJECT_DIR; unset OPENCODE_CONFIG; source "$TMPF.func"; strip_mcp_for_ci; echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-unset}" ) > "$TMPF.out" 2>&1
  run cat "$TMPF.out"
  assert_output --partial "OPENCODE_CONFIG=unset"
  rm -f "$TMPF" "$TMPF.func" "$TMPF.out"
}

@test "strip_mcp_for_ci: strips mcp key when CI_PROJECT_DIR is set" {
  # In CI, the mcp key should be removed from the temp config.
  WORKDIR=$(mktemp -d)
  mkdir -p "$WORKDIR/.opencode"
  cat > "$WORKDIR/.opencode/opencode.json" <<'EOF'
{
  "mcp": {"codebase-memory-mcp": {"type": "local", "command": ["codebase-memory-mcp"]}},
  "agent": {"triage": {"model": "minimax-m3"}}
}
EOF
  extract_func strip_mcp_for_ci "$WORKDIR/func"
  # shellcheck disable=SC1090
  ( export CI_PROJECT_DIR="$WORKDIR"; unset OPENCODE_CONFIG; source "$WORKDIR/func"; strip_mcp_for_ci; cat "$OPENCODE_CONFIG" ) > "$WORKDIR/out" 2>&1
  run cat "$WORKDIR/out"
  # mcp key must be gone, agent key must survive.
  refute_output --partial '"codebase-memory-mcp"'
  refute_output --partial '"mcp"'
  assert_output --partial '"minimax-m3"'
  rm -rf "$WORKDIR"
}

@test "strip_mcp_for_ci: no-op when .opencode/opencode.json is absent" {
  WORKDIR=$(mktemp -d)
  extract_func strip_mcp_for_ci "$WORKDIR/func"
  # shellcheck disable=SC1090
  ( export CI_PROJECT_DIR="$WORKDIR"; unset OPENCODE_CONFIG; source "$WORKDIR/func"; strip_mcp_for_ci; echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-unset}" ) > "$WORKDIR/out" 2>&1
  run cat "$WORKDIR/out"
  assert_output --partial "OPENCODE_CONFIG=unset"
  rm -rf "$WORKDIR"
}
