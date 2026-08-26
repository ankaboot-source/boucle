#!/usr/bin/env bats

# test/spec-metadata.bats — the merged `## Metadata` section of a triage spec
#
# The spec's machine-facing fields (impacts, impacted files, size,
# validation, disposition) used to be four separate sections a human
# scrolled past: ## Impacts, ## Impacted files, ## Classification and
# ## Disposition. They are now one `## Metadata` section at the end of the
# comment. These tests pin BOTH halves of that contract:
#   1. the new format parses (disposition, size, validation);
#   2. a spec posted before the merge — still in flight on a paused issue —
#      keeps parsing through the legacy fallback.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  PARSERS="$(mktemp)"
  # The parsers live inside boucle_ci_triage(), indented two spaces.
  awk '
    /^  (spec_section|parse_disposition|parse_size|parse_validation)\(\) \{/ { p = 1 }
    p { print }
    p && /^  \}$/ { p = 0 }
  ' lib/boucle-ci/triage.sh > "$PARSERS"
  NEW_SPEC='<!-- boucle:triage v=1 -->
## TL;DR
The page already loads, it just needs a link.

## Draft acceptance criteria
- [ ] **Happy path** — Given a visitor, When they open /, Then the link is visible

## Metadata
<!-- boucle:impacts v=1 kinds=architecture,ui -->
<!-- boucle:files v=1 paths=src/Layout.astro,src/pages/index.astro -->
- **Impacts** — 🏗️ architecture, ui
- **Impacted files** — 📁 `src/Layout.astro`, `src/pages/index.astro`
- **Size** — M
- **Validation** — author-required
- **Disposition** — NEEDS-INFO'
  LEGACY_SPEC='<!-- boucle:triage v=1 -->
## TL;DR
The page already loads, it just needs a link.

## Impacts
🏗️ architecture, ui

<!-- boucle:impacts v=1 kinds=architecture,ui -->

## Impacted files
📁 `src/Layout.astro`

<!-- boucle:files v=1 paths=src/Layout.astro -->

## Classification
Size: M
Validation: author-required

## Disposition
NEEDS-INFO'
}

teardown() {
  rm -f "$PARSERS"
}

# Run one parser against a body, in a subshell that has sourced the
# extracted definitions.
parse() {
  bash -c ". '$PARSERS'; $1 \"\$1\"" bash "$2"
}

# ── The parsers read the merged section ───────────────────────────────

@test "metadata: disposition parses from the ## Metadata section" {
  run parse parse_disposition "$NEW_SPEC"
  assert_output "NEEDS-INFO"
}

@test "metadata: size parses from the ## Metadata section" {
  run parse parse_size "$NEW_SPEC"
  assert_output "M"
}

@test "metadata: validation parses from the ## Metadata section" {
  run parse parse_validation "$NEW_SPEC"
  assert_output "author-required"
}

@test "metadata: every disposition value round-trips" {
  for d in READY NEEDS-INFO NEEDS-SPLIT; do
    run parse parse_disposition "## Metadata
- **Size** — S
- **Disposition** — $d"
    assert_output "$d"
  done
}

@test "metadata: an autonomous validation parses" {
  run parse parse_validation "## Metadata
- **Validation** — autonomous
- **Disposition** — READY"
  assert_output "autonomous"
}

# ── Legacy specs (posted before the merge) still parse ────────────────

@test "legacy: disposition falls back to the standalone ## Disposition section" {
  run parse parse_disposition "$LEGACY_SPEC"
  assert_output "NEEDS-INFO"
}

@test "legacy: size falls back to the ## Classification section" {
  run parse parse_size "$LEGACY_SPEC"
  assert_output "M"
}

@test "legacy: validation falls back to the ## Classification section" {
  run parse parse_validation "$LEGACY_SPEC"
  assert_output "author-required"
}

# ── No false matches (the reason parsing is section-scoped) ───────────

@test "scoping: 'already' in an acceptance criterion is not a READY disposition" {
  # A whole-body grep for READY matches "already". The parser is scoped to
  # the machine section, so a spec with no disposition returns empty.
  run parse parse_disposition '## TL;DR
The link already exists.

## Draft acceptance criteria
- [ ] **Happy path** — Given the page is already rendered, Then the link shows'
  assert_output ""
}

@test "scoping: a size mentioned in prose outside ## Metadata is ignored" {
  run parse parse_size '## Analysis
Size L would be wrong here — this is one line of CSS.

## Metadata
- **Size** — S
- **Disposition** — READY'
  assert_output "S"
}

@test "scoping: the section ends at the next header" {
  # A field that appears AFTER ## Metadata closes belongs to no section.
  run parse parse_disposition '## Metadata
- **Size** — S

## Consequences
- The follow-up issue is READY once this merges.'
  assert_output ""
}

@test "scoping: parsers return empty on a comment with no machine section" {
  run parse parse_disposition '## TL;DR
Nothing structured here.'
  assert_output ""
  run parse parse_size '## TL;DR
Nothing structured here.'
  assert_output ""
  run parse parse_validation '## TL;DR
Nothing structured here.'
  assert_output ""
}

# ── The routing filters accept both shapes ────────────────────────────

@test "filters: the triage note selector accepts ## Metadata and ## Disposition" {
  local notes='[
    {"id": 1, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Metadata\n- **Disposition** — READY"},
    {"id": 2, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"},
    {"id": 3, "body": "<!-- boucle:triage v=1 -->\nDRAFT — refining next.\n\n## Metadata\n- **Disposition** — READY"}
  ]'
  # The filter used by triage.sh and bin/collapse-duplicate-notes: marker +
  # ## TL;DR + the machine section. Note 3 (no ## TL;DR) must not match.
  run bash -c "printf '%s' '$notes' | jq -r '[.[] | select(.body | test(\"<!-- boucle:triage\")) | select(.body | test(\"(?m)^## TL;DR\")) | select(.body | test(\"(?m)^## (Metadata|Disposition)\")) | .id] | @csv'"
  assert_output '1,2'
}

@test "filters: triage.sh and collapse-duplicate-notes use the same alternation" {
  run bash -c "grep -c '## (Metadata|Disposition)' lib/boucle-ci/triage.sh"
  [ "$output" -ge 5 ]
  run grep -q '(?m)\^## (Metadata|Disposition)' bin/collapse-duplicate-notes
  assert_success
}

# ── The log-scrape fallback stops on the disposition line ─────────────

@test "log-scrape: a full new-format comment is recovered from the agent log" {
  # The step-limit fallback scrapes from the marker to the disposition
  # line. In the merged format that line is the LAST line of the comment,
  # so the whole spec — markers included — is recovered.
  local log
  log="$(mktemp)"
  {
    printf '> triage · glm-5.2\n'
    printf '%s\n' "$NEW_SPEC"
    printf 'Done in 42 steps.\n'
  } > "$log"
  run awk '
    /^<!-- boucle:triage v=1 -->/ { found=1 }
    found { print; if (/^## (Metadata|Disposition)/) { disp=1 } }
    disp && /(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ { exit }
  ' "$log"
  assert_output --partial '<!-- boucle:impacts v=1 kinds=architecture,ui -->'
  assert_output --partial '<!-- boucle:files v=1 paths=src/Layout.astro,src/pages/index.astro -->'
  assert_output --partial '- **Disposition** — NEEDS-INFO'
  refute_output --partial 'Done in 42 steps.'
  rm -f "$log"
}

@test "log-scrape: a legacy comment still stops at the bare disposition line" {
  local log
  log="$(mktemp)"
  {
    printf '%s\n' "$LEGACY_SPEC"
    printf 'Done in 42 steps.\n'
  } > "$log"
  run awk '
    /^<!-- boucle:triage v=1 -->/ { found=1 }
    found { print; if (/^## (Metadata|Disposition)/) { disp=1 } }
    disp && /(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ { exit }
  ' "$log"
  assert_output --partial '## Disposition'
  refute_output --partial 'Done in 42 steps.'
  rm -f "$log"
}

# ── The template and the prompt emit one section, not four ────────────

@test "template: templates/triage.md has a single ## Metadata section and no legacy ones" {
  run bash -c "grep -c '^## Metadata\$' templates/triage.md"
  assert_output "1"
  run grep -qE '^## (Impacts|Impacted files|Classification|Disposition)$' templates/triage.md
  assert_failure
}

@test "template: ## Metadata is the last section and ends on the disposition" {
  run bash -c "grep '^## ' templates/triage.md | tail -1"
  assert_output "## Metadata"
  run bash -c "tail -1 templates/triage.md"
  assert_output '- **Disposition** — {{disposition}}'
}

@test "template: both machine markers sit inside ## Metadata" {
  run bash -c "awk '/^## Metadata\$/{f=1;next}/^## /{f=0}f' templates/triage.md"
  assert_output --partial '<!-- boucle:impacts v=1 kinds='
  assert_output --partial '<!-- boucle:files v=1 paths='
}

@test "prompt: triage.md emits the merged section in its output format" {
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -c '^## Metadata\$'"
  assert_output "1"
}

@test "prompt: triage.md tells the agent not to split the section back out" {
  run grep -q 'Never split these' .jcode/agents/triage.md
  assert_success
  run grep -q 'they were merged into `## Metadata`' .jcode/agents/triage.md
  assert_success
}

@test "prompt: no legacy section header survives in the output format block" {
  # The prose may name the old headers (to forbid them); the format block
  # the agent copies must not contain them as headers.
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -cE '^## (Impacts|Impacted files|Classification|Disposition)\$'"
  assert_output "0"
}
