#!/usr/bin/env bats
# Spec gate: the decision is emitted, and the AUTHOR approves (#2)
#
# The gate used to be (LLM size judgment x BOUCLE_SPEC_PROFILE) -> decision,
# which is the inference-on-agent-output trap AGENTS.md principle 12 names:
# the decision belonged to neither the agent nor the config, and could be
# read off neither. And any non-bot actor could approve someone else's spec.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# The gate is a case statement inside boucle_ci_triage; drive it directly.
gate() {
  local validation="$1" profile="$2" size="$3"
  bash -c "
    set -euo pipefail
    VALIDATION='$validation'; SPEC_PROFILE='$profile'; SIZE='$size'
    SHOULD_GATE=false
    case \"\${VALIDATION:-}\" in
      author-required) SHOULD_GATE=true ;;
      autonomous) SHOULD_GATE=false ;;
      *)
        case \"\$SPEC_PROFILE\" in
          off) SHOULD_GATE=false ;;
          strict) SHOULD_GATE=true ;;
          product) [ \"\$SIZE\" = 'M' ] && SHOULD_GATE=true ;;
          *) [ \"\$SIZE\" = 'M' ] && SHOULD_GATE=true ;;
        esac
        ;;
    esac
    echo \"\$SHOULD_GATE\"
  "
}

@test "gate: the emitted field wins over the size x profile mapping" {
  # A Size S issue under the 'product' profile would NOT have been gated by
  # the old mapping. The agent's decision overrides it.
  [ "$(gate author-required product S)" = "true" ]
  # And an M issue the agent judged autonomous is not gated, though the
  # mapping would have gated it.
  [ "$(gate autonomous product M)" = "false" ]
}

@test "gate: the emitted field wins even against the strict profile" {
  [ "$(gate autonomous strict L)" = "false" ]
  [ "$(gate author-required off S)" = "true" ]
}

@test "gate: no emitted field falls back to the old mapping" {
  # Compatibility path for a comment predating the field, or one posted
  # before the agent exhausted its steps.
  [ "$(gate '' product M)" = "true" ]
  [ "$(gate '' product S)" = "false" ]
  [ "$(gate '' strict S)" = "true" ]
  [ "$(gate '' off M)" = "false" ]
}

@test "gate: the fallback is announced, not silent" {
  run grep -q 'falling back to the size x profile mapping' lib/boucle-ci/triage.sh
  assert_success
}

@test "gate: triage emits Validation in its comment format" {
  run bash -c "grep -c 'Validation: author-required | autonomous' .jcode/agents/triage.md"
  assert_output "2"
}

@test "gate: the agent is handed the policy instead of the config applying it" {
  # AGENTS.md principle 12: make the agent's output more structured rather
  # than building an inference layer on top of it.
  run grep -q 'Spec-validation policy in force: BOUCLE_SPEC_PROFILE=' bin/jc
  assert_success
  run grep -q 'this is your call, not a config' .jcode/agents/triage.md
  assert_success
}

@test "gate: triage is told to emit exactly one value" {
  run grep -q 'Emit exactly one value' .jcode/agents/triage.md
  assert_success
}

# ── Approval belongs to the author ────────────────────────────────────

approver() {
  local actor="$1" author="$2" bot="${3:-up-bot}"
  bash -c "
    ACTOR='$actor'; SPEC_AUTHOR='$author'; BOUCLE_BOT_USERNAME='$bot'; IID=7
    forge_issue_note() { :; }
    spec_approver_ok() {
      [ \"\$ACTOR\" = \"\${BOUCLE_BOT_USERNAME:-up-bot}\" ] && return 1
      [ -z \"\$SPEC_AUTHOR\" ] && return 0
      [ \"\$ACTOR\" = \"\$SPEC_AUTHOR\" ] && return 0
      return 1
    }
    if spec_approver_ok; then echo yes; else echo no; fi
  "
}

@test "approval: the author approves" {
  [ "$(approver alice alice)" = "yes" ]
}

@test "approval: a colleague does not" {
  [ "$(approver bob alice)" = "no" ]
}

@test "approval: the bot never does" {
  [ "$(approver up-bot up-bot)" = "no" ]
  [ "$(approver up-bot alice)" = "no" ]
}

@test "approval: an unresolvable author falls back to the previous behaviour" {
  # Empty means UNKNOWN, never "not the author": denying on an API hiccup
  # would stall the loop, and the fallback is the status quo, not a new risk.
  [ "$(approver bob '')" = "yes" ]
  run grep -q 'accepting approval from any non-bot actor (previous behaviour)' lib/boucle-ci/dispatch.sh
  assert_success
}

@test "approval: a non-author is told who has to act, not ignored silently" {
  run grep -q "la validation du spec revient à l'auteur de l'issue" lib/boucle-ci/dispatch.sh
  assert_success
}

@test "approval: the author walk handles bot-created sub-issues" {
  run grep -q '^resolve_reporter_username()' lib/boucle.sh
  assert_success
  run bash -c "awk '/^resolve_reporter_username\(\) \{/,/^}/' lib/boucle.sh | grep -c 'Parent issue'"
  assert_output "1"
}
