#!/usr/bin/env bats

# test/spec-sections.bats — the section layout of a triage spec comment
#
# Two groups of sections were merged so the human reads a spec instead of
# scrolling past headers:
#   - the machine-facing fields (## Impacts, ## Impacted files,
#     ## Classification, ## Disposition) → one `## Metadata` section, last;
#   - the contract (## Draft acceptance criteria, ## Must-haves,
#     ## Non-goals) → one `## Criteria` section with three `###` blocks.
# Each test group pins BOTH halves of the contract:
#   1. the new shape parses;
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
    /^  (spec_section|spec_field_line|parse_disposition|parse_size|parse_validation)\(\) \{/ { p = 1 }
    p { print }
    p && /^  \}$/ { p = 0 }
  ' lib/boucle-ci/triage.sh > "$PARSERS"
  NEW_SPEC='<!-- boucle:triage v=1 -->
## TL;DR
The page already loads, it just needs a link.

## Draft acceptance criteria
- [ ] **Happy path** — Given a visitor, When they open /, Then the link is visible

## Metadata
<details><summary>machine block — CI reads this, you do not have to</summary>

<!-- boucle:impacts v=1 kinds=architecture,ui -->
<!-- boucle:files v=1 paths=src/Layout.astro,src/pages/index.astro -->
- **Impacts** — 🏗️ architecture, ui
- **Impacted files** — 📁 `src/Layout.astro`, `src/pages/index.astro`
- **Size** — M
- **Validation** — author-required
- **Disposition** — NEEDS-INFO

</details>'
  NEW_CRITERIA='## Criteria

### Acceptance
- [ ] **Happy path** — Given a visitor, When they open /, Then the link is visible

### Must-haves
- **Truths** — the page loads in <2s on 3G

### Non-goals
- do not touch the auth flow

## Metadata
- **Disposition** — READY'
  LEGACY_CRITERIA='## Draft acceptance criteria
- [ ] **Happy path** — legacy criterion

## Must-haves
- **Truths** — legacy truth

## Non-goals
- legacy non-goal

## Classification
Size: M'
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
    found && /^<details>|^<details><summary>/ { det=1 }
    found { print; if (/^## (Metadata|Disposition)/) { disp=1 } }
    disp && /(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ {
      if (det) { print ""; print "</details>" }
      exit
    }
  ' "$log"
  assert_output --partial '<!-- boucle:impacts v=1 kinds=architecture,ui -->'
  assert_output --partial '<!-- boucle:files v=1 paths=src/Layout.astro,src/pages/index.astro -->'
  assert_output --partial '- **Disposition** — NEEDS-INFO'
  refute_output --partial 'Done in 42 steps.'
  # The recovered comment closes the <details> it opened — an unbalanced
  # tag would swallow the rest of the rendered comment.
  [ "$(printf '%s\n' "$output" | grep -c '<details>')" = "$(printf '%s\n' "$output" | grep -c '</details>')" ]
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
    found && /^<details>|^<details><summary>/ { det=1 }
    found { print; if (/^## (Metadata|Disposition)/) { disp=1 } }
    disp && /(READY|NEEDS-INFO|NEEDS-SPLIT)[[:space:]]*$/ {
      if (det) { print ""; print "</details>" }
      exit
    }
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
  # Last field of the block (the collapsed wrapper closes after it): the
  # step-limit log-scrape stops on the disposition line.
  run bash -c "grep -v '^</details>\$' templates/triage.md | sed '/^\$/d' | tail -1"
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

# ── The criteria contract: one ## Criteria section, three ### blocks ───

# Extract spec_criteria_block from worker.sh (a top-level function there).
criteria() {
  local fn
  fn="$(mktemp)"
  awk '/^spec_criteria_block\(\) \{/ { p = 1 } p { print } p && /^\}$/ { p = 0 }' \
    lib/boucle-ci/worker.sh > "$fn"
  bash -c ". '$fn'; spec_criteria_block \"\$1\" \"\$2\" \"\$3\"" bash "$1" "$2" "$3"
  rm -f "$fn"
}

@test "criteria: acceptance parses from the ### Acceptance block" {
  run criteria "$NEW_CRITERIA" Acceptance "Draft acceptance criteria"
  assert_output --partial '**Happy path**'
  refute_output --partial 'Truths'
  refute_output --partial 'do not touch'
}

@test "criteria: must-haves parses from the ### Must-haves block" {
  run criteria "$NEW_CRITERIA" Must-haves Must-haves
  assert_output --partial '**Truths**'
  refute_output --partial 'Happy path'
}

@test "criteria: non-goals parses from the ### Non-goals block" {
  run criteria "$NEW_CRITERIA" Non-goals Non-goals
  assert_output --partial 'do not touch the auth flow'
  refute_output --partial 'Truths'
}

@test "criteria: a block stops before the next ## section" {
  # ## Metadata follows ### Non-goals — its bullets must not leak into the
  # non-goals seeded into state.md.
  run criteria "$NEW_CRITERIA" Non-goals Non-goals
  refute_output --partial 'Disposition'
}

@test "criteria: legacy top-level sections still parse (fallback)" {
  run criteria "$LEGACY_CRITERIA" Acceptance "Draft acceptance criteria"
  assert_output --partial 'legacy criterion'
  run criteria "$LEGACY_CRITERIA" Must-haves Must-haves
  assert_output --partial 'legacy truth'
  run criteria "$LEGACY_CRITERIA" Non-goals Non-goals
  assert_output --partial 'legacy non-goal'
}

@test "criteria: a missing block yields empty, not the whole comment" {
  run criteria '## TL;DR
No contract here.' Acceptance "Draft acceptance criteria"
  refute_output --partial 'No contract here.'
}

@test "template: templates/triage.md groups the contract under ## Criteria" {
  run bash -c "grep -c '^## Criteria\$' templates/triage.md"
  assert_output "1"
  run bash -c "grep -cE '^### (Acceptance|Must-haves|Non-goals)\$' templates/triage.md"
  assert_output "3"
  run grep -qE '^## (Draft acceptance criteria|Must-haves|Non-goals)$' templates/triage.md
  assert_failure
}

@test "prompt: triage.md emits ## Criteria with the three ### blocks" {
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -cE '^### (Acceptance|Must-haves|Non-goals)\$'"
  assert_output "3"
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -cE '^## (Draft acceptance criteria|Must-haves|Non-goals)\$'"
  assert_output "0"
}

@test "state.md keeps its own three sections (reviewer and e2e read them there)" {
  run bash -c "awk '/Seed state.md on first run/,/^  fi\$/' lib/boucle-ci/worker.sh"
  assert_output --partial '## Acceptance criteria'
  assert_output --partial '## Must-haves'
  assert_output --partial '## Non-goals'
}

# ── The approval call to action sits at the very end ──────────────────

@test "approval: the ## Validation block is appended last" {
  # `## Metadata` renders as a single collapsed line, so the call to
  # action stays the last thing in the comment.
  local body='## TL;DR
Short.

## Metadata
<details><summary>machine block — CI reads this, you do not have to</summary>

- **Disposition** — READY

</details>'
  run bash -c "printf '%s\n\n%s' \"\$1\" '## Validation

React to approve.' | grep '^## ' | paste -sd' ' -" bash "$body"
  assert_output '## TL;DR ## Metadata ## Validation'
}

@test "approval: triage.sh appends the block rather than inserting it" {
  run bash -c "awk '/Idempotency guard: skip if the validation section/,/UPDATED_BODY=/' lib/boucle-ci/triage.sh"
  assert_output --partial 'The call to action goes LAST'
  assert_output --partial 'UPDATED_BODY=$(printf'
}

@test "approval: the appended block does not disturb field parsing" {
  # ## Validation closes the ## Metadata section — the fields are before
  # it, so the disposition still parses after CI appends the block.
  run parse parse_disposition "$NEW_SPEC
\n## Validation\n\nReact with 👍 to approve."
  assert_output "NEEDS-INFO"
}

# ── The two visual sections open the spec ─────────────────────────────

@test "layout: ## Diagram comes before ## Analysis in the template" {
  run bash -c "grep '^## ' templates/triage.md | head -3 | paste -sd' ' -"
  assert_output --partial '## TL;DR'
  # TL;DR, then the diagram, then the prose.
  [[ "$output" =~ TL\;DR.*Diagram.*Analysis ]]
}

@test "layout: ## Diagram comes before ## Analysis in the prompt's output format" {
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -E '^## (TL;DR|Diagram|Analysis)' | paste -sd' ' -"
  [[ "$output" =~ TL\;DR.*Diagram.*Analysis ]]
}

@test "layout: the rendered preview lands in the same slot, above the diagram" {
  # CI inserts ## Preview at the first `## ` header after ## TL;DR — now
  # the diagram — so preview and diagram sit together at the top.
  local body='## TL;DR
Short.

## Diagram
caption

## Analysis
prose'
  run bash -c "printf '%s\n' \"\$1\" | awk -v img='![shot](/uploads/a.png)' '
    /^## TL;DR/ { in_tldr=1; print; next }
    in_tldr && /^## / && !inserted { print \"## Preview\"; print img; print \"\"; inserted=1; in_tldr=0 }
    { print }
    END { if (!inserted) { print \"\"; print \"## Preview\"; print img } }
  ' | grep '^## ' | paste -sd' ' -" bash "$body"
  assert_output '## TL;DR ## Preview ## Diagram ## Analysis'
}

@test "layout: the preview insertion in triage.sh still anchors on ## TL;DR" {
  run bash -c "awk '/insert Preview right after/,/inserted=1/' lib/boucle-ci/triage.sh"
  assert_output --partial '/^## TL;DR/ { in_tldr=1'
}

# ── The machine block is collapsed by default ─────────────────────────

@test "collapsed: the fields parse through the <details> wrapper" {
  run parse parse_disposition "$NEW_SPEC"
  assert_output "NEEDS-INFO"
  run parse parse_size "$NEW_SPEC"
  assert_output "M"
  run parse parse_validation "$NEW_SPEC"
  assert_output "author-required"
}

@test "collapsed: the <summary> line is chrome, never a field value" {
  # A summary naming the fields would poison a section-wide grep. The
  # parsers read the `- **Field** — value` bullets only.
  run parse parse_size '## Metadata
<details><summary>impacts · size · validation · disposition</summary>

- **Size** — L

</details>'
  assert_output "L"
  run parse parse_disposition '## Metadata
<details><summary>size · validation · disposition (READY when green)</summary>

- **Disposition** — NEEDS-SPLIT

</details>'
  assert_output "NEEDS-SPLIT"
}

@test "collapsed: a field written without its bullet still parses" {
  # Tolerance for an agent that drops the dashes — the second pass skips
  # the HTML chrome rather than the whole section.
  run parse parse_disposition '## Metadata
<details><summary>machine block</summary>

Disposition: NEEDS-SPLIT

</details>'
  assert_output "NEEDS-SPLIT"
  run parse parse_size '## Metadata
<details><summary>machine block</summary>

Size: L

</details>'
  assert_output "L"
}

@test "collapsed: template wraps the fields and leaves the header outside" {
  # The header stays a real `## ` section: CI anchors the field parsing
  # and the ## Validation insertion on it.
  run bash -c "grep -A1 '^## Metadata\$' templates/triage.md | tail -1"
  assert_output --partial '<details>'
  run bash -c "awk '/^## Metadata\$/{f=1;next}/^## /{f=0}f' templates/triage.md | grep -c '</details>'"
  assert_output "1"
  # Blank line after <summary> and before </details> — without them the
  # forge renders the markdown inside as raw text.
  run bash -c "awk '/^## Metadata\$/,0' templates/triage.md | sed -n '3p'"
  assert_output ""
}

@test "collapsed: the prompt shows the wrapper in its output format" {
  run bash -c "awk '/^## Output format/,0' .jcode/agents/triage.md | grep -c '<details><summary>'"
  assert_output "1"
  run grep -q 'wrap the fields in the `<details>` block exactly as' .jcode/agents/triage.md
  assert_success
}
