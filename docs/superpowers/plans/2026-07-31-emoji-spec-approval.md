# Emoji Spec Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow humans to approve a spec by reacting with one of six approval emojis on the triage comment, alongside the existing note-based approval.

**Architecture:** Additive extension of the existing dispatch (real-time) + doctor (recovery) spec-approval mechanism in `.gitlab-ci.yml`. Dispatch handles `object_kind=emoji` webhook events; doctor polls the `award_emoji` API on the triage comment. Triage comment text updated to invite emoji approval. No new jobs, no removal of existing behavior.

**Tech Stack:** GitLab CI/CD pipeline (bash), `glab` CLI, `jq`, GitLab Award Emoji REST API, GitLab Emoji webhook events (v16.4+).

**Spec:** `docs/superpowers/specs/2026-07-31-emoji-spec-approval-design.md`

---

## File Structure

All changes are in a single file: `.gitlab-ci.yml` (1682 lines). Three jobs are modified:

| Job | Lines (current) | Change |
|---|---|---|
| dispatch | 165-169 (IID extraction), 240-249 (spec-review branch) | Extend IID extraction for `emoji`; add emoji `elif` in spec-review branch |
| triage | 436 (SPEC_MSG) | Update spec-review invitation text |
| doctor | 1479-1508 (spec-review recovery loop) | Add emoji polling on triage comment |

No new files. No other jobs touched.

---

## Task 1: Add the approval-emoji constant

**Files:**
- Modify: `.gitlab-ci.yml` — dispatch job, near the top of the `script:` block (after `ACTOR`/`OBJECT_KIND` extraction, before the decision tree)

- [ ] **Step 1: Locate the insertion point**

Read `.gitlab-ci.yml` lines 120-210 (dispatch job script block). Confirm `ACTOR` is extracted at line ~124, `OBJECT_KIND` at line ~127, and the decision tree (`SHOULD_TRIAGE=false`) begins around line ~208.

- [ ] **Step 2: Add the constant**

Insert immediately before the `SHOULD_TRIAGE=false` line (line ~208):

```bash
# Emoji reactions that count as spec approval (GitLab internal alpha codes).
# Skin-tone modifiers are ignored — GitLab stores the base name regardless.
BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup|white_check_mark|ballot_box_with_check|heavy_check_mark|ok|ok_hand"
```

- [ ] **Step 3: Verify the constant is in scope**

The constant is defined in the dispatch job's `script:` block, so it's available to the decision tree below. Confirm with:

Run: `rg -n "BOUCLE_SPEC_APPROVAL_EMOJIS" .gitlab-ci.yml`
Expected: exactly 1 match (the definition line).

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(spec-approval): add approval-emoji constant

Pipe-separated list of 6 GitLab internal emoji names that count as
spec approval: thumbsup, white_check_mark, ballot_box_with_check,
heavy_check_mark, ok, ok_hand."
```

---

## Task 2: Extend dispatch IID extraction for emoji events

**Files:**
- Modify: `.gitlab-ci.yml:165-169` (dispatch IID extraction)

- [ ] **Step 1: Read the current IID extraction**

Confirm lines 165-169 read exactly:

```bash
if [ "$OBJECT_KIND" = "note" ]; then
  IID=$(jq -r '.issue.iid // .work_item.iid // .epic.iid // empty' "$TRIGGER_PAYLOAD")
else
  IID=$(jq -r '.object_attributes.iid // .issue.iid // empty' "$TRIGGER_PAYLOAD")
fi
```

- [ ] **Step 2: Add `emoji` to the note-like branch**

Replace the `if` condition to also match `emoji` (emoji payloads carry `.issue.iid` when `awardable_type=Note` on an issue, same shape as note payloads):

```bash
if [ "$OBJECT_KIND" = "note" ] || [ "$OBJECT_KIND" = "emoji" ]; then
  IID=$(jq -r '.issue.iid // .work_item.iid // .epic.iid // empty' "$TRIGGER_PAYLOAD")
else
  IID=$(jq -r '.object_attributes.iid // .issue.iid // empty' "$TRIGGER_PAYLOAD")
fi
```

- [ ] **Step 3: Verify the edit**

Run: `rg -n 'OBJECT_KIND.*note.*emoji' .gitlab-ci.yml`
Expected: 1 match on the modified line.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(spec-approval): extract IID from emoji webhook payloads

Emoji events (object_kind=emoji) carry .issue.iid when the awardable
is a Note on an issue, same shape as note events. Treat them alike."
```

---

## Task 3: Add emoji branch to dispatch spec-review detection

**Files:**
- Modify: `.gitlab-ci.yml:240-249` (dispatch spec-review branch)

- [ ] **Step 1: Read the current spec-review branch**

Confirm lines 240-249 read exactly:

```bash
elif echo "$LABELS" | grep -q "boucle:spec-review"; then
  # Author approved the spec (added a non-bot note to an issue that
  # was at boucle:spec-review). The boucle:spec-approved label was
  # removed — authors now approve by replying instead. Trigger the
  # worker — it will relabel to boucle:working (replacing all boucle:
  # labels, including the stale boucle:spec-review). We do NOT strip
  # boucle:spec-review here.
  if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "up-bot" ]; then
    SHOULD_WORK=true
  fi
```

- [ ] **Step 2: Add the emoji elif**

Replace the inner `if` block (lines 246-249) with a note branch plus a new emoji branch. Keep the comment block (lines 241-245) unchanged. The replacement for lines 246-249:

```bash
  if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "up-bot" ]; then
    SHOULD_WORK=true
  elif [ "$OBJECT_KIND" = "emoji" ] && [ "$ACTOR" != "up-bot" ]; then
    EMOJI_NAME=$(jq -r '.object_attributes.name // empty' "$TRIGGER_PAYLOAD")
    EMOJI_ACTION=$(jq -r '.object_attributes.action // empty' "$TRIGGER_PAYLOAD")
    AWARDABLE_TYPE=$(jq -r '.object_attributes.awardable_type // empty' "$TRIGGER_PAYLOAD")
    if [ "$EMOJI_ACTION" = "award" ] \
       && [ "$AWARDABLE_TYPE" = "Note" ] \
       && echo "$EMOJI_NAME" | grep -Eq "^($BOUCLE_SPEC_APPROVAL_EMOJIS)$"; then
      SHOULD_WORK=true
    fi
  fi
```

- [ ] **Step 3: Verify the edit**

Run: `rg -n 'EMOJI_ACTION.*award' .gitlab-ci.yml`
Expected: 1 match.

Run: `rg -n 'AWARDABLE_TYPE.*Note' .gitlab-ci.yml`
Expected: 1 match.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(spec-approval): trigger worker on approval emoji in dispatch

When an emoji webhook (object_kind=emoji, action=award) arrives on an
issue labeled boucle:spec-review, and the emoji is one of the six
approval emojis on a Note (comment), set SHOULD_WORK=true. Sticky
approval — revoke events are ignored."
```

---

## Task 4: Update triage spec-review comment to invite emoji approval

**Files:**
- Modify: `.gitlab-ci.yml:436` (triage SPEC_MSG)

- [ ] **Step 1: Read the current SPEC_MSG**

Confirm line 436 reads:

```bash
SPEC_MSG=$(printf 'Review the acceptance criteria above. If they match what you want, reply to this issue to start implementation. If not, reply with corrections.')
```

- [ ] **Step 2: Replace with the emoji-aware invitation**

```bash
SPEC_MSG=$(printf 'Review the acceptance criteria above. If they match what you want:\n- React with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR\n- Reply to this issue with any comment.\nIf not, reply with corrections.')
```

- [ ] **Step 3: Verify the edit**

Run: `rg -n 'React with' .gitlab-ci.yml`
Expected: 1 match.

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(spec-approval): invite emoji approval in triage comment

Update the spec-review invitation to tell humans they can react with
an approval emoji on the triage comment as an alternative to replying."
```

---

## Task 5: Add emoji polling to doctor spec-review recovery

**Files:**
- Modify: `.gitlab-ci.yml:1479-1508` (doctor spec-review recovery loop)

- [ ] **Step 1: Read the current recovery loop**

Confirm lines 1479-1508 read exactly (note: `| first |` semantics — the FIRST triage comment, not the last):

```bash
# Recover orphaned boucle:spec-review issues: the author replied
# (any non-bot note after the last triage comment) but the dispatch
# pipeline was canceled/orphaned before it could trigger the worker.
# Issue still has boucle:spec-review (dispatch didn't run to strip it).
# Worker relabels to boucle:working on start, which clears it.
SPEC_REVIEW_ISSUES=$(glab api --hostname "$HOST" "/projects/$PID/issues?state=opened&labels=boucle:spec-review&per_page=100" \
  | jq -r '.[].iid')

for IID in $SPEC_REVIEW_ISSUES; do
  echo "Checking #$IID (boucle:spec-review) for spec approval..."
  NOTES=$(glab api --hostname "$HOST" "/projects/$PID/issues/$IID/notes")
  # Find the last triage comment (same as needs-info recovery above)
  LAST_TRIAGE_NOTE_ID=$(echo "$NOTES" | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | first | .id // 0')
  # Detect any non-bot note after the last triage comment
  HUMAN_REPLY_AFTER_TRIAGE=$(echo "$NOTES" | jq -r --arg tid "$LAST_TRIAGE_NOTE_ID" '
    [.[] | select(.author.username != "up-bot") | select(.id > ($tid | tonumber))]
    | length
  ')
  if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ]; then
    echo "  → #$IID has author reply after spec-review — orphaned spec gate, re-triggering worker"
    set_boucle_label "$IID" "boucle:todo" "boucle::status::bot"
    curl -s -X POST "https://$HOST/api/v4/projects/$PID/trigger/pipeline" \
      -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
      -F "variables[BOUCLE_ISSUE]=$IID" -F "variables[BOUCLE_ROLE]=worker" > /dev/null
    echo "  → re-triggered worker for #$IID"
    RECOVERED=$((RECOVERED + 1))
  else
    echo "  → #$IID: still waiting for author to reply"
  fi
done
```

- [ ] **Step 2: Add emoji detection after HUMAN_REPLY_AFTER_TRIAGE**

Insert this block immediately after the `HUMAN_REPLY_AFTER_TRIAGE=$(...)` assignment and before the `if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ]; then` line:

```bash
  # Check for an approval emoji on the triage comment (polls the
  # award_emoji API — recovers even if the emoji webhook was missed).
  EMOJI_APPROVAL_FOUND=false
  if [ "$LAST_TRIAGE_NOTE_ID" != "0" ] && [ -n "$LAST_TRIAGE_NOTE_ID" ]; then
    AWARDS=$(glab api --hostname "$HOST" \
      "/projects/$PID/issues/$IID/notes/$LAST_TRIAGE_NOTE_ID/award_emoji" 2>/dev/null)
    if echo "$AWARDS" | jq -e --arg emojis "$BOUCLE_SPEC_APPROVAL_EMOJIS" '
      [.[] | select(.user.username != "up-bot") | .name]
      | map(select(. as $n | ($emojis | split("|")) | index($n)))
      | length > 0
    ' >/dev/null 2>&1; then
      EMOJI_APPROVAL_FOUND=true
    fi
  fi
```

- [ ] **Step 3: Extend the recovery condition to OR note and emoji**

Replace the `if` and `else` branches:

```bash
  if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ] || [ "$EMOJI_APPROVAL_FOUND" = true ]; then
    echo "  → #$IID approved (reply=$HUMAN_REPLY_AFTER_TRIAGE, emoji=$EMOJI_APPROVAL_FOUND) — re-triggering worker"
    set_boucle_label "$IID" "boucle:todo" "boucle::status::bot"
    curl -s -X POST "https://$HOST/api/v4/projects/$PID/trigger/pipeline" \
      -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
      -F "variables[BOUCLE_ISSUE]=$IID" -F "variables[BOUCLE_ROLE]=worker" > /dev/null
    echo "  → re-triggered worker for #$IID"
    RECOVERED=$((RECOVERED + 1))
  else
    echo "  → #$IID: still waiting for author reply or approval emoji"
  fi
```

- [ ] **Step 4: Verify the edits**

Run: `rg -n 'EMOJI_APPROVAL_FOUND' .gitlab-ci.yml`
Expected: 3 matches (declaration, assignment in `if`, use in condition).

Run: `rg -n 'award_emoji' .gitlab-ci.yml`
Expected: 1 match (the doctor API call).

Run: `rg -n 'still waiting for author reply or approval emoji' .gitlab-ci.yml`
Expected: 1 match.

- [ ] **Step 5: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(spec-approval): poll approval emoji in doctor recovery

Doctor now also checks the triage comment for approval emojis via the
award_emoji API, recovering spec approvals even when the emoji webhook
was missed. Note OR emoji triggers recovery."
```

---

## Task 6: Manual verification on framagit

**Files:** none (manual testing on a live GitLab project)

- [ ] **Step 1: Enable emoji webhook events**

On framagit: project → Settings → Webhooks → check **"Emoji events"** (in addition to the already-active Comment events and Issue events). Save.

- [ ] **Step 2: Verify GitLab version ≥ 16.4**

Run: `glab api --hostname <framagit-host> /version`
Expected: `version` field ≥ 16.4. (If the emoji webhook UI checkbox is visible, the version already supports it.)

- [ ] **Step 3: Test real-time emoji approval**

1. Create a test issue on the project.
2. Wait for triage to run → issue gets `boucle:spec-review` + spec-review comment with the new invitation text.
3. React with 👍 on the triage comment.
4. Observe: dispatch pipeline triggers → worker runs → issue relabeled `boucle:working`.

- [ ] **Step 4: Test each approval emoji**

Repeat Step 3 with each of: ✅, ☑️, ✔️, 🆗, 👌. Each should trigger the worker.

- [ ] **Step 5: Test non-approval emoji is ignored**

1. Create a test issue → triage → `boucle:spec-review`.
2. React with 🎉 (not in the approval set) on the triage comment.
3. Observe: no dispatch trigger, issue stays `boucle:spec-review`.

- [ ] **Step 6: Test doctor recovery (missed webhook)**

1. Temporarily uncheck "Emoji events" in webhook settings.
2. Create a test issue → triage → `boucle:spec-review`.
3. React with 👍 on the triage comment (no webhook fires).
4. Re-check "Emoji events".
5. Trigger the doctor job (or wait for its next run).
6. Observe: doctor detects the emoji via `award_emoji` API → re-triggers worker → issue relabeled.

- [ ] **Step 7: Test note-based approval still works**

1. Create a test issue → triage → `boucle:spec-review`.
2. Reply with any comment (no emoji).
3. Observe: dispatch triggers worker (existing behavior unchanged).

- [ ] **Step 8: Commit verification record**

No code change. Record results in the PR description.

---

## Self-Review

**1. Spec coverage:**
- Section 3 (emoji set) → Task 1 ✓
- Section 5.1 (dispatch IID + emoji branch) → Tasks 2, 3 ✓
- Section 5.2 (doctor polling) → Task 5 ✓
- Section 5.3 (triage comment text) → Task 4 ✓
- Section 5.4 (webhook config) → Task 6 Step 1 ✓
- Section 8 (testing) → Task 6 ✓
- Sections 4, 6, 7, 9 (decisions, data flow, error handling, out of scope) → no code tasks, documented in spec ✓

**2. Placeholder scan:** No TBD/TODO. All steps have exact code. ✓

**3. Type consistency:**
- `BOUCLE_SPEC_APPROVAL_EMOJIS` — same name in Task 1 (definition), Task 3 (dispatch `grep -Eq`), Task 5 (doctor `--arg`). ✓
- `EMOJI_APPROVAL_FOUND` — declared `false`, set `true`, used in `||`. ✓
- `LAST_TRIAGE_NOTE_ID` — preserved `| first |` semantics from current code (not changed to `| last |`). ✓
- `$HOST` / `$PID` — doctor locals, used consistently. ✓

No issues found.