#!/usr/bin/env bats
# Configuration readiness audit (#41)
#
# bin/doctor's default mode checks the forge is reachable. This checks the
# CONFIGURATION is coherent — the class of problem a consumer otherwise
# discovers mid-loop, one failed run at a time.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
}

teardown() {
  cd "$BATS_TEST_DIRNAME" 2> /dev/null || cd / || true
  rm -rf "$TMP"
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

@test "audit: external mode with command-mode e2e needs no live URL (#182)" {
  # BOUCLE_E2E_COMMAND runs a verify command instead of probing a URL, so an
  # infra install (no BOUCLE_LIVE_URL) must not be blocked. Main generalized
  # the whole external-without-URL case to advisory (4325b74), superseding
  # the E2E_COMMAND exemption; this pins the infra shape: command-mode
  # configured, readiness stays advisory, never BLOCKER.
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_DEPLOY_MODE=external BOUCLE_E2E_COMMAND=true bash bin/doctor --audit
  assert_success
  refute_output --partial "BLOCKER"
  assert_output --partial "ADVISORY"
}

@test "audit: an unset/auto profile is advisory, never a blocker (#186)" {
  # The first-issue profile determination defers the site/infra decision, so
  # an undetermined profile is a valid state — the first triaged issue will
  # propose it. Advisory only.
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash bin/doctor --audit
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "BOUCLE_PROFILE is unset/auto"
  refute_output --partial "BLOCKER"
}

@test "audit: an explicit profile is not flagged (#186)" {
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_PROFILE=infra bash bin/doctor --audit
  assert_success
  assert_output --partial "install profile 'infra' is explicit"
  refute_output --partial "BOUCLE_PROFILE is unset/auto"
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

# ── Metrics wiring / liveness (#177) ──────────────────────────────────
# The audit stays OFFLINE: it runs before a project is even reachable, so it
# reads the local remote-tracking ref instead of fetching. These tests prove
# the branch state and the "never populated" flag reach the operator without a
# network round-trip.

# metrics_audit_work <dir> <metrics-jsonl-content-or-empty>
metrics_audit_work() {
  local work="$1" metrics="$2"
  git init -q --bare "$work.origin.git"
  git init -q "$work"
  git -C "$work" remote add origin "$work.origin.git"
  git -C "$work" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$work" push -q origin HEAD:main
  git -C "$work" checkout -q --orphan boucle/metrics
  printf '%s' "$metrics" > "$work/metrics.jsonl"
  git -C "$work" add -A
  git -C "$work" -c user.email=a@b -c user.name=a commit -q -m metrics
  git -C "$work" push -q origin boucle/metrics
  git -C "$work" fetch -q origin \
    "refs/heads/boucle/metrics:refs/remotes/origin/boucle/metrics"
}

@test "audit: metrics wiring reports the branch counts and last-row age" {
  WORK="$TMP/metrics-audit"
  metrics_audit_work "$WORK" '{"schema":3,"timestamp":"2026-10-02T10:00:00Z","issue":"7","terminal":"done"}
{"schema":1,"timestamp":"2026-10-02T11:00:00Z","event":"heartbeat","stage":"dispatch"}
'
  cd "$WORK" || return 1
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash "$REPO/bin/doctor" --audit
  assert_success
  assert_output --partial "metrics: boucle/metrics carries 1 issue row(s)"
  assert_output --partial "1 heartbeat(s)"
  assert_output --partial "last row: 2026-10-02T11:00:00Z"
}

@test "audit: a never-populated branch with metrics enabled is flagged" {
  WORK="$TMP/metrics-empty"
  metrics_audit_work "$WORK" ''
  cd "$WORK" || return 1
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash "$REPO/bin/doctor" --audit
  assert_success
  assert_output --partial "ADVISORY"
  assert_output --partial "metrics are enabled but boucle/metrics has never carried a row"
}

@test "audit: a disabled metrics switch is reported, never flagged" {
  WORK="$TMP/metrics-disabled"
  metrics_audit_work "$WORK" ''
  cd "$WORK" || return 1
  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_METRICS_ENABLED=false bash "$REPO/bin/doctor" --audit
  assert_success
  assert_output --partial "metrics: disabled"
  refute_output --partial "has never carried a row"
}
