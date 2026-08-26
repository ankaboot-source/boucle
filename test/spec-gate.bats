#!/usr/bin/env bats
# Spec gate: the decision is emitted, and the AUTHOR approves (#2)
#
# The gate used to be (LLM size judgment x BOUCLE_SPEC_PROFILE) -> decision,
# which is the inference-on-agent-output trap LESSONS.yml lesson #87 names:
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
  # The field lives in the merged ## Metadata section: draft format,
  # Phase-1 final format, and the Output format block.
  run bash -c "grep -c -- '- \*\*Validation\*\* — author-required | autonomous' .jcode/agents/triage.md"
  assert_output "3"
}

@test "gate: the agent is handed the policy instead of the config applying it" {
  # LESSONS.yml lesson #87: make the agent's output more structured rather
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
  # The gate resolves the author through the SAME parent walk the assignment
  # path uses, so a bot-created sub-issue resolves to the human who owns the
  # parent instead of to the bot. Sharing the walk is the property under test:
  # a second, divergent implementation is how the two paths drift apart.
  run grep -q '^resolve_reporter_username()' lib/boucle.sh
  assert_success
  run bash -c "awk '/^resolve_reporter_username\(\) \{/,/^}/' lib/boucle.sh | grep -c '_resolve_reporter_walk'"
  assert_output "1"
  run bash -c "awk '/^_resolve_reporter_walk\(\) \{/,/^}/' lib/boucle.sh | grep -c 'Parent issue'"
  assert_output "1"
}

# ── The doctor mirrors the dispatch contract ───────────────────────────
# LESSONS.yml lesson #83 ✅: "mirror the dispatch contract in the doctor's
# orphan-recovery path so a missed webhook recovers to the same state."
# Restricting approval to the author in the dispatch alone leaves the gate
# bypassable by waiting: dispatch refuses a colleague's 👍, the next doctor
# sweep accepts it.

@test "doctor: orphan recovery resolves the author before accepting a reaction" {
  run bash -c "awk '/Recover orphaned boucle:spec-review/,/EMOJI_APPROVAL_FOUND=false/' lib/boucle-ci/doctor.sh | grep -c 'resolve_reporter_username'"
  assert_output "1"
}

@test "doctor: the reaction filter is scoped to the author, not any non-bot user" {
  # The jq filter must narrow on the author in ADDITION to excluding the bot.
  run bash -c "awk '/AWARDS=\\\$\\(forge_note_reactions/,/length > 0/' lib/boucle-ci/doctor.sh"
  assert_success
  assert_output --partial 'select(.user.username != $bname)'
  assert_output --partial 'select($author == "" or .user.username == $author)'
}

@test "doctor: an unresolvable author falls back to any non-bot reactor" {
  # Fail-open, same as the dispatch: an API hiccup must not stall the loop.
  # The empty-author disjunct in the jq filter IS the fallback.
  run bash -c "awk '/AWARDS=\\\$\\(forge_note_reactions/,/length > 0/' lib/boucle-ci/doctor.sh | grep -c '\\\$author == \"\"'"
  assert_output "1"
  run grep -q 'accepting a reaction from any non-bot user (previous behaviour)' lib/boucle-ci/doctor.sh
  assert_success
}

# ── Spec-completeness guard (LESSONS.yml lesson #92) ───────────────────
# A triage comment is only routable when it carries BOTH ## TL;DR and
# ## Disposition. The main jq COMMENT filter already enforces this, but
# three recovery paths (pre-agent draft promotion, log-scraping fallback,
# posted-draft promotion) parse ## Disposition DIRECTLY, bypassing the
# ## TL;DR check. An agent that posts a draft stub ("DRAFT — first-pass
# triage, refining next.") with the FINAL marker + ## Disposition READY
# but no ## TL;DR would be promoted by those paths, routing an EMPTY
# spec to the spec gate and asking the human to approve nothing
# (boucle.dev #73). The guard refuses to promote a comment without
# ## TL;DR and escalates to human instead of routing an empty spec.

@test "spec-completeness: comment_has_tldr detects a ## TL;DR section header" {
  run bash -c "
    comment_has_tldr() { printf '%s' \"\$1\" | grep -qiE '^## TL;DR[[:space:]]*\$'; }
    comment_has_tldr '## TL;DR
some content' && echo yes || echo no
  "
  assert_output "yes"
}

@test "spec-completeness: comment_has_tldr rejects a draft stub without ## TL;DR" {
  run bash -c "
    comment_has_tldr() { printf '%s' \"\$1\" | grep -qiE '^## TL;DR[[:space:]]*\$'; }
    comment_has_tldr 'DRAFT — first-pass triage, refining next.
## Disposition
READY' && echo yes || echo no
  "
  assert_output "no"
}

@test "spec-completeness: comment_has_tldr does not false-match TL;DR in prose" {
  # A body-text grep for 'TL;DR' would false-match website content being
  # triaged (e.g. a draft page the author wants reviewed). The structural
  # check (section header) does not.
  run bash -c "
    comment_has_tldr() { printf '%s' \"\$1\" | grep -qiE '^## TL;DR[[:space:]]*\$'; }
    comment_has_tldr 'The TL;DR of this issue is that the page is broken.
## Disposition
READY' && echo yes || echo no
  "
  assert_output "no"
}

@test "spec-completeness: triage.sh defines comment_has_tldr and INCOMPLETE_SPEC" {
  run grep -q 'comment_has_tldr()' lib/boucle-ci/triage.sh
  assert_success
  run grep -q 'INCOMPLETE_SPEC=0' lib/boucle-ci/triage.sh
  assert_success
}

@test "spec-completeness: pre-agent draft promotion guards on ## TL;DR" {
  # The pre-agent promotion path MUST call comment_has_tldr before promoting
  # a draft. A draft without ## TL;DR is an incomplete spec.
  run bash -c "grep -c 'comment_has_tldr \"\$PRE_DRAFTED_COMMENT\"' lib/boucle-ci/triage.sh"
  assert_success
  [ "$output" -ge 1 ]
}

@test "spec-completeness: log-scraping fallback guards on ## TL;DR" {
  run bash -c "grep -c 'comment_has_tldr \"\$DRAFTED_COMMENT\"' lib/boucle-ci/triage.sh"
  assert_success
  [ "$output" -ge 2 ]
}

@test "spec-completeness: posted-draft promotion guards on ## TL;DR" {
  # The posted-draft promotion path also guards on ## TL;DR (the second
  # occurrence of comment_has_tldr \"\$DRAFTED_COMMENT\" is in this path).
  run bash -c "grep -c 'comment_has_tldr' lib/boucle-ci/triage.sh"
  assert_success
  # 3 call sites (pre-agent, log-scrape, posted-draft) + 1 definition = 4.
  [ "$output" -ge 4 ]
}

@test "spec-completeness: INCOMPLETE_SPEC escalation posts a note and escalates to human" {
  # When INCOMPLETE_SPEC=1, the no-disposition handler MUST post an
  # explanatory note and set boucle:human — never route an empty spec to
  # the spec gate.
  run bash -c "awk '/Incomplete-spec escalation/,/set_boucle_label .*boucle:human/' lib/boucle-ci/triage.sh | grep -c 'INCOMPLETE_SPEC'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | tail -1)" -ge 1 ]
  run grep -q 'incomplete spec' lib/boucle-ci/triage.sh
  assert_success
  run grep -q 'empty spec cannot be approved' lib/boucle-ci/triage.sh
  assert_success
}

@test "spec-completeness: the escalation note names the re-trigger path" {
  # The human must know how to resume: re-apply boucle:triage.
  run grep -q 'Re-trigger triage' lib/boucle-ci/triage.sh
  assert_success
}

# ── Mutually-exclusive options are blocking, not advisory ──────────────
# LESSONS.yml lesson #94: the triage agent used to present 3 mutually-
# exclusive user-visible outcomes (different taglines, different logo
# treatments) as `## Creative proposals` with `Questions: none` and
# Disposition READY. But creative proposals are advisory — the worker is
# not bound by them. When the worker must pick between variants, the
# choice changes what gets built, so it is a blocking question. A READY
# spec with three directions and no question forces the worker to guess
# (boucle.dev #73).

@test "prompt: triage.md distinguishes advisory proposals from blocking choices" {
  # The prompt must tell the agent that mutually-exclusive user-visible
  # outcomes are blocking questions, not creative proposals.
  run grep -q 'Mutually-exclusive options are NOT creative proposals' .jcode/agents/triage.md
  assert_success
  run grep -q 'Mutually-exclusive user-visible outcomes are always blocking' .jcode/agents/triage.md
  assert_success
}

@test "prompt: the advisory/ blocking test is stated in the prompt" {
  # The agent needs a decision rule, not just a prohibition. The test:
  # "if the worker picks the wrong one, is the result visibly wrong?" →
  # blocking; "if the worker ignores it, is the result still correct?" →
  # advisory.
  run grep -q 'if the worker picks the wrong one, is the result visibly wrong' .jcode/agents/triage.md
  assert_success
  run grep -q 'if the worker ignores it, is the result still correct' .jcode/agents/triage.md
  assert_success
}

@test "prompt: the self-review checklist catches mutually-exclusive proposals" {
  # The self-review checklist (§3) must scan Creative proposals for
  # mutually-exclusive variants and force them into Questions before
  # posting. A READY spec with three directions and no question is a
  # triage defect — catch it before the comment ships.
  run grep -q 'Mutually-exclusive options' .jcode/agents/triage.md
  assert_success
  run bash -c "grep -c 'Mutually-exclusive options' .jcode/agents/triage.md"
  # Two occurrences: the rule in Phase 3 + the checklist item in §3.
  [ "$output" -ge 2 ]
}
