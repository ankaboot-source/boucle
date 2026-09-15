#!/usr/bin/env bats
#
# test/forge-pagination.bats — a paginated list must reach jq as ONE value.
#
# Both CLIs stream one JSON document per page: `glab api --paginate` and
# `gh api --paginate` emit `[...]\n[...]` for a two-page list. jq then runs
# the caller's filter once per page and prints one result per page. That is
# not an error, so nothing went red until a per-page result was used as a
# scalar.
#
# Observed on a consumer (2026-09), doctor job, issue #148 past 100 notes:
#
#   LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[...] | first | .id // 0')
#
# matched on page 1 and hit the `// 0` default on page 2 → "2452949\n0".
# The next filter did `$tid | tonumber` and jq exited 5 with
# "Unexpected extra JSON values (while parsing '2452949\n0')", killing the
# doctor sweep.
#
# The crash was the lucky part. `first`, `last`, `length` and `any` were
# being evaluated PER PAGE, so every answer computed over a multi-page list
# had been wrong for as long as any list had two pages.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  source bin/forge/common.sh
}

# Two pages as the CLIs actually emit them: one array per page, no separator.
two_pages() {
  printf '%s\n%s\n' \
    '[{"id":2452949,"body":"<!-- boucle:triage --> spec"}]' \
    '[{"id":2452950,"body":"plain human note"}]'
}

@test "merge_pages: consecutive page arrays become one array" {
  run bash -c 'source bin/forge/common.sh; printf "[{\"id\":1}]\n[{\"id\":2}]\n[{\"id\":3}]\n" | forge_merge_pages'
  assert_success
  assert_output '[{"id":1},{"id":2},{"id":3}]'
}

@test "merge_pages: a single page is unchanged" {
  run bash -c 'source bin/forge/common.sh; printf "[{\"id\":1}]\n" | forge_merge_pages'
  assert_success
  assert_output '[{"id":1}]'
}

@test "merge_pages: a single object passes through (non-list GETs)" {
  run bash -c 'source bin/forge/common.sh; printf "{\"iid\":42}\n" | forge_merge_pages'
  assert_success
  assert_output '{"iid":42}'
}

@test "merge_pages: empty input stays empty, so callers' || echo [] still decides" {
  run bash -c 'source bin/forge/common.sh; printf "" | forge_merge_pages'
  assert_success
  assert_output ""
}

@test "merge_pages: an empty list survives as an empty list" {
  run bash -c 'source bin/forge/common.sh; printf "[]\n" | forge_merge_pages'
  assert_success
  assert_output '[]'
}

# ── the regression itself ─────────────────────────────────────────────

@test "unmerged pages produce the two-line scalar that killed the doctor" {
  # Guard the diagnosis, not just the fix: if this ever stops reproducing,
  # the explanation above is wrong and the fix below is cargo cult.
  run bash -c "$(declare -f two_pages); two_pages | jq -r '[.[] | select(.body | contains(\"<!-- boucle:triage\"))] | first | .id // 0'"
  assert_success
  assert_line --index 0 "2452949"
  assert_line --index 1 "0"
}

@test "merged pages produce a single note id" {
  run bash -c "source bin/forge/common.sh; $(declare -f two_pages); two_pages | forge_merge_pages | jq -r '[.[] | select(.body | contains(\"<!-- boucle:triage\"))] | first | .id // 0'"
  assert_success
  assert_output "2452949"
}

@test "the doctor's tonumber filter survives a two-page note list" {
  # The exact pair of filters from lib/boucle-ci/doctor.sh's spec-review
  # recovery: capture the last triage note id, then compare note ids to it.
  run bash -c "
    source bin/forge/common.sh
    $(declare -f two_pages)
    NOTES=\$(two_pages | forge_merge_pages)
    TID=\$(echo \"\$NOTES\" | jq -r '[.[] | select(.body | contains(\"<!-- boucle:triage\"))] | first | .id // 0')
    echo \"\$NOTES\" | jq -r --arg tid \"\$TID\" '[.[] | select(.id > (\$tid | tonumber))] | length'
  "
  assert_success
  assert_output "1"
  refute_output --partial "Unexpected extra JSON values"
}

# ── every paginated call site is merged ───────────────────────────────

@test "gitlab: no --paginate call reaches jq without forge_merge_pages" {
  # grep the backend rather than trust review: a new paginated endpoint
  # added without the merge is the same bug again.
  # Count actual invocations (a `glab api` line carrying --paginate) against
  # actual merges (a line that pipes into forge_merge_pages). Comments
  # mentioning either name are excluded by anchoring on the pipe and on
  # `glab api`, so prose cannot satisfy the assertion.
  local invocations merges
  invocations=$(grep -cE '^[^#]*glab api[^#]*--paginate' bin/forge/gitlab.sh)
  merges=$(grep -cE '^[[:space:]]*\| forge_merge_pages' bin/forge/gitlab.sh)

  [ "$invocations" -gt 0 ] || fail "no paginated glab call found — did the backend change shape?"
  assert_equal "$merges" "$invocations"
}

@test "github: _gh_api merges pages and still re-raises gh's exit status" {
  run bash -c '
    source bin/forge/common.sh
    source bin/forge/github.sh
    gh() { printf "[{\"id\":1}]\n[{\"id\":2}]\n"; }
    _gh_api /whatever
  '
  assert_success
  assert_output '[{"id":1},{"id":2}]'

  # A failing gh must stay a failure, not become an empty success: piping
  # gh straight into jq would have handed the caller jq's status instead.
  run bash -c '
    source bin/forge/common.sh
    source bin/forge/github.sh
    gh() { return 22; }
    _gh_api /whatever
  '
  assert_failure 22
}
