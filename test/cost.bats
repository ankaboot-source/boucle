#!/usr/bin/env bats
# Per-issue token and cost accounting (#35)
#
# Boucle's pitch is a 9.9x cost advantage over Claude Code
# (docs/cost-benchmark.md). Until now a user could not verify that on their
# own repository: the number lived in the README, not in the product.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

extract_cost_funcs() {
  awk '/^extract_token_usage\(\) \{/,/^}/' bin/jc > "$1"
  awk '/^record_cost\(\) \{/,/^}/' bin/jc >> "$1"
}

summary_func() {
  awk '/^boucle_cost_summary\(\) \{/,/^}/' lib/boucle.sh > "$1"
}

@test "cost: token usage is summed across every call in the log" {
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_cost_funcs "$TMPF"
  printf '{"usage":{"prompt_tokens": 1200, "completion_tokens":340}}\nusage: {"prompt_tokens":800,"completion_tokens": 60}\n' > "$LOG"
  run bash -c "source '$TMPF'; extract_token_usage '$LOG' prompt_tokens"
  assert_output "2000"
  run bash -c "source '$TMPF'; extract_token_usage '$LOG' completion_tokens"
  assert_output "400"
  rm -f "$TMPF" "$LOG"
}

@test "cost: a log with no usage reports nothing rather than zero" {
  # Fabricating a number would be worse than reporting none.
  TMPF=$(mktemp); LOG=$(mktemp)
  extract_cost_funcs "$TMPF"
  printf 'wrote src/index.astro\n' > "$LOG"
  run bash -c "source '$TMPF'; extract_token_usage '$LOG' prompt_tokens"
  assert_output ""
  rm -f "$TMPF" "$LOG"
}

@test "cost: entries accumulate across iterations instead of overwriting" {
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_cost_funcs "$TMPF"
  printf '{"prompt_tokens":100,"completion_tokens":10}\n' > "$T/agent-output.log"
  bash -c "
    AGENT_LOG='$T/agent-output.log'; STATE_DIR='$T'; ROLE=worker; ITERATION=1
    MODEL=m; PROVIDER_PROFILE=p
    source '$TMPF'
    record_cost
    ITERATION=2 record_cost
  " 2> /dev/null
  run jq '.entries | length' "$T/cost.json"
  assert_output "2"
  rm -rf "$TMPF" "$T"
}

@test "cost: no dollar figure without BOUCLE_PRICING_JSON" {
  # Provider prices drift and boucle is provider-agnostic: a confident
  # wrong number is worse than tokens alone.
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_cost_funcs "$TMPF"
  printf '{"prompt_tokens":100,"completion_tokens":10}\n' > "$T/agent-output.log"
  bash -c "
    AGENT_LOG='$T/agent-output.log'; STATE_DIR='$T'; ROLE=worker; ITERATION=1
    MODEL=m; PROVIDER_PROFILE=p
    unset BOUCLE_PRICING_JSON
    source '$TMPF'; record_cost
  " 2> /dev/null
  run jq -r '.entries[0].cost_usd' "$T/cost.json"
  assert_output "null"
  rm -rf "$TMPF" "$T"
}

@test "cost: pricing is applied per million tokens" {
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_cost_funcs "$TMPF"
  printf '{"prompt_tokens":2000000,"completion_tokens":1000000}\n' > "$T/agent-output.log"
  bash -c "
    AGENT_LOG='$T/agent-output.log'; STATE_DIR='$T'; ROLE=worker; ITERATION=1
    MODEL=fast; PROVIDER_PROFILE=p
    BOUCLE_PRICING_JSON='{\"fast\":{\"in\":1.0,\"out\":2.0}}'
    source '$TMPF'; record_cost
  " 2> /dev/null
  run jq -r '.entries[0].cost_usd' "$T/cost.json"
  assert_output "4"
  rm -rf "$TMPF" "$T"
}

@test "cost: a fallback run is attributed to the fallback model" {
  # Otherwise the breakdown blames the wrong provider.
  TMPF=$(mktemp); T=$(mktemp -d)
  extract_cost_funcs "$TMPF"
  printf '{"prompt_tokens":10,"completion_tokens":1}\n' > "$T/agent-output.log"
  bash -c "
    AGENT_LOG='$T/agent-output.log'; STATE_DIR='$T'; ROLE=worker; ITERATION=1
    MODEL=primary-model; PROVIDER_PROFILE=primary
    FALLBACK_USED=1; FALLBACK_MODEL=backup-model; FALLBACK_PROVIDER=backup
    source '$TMPF'; record_cost
  " 2> /dev/null
  run jq -r '.entries[0].model' "$T/cost.json"
  assert_output "backup-model"
  rm -rf "$TMPF" "$T"
}

@test "cost summary: prints nothing when there is no accumulator" {
  TMPF=$(mktemp); T=$(mktemp -d)
  summary_func "$TMPF"
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_cost_summary 7"
  assert_success
  assert_output ""
  rm -rf "$TMPF" "$T"
}

@test "cost summary: groups by role and totals" {
  TMPF=$(mktemp); T=$(mktemp -d); mkdir -p "$T/.boucle-state/7"
  summary_func "$TMPF"
  cat > "$T/.boucle-state/7/cost.json" <<'JSON'
{"entries":[
 {"role":"worker","iteration":1,"prompt_tokens":100,"completion_tokens":10,"cost_usd":0.01},
 {"role":"worker","iteration":2,"prompt_tokens":200,"completion_tokens":20,"cost_usd":0.02},
 {"role":"reviewer","iteration":1,"prompt_tokens":50,"completion_tokens":5,"cost_usd":0.005}
]}
JSON
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_cost_summary 7"
  assert_success
  assert_output --partial "### Cost"
  assert_output --partial "| worker | 2 | 300 | 30 |"
  assert_output --partial "**350**"
  rm -rf "$TMPF" "$T"
}

@test "cost summary: tokens only, no dollar column, when nothing is priced" {
  TMPF=$(mktemp); T=$(mktemp -d); mkdir -p "$T/.boucle-state/7"
  summary_func "$TMPF"
  cat > "$T/.boucle-state/7/cost.json" <<'JSON'
{"entries":[{"role":"worker","iteration":1,"prompt_tokens":100,"completion_tokens":10,"cost_usd":null}]}
JSON
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_cost_summary 7"
  assert_success
  assert_output --partial "| Role | Runs | Prompt | Completion |"
  refute_output --partial "Cost |"
  refute_output --partial "$"
  rm -rf "$TMPF" "$T"
}

@test "cost summary: a partially-priced set is flagged as a lower bound" {
  TMPF=$(mktemp); T=$(mktemp -d); mkdir -p "$T/.boucle-state/7"
  summary_func "$TMPF"
  cat > "$T/.boucle-state/7/cost.json" <<'JSON'
{"entries":[
 {"role":"worker","iteration":1,"prompt_tokens":100,"completion_tokens":10,"cost_usd":0.01},
 {"role":"e2e","iteration":1,"prompt_tokens":50,"completion_tokens":5,"cost_usd":null}
]}
JSON
  run bash -c "BOUCLE_WORKSPACE='$T'; source '$TMPF'; boucle_cost_summary 7"
  assert_success
  assert_output --partial "lower bound"
  rm -rf "$TMPF" "$T"
}

@test "cost: the MR description embeds the breakdown on runs that ship code" {
  run grep -q 'cost_block=$(boucle_cost_summary "$BOUCLE_ISSUE"' lib/boucle-ci/worker.sh
  assert_success
}
