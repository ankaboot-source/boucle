# Direct Merge Catchup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a human merges a `boucle/<iid>` MR directly via the GitLab UI (bypassing the approval circuit), boucle catches up by closing the issue and triggering the parent cascade — `boucle:done` if the issue was at `boucle:approval`, `boucle:human` if merged early.

**Architecture:** A new `catchup` job in `.gitlab-ci.yml`, triggered by `dispatch` when a webhook `merge_request` with `action=merge` arrives for a `boucle/<iid>` branch. Dispatch stays a pure router; `catchup` does the issue-state inspection, label write, audit comment, close, and parent cascade. No e2e agent runs (trust human judgment). Helpers are duplicated locally in the job, matching the existing per-job pattern.

**Tech Stack:** GitLab CI (`.gitlab-ci.yml`), inline bash, `glab` CLI, `jq`, `curl`. No test framework exists for the inline bash — verification is via YAML lint + manual smoke test against the live `gitlab.example.com` instance.

**Spec:** `docs/superpowers/specs/2026-07-31-direct-merge-catchup-design.md`

---

## File Structure

- **Modify:** `.gitlab-ci.yml` (single file, two changes)
  - Change 1 (Task 1): Split the `open|merge)` case in `dispatch` (lines 247-252) into a dedicated `merge)` case that triggers `catchup`, and a separate `open)` case that stays a skip.
  - Change 2 (Task 2): Insert the new `catchup` job between `merger` (ends line 1385) and `deploy` (starts line 1387).

No new files. No other files touched. The spec is already committed.

---

## Task 1: Route `action=merge` to the new `catchup` job in `dispatch`

**Files:**
- Modify: `.gitlab-ci.yml:247-252` (the `open|merge)` case in the `dispatch` job's `case "$MR_ACTION"` statement)

- [ ] **Step 1: Read the exact current code to confirm the match**

Run: `sed -n '247,256p' .gitlab-ci.yml`
Expected output:
```
          open|merge)
            # open: the worker creates the MR and chains to reviewer itself —
            # no dispatch action needed. merge: the merger job handles it.
            echo "MR !${MR_IID} action=$MR_ACTION — handled by worker/merger, skipping"
            exit 0
            ;;
          *)
            echo "MR !${MR_IID} action=$MR_ACTION — not handled, skipping"
```

- [ ] **Step 2: Replace the `open|merge)` case with a dedicated `merge)` case + a separate `open)` case**

Use the `edit` tool to replace this exact block:

```
          open|merge)
            # open: the worker creates the MR and chains to reviewer itself —
            # no dispatch action needed. merge: the merger job handles it.
            echo "MR !${MR_IID} action=$MR_ACTION — handled by worker/merger, skipping"
            exit 0
            ;;
```

with this:

```
          merge)
            # A boucle/<iid> MR was merged directly (human clicked Merge in the
            # GitLab UI, bypassing the approval circuit → merger job). The
            # push to master already triggered deploy → smoke e2e (no issue
            # context). Catch up: trigger the catchup job to close the issue
            # + cascade the parent, so it doesn't stay stuck at boucle:approval.
            # MR_ISSUE_IID was extracted from the branch name above (line 173);
            # non-boucle branches already exited at line 174-176.
            echo "MR !${MR_IID} merged directly (action=merge) for issue #$MR_ISSUE_IID — triggering catchup"
            curl -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline" \
              -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
              -F "variables[BOUCLE_ISSUE]=$MR_ISSUE_IID" \
              -F "variables[BOUCLE_ROLE]=catchup" > /dev/null
            exit 0
            ;;
          open)
            # open: the worker creates the MR and chains to reviewer itself —
            # no dispatch action needed.
            echo "MR !${MR_IID} action=$MR_ACTION — handled by worker, skipping"
            exit 0
            ;;
```

Notes:
- `MR_ISSUE_IID` is already extracted at line 173 (`sed -n 's/^boucle\/\([0-9]\+\)$/\1/p'`) and non-boucle branches already `exit 0` at lines 174-176, so by the time we reach `case "$MR_ACTION"`, `MR_ISSUE_IID` is guaranteed non-empty for boucle MRs.
- The `curl` call mirrors the exact pattern used by `approved` (line 188-190), `update` (207-209), `close` (221-223), `reopen` (229-231), `unapproved` (242-244): same endpoint, same `-F "token=…"` + `-F "ref=master"` + `-F "variables[BOUCLE_ISSUE]=…"` + `-F "variables[BOUCLE_ROLE]=…"`, output redirected to `/dev/null`.
- `open` is split out as its own case that still skips (worker handles it).

- [ ] **Step 3: Verify the YAML still parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml')); print('YAML OK')"`
Expected: `YAML OK`

If `python3`/`pyyaml` is unavailable, fall back to: `node -e "const y=require('fs').readFileSync('.gitlab-ci.yml','utf8'); console.log('read OK, '+y.length+' bytes')"` (confirms the file is readable; full YAML validation happens when GitLab picks up the pipeline).

- [ ] **Step 4: Verify the dispatch case statement is well-formed (balanced `;;` and `esac`)**

Run: `sed -n '179,260p' .gitlab-ci.yml | grep -cE '^\s*(approved|update|close|reopen|unapproved|merge|open|\*)\)'`
Expected: `8` (the 7 named cases + the `*)` catch-all)

Run: `sed -n '179,260p' .gitlab-ci.yml | grep -c 'esac'`
Expected: `1`

- [ ] **Step 5: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): route direct MR merges to catchup job in dispatch

Split the open|merge case in dispatch: merge now triggers a new catchup
job (closes the issue + cascades the parent when a human merges a
boucle/<iid> MR directly, bypassing the approval circuit). open stays a
skip (worker handles it)."
```

---

## Task 2: Add the `catchup` job

**Files:**
- Modify: `.gitlab-ci.yml` — insert a new `catchup:` job between the end of `merger` (line 1385, `timeout: 15m`) and the start of `deploy` (line 1387, `# ── Deploy ...`).

- [ ] **Step 1: Read the exact insertion boundary to confirm the match**

Run: `sed -n '1383,1389p' .gitlab-ci.yml`
Expected output:
```
        -F "variables[BOUCLE_LIVE_URL]=$LIVE_URL" > /dev/null 2>&1 || true
      echo "Triggered e2e for issue #$BOUCLE_ISSUE with LIVE_URL=$LIVE_URL"
  timeout: 15m

# ── Deploy (on push to master) ─────────────────────────────────────────
deploy:
```

- [ ] **Step 2: Insert the `catchup` job between `merger` and `deploy`**

Use the `edit` tool. The `oldString` is the boundary between the two jobs:

```
  timeout: 15m

# ── Deploy (on push to master) ─────────────────────────────────────────
deploy:
```

The `newString` inserts the full `catchup` job before the `deploy` header:

```
  timeout: 15m

# ── Catchup (direct merge recovery) ────────────────────────────────────
# Triggered by dispatch when a human merges a boucle/<iid> MR directly
# (merge_request webhook, action=merge), bypassing the approval circuit.
# The push to master already triggered deploy → smoke e2e (no issue
# context). This job catches up: inspects the issue state, sets
# boucle:done (if was at boucle:approval) or boucle:human (if merged
# early), posts an audit comment, closes the issue, and cascades the
# parent close. No e2e agent runs — we trust the human's merge judgment.
catchup:
  stage: merge
  # Loop-critical control-plane job: API calls only, no build. Run on ANY
  # available runner (tags: []) so a direct merge is never blocked waiting
  # behind a heavy worker/reviewer job on the single tooling runner.
  tags: []
  needs:
    - job: dispatch
      optional: true
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger" && $BOUCLE_ROLE == "catchup"
  script:
    - |
      export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"

      # ── Helpers (local copies — matches the per-job pattern used by  ──
      # merger, e2e, doctor: each job duplicates set_boucle_label,
      # close_issue, maybe_close_parent in its own script block).
      # No cross-job refactoring (out of scope for a 1957-line inline file).

      # Label helper: preserve non-boucle labels when writing a boucle label.
      # The jq filter uses startswith("boucle:") which catches BOTH the detail
      # axis (boucle:triage) AND the gross axis (boucle::status::bot, also
      # starts with "boucle:"), so we strip all boucle-managed labels when
      # writing a new pair. Caller passes detail as $2 and gross as $3.
      # Tolerate glab non-zero exit (version warnings, transient API errors).
      set_boucle_label() {
        local iid="$1" new="$2" gross="$3"
        local current
        current=$(set +e; glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$iid" 2>/dev/null | jq -r '.labels | map(select(startswith("boucle:") | not)) | join(",")' 2>/dev/null) || true
        local merged="${current:+$current,}$new,$gross"
        glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$iid" -f labels="$merged" > /dev/null 2>&1 || true
        # When the issue moves to the bot side, assign it to the bot user so
        # the board reflects who owns the next action. Best-effort: skip
        # silently if BOUCLE_BOT_ID is unset (backward compat).
        if [ "$gross" = "boucle::status::bot" ] && [ -n "${BOUCLE_BOT_ID:-}" ]; then
          curl -s -o /dev/null -X PUT "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/issues/$iid" \
            --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
            --data-urlencode "assignee_ids[]=$BOUCLE_BOT_ID" 2>/dev/null || true
        fi
      }

      # Close a GitLab issue (boucle:done is a board label, not a close state)
      close_issue() {
        local iid="$1"
        glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$iid" \
          -f state_event=close > /dev/null 2>&1 || true
      }

      # List child work items of a parent. Returns JSON array (empty on failure).
      get_work_item_children() {
        local parent_iid="$1" children out
        children=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/-/work_items/$parent_iid/children" 2>/dev/null) || { echo "[]"; return; }
        out=$(printf '%s' "$children" | jq -c 'if type == "array" then . else [] end' 2>/dev/null)
        printf '%s' "${out:-[]}"
      }

      # Parent-close cascade: if this issue is a sub-issue (has a "## Parent
      # issue" section in its body), check whether ALL its sibling sub-issues
      # are closed. If so, close the parent too. No-op if not a sub-issue.
      maybe_close_parent() {
        local child_iid="$1"
        local child_data parent_iid
        child_data=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$child_iid" 2>/dev/null) || { echo "maybe_close_parent: can't fetch issue #$child_iid — skipping."; return 0; }
        parent_iid=$(echo "$child_data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
        if [ -z "$parent_iid" ]; then
          echo "maybe_close_parent: no parent issue link in #$child_iid — not a sub-issue."
          return 0
        fi
        local parent_data parent_state
        parent_data=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$parent_iid" 2>/dev/null) || { echo "maybe_close_parent: can't fetch parent #$parent_iid — skipping."; return 0; }
        parent_state=$(echo "$parent_data" | jq -r '.state')
        if [ "$parent_state" = "closed" ]; then
          echo "maybe_close_parent: parent #$parent_iid already closed."
          return 0
        fi
        local children_data sibling_iids
        children_data=$(get_work_item_children "$parent_iid")
        sibling_iids=$(echo "$children_data" | jq -r '[.[].iid] | join(",")' 2>/dev/null)
        if [ -z "$sibling_iids" ]; then
          local parent_notes
          parent_notes=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$parent_iid/notes" 2>/dev/null) || { echo "maybe_close_parent: can't fetch parent notes — skipping."; return 0; }
          sibling_iids=$(echo "$parent_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
          if [ -z "$sibling_iids" ]; then
            echo "maybe_close_parent: no children via hierarchy API and no split-parent marker on #$parent_iid — checking REST links..."
            local links_data
            links_data=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$parent_iid/links" 2>/dev/null) || links_data="[]"
            sibling_iids=$(echo "$links_data" | jq -r '[.[] | select(.iid != null) | .iid] | join(",")')
            if [ -z "$sibling_iids" ]; then
              echo "maybe_close_parent: parent #$parent_iid has no children, no marker, and no REST links — can't check siblings."
              return 0
            fi
            echo "maybe_close_parent: found $sibling_iids via REST links fallback"
            local all_closed=true iid
            for iid in $(echo "$sibling_iids" | tr ',' ' '); do
              local sib_state
              sib_state=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$iid" 2>/dev/null | jq -r '.state // "unknown"')
              if [ "$sib_state" != "closed" ]; then
                echo "maybe_close_parent: sibling #$iid is $sib_state — parent #$parent_iid stays open."
                all_closed=false
                break
              fi
            done
            if [ "$all_closed" = "true" ]; then
              echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
              close_issue "$parent_iid"
            fi
            return 0
          fi
          echo "maybe_close_parent: found $sibling_iids via legacy split-parent marker"
          local all_closed=true iid
          for iid in $(echo "$sibling_iids" | tr ',' ' '); do
            local sib_state
            sib_state=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$iid" 2>/dev/null | jq -r '.state // "unknown"')
            if [ "$sib_state" != "closed" ]; then
              echo "maybe_close_parent: sibling #$iid is $sib_state — parent #$parent_iid stays open."
              all_closed=false
              break
            fi
          done
          if [ "$all_closed" = "true" ]; then
            echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
            close_issue "$parent_iid"
          fi
          return 0
        fi
        local all_closed=true
        local open_count
        open_count=$(echo "$children_data" | jq '[.[] | select(.state != "closed")] | length' 2>/dev/null || echo 1)
        if [ "${open_count:-1}" -gt 0 ]; then
          local open_iids
          open_iids=$(echo "$children_data" | jq -r '[.[] | select(.state != "closed") | .iid] | join(",")')
          echo "maybe_close_parent: open sub-issue(s) #$open_iids — parent #$parent_iid stays open."
          all_closed=false
        fi
        if [ "$all_closed" = "true" ]; then
          echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
          close_issue "$parent_iid"
        fi
      }

      # ── Main: inspect issue state, branch, close, cascade ──────────────
      # Fetch the issue's current labels.
      ISSUE_DATA=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" 2>/dev/null)
      if [ -z "$ISSUE_DATA" ]; then
        echo "FAIL: can't fetch issue #$BOUCLE_ISSUE" >&2
        exit 1
      fi
      ISSUE_STATE=$(echo "$ISSUE_DATA" | jq -r '.state // "unknown"')
      ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels | join(",")')

      # If the issue is already closed, nothing to catch up — idempotence.
      if [ "$ISSUE_STATE" = "closed" ]; then
        echo "Issue #$BOUCLE_ISSUE already closed — nothing to catch up."
        exit 0
      fi

      # Determine the current boucle:* detail label (not the gross-axis
      # boucle::status::* labels, which also start with "boucle:").
      CURRENT_BOUCLE=$(echo "$ISSUE_LABELS" | tr ',' '\n' | grep -E '^boucle:(triage|needs-info|spec-review|todo|working|review|approval|merging|done|human|split|blocked)$' | head -1)

      case "$CURRENT_BOUCLE" in
        approval)
          # Happy path: the issue was waiting for approval and the human
          # merged directly. Trust the judgment → mark done.
          set_boucle_label "$BOUCLE_ISSUE" "boucle:done" "boucle::status::done"
          TARGET="done"
          ;;
        triage|needs-info|spec-review|todo|working|review|merging)
          # Merged before the loop finished its review. Honest signal: the
          # bot did not validate completion → mark human. Still close +
          # cascade so the issue doesn't stay stuck.
          set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
          TARGET="human"
          ;;
        done|human|split|blocked)
          # Already at a terminal state — issue was handled by another path.
          echo "Issue #$BOUCLE_ISSUE already at terminal state boucle:$CURRENT_BOUCLE — skipping."
          exit 0
          ;;
        "")
          # No boucle label — issue is outside the loop. Don't touch it.
          echo "Issue #$BOUCLE_ISSUE has no boucle label — outside the loop, skipping."
          exit 0
          ;;
      esac

      echo "Catchup: issue #$BOUCLE_ISSUE was boucle:$CURRENT_BOUCLE → now boucle:$TARGET"

      # Post an audit comment (with hidden tag for idempotence/audit).
      # The MR IID isn't passed as a variable (dispatch only forwards
      # BOUCLE_ISSUE + BOUCLE_ROLE); reference the issue + branch instead.
      AUDIT_BODY="<!-- boucle:catchup v=1 iid=$BOUCLE_ISSUE state=$CURRENT_BOUCLE target=$TARGET -->
🤖 Rattrapage automatique — la MR sur la branche \`boucle/$BOUCLE_ISSUE\` a été fusionnée directement sans passer par le circuit d'approbation.

État de l'issue au moment de la fusion : \`boucle:$CURRENT_BOUCLE\`.
Issue marquée \`boucle:$TARGET\` et fermée."
      glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE/notes" \
        -f body="$AUDIT_BODY" > /dev/null 2>&1 || true

      # Close the issue (boucle:done is a board label, not a GitLab close state).
      close_issue "$BOUCLE_ISSUE"
      echo "Catchup: closed issue #$BOUCLE_ISSUE"

      # Cascade: if this is a sub-issue, close the parent when all siblings are closed.
      maybe_close_parent "$BOUCLE_ISSUE"
  timeout: 5m

# ── Deploy (on push to master) ─────────────────────────────────────────
deploy:
```

Notes on the helpers:
- `set_boucle_label`, `close_issue`, `get_work_item_children`, `maybe_close_parent` are **verbatim copies** of the e2e job's versions (`.gitlab-ci.yml:1442-1576`), which are the most defensive variants (they tolerate glab/jq non-zero exit with `set +e` + `|| true`). This matches the existing per-job duplication pattern — merger and doctor each have their own copies too.
- The `catchup` job uses `tags: []` (runs on any runner, like dispatch/merger) because it's loop-critical and makes only API calls — no build.
- `stage: merge` places it in the same stage as `merger` (consistent with the spec).
- `needs: [dispatch]` with `optional: true` mirrors `merger`'s `needs` (line 1234-1236) — allows the job to run when triggered via the token (dispatch isn't in the same pipeline).
- `rules` mirrors `merger`'s rules (line 1237-1240): gated on `$BOUCLE_ENABLED` + `$CI_PIPELINE_SOURCE == "trigger" && $BOUCLE_ROLE == "catchup"`.
- `timeout: 5m` — the job makes a handful of API calls, no build, no agent. 5 min is generous.
- The audit comment references the branch `boucle/$BOUCLE_ISSUE` rather than `!{MR_IID}` because dispatch only forwards `BOUCLE_ISSUE` + `BOUCLE_ROLE` to the triggered pipeline (same as every other role trigger). Adding `BOUCLE_MR_IID` as a forwarded variable would require changing the dispatch `curl` in Task 1 — kept out of scope for simplicity; the branch name uniquely identifies the MR.

- [ ] **Step 3: Verify the YAML still parses**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('.gitlab-ci.yml')); print('YAML OK, jobs:', list(d.keys()))"`
Expected: `YAML OK, jobs: ['default', 'variables', 'stages', 'dispatch', 'triage', 'worker', 'reviewer', 'merger', 'catchup', 'deploy', 'e2e', 'doctor']` (the `catchup` key appears between `merger` and `deploy`).

If `pyyaml` is unavailable, fall back to: `node -e "const y=require('yaml').parse(require('fs').readFileSync('.gitlab-ci.yml','utf8')); console.log('YAML OK, jobs:', Object.keys(y).filter(k=>!['default','variables','stages'].includes(k)))"` (requires `yaml` npm package; if also unavailable, skip — GitLab will validate on pipeline pickup).

- [ ] **Step 4: Verify the `catchup` job structure (stage, rules, helpers present)**

Run: `grep -nE '^(catchup:|  stage:|  rules:|  tags:|  needs:|  timeout:|  script:)' .gitlab-ci.yml | grep -A8 '^.*catchup:'`
Expected: shows `catchup:`, `stage: merge`, `tags: []`, `needs:`, `rules:`, `script:`, `timeout: 5m`.

Run: `grep -cE 'set_boucle_label\(\)|close_issue\(\)|maybe_close_parent\(\)|get_work_item_children\(\)' .gitlab-ci.yml`
Expected: a number ≥ 16 (4 helper definitions in catchup + their calls; the same helpers also exist in merger/e2e/doctor). The key check: the count should be higher than before this task (the 4 new definitions in catchup add 4 to the count).

- [ ] **Step 5: Verify the dispatch → catchup trigger wiring**

Run: `grep -n 'BOUCLE_ROLE]=catchup' .gitlab-ci.yml`
Expected: exactly 1 match, in the dispatch `merge)` case (the trigger `curl`).

Run: `grep -n 'BOUCLE_ROLE == "catchup"' .gitlab-ci.yml`
Expected: exactly 1 match, in the `catchup` job `rules:`.

- [ ] **Step 6: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): add catchup job for direct-merge recovery

New catchup job triggered by dispatch when a human merges a boucle/<iid>
MR directly (action=merge), bypassing the approval circuit. Inspects the
issue state: boucle:approval → boucle:done, any other active state →
boucle:human, terminal/no-label → skip. Posts an audit comment, closes
the issue, and cascades the parent close. No e2e agent runs (trusts the
human merge judgment). Helpers duplicated locally per the existing
per-job pattern."
```

---

## Task 3: Manual smoke test (verification before merge)

**Files:** None modified — this is a verification task against the live `gitlab.example.com` instance.

This codebase has no automated test framework for the inline bash in `.gitlab-ci.yml` (confirmed by the spec, section 7). Verification is by manual smoke test. This task documents the procedure; it is performed by a human on the live GitLab instance, not by the agent.

- [ ] **Step 1: Confirm `bin/doctor` still passes (no setup regression)**

Run: `./bin/doctor`
Expected: all ~20 checks pass (the catchup feature adds no new labels, no new CI variables, no new webhook events — `bin/setup` and `bin/doctor` are unchanged). If any check fails, it's pre-existing and unrelated to this change.

- [ ] **Step 2: Document the manual smoke test procedure for the human**

The human operator performs this on the `gitlab.example.com` fork after the branch is pushed:

**Test A — happy path (issue at `boucle:approval`):**
1. Create or use an issue that has reached `boucle:approval` (reviewer PASS'd, MR open on `boucle/<iid>`).
2. In the GitLab UI, click **Merge** on the MR directly (do NOT click Approve first — bypass the circuit).
3. Observe: the `merge_request` webhook fires `action=merge` → `dispatch` → triggers `catchup`.
4. Verify on the issue:
   - Label changes from `boucle:approval` to `boucle:done` (+ `boucle::status::done`).
   - An audit comment is posted (starts with `<!-- boucle:catchup v=1 ... -->`, then the 🤖 rattrapage message).
   - The issue is **closed**.
   - If the issue was a sub-issue of a `boucle:split` parent, the parent closes too (if all siblings are closed).

**Test B — early merge (issue at `boucle:working`):**
1. Create or use an issue at `boucle:working` or `boucle:review` with an open MR on `boucle/<iid>`.
2. Merge the MR directly via the GitLab UI.
3. Verify: label changes to `boucle:human` (+ `boucle::status::human`), audit comment posted, issue closed, parent cascade runs.

**Test C — idempotence (re-triggered merge event):**
1. After Test A, if GitLab re-fires the `merge` event (rare), `catchup` runs again.
2. Verify: the issue is already closed → `catchup` exits early at the `ISSUE_STATE = closed` check (line: "Issue #$BOUCLE_ISSUE already closed — nothing to catch up."). No duplicate audit comment, no error.

**Test D — non-boucle MR merge:**
1. Merge a regular (non-`boucle/`) MR on the same project.
2. Verify: `dispatch` skips at the branch-name check (line 174-176, "not a boucle branch, skipping"). `catchup` is never triggered. No issue touched.

- [ ] **Step 3: Final commit (if any fixups were needed from smoke test)**

If the smoke test reveals a bug, fix it in `.gitlab-ci.yml` and commit with `fix(ci): ...`. If the smoke test passes, no further commit is needed — Tasks 1 and 2 are the implementation.

---

## Self-Review

**1. Spec coverage:**
- §2 Objectif (close issue + cascade, no e2e) → Task 2 main logic (close_issue + maybe_close_parent, no e2e agent). ✓
- §3 Decisions / §4.2 dispatch `case "merge"` → Task 1. ✓
- §4.3 catchup job (stage merge, needs dispatch, rules trigger token + BOUCLE_ROLE==catchup) → Task 2. ✓
- §4.4 helpers (local copies) → Task 2 (verbatim copies of e2e's helpers). ✓
- §4.5 audit comment (hidden tag + rattrapage message) → Task 2 AUDIT_BODY. ✓
- §4.6 branching logic (approval→done, other-active→human, terminal→skip, no-label→skip) → Task 2 case statement. ✓
- §5 unchanged (merger/e2e/doctor/deploy/bin/setup/bin/doctor) → no tasks touch them. ✓
- §6 edge cases (non-boucle MR, already-closed issue, replayed event, no boucle label, terminal state, merging state) → Task 2 handles all: non-boucle in dispatch (line 174), already-closed (ISSUE_STATE check), replayed (idempotence via closed check), no-label (CURRENT_BOUCLE="" → skip), terminal (done|human|split|blocked → skip), merging (falls into "other active" → human). ✓
- §7 tests (no framework, manual smoke) → Task 3. ✓
- §8 out of scope (doctor recovery, e2e on direct merge, non-boucle MRs via Closes #N, helper refactoring) → none implemented. ✓

**2. Placeholder scan:** No TBD/TODO/"implement later"/"add error handling" patterns. All code blocks are complete. ✓

**3. Type consistency:**
- `set_boucle_label "$iid" "boucle:done" "boucle::status::done"` — matches e2e usage (line 1616). ✓
- `close_issue "$iid"` — matches e2e (line 1618). ✓
- `maybe_close_parent "$BOUCLE_ISSUE"` — matches e2e (line 1621). ✓
- `BOUCLE_ROLE == "catchup"` in rules matches `BOUCLE_ROLE]=catchup` in dispatch trigger. ✓
- `BOUCLE_ISSUE` forwarded by dispatch and consumed by catchup via `export BOUCLE_ISSUE="${BOUCLE_ISSUE:?...}"`. ✓

No issues found.