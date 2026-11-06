#!/usr/bin/env bats
# Configuration readiness audit (#41)
#
# bin/doctor's default mode checks the forge is reachable. This checks the
# CONFIGURATION is coherent — the class of problem a consumer otherwise
# discovers mid-loop, one failed run at a time.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

audit() {
  env -i PATH="$PATH" HOME="$HOME" "$@" bash bin/doctor --audit 2>&1
}

@test "audit: a coherent configuration scores high and exits 0" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_DND_TZ=Europe/Paris bash bin/doctor --audit
  assert_success
  assert_output --partial "Readiness:"
  refute_output --partial "BLOCKER"
}

@test "audit: external deploy mode without a live URL is advisory, not a blocker" {
  # A consumer that publishes nothing (an Ansible playbook, a backend service)
  # legitimately has no live URL and runs e2e via BOUCLE_E2E_COMMAND. This MUST
  # NOT be a blocker: it would tank readiness for a valid, complete setup.
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_DEPLOY_MODE=external bash bin/doctor --audit
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "BOUCLE_DEPLOY_MODE=external without BOUCLE_LIVE_URL"
  assert_output --partial "BOUCLE_E2E_COMMAND"
  refute_output --partial "BLOCKER"
}

@test "audit: a missing LLM key is a blocker and names where to set it" {
  run env -i PATH="$PATH" HOME="$HOME" bash bin/doctor --audit
  assert_failure
  assert_output --partial "BOUCLE_LLM_API_KEY is not set"
  assert_output --partial "MASKED"
}

@test "audit: a fallback provider without its URL and key is degraded, not fatal" {
  # It looks like a safety net and is not one.
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_FALLBACK_PROVIDER=backup bash bin/doctor --audit
  assert_success
  assert_output --partial "DEGRADED"
  assert_output --partial "inert"
}

@test "audit: a staleness threshold below the job timeout is degraded" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_STALENESS_THRESHOLD=600 bash bin/doctor --audit
  assert_success
  assert_output --partial "below the max job timeout"
}

@test "audit: a UTC quiet window is flagged as silently wrong when DND is enabled" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_DND_ENABLED=true bash bin/doctor --audit
  assert_success
  assert_output --partial "BOUCLE_DND_TZ is UTC"
}

@test "audit: an unknown enum value is reported with its fallback" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_SPEC_PROFILE=typo bash bin/doctor --audit
  assert_success
  assert_output --partial "BOUCLE_SPEC_PROFILE='typo' is unknown"
  assert_output --partial "Falling back to 'strict'"
}

@test "audit: malformed pricing JSON is degraded" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_PRICING_JSON='{not json' bash bin/doctor --audit
  assert_success
  assert_output --partial "not valid JSON"
}

@test "audit: blockers dominate the score" {
  # A blocker costs 40, an advisory 3 — a blocker must always score strictly
  # below an advisory-only config, which scores below a clean one. (external
  # without a live URL is an advisory, see the test above.)
  score() { env -i PATH="$PATH" HOME="$HOME" "$@" bash bin/doctor --audit 2>&1 | grep -oE 'Readiness: [0-9]+' | grep -oE '[0-9]+'; }
  clean=$(score BOUCLE_LLM_API_KEY=k BOUCLE_DND_TZ=Europe/Paris)
  advisory=$(score BOUCLE_LLM_API_KEY=k BOUCLE_DEPLOY_MODE=external)
  blocker=$(score BOUCLE_DND_TZ=Europe/Paris) # no BOUCLE_LLM_API_KEY
  [ "$blocker" -lt "$advisory" ]
  [ "$advisory" -lt "$clean" ]
  [ $((advisory - blocker)) -ge 30 ]
}

@test "audit: runs without BOUCLE_PROJECT_ID (usable before the forge is wired)" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash bin/doctor --audit
  assert_success
}

@test "audit: performs no writes" {
  # Read-only by construction: no label, comment or issue APIs.
  run bash -c "awk '/^run_config_audit\(\) \{/,/^}/' bin/doctor | grep -cE 'forge_issue_note|set_boucle_label|forge_issue_create|forge_issue_labels_set'"
  assert_output "0"
}

@test "audit: bin/setup prints it without failing the install" {
  run grep -q 'doctor" --audit || true' bin/setup
  assert_success
}
