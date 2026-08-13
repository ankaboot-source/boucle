#!/usr/bin/env bats
# test/collapse-duplicate-notes.bats — jq filter logic tests for
# bin/collapse-duplicate-notes.
#
# bin/collapse-duplicate-notes drives glab (network), so we test the
# jq filter it composes (per <type>) against mock note arrays instead.
# The filter is the heart of the script — if it misclassifies a note,
# the wrong body gets PUT or the wrong note gets DELETE. Tests mirror
# the FILTER and DRAFT_FILTER variables built in the case statement.
#
# Bodies contain newlines, so we can't count records with `wc -l` —
# each match starts a new "record" on a line beginning with `<id>\t`,
# but the body's own newlines start subsequent lines. We use
# `grep -c '^[0-9]\{1,\}\t'` which counts only lines that begin a record.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── Final filter tests (existing behavior) ────────────────────────────

@test "collapse triage filter selects only boucle:triage notes with ## TL;DR and ## Disposition" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"},
    {"id": 2, "body": "<!-- boucle:verdict v=1 role=reviewer -->\n\n## Verdict\nAPPROVE"},
    {"id": 3, "body": "<!-- boucle:triage v=1 -->\n\n(no TL;DR, no disposition section)"}
  ]'
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^1	'
}

@test "collapse triage filter respects pre_id boundary" {
  mock_notes='[
    {"id": 10, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"},
    {"id": 20, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nNEEDS-INFO"},
    {"id": 30, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"}
  ]'
  # pre_id=15 → only notes 20 and 30 should match
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | select(.id > 15) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "2" ]
  printf '%s' "$result" | grep -q '^20	'
  printf '%s' "$result" | grep -q '^30	'
}

@test "collapse reviewer filter selects role=reviewer verdicts and anchors on sha" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->\n\n## Verdict\nAPPROVE"},
    {"id": 2, "body": "<!-- boucle:verdict v=1 role=e2e sha=abc123 -->\n\n## Verdict\nPASS"},
    {"id": 3, "body": "<!-- boucle:verdict v=1 role=reviewer sha=def456 -->\n\n## Verdict\nCHANGES"}
  ]'
  # With sha=abc123: only note 1 matches
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=reviewer")) | select(.body | test("abc123")) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^1	'
}

@test "collapse e2e filter selects role=e2e verdicts" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->\n\n## Verdict\nAPPROVE"},
    {"id": 2, "body": "<!-- boucle:verdict v=1 role=e2e sha=abc123 -->\n\n## Verdict\nPASS"},
    {"id": 3, "body": "<!-- boucle:verdict v=1 role=e2e sha=abc123 -->\n\n## Verdict\nFAIL"}
  ]'
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=e2e")) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "2" ]
  printf '%s' "$result" | grep -q '^2	'
  printf '%s' "$result" | grep -q '^3	'
}

@test "collapse with pre_id=0 selects all matching notes (first run)" {
  mock_notes='[
    {"id": 5, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"},
    {"id": 6, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nNEEDS-INFO"}
  ]'
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | select(.id > 0) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "2" ]
}

# ── Draft filter tests (new behavior) ─────────────────────────────────

@test "draft filter selects boucle:draft role=triage notes" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nNEEDS-INFO"},
    {"id": 2, "body": "<!-- boucle:triage v=1 -->\n\n## Disposition\nREADY"},
    {"id": 3, "body": "<!-- boucle:draft role=reviewer -->\n\n## Verdict\nAPPROVE"}
  ]'
  # DRAFT_FILTER for triage: only note 1 matches
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=triage")) | select(.id > 0) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^1	'
}

@test "draft filter selects boucle:draft role=reviewer notes" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nNEEDS-INFO"},
    {"id": 2, "body": "<!-- boucle:draft role=reviewer -->\n\n## Verdict\nAPPROVE"},
    {"id": 3, "body": "<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->\n\n## Verdict\nAPPROVE"}
  ]'
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=reviewer")) | select(.id > 0) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^2	'
}

@test "draft filter selects boucle:draft role=e2e notes" {
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=e2e -->\n\n## Verdict\nPASS"},
    {"id": 2, "body": "<!-- boucle:verdict v=1 role=e2e sha=abc123 -->\n\n## Verdict\nPASS"}
  ]'
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=e2e")) | select(.id > 0) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^1	'
}

@test "draft filter respects pre_id boundary" {
  mock_notes='[
    {"id": 10, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nNEEDS-INFO"},
    {"id": 20, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nREADY"},
    {"id": 30, "body": "<!-- boucle:triage v=1 -->\n\n## Disposition\nREADY"}
  ]'
  # pre_id=15 → only draft note 20 should match (10 is below boundary)
  result="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=triage")) | select(.id > 15) | "\(.id)\t\(.body)"')"
  [ "$(printf '%s' "$result" | grep -c '^[0-9]\{1,\}	')" = "1" ]
  printf '%s' "$result" | grep -q '^20	'
}

# ── Draft cleanup behavior (the fix) ──────────────────────────────────
# When a final exists, the draft is REPLACED IN PLACE: the final body is
# PUT onto the draft's note id (so the #note_<id> anchor stays stable),
# then the redundant final note is deleted. When no final exists, drafts
# must be left untouched (the log-scraping fallback promotes them).

@test "draft+final: draft is the target (oldest id), final is the source body" {
  # Simulate: agent posted draft (id=1), then final (id=2).
  # TARGET_ID = oldest = 1 (the draft). NEWEST_FINAL_ID = 2.
  # The final body is PUT onto note id 1; note id 2 is then deleted.
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nNEEDS-INFO"},
    {"id": 2, "body": "<!-- boucle:triage v=1 -->\n\n## TL;DR\nShort.\n\n## Disposition\nREADY"}
  ]'
  final_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | select(.id > 0) | .id' | sort -n)"
  draft_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=triage")) | select(.id > 0) | .id' | sort -n)"
  # Final exists → draft is the replace-in-place target
  [ -n "$final_ids" ]
  [ -n "$draft_ids" ]
  [ "$final_ids" = "2" ]
  [ "$draft_ids" = "1" ]
  # ALL_IDS = oldest→newest, deduped; TARGET_ID = head = 1 (the draft)
  all_ids="$(printf '%s\n' "$final_ids" "$draft_ids" | grep -E '^[0-9]+$' | sort -n | awk '!seen[$0]++')"
  target_id="$(printf '%s\n' "$all_ids" | head -n1)"
  [ "$target_id" = "1" ]
}

@test "draft-only (no final): draft is NOT touched (fallback will promote it)" {
  # Simulate: agent posted only a draft, exhausted steps before final.
  # FINAL_IDS should be empty, DRAFT_IDS should contain [1].
  # Script must exit without PUTting or DELETEing drafts (no final body
  # to replace them with; the log-scraping fallback promotes them).
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=triage -->\n\n## Disposition\nNEEDS-INFO"}
  ]'
  final_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | select(.id > 0) | .id' | sort -n)"
  draft_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=triage")) | select(.id > 0) | .id' | sort -n)"
  # No final → drafts must NOT be touched
  [ -z "$final_ids" ]
  [ -n "$draft_ids" ]
  [ "$draft_ids" = "1" ]
}

@test "#42 regression: draft with final marker but no ## TL;DR is NOT matched by final filter" {
  # This is the issue #42 incident pattern: the agent posted a first-pass
  # draft using the FINAL marker (<!-- boucle:triage v=1 -->) instead of
  # the draft marker (<!-- boucle:draft role=triage -->). The body has
  # ## Disposition but NO ## TL;DR (a final triage comment always starts
  # with ## TL;DR per the prompt format spec). The final filter must
  # reject it so the CI does not act on the draft.
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:triage v=1 -->\nDRAFT — first-pass triage, refining next.\n## Disposition\nNEEDS-INFO"}
  ]'
  final_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:triage")) | select(.body | test("(?m)^## TL;DR")) | select(.body | test("(?m)^## Disposition")) | select(.id > 0) | .id' | sort -n)"
  # Must NOT match — no ## TL;DR means it is a draft, not a final
  [ -z "$final_ids" ]
}

@test "multiple drafts + final: oldest draft is the replace-in-place target" {
  # Simulate: agent posted draft (id=1), draft v2 (id=2), then final (id=3).
  # TARGET_ID = oldest = 1 (the first draft). The final body is PUT onto
  # note id 1; notes 2 and 3 are deleted. The #note_1 anchor stays stable.
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=reviewer -->\n\n## Verdict\nUNCERTAIN"},
    {"id": 2, "body": "<!-- boucle:draft role=reviewer -->\n\n## Verdict\nPASS"},
    {"id": 3, "body": "<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->\n\n## Verdict\nPASS"}
  ]'
  final_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:verdict")) | select(.body | test("role=reviewer")) | select(.body | test("abc123")) | select(.id > 0) | .id' | sort -n)"
  draft_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=reviewer")) | select(.id > 0) | .id' | sort -n)"
  [ "$final_ids" = "3" ]
  [ "$(printf '%s\n' "$draft_ids" | wc -l | tr -d ' ')" = "2" ]
  printf '%s\n' "$draft_ids" | grep -qx 1
  printf '%s\n' "$draft_ids" | grep -qx 2
  # ALL_IDS = 1,2,3 oldest→newest; TARGET_ID = 1 (oldest draft)
  all_ids="$(printf '%s\n' "$final_ids" "$draft_ids" | grep -E '^[0-9]+$' | sort -n | awk '!seen[$0]++')"
  target_id="$(printf '%s\n' "$all_ids" | head -n1)"
  [ "$target_id" = "1" ]
  # DELETE list = all except target = 2,3
  del_ids="$(printf '%s\n' "$all_ids" | tail -n +2)"
  [ "$(printf '%s\n' "$del_ids" | wc -l | tr -d ' ')" = "2" ]
  printf '%s\n' "$del_ids" | grep -qx 2
  printf '%s\n' "$del_ids" | grep -qx 3
}

@test "draft from different role is NOT deleted" {
  # A reviewer draft should NOT be deleted by the e2e collapse run.
  mock_notes='[
    {"id": 1, "body": "<!-- boucle:draft role=reviewer -->\n\n## Verdict\nAPPROVE"},
    {"id": 2, "body": "<!-- boucle:verdict v=1 role=e2e sha=abc123 -->\n\n## Verdict\nPASS"}
  ]'
  # e2e DRAFT_FILTER should NOT match the reviewer draft
  draft_ids="$(printf '%s' "$mock_notes" | jq -r '.[] | select(.body | test("<!-- boucle:draft role=e2e")) | select(.id > 0) | .id' | sort -n)"
  [ -z "$draft_ids" ]
}
