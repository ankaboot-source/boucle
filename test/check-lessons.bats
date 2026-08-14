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
