#!/usr/bin/env bats

# test/check-lessons.bats — tests for bin/check-lessons CI gate

# shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LESSONS="$REPO_ROOT/LESSONS.yml"
CHECK="$REPO_ROOT/bin/check-lessons"

@test "check-lessons passes on the current LESSONS.yml" {
  run "$CHECK" "$LESSONS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"doc-sync OK"* ]]
}

@test "check-lessons fails when a lesson is missing ❌" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  # Remove the ❌ key from lesson #1
  python3 -c "
import yaml, sys
with open('$tmp') as f: d = yaml.safe_load(f)
del d[1]['❌']
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#1: missing"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a lesson is missing ✅" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
del d[1]['✅']
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#1: missing"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a lesson has a Context: key" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[1]['Context'] = 'this is a forbidden narrative'
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Context:"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a lesson contains an issue number" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[1]['❌'] = 'DO NOT do X (issue #999 on a consumer repo)'
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"issue number"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a lesson contains an MR number" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[1]['❌'] = 'DO NOT do X (MR !999 on a consumer repo)'
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MR number"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a lesson references a non-existent lesson" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[1]['❌'] = 'DO NOT do X — see lesson #999 for context'
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"references #999"* ]]
  rm -f "$tmp"
}

@test "check-lessons fails when a gap has no pruned/merged marker" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
del d[3]  # create a gap without a pruned marker
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 1 ]
  [[ "$output" == *"#3: missing"* ]]
  rm -f "$tmp"
}

@test "check-lessons detects potential duplicates (--strict)" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  # Make lesson #2 a near-duplicate of lesson #1
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[2]['❌'] = d[1].get('❌', 'DO NOT refine a comment in a loop before posting it.')
d[2]['✅'] = d[1].get('✅', 'DO: post before refining.')
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp" --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate"* ]]
  rm -f "$tmp"
}

@test "check-lessons accepts pruned lessons without ❌/✅" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[74] = {'pruned': True, 'reason': 'test — obsolete lesson'}
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "check-lessons accepts merged lessons without ❌/✅" {
  tmp=$(mktemp)
  cp "$LESSONS" "$tmp"
  python3 -c "
import yaml
with open('$tmp') as f: d = yaml.safe_load(f)
d[74] = {'merged_into': 1, 'reason': 'test — merged into #1'}
with open('$tmp','w') as f: yaml.dump(d, f, allow_unicode=True, sort_keys=True)
"
  run "$CHECK" "$tmp"
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

# ── --against: cross-file duplicate detection (a consumer's own lessons) ──
# A consumer keeps its lessons in LESSONS.yml at the repo root while the
# engine's live under .boucle/, and bin/jc injects BOTH. An entry that
# restates an engine lesson is therefore paid for twice in every prompt.

# A near-copy of engine lesson #3 ("No MCP in CI").
write_restatement() {
  cat > "$1" <<'YAML'
1:
  title: MCP is stripped in our CI too
  ✅: 'DO: strip MCP in CI; use native `glob`/`grep`/`read` and the `codebase-memory-mcp cli` fallback. Every prompt citing graph tools MUST document both interfaces.'
  ❌: DO NOT rely on `codebase-memory-mcp` tools in CI (the handshake hangs).
YAML
}

# A lesson that could only come from one repository.
write_repo_specific() {
  cat > "$1" <<'YAML'
1:
  title: Seed the fixture volume first
  ✅: 'DO: run the seed task before invoking any browser suite.'
  ❌: DO NOT invoke the browser suite against an unseeded fixture volume.
YAML
}

@test "check-lessons --against flags a lesson that restates one in the other file" {
  tmp=$(mktemp)
  write_restatement "$tmp"
  run "$CHECK" "$tmp" --against "$LESSONS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restates #3"* ]]
  rm -f "$tmp"
}

@test "check-lessons --against --strict fails on a restatement" {
  tmp=$(mktemp)
  write_restatement "$tmp"
  run "$CHECK" "$tmp" --against "$LESSONS" --strict
  [ "$status" -ne 0 ]
  rm -f "$tmp"
}

@test "check-lessons --against passes a lesson specific to the repository" {
  tmp=$(mktemp)
  write_repo_specific "$tmp"
  run "$CHECK" "$tmp" --against "$LESSONS" --strict
  [ "$status" -eq 0 ]
  rm -f "$tmp"
}

@test "check-lessons --against errors when the other file does not exist" {
  tmp=$(mktemp)
  write_repo_specific "$tmp"
  run "$CHECK" "$tmp" --against /nonexistent/LESSONS.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *"--against file not found"* ]]
  rm -f "$tmp"
}

@test "check-lessons --against skips the AGENTS.md check (engine-only guard)" {
  # A consumer file must not be judged against AGENTS.md: the consumer does
  # not own that document. Run from a directory whose AGENTS.md WOULD trip
  # the guard and assert the consumer file still passes.
  tmp=$(mktemp -d)
  write_repo_specific "$tmp/LESSONS.yml"
  printf '## Lessons learned\n\n99. **A lesson in AGENTS.md** - would trip the guard.\n' > "$tmp/AGENTS.md"
  run bash -c "cd '$tmp' && python3 '$CHECK' LESSONS.yml --against '$LESSONS'"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
}

@test "check-lessons without --against still runs the AGENTS.md check" {
  tmp=$(mktemp -d)
  write_repo_specific "$tmp/LESSONS.yml"
  printf '## Lessons learned\n\n99. **A lesson in AGENTS.md** - would trip the guard.\n' > "$tmp/AGENTS.md"
  run bash -c "cd '$tmp' && python3 '$CHECK' LESSONS.yml"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}
