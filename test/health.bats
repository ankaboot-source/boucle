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
