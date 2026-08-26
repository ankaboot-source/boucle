#!/usr/bin/env bats
#
# test/diagram-syntax.bats — the deterministic diagram syntax gate.
#
# Regression target: boucle.dev#86. That spec passed every gate — it declared
# `data-model` impacts, carried a `## Diagram` section AND a valid
# `<!-- boucle:diagram v=1 -->` marker — and still reached the human with a
# diagram the forge rendered as an error box, because nothing had ever asked
# the Mermaid parser whether the diagram parses.
#
# Two layers, tested separately:
#   - bin/check-mermaid — extraction + the real parser. Needs mermaid/jsdom;
#     the tests that need a parser skip when it is unavailable, and the
#     resolution/fail-open paths are tested with a stubbed PATH instead.
#   - check_diagram_syntax_gate (lib/boucle-ci/gates.sh) — the block/pass
#     decision. Tested against a STUBBED bin/check-mermaid so the verdict
#     logic is exercised with no parser and no network at all.

# shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  TMP="$(mktemp -d)"
  export TMP
  # One cache for the whole run, not one per test: on a runner with no
  # pre-baked mermaid the checker installs it once, and the remaining tests
  # reuse that install instead of paying for it eleven times.
  # shellcheck disable=SC2154 # BATS_RUN_TMPDIR is set by bats at runtime
  export BOUCLE_MERMAID_CACHE="${BOUCLE_MERMAID_CACHE:-$BATS_RUN_TMPDIR/mermaid-cache}"
}

teardown() {
  rm -rf "$TMP"
}

# A PATH holding ONLY the binaries named, so the resolution order can be
# driven from the test (no node, no npm, no accidental global mermaid).
stub_path() {
  local dir="$TMP/stub-bin" tool
  mkdir -p "$dir"
  for tool in "$@"; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  echo "$dir"
}

# True when the checker can actually obtain a parser HERE — asked by running
# it, not by guessing at install locations. Exit 3 is its "unavailable"
# signal; anything else means it parsed something. This deliberately lets
# the checker's own npm fallback run, so a CI runner with node and network
# exercises the real parser instead of skipping every verdict test.
have_parser() {
  local rc=0
  printf '```mermaid\nflowchart LR\n  A --> B\n```\n' \
    | "$REPO_ROOT/bin/check-mermaid" - > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 3 ]
}

# ── bin/check-mermaid: contract ────────────────────────────────────────

@test "check-mermaid: no argument is a usage error (exit 2)" {
  run "$REPO_ROOT/bin/check-mermaid"
  [ "$status" -eq 2 ]
  assert_output --partial "Usage:"
}

@test "check-mermaid: no node reports unavailable (exit 3), never a verdict" {
  # A runner without node is broken infrastructure. Exit 3 is the signal
  # callers translate into "pass" — a diagram must never be called invalid
  # because the parser could not run.
  run env PATH="$(stub_path sh dirname)" "$REPO_ROOT/bin/check-mermaid" "$REPO_ROOT/SKILL.md"
  [ "$status" -eq 3 ]
  assert_output --partial "node not found"
}

@test "check-mermaid: no modules and no install reports unavailable (exit 3)" {
  # node present, npm absent from PATH, install forbidden, cwd has no
  # node_modules → every resolution step misses.
  cd "$TMP"
  run env PATH="$(stub_path sh node dirname mkdir)" BOUCLE_MERMAID_INSTALL=false \
    BOUCLE_MERMAID_NODE_PATH="$TMP/does-not-exist" \
    BOUCLE_MERMAID_CACHE="$TMP/empty-cache" \
    "$REPO_ROOT/bin/check-mermaid" "$REPO_ROOT/SKILL.md"
  [ "$status" -eq 3 ]
  assert_output --partial "unavailable"
}

# ── bin/check-mermaid: verdicts (need the real parser) ─────────────────

@test "check-mermaid: rejects the erDiagram that shipped in boucle.dev#86" {
  have_parser || skip "mermaid/jsdom not installed"
  # Verbatim shape of the failure: an erDiagram attribute line whose third
  # token is a bare path. The grammar allows `type name [PK|FK|UK]
  # [\"comment\"]` and nothing else.
  cat > "$TMP/spec.md" << 'EOF'
## Diagram

```mermaid
erDiagram
    open_source_md {
        string file src/content/open-source/open-source.md
    }
    open_source_md ||--|| open_source_collection : validated by
```
EOF
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 1 ]
  assert_output --partial "FAIL"
  assert_output --partial "Parse error"
}

@test "check-mermaid: accepts the same diagram once the path is quoted" {
  have_parser || skip "mermaid/jsdom not installed"
  cat > "$TMP/spec.md" << 'EOF'
```mermaid
erDiagram
    open_source_md {
        string file "src/content/open-source/open-source.md"
    }
    open_source_md ||--|| open_source_collection : validated by
```
EOF
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 0 ]
  assert_output --partial "OK"
}

@test "check-mermaid: an unknown diagram type is a failure, not a pass" {
  have_parser || skip "mermaid/jsdom not installed"
  printf '```mermaid\nnotADiagram\n  A --> B\n```\n' > "$TMP/spec.md"
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 1 ]
  assert_output --partial "FAIL"
}

@test "check-mermaid: an empty fence is a failure" {
  have_parser || skip "mermaid/jsdom not installed"
  printf '```mermaid\n```\n' > "$TMP/spec.md"
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 1 ]
  assert_output --partial "empty mermaid fence"
}

@test "check-mermaid: ignores non-mermaid fences" {
  have_parser || skip "mermaid/jsdom not installed"
  printf '```\nerDiagram\n  a { string b c }\n```\n\n```sh\nnot mermaid\n```\n' > "$TMP/spec.md"
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 0 ]
  refute_output --partial "FAIL"
}

@test "check-mermaid: skips a template placeholder instead of failing it" {
  have_parser || skip "mermaid/jsdom not installed"
  # templates/triage.md ships `{{mermaid_body}}` — a file that is never
  # rendered as-is must not turn the repo's own check red forever.
  printf '```mermaid\n{{mermaid_body}}\n```\n' > "$TMP/spec.md"
  run "$REPO_ROOT/bin/check-mermaid" "$TMP/spec.md"
  [ "$status" -eq 0 ]
  assert_output --partial "SKIP"
}

@test "check-mermaid: reads stdin with -" {
  have_parser || skip "mermaid/jsdom not installed"
  run bash -c "printf '\`\`\`mermaid\nflowchart LR\n  A --> B\n\`\`\`\n' | '$REPO_ROOT/bin/check-mermaid' -"
  [ "$status" -eq 0 ]
  assert_output --partial "<stdin>"
}

@test "check-mermaid: every Mermaid diagram in this repo's own docs parses" {
  have_parser || skip "mermaid/jsdom not installed"
  # Dogfood: the engine's own charter docs are the diagrams the agents copy
  # from. A broken one there teaches the failure the gate exists to catch.
  cd "$REPO_ROOT"
  run bash -c 'git ls-files "*.md" ":!:.jcode" | xargs bin/check-mermaid'
  [ "$status" -eq 0 ]
  refute_output --partial "FAIL"
}

# ── check_diagram_syntax_gate: the block/pass decision ─────────────────

# Build a fake BOUCLE_HOME whose bin/check-mermaid exits with $1 and prints
# $2, so the gate's logic is tested with no parser and no network.
fake_home() {
  local exit_code="$1" out="${2:-}"
  mkdir -p "$TMP/home/bin"
  cat > "$TMP/home/bin/check-mermaid" << EOF
#!/usr/bin/env sh
printf '%s\n' '$out'
exit $exit_code
EOF
  chmod +x "$TMP/home/bin/check-mermaid"
  echo "$TMP/home"
}

# The gate under test, with the forge mocked. \$1 = BOUCLE_HOME, \$2 = the
# comment body, \$3 = how many diagram-invalid notes already exist.
run_gate() {
  run bash -c "
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    BOUCLE_HOME='$1'
    forge_issue_notes() { printf '%s' '$(printf '[%s]' "$(_invalid_notes "${3:-0}")")'; }
    set_boucle_label() { echo \"LABEL:\$1:\$2\"; }
    forge_issue_note() { echo \"NOTE:\$1:\$2\"; }
    check_diagram_syntax_gate 42 \"\$(cat '$2')\"
    echo \"RC=\$?\"
  "
}

# N notes carrying the diagram-invalid marker, as a JSON array body.
_invalid_notes() {
  local n="$1" i out=""
  for i in $(seq 1 "$n"); do
    [ -n "$out" ] && out="$out,"
    out="$out{\"id\":$i,\"body\":\"<!-- boucle:diagram-invalid v=1 rounds=0 -->\"}"
  done
  printf '%s' "$out"
}

@test "gate: a spec with no Mermaid fence never calls the checker" {
  local home
  home="$(fake_home 1 'FAIL should not be reached')"
  printf '## TL;DR\nno diagram here\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  run_gate "$home" "$TMP/body.md" 0
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "gate: a parsing diagram passes without touching labels" {
  local home
  home="$(fake_home 0 'OK   /tmp/x.md:3')"
  printf '## Diagram\n```mermaid\nflowchart LR\n  A --> B\n```\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  run_gate "$home" "$TMP/body.md" 0
  assert_output --partial "RC=0"
  assert_output --partial "diagram syntax OK"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "gate: a broken diagram blocks, re-triggers triage, and posts the error" {
  local home
  home="$(fake_home 1 'FAIL /tmp/x.md:12 — Parse error on line 20')"
  printf '## Diagram\n```mermaid\nerDiagram\n  a { string b c/d }\n```\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  run_gate "$home" "$TMP/body.md" 0
  assert_output --partial "RC=1"
  assert_output --partial "LABEL:42:boucle:triage"
  assert_output --partial "<!-- boucle:diagram-invalid v=1 rounds=0 -->"
  # The human and the next triage round both need the parser's own message.
  assert_output --partial "Parse error on line 20"
}

@test "gate: an unavailable parser passes (fail-open on infrastructure)" {
  local home
  home="$(fake_home 3 'check-mermaid: node not found')"
  printf '## Diagram\n```mermaid\nflowchart LR\n  A --> B\n```\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  run_gate "$home" "$TMP/body.md" 0
  assert_output --partial "RC=0"
  assert_output --partial "unavailable"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "gate: a missing checker passes (fail-open)" {
  cd "$REPO_ROOT"
  printf '## Diagram\n```mermaid\nflowchart LR\n  A --> B\n```\n' > "$TMP/body.md"
  run_gate "$TMP/no-such-home" "$TMP/body.md" 0
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "gate: the retry bound hands the spec to the human instead of looping" {
  local home
  home="$(fake_home 1 'FAIL /tmp/x.md:12 — Parse error on line 20')"
  printf '## Diagram\n```mermaid\nerDiagram\n  a { string b c/d }\n```\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  # Two rounds already spent (BOUCLE_DIAGRAM_SYNTAX_MAX_RETRIES default 2).
  run_gate "$home" "$TMP/body.md" 2
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
  assert_output --partial "state=exhausted"
}

@test "gate: BOUCLE_DIAGRAM_SYNTAX_GATE=false disables it" {
  local home
  home="$(fake_home 1 'FAIL /tmp/x.md:12 — Parse error')"
  printf '## Diagram\n```mermaid\nerDiagram\n  a { string b c/d }\n```\n' > "$TMP/body.md"
  cd "$REPO_ROOT"
  run bash -c "
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    BOUCLE_HOME='$home'
    BOUCLE_DIAGRAM_SYNTAX_GATE=false
    forge_issue_notes() { echo '[]'; }
    set_boucle_label() { echo \"LABEL:\$1:\$2\"; }
    forge_issue_note() { echo \"NOTE:\$1:\$2\"; }
    check_diagram_syntax_gate 42 \"\$(cat '$TMP/body.md')\"
    echo \"RC=\$?\"
  "
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}

# ── check_diagram_fit_gate: does the diagram draw what the spec changes? ─

# Run the fit gate against a body file, with the forge mocked. $1 = body
# file, $2 = how many diagram-unfit notes already exist.
run_fit_gate() {
  run bash -c "
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    forge_issue_notes() { printf '%s' '$(printf '[%s]' "$(_unfit_notes "${2:-0}")")'; }
    set_boucle_label() { echo \"LABEL:\$1:\$2\"; }
    forge_issue_note() { echo \"NOTE:\$1:\$2\"; }
    check_diagram_fit_gate 42 \"\$(cat '$1')\"
    echo \"RC=\$?\"
  "
}

_unfit_notes() {
  local n="$1" i out=""
  for i in $(seq 1 "$n"); do
    [ -n "$out" ] && out="$out,"
    out="$out{\"id\":$i,\"body\":\"<!-- boucle:diagram-unfit v=1 rounds=0 -->\"}"
  done
  printf '%s' "$out"
}

@test "fit gate: blocks the erDiagram-of-files that shipped in boucle.dev#86" {
  # The spec's own three markers, verbatim in shape: a navigation/section
  # change drawn as an entity model whose entities ARE the impacted files.
  cat > "$TMP/body.md" << 'EOF'
## Impacts
🏗️ data-model, ui

<!-- boucle:impacts v=1 kinds=data-model,ui -->

## Diagram

```mermaid
erDiagram
    content_config_ts {
        string collections
    }
    open_source_md {
        string file "src/content/open-source/open-source.md"
    }
    index_astro {
        string section "id=open-source"
    }
    content_config_ts ||--|| index_astro : rendered by
```

<!-- boucle:diagram v=1 types=erDiagram -->

## Impacted files
<!-- boucle:files v=1 paths=src/content.config.ts,src/content/open-source/open-source.md,src/pages/index.astro,public/admin/config.yml -->
EOF
  cd "$REPO_ROOT"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=1"
  assert_output --partial "LABEL:42:boucle:triage"
  assert_output --partial "impacted FILES as entities"
  assert_output --partial "<!-- boucle:diagram-unfit v=1 kinds=data-model,ui types=erDiagram rounds=0 -->"
}

@test "fit gate: a real data model with the same declarations passes" {
  # Same kinds, same type, same impacted files — but the entities are the
  # DATA, not the files. The gate must not punish the type, only the misuse.
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=data-model,ui -->

```mermaid
erDiagram
    open_source_entry {
        string title
        string licence
        string ctaHref
    }
    cost_figure {
        string label
        string value
    }
    open_source_entry ||--o{ cost_figure : cites
```

<!-- boucle:diagram v=1 types=erDiagram -->
<!-- boucle:files v=1 paths=src/content.config.ts,src/content/open-source/open-source.md,src/pages/index.astro,public/admin/config.yml -->
EOF
  cd "$REPO_ROOT"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "fit gate: blocks a diagram type no declared impact is drawn with" {
  # A spec that only claims to change the data model, drawn as a journey.
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=data-model -->

```mermaid
journey
  title Visit
  section Land
    Read: 5: Visitor
```

<!-- boucle:diagram v=1 types=journey -->
EOF
  cd "$REPO_ROOT"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=1"
  assert_output --partial "does not draw any impact this spec declares"
}

@test "fit gate: a flowchart on a ui change passes (the visitor's path)" {
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=ui -->

```mermaid
flowchart LR
  quick_start --> open_source --> footer
```

<!-- boucle:diagram v=1 types=flowchart -->
EOF
  cd "$REPO_ROOT"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}

@test "fit gate: an unknown impact kind fails open on the type check" {
  # The closed set moved without the table — judging fit against a table we
  # know is stale would block a correct diagram.
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=telepathy -->

```mermaid
journey
  title Visit
  section Land
    Read: 5: Visitor
```

<!-- boucle:diagram v=1 types=journey -->
EOF
  cd "$REPO_ROOT"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
}

@test "fit gate: no diagram marker, no impacts marker, or kinds=none → pass" {
  cd "$REPO_ROOT"
  printf '<!-- boucle:impacts v=1 kinds=ui -->\nno diagram marker here\n' > "$TMP/body.md"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
  printf '<!-- boucle:diagram v=1 types=erDiagram -->\nno impacts marker here\n' > "$TMP/body.md"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
  printf '<!-- boucle:impacts v=1 kinds=none -->\n<!-- boucle:diagram v=1 types=erDiagram -->\n' > "$TMP/body.md"
  run_fit_gate "$TMP/body.md" 0
  assert_output --partial "RC=0"
}

@test "fit gate: the retry bound hands the spec to the human instead of looping" {
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=data-model -->

```mermaid
journey
  title Visit
  section Land
    Read: 5: Visitor
```

<!-- boucle:diagram v=1 types=journey -->
EOF
  cd "$REPO_ROOT"
  # One round already spent (BOUCLE_DIAGRAM_FIT_MAX_RETRIES default 1).
  run_fit_gate "$TMP/body.md" 1
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
  assert_output --partial "state=exhausted"
}

@test "fit gate: BOUCLE_DIAGRAM_FIT_GATE=false disables it" {
  cat > "$TMP/body.md" << 'EOF'
<!-- boucle:impacts v=1 kinds=data-model -->
<!-- boucle:diagram v=1 types=journey -->
EOF
  cd "$REPO_ROOT"
  run bash -c "
    BOUCLE_FORGE_HOST=h CI_PROJECT_ID=1
    forge_issue_get() { :; }
    source lib/boucle.sh
    source lib/boucle-ci/gates.sh
    BOUCLE_DIAGRAM_FIT_GATE=false
    forge_issue_notes() { echo '[]'; }
    set_boucle_label() { echo \"LABEL:\$1:\$2\"; }
    forge_issue_note() { echo \"NOTE:\$1:\$2\"; }
    check_diagram_fit_gate 42 \"\$(cat '$TMP/body.md')\"
    echo \"RC=\$?\"
  "
  assert_output --partial "RC=0"
  refute_output --partial "LABEL:42:boucle:triage"
}
