# Emoji Spec Approval — Design

**Date:** 2026-07-31
**Status:** Approved
**Scope:** Additive — extends the existing note-based spec-approval mechanism with emoji-reaction approval. No removal of existing behavior.

---

## 1. Problem

Today, a human approves a spec by replying with any non-bot note on an issue labeled `boucle:spec-review`. This works but is heavier than necessary for a simple "yes, go" signal. Reacting with an emoji on the triage comment is a lighter, more idiomatic approval gesture.

## 2. Goal

Allow a human to approve a spec by reacting with one of six approval emojis on the triage comment (the bot comment containing `<!-- boucle:triage -->` and the acceptance criteria). The existing note-based approval remains fully functional as a fallback.

## 3. Approval Emoji Set

A fixed set of 6 GitLab internal emoji names count as spec approval:

| Visual | Internal name |
|---|---|
| 👍 Thumbs Up | `thumbsup` |
| ✅ White Check Mark | `white_check_mark` |
| ☑️ Ballot Box With Check | `ballot_box_with_check` |
| ✔️ Heavy Check Mark | `heavy_check_mark` |
| 🆗 OK Button | `ok` |
| 👌 OK Hand | `ok_hand` |

Skin-tone modifiers are ignored — GitLab stores the base alpha code regardless of skin tone.

Stored as a pipe-separated shell constant for `grep -E`:

```bash
BOUCLE_SPEC_APPROVAL_EMOJIS="thumbsup|white_check_mark|ballot_box_with_check|heavy_check_mark|ok|ok_hand"
```

## 4. Design Decisions

1. **Target of the emoji:** the triage comment (the bot comment presenting the acceptance criteria), not the issue itself. Semantic: the human approves the spec, not the issue.
2. **Sticky approval:** once an approval emoji is awarded (`action=award`), approval is acquired even if the human later revokes the emoji. No `revoke` handling. Consistent with the note mechanism (a note cannot be "un-posted").
3. **Approach A (chosen):** extend `dispatch` (real-time) + `doctor` (recovery). Symmetric with the existing note mechanism. Reuses the `SHOULD_WORK` pipeline. Robust to missed webhooks via doctor polling.
4. **Webhook config:** manual one-time setup — check "Emoji events" in Settings → Webhooks on framagit. Consistent with the existing manual webhook config for comment/issue events. No automation.
5. **Version check:** none explicit. If an `object_kind=emoji` event arrives, the instance supports emoji webhooks (≥ 16.4) by construction. Presence of the event is the proof.

## 5. Changes

### 5.1 Dispatch job — real-time emoji event detection

**File:** `.gitlab-ci.yml`, dispatch job.

**IID extraction (lines ~165-169) extended** to treat `emoji` like `note` (both carry `.issue.iid` when the awardable is a Note on an issue):

```bash
if [ "$OBJECT_KIND" = "note" ] || [ "$OBJECT_KIND" = "emoji" ]; then
  IID=$(jq -r '.issue.iid // .work_item.iid // .epic.iid // empty' "$TRIGGER_PAYLOAD")
else
  IID=$(jq -r '.object_attributes.iid // .issue.iid // empty' "$TRIGGER_PAYLOAD")
fi
```

**Spec-review branch (lines ~230-239) extended** — existing note branch kept; new `elif` for emoji added:

```bash
elif echo "$LABELS" | grep -q "boucle:spec-review"; then
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

**Notes:**
- `action=award` only (sticky approval, no revoke handling).
- `awardable_type=Note` only (emoji on a comment, not on the issue itself).
- Anti-loop guard `ACTOR != "up-bot"` already enforced at job level (line ~124).
- Dispatch trusts the `boucle:spec-review` label presence — it does NOT verify the emoji is on the triage comment specifically. That precise semantic check is deferred to doctor recovery (which has the note-id context).

### 5.2 Doctor job — recovery via emoji polling

**File:** `.gitlab-ci.yml`, doctor job, spec-review recovery loop (lines ~1384-1413).

After the existing `HUMAN_REPLY_AFTER_TRIAGE` calculation, add emoji detection on the triage comment:

```bash
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

if [ "$HUMAN_REPLY_AFTER_TRIAGE" -gt 0 ] || [ "$EMOJI_APPROVAL_FOUND" = true ]; then
  echo "  → #$IID approved (reply=$HUMAN_REPLY_AFTER_TRIAGE, emoji=$EMOJI_APPROVAL_FOUND) — re-triggering worker"
  set_boucle_label "$IID" "boucle:todo" "boucle::status::bot"
  curl -s -X POST "https://$HOST/api/v4/projects/$PID/trigger/pipeline" \
    -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
    -F "variables[BOUCLE_ISSUE]=$IID" -F "variables[BOUCLE_ROLE]=worker" > /dev/null
  RECOVERED=$((RECOVERED + 1))
else
  echo "  → #$IID: still waiting for author reply or approval emoji"
fi
```

**Notes:**
- Anchored on `LAST_TRIAGE_NOTE_ID` (the comment containing `<!-- boucle:triage`). Unlike dispatch, doctor verifies the emoji is precisely on the triage comment — the semantic check dispatch cannot do in real time (the webhook gives `awardable_id` numeric, not the issue iid).
- `award_emoji` API: `GET /projects/:id/issues/:issue_iid/notes/:note_id/award_emoji`. Filters `user.username != "up-bot"` + name in the approval set.
- `jq -e` exits 0 if truthy; `2>/dev/null` guards against a note with no reactions.
- `BOUCLE_SPEC_APPROVAL_EMOJIS` passed via `--arg` (string), split by `|` inside jq. Consistent with dispatch's shell-side `grep -E`.
- Logical OR: note OR emoji triggers recovery.
- No double-trigger: if dispatch already processed the emoji in real time, the issue no longer carries `boucle:spec-review` (worker replaced it with `boucle:working`), so it won't appear in `SPEC_REVIEW_ISSUES`.

### 5.3 Triage job — invite emoji approval in the spec-review comment

**File:** `.gitlab-ci.yml`, triage job, spec-review comment template.

Update the existing spec-review invitation text from:

> Review the acceptance criteria above. If they match what you want, reply to this issue to start implementation. If not, reply with corrections.

to:

> Review the acceptance criteria above. If they match what you want:
> - React with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR
> - Reply to this issue with any comment.
> If not, reply with corrections.

Text-only change. No new logic. The `<!-- boucle:triage -->` marker is preserved (doctor relies on it).

### 5.4 Webhook configuration (manual, one-time)

On framagit: Settings → Webhooks → check **"Emoji events"** in addition to the already-active "Comment events" and "Issue events". Documented as a setup step. No automation.

## 6. Data Flow

```
Human reacts 👍 on triage comment
        │
        ▼
GitLab emits Emoji Hook (object_kind=emoji, action=award, awardable_type=Note)
        │
        ▼
dispatch job: OBJECT_KIND=emoji, ACTOR≠up-bot, LABELS contains boucle:spec-review
   → EMOJI_NAME in approval set, AWARDABLE_TYPE=Note, EMOJI_ACTION=award
   → SHOULD_WORK=true → trigger worker
        │
        ▼
worker: relabels boucle:spec-review → boucle:working (strips all boucle: labels)

── If dispatch webhook missed ──
        │
        ▼
doctor job (periodic / on note event): scans boucle:spec-review issues
   → GET .../notes/LAST_TRIAGE_NOTE_ID/award_emoji
   → non-bot approval emoji found → re-trigger worker
```

## 7. Error Handling

- **Webhook not configured:** doctor polling recovers emoji approvals even without the emoji webhook (it polls the `award_emoji` API directly). The feature degrades gracefully to polling-only.
- **Emoji on wrong comment:** dispatch trusts the label and triggers; doctor verifies the emoji is on the triage comment. An emoji on a non-triage comment would be caught by dispatch (label present) but not by doctor (wrong note). Acceptable: the human intended approval, the spec is on the issue.
- **Bot reaction:** filtered by `ACTOR != "up-bot"` (dispatch) and `user.username != "up-bot"` (doctor). The bot never reacts with approval emojis.
- **Revoke after award:** ignored (sticky approval). The worker is already triggered or the issue is already relabeled.

## 8. Testing

Manual verification on a framagit test project:
1. Create an issue → triage runs → issue gets `boucle:spec-review` + spec-review comment.
2. React with 👍 on the triage comment → dispatch triggers worker → issue relabeled `boucle:working`.
3. Repeat with each of the 6 approval emojis → each triggers the worker.
4. React with a non-approval emoji (e.g. 🎉) → no trigger.
5. Simulate a missed webhook (disable emoji events temporarily) → react → re-enable → run doctor → doctor recovers via `award_emoji` API.
6. Verify note-based approval still works alongside emoji approval.

## 9. Out of Scope

- Revocation handling (sticky approval by design).
- Emoji on the issue itself (only `awardable_type=Note` is honored).
- Automating webhook configuration.
- Explicit GitLab version check.
- Changing the existing note-based approval mechanism.