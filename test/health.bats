#!/usr/bin/env bats
# Loop-health measurement + structured escalation diagnostics (#52)

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract the three health helpers + cost_summary (used by the diagnostic)
# from lib/boucle.sh into a standalone file.
health_funcs() {
  awk '/^boucle_health_record\(\) \{/,/^}/' lib/boucle.sh > "$1"
  awk '/^boucle_health_outcome\(\) \{/,/^}/' lib/boucle.sh >> "$1"
  awk '/^boucle_escalation_diagnostic\(\) \{/,/^}/' lib/boucle.sh >> "$1"
  awk '/^boucle_cost_summary\(\) \{/,/^}/' lib/boucle.sh >> "$1"
}

@test "health: boucle_health_record appends a JSONL line with the right fields" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_record 7 worker 2 0 1500 400 0.01 'deepseek-v4-flash' 'boucle'"
  assert_success
  run jq -r 'select(.role=="worker") | .role + ":" + (.iteration|tostring) + ":" + (.exit_code|tostring) + ":" + (.prompt_chars|tostring) + ":" + .tokens + ":" + .cost_usd + ":" + .model + ":" + .provider' "$T/.boucle-state/7/health.jsonl"
  assert_output "worker:2:0:1500:400:0.01:deepseek-v4-flash:boucle"
  run jq -r 'select(.role=="worker") | .timestamp' "$T/.boucle-state/7/health.jsonl"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  rm -rf "$TMPF" "$T"
}

@test "health: boucle_health_outcome appends an outcome line" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_outcome 7 reviewer FAIL 'criteria 2 of 5'"
  assert_success
  run jq -r 'select(has("outcome")) | .role + ":" + .outcome + ":" + .detail' "$T/.boucle-state/7/health.jsonl"
  assert_output "reviewer:FAIL:criteria 2 of 5"
  rm -rf "$TMPF" "$T"
}

@test "health: diagnostic classifies a no-changes trigger as step-budget-exhaustion" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  # Golden fixture: 3 no-changes outcomes, no cost file.
  cat > "$T/.boucle-state/7/health.jsonl" << 'JSONL'
{"timestamp":"2026-01-01T00:00:00Z","role":"worker","outcome":"no-changes","detail":"iteration 1"}
{"timestamp":"2026-01-01T00:00:01Z","role":"worker","outcome":"no-changes","detail":"iteration 2"}
{"timestamp":"2026-01-01T00:00:02Z","role":"worker","outcome":"no-changes","detail":"iteration 3 (cap reached)"}
JSONL
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  assert_output --partial "class=step-budget-exhaustion"
  assert_output --partial "3 worker iteration(s) produced no code changes."
  assert_output --partial "Re-queue with \`boucle:todo\` to retry."
  assert_output --partial "boucle:diagnostic v=1 iid=7"
  rm -rf "$TMPF" "$T"
}

@test "health: diagnostic classifies an exit-4 trigger as provider/quota" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  printf '%s\n' '{"role":"worker","outcome":"no-changes"}' > "$T/.boucle-state/7/health.jsonl"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 exit-4"
  assert_success
  assert_output --partial "class=provider/quota"
  assert_output --partial "provider down or quota exhausted"
  assert_output --partial "BOUCLE_FALLBACK_PROVIDER"
  rm -rf "$TMPF" "$T"
}

@test "health: diagnostic embeds the cost summary when cost.json exists" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  printf '%s\n' '{"role":"worker","outcome":"no-changes"}' > "$T/.boucle-state/7/health.jsonl"
  echo '{"entries":[{"role":"worker","iteration":1,"prompt_tokens":100,"completion_tokens":10,"cost_usd":0.01}]}' > "$T/.boucle-state/7/cost.json"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  assert_output --partial "### Cost"
  assert_output --partial "| worker | 1 | 100 | 10 |"
  rm -rf "$TMPF" "$T"
}

@test "health: bin/health reads a fixture and prints a summary" {
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  cat > "$T/.boucle-state/7/health.jsonl" << 'JSONL'
{"timestamp":"2026-01-01T00:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":1500,"tokens":"400","cost_usd":"0.01","model":"m","provider":"p"}
{"timestamp":"2026-01-01T00:00:01Z","role":"worker","outcome":"committed","detail":"iteration 1"}
{"timestamp":"2026-01-01T00:00:02Z","role":"reviewer","outcome":"PASS","detail":"all criteria"}
JSONL
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_WORKSPACE="$T" bash bin/health 7
  assert_success
  assert_output --partial "Issue #7"
  assert_output --partial "runs: 1"
  assert_output --partial "worker: 1 committed, 0 no-changes, 0 build-fail"
  assert_output --partial "reviewer: 1 PASS, 0 FAIL"
  assert_output --partial "last outcome: reviewer:PASS"
  rm -rf "$T"
}

# ── failure_side (A1) ─────────────────────────────────────────────────
# The harness stopping a run is not the model failing the task, and the two
# call for different actions. `step-budget-exhaustion` is harness-side by
# the same reasoning: a cap that fires terminated the run prematurely, it
# did not establish that the task was beyond the agent.

@test "health: diagnostic labels a step-budget exhaustion as harness-side" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  printf '{"role":"worker","outcome":"no-changes","detail":"iteration 1"}\n' > "$T/.boucle-state/7/health.jsonl"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 no-changes"
  assert_success
  assert_output --partial "side=harness"
  assert_output --partial "(**harness**-side)"
  assert_output --partial "The harness stopped this run"
  rm -rf "$TMPF" "$T"
}

@test "health: diagnostic labels a build failure as model-side" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  printf '{"role":"worker","outcome":"build-fail","detail":"iteration 1"}\n' > "$T/.boucle-state/7/health.jsonl"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 build-fail"
  assert_success
  assert_output --partial "side=model"
  assert_output --partial "The agent reached the task and did not deliver"
  rm -rf "$TMPF" "$T"
}

@test "health: diagnostic labels provider/quota and merge failures as harness-side" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  : > "$T/.boucle-state/7/health.jsonl"
  health_funcs "$TMPF"
  for trigger in exit-4 rebase-conflict not-mergeable; do
    run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 $trigger"
    assert_success
    assert_output --partial "side=harness"
  done
  rm -rf "$TMPF" "$T"
}

@test "health: an unclassified trigger leaves the side undetermined rather than guessing" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  : > "$T/.boucle-state/7/health.jsonl"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_escalation_diagnostic 7 something-new"
  assert_success
  assert_output --partial "side=unknown"
  assert_output --partial "Side undetermined"
  rm -rf "$TMPF" "$T"
}

# ── swarm_spawns on the run record (A2) ───────────────────────────────

@test "health: boucle_health_record carries the swarm spawn count" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_record 7 worker 1 0 1500 400 0.01 m p 'astro' full '' 3"
  assert_success
  run jq -r 'select(.role=="worker") | .swarm_spawns | tostring' "$T/.boucle-state/7/health.jsonl"
  assert_output "3"
  rm -rf "$TMPF" "$T"
}

@test "health: a missing or non-numeric swarm count records 0, never a broken row" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_record 7 worker 1 0 1500 400 0.01 m p 'astro' full '' 'not-a-number'"
  assert_success
  run jq -r '.swarm_spawns | tostring' "$T/.boucle-state/7/health.jsonl"
  assert_output "0"
  # Omitted entirely (every existing caller before A2)
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_record 8 worker 1 0 1500 400 0.01 m p 'astro' full ''"
  assert_success
  rm -rf "$TMPF" "$T"
}

# ── the reviewer and e2e actually write their verdict (A7) ────────────
# boucle_health_outcome documented itself as taking reviewer/e2e rows and
# no stage ever wrote one, so boucle_escalation_diagnostic counted 0
# reviewer FAILs on every escalation. These guard the wiring, not the
# function: the function was always fine, the calls were missing.

@test "health: reviewer.sh records its verdict before acting on it" {
  run grep -n 'boucle_health_outcome "\$BOUCLE_ISSUE" "reviewer"' lib/boucle-ci/reviewer.sh
  assert_success
  # Must be written BEFORE the routing switch, so a verdict that ends the
  # loop is recorded too.
  record_line=$(grep -n 'boucle_health_outcome "\$BOUCLE_ISSUE" "reviewer"' lib/boucle-ci/reviewer.sh | head -1 | cut -d: -f1)
  switch_line=$(grep -n '^  case "\$VERDICT" in' lib/boucle-ci/reviewer.sh | head -1 | cut -d: -f1)
  [ "$record_line" -lt "$switch_line" ]
}

@test "health: e2e.sh records its verdict before acting on it" {
  run grep -n 'boucle_health_outcome "\$BOUCLE_ISSUE" "e2e"' lib/boucle-ci/e2e.sh
  assert_success
  record_line=$(grep -n 'boucle_health_outcome "\$BOUCLE_ISSUE" "e2e"' lib/boucle-ci/e2e.sh | head -1 | cut -d: -f1)
  switch_line=$(grep -n '^  case "\$VERDICT" in' lib/boucle-ci/e2e.sh | head -1 | cut -d: -f1)
  [ "$record_line" -lt "$switch_line" ]
}

@test "health: an absent verdict is recorded as UNCERTAIN, not as silence" {
  # No verdict is a fact about the run. Recording nothing would make it
  # indistinguishable from a PASS in the record.
  run grep -c 'VERDICT:-UNCERTAIN' lib/boucle-ci/reviewer.sh lib/boucle-ci/e2e.sh
  assert_success
  assert_line --index 0 --partial "reviewer.sh:1"
  assert_line --index 1 --partial "e2e.sh:1"
}

@test "health: the diagnostic's reviewer-FAIL count now has rows to count" {
  TMPF=$(mktemp)
  T=$(mktemp -d)
  mkdir -p "$T/.boucle-state/7"
  health_funcs "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_health_outcome 7 reviewer FAIL 'iteration 1'; boucle_health_outcome 7 reviewer FAIL 'iteration 2'; boucle_escalation_diagnostic 7 something-new"
  assert_success
  assert_output --partial "2 reviewer FAIL(s)"
  rm -rf "$TMPF" "$T"
}
