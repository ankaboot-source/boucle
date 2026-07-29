#!/usr/bin/env bash
# boucle POC — looper health check
# Runs every 5 min via cron. Detects stuck loops, applies quick-win fixes,
# logs drawbacks to docs/poc-looper-status.md for POC lessons.
# Minimalist: no deps beyond looper, sqlite3, gh, jq.

set -euo pipefail

# Cron has a minimal PATH and no D-Bus keyring session, so `gh` is neither on
# PATH nor able to read the keyring. Export both explicitly.
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
GH_TOKEN="$(grep -oE 'GH_TOKEN = "[^"]+"' "$HOME/.looper/config.toml" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' || true)"
export GH_TOKEN

LOOPER="/tmp/looper-dev/looper"
DB="$HOME/.looper/looper.sqlite"
LOG="$HOME/.looper/logs/health-check.log"
POC_DIR="$HOME/Projects/ankaboot-source/boucle"
DRAWBACKS="$POC_DIR/docs/poc-looper-drawbacks.md"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$LOG")"
mkdir -p "$(dirname "$DRAWBACKS")"

log() { echo "[$TS] $*" >> "$LOG"; }

log "=== health check start ==="

# 1. Daemon alive?
DAEMON_PID=$(pgrep -f "looperd" | head -1 || true)
if [ -z "$DAEMON_PID" ]; then
  log "DRAWBACK: daemon not running — restarting via start-looperd-as-bot.sh"
  echo "## $TS — daemon not running" >> "$DRAWBACKS"
  echo "- **Symptom:** pgrep looperd empty" >> "$DRAWBACKS"
  echo "- **Quick-win:** restarted daemon" >> "$DRAWBACKS"
  echo "- **Root cause:** unknown (no systemd supervision)" >> "$DRAWBACKS"
  echo "" >> "$DRAWBACKS"
  nohup "$HOME/.looper/start-looperd-as-bot.sh" >> "$HOME/.looper/logs/looperd-restart.log" 2>&1 &
  sleep 3
  DAEMON_PID=$(pgrep -f "looperd" | head -1 || true)
  if [ -z "$DAEMON_PID" ]; then
    log "FATAL: daemon restart failed"
    exit 1
  fi
  log "daemon restarted, PID=$DAEMON_PID"
fi

# 2. Stuck reviewer loops (backing_off/paused with reviews posted but marker mismatch — bug #599)
STUCK_REVIEWERS=$(sqlite3 "$DB" "SELECT seq, repo, pr_number FROM loops WHERE type='reviewer' AND status IN ('backing_off','paused') AND pr_number IS NOT NULL;" 2>/dev/null || true)

if [ -n "$STUCK_REVIEWERS" ]; then
  while IFS='|' read -r seq repo pr; do
    [ -z "$seq" ] && continue
    # Check if a review was actually posted by ankaboot-bot on this PR
    REVIEWS=$(gh api "repos/$repo/pulls/$pr/reviews" --jq '[.[] | select(.user.login=="ankaboot-bot")] | length' 2>/dev/null || echo "0")
    if [ "$REVIEWS" -gt 0 ]; then
      log "DRAWBACK: reviewer loop #$seq stuck (bug #599) but $REVIEWS review(s) posted on $repo#$pr — marking completed"
      echo "## $TS — reviewer loop #$seq stuck (bug #599)" >> "$DRAWBACKS"
      echo "- **Symptom:** loop status backing_off/paused, but $REVIEWS review(s) posted by ankaboot-bot on $repo#$pr" >> "$DRAWBACKS"
      echo "- **Quick-win:** cancel stuck queue items, mark loop completed" >> "$DRAWBACKS"
      echo "- **Root cause:** bug #599 — agent posts marker without :headSHA suffix, daemon expects it" >> "$DRAWBACKS"
      echo "- **Intermittent:** yes — agent sometimes includes :headSHA, sometimes drops it" >> "$DRAWBACKS"
      echo "" >> "$DRAWBACKS"
      # Cancel stuck queue items for this loop
      sqlite3 "$DB" "UPDATE queue_items SET status='cancelled' WHERE loop_id=(SELECT id FROM loops WHERE seq=$seq) AND status IN ('queued','running');" 2>/dev/null || true
      # Mark loop completed
      sqlite3 "$DB" "UPDATE loops SET status='completed' WHERE seq=$seq;" 2>/dev/null || true
      log "loop #$seq marked completed"
    fi
  done <<< "$STUCK_REVIEWERS"
fi

# 3. Stuck queue items blocking scheduler slots (high attempts)
STUCK_QUEUE=$(sqlite3 "$DB" "SELECT id, loop_id, attempts FROM queue_items WHERE status='queued' AND attempts >= 3;" 2>/dev/null || true)
if [ -n "$STUCK_QUEUE" ]; then
  while IFS='|' read -r qid lid attempts; do
    [ -z "$qid" ] && continue
    log "DRAWBACK: queue item $qid stuck ($attempts attempts) — cancelling"
    echo "## $TS — queue item stuck ($attempts attempts)" >> "$DRAWBACKS"
    echo "- **Symptom:** queue item $qid for loop $lid stuck in queued with $attempts attempts" >> "$DRAWBACKS"
    echo "- **Quick-win:** cancel queue item to free scheduler slot" >> "$DRAWBACKS"
    echo "- **Root cause:** likely bug #599 marker mismatch or #595 EBADF" >> "$DRAWBACKS"
    echo "" >> "$DRAWBACKS"
    sqlite3 "$DB" "UPDATE queue_items SET status='cancelled' WHERE id='$qid';" 2>/dev/null || true
  done <<< "$STUCK_QUEUE"
fi

# 4. Worker PRs without review (issue #598 — manual trigger needed)
WORKER_PRS=$(sqlite3 "$DB" "SELECT seq, repo, pr_number FROM loops WHERE type='worker' AND status='completed' AND pr_number IS NOT NULL;" 2>/dev/null || true)
if [ -n "$WORKER_PRS" ]; then
  while IFS='|' read -r seq repo pr; do
    [ -z "$seq" ] && continue
    # Check if this PR already has a reviewer loop
    HAS_REVIEWER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM loops WHERE type='reviewer' AND pr_number=$pr AND repo='$repo';" 2>/dev/null || echo "0")
    if [ "$HAS_REVIEWER" -eq 0 ]; then
      log "DRAWBACK: worker PR $repo#$pr has no reviewer loop (issue #598) — triggering manual review"
      echo "## $TS — worker PR $repo#$pr needs manual review (issue #598)" >> "$DRAWBACKS"
      echo "- **Symptom:** worker completed PR $repo#$pr but no reviewer loop auto-triggered" >> "$DRAWBACKS"
      echo "- **Quick-win:** manual \`looper review $repo#$pr\`" >> "$DRAWBACKS"
      echo "- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs" >> "$DRAWBACKS"
      echo "" >> "$DRAWBACKS"
      $LOOPER review "$repo#$pr" >> "$LOG" 2>&1 || log "manual review trigger failed for $repo#$pr"
    fi
  done <<< "$WORKER_PRS"
fi

# 5. Spec PRs with looper:spec-reviewing label but no reviewer loop (specReview should auto-discover)
SPEC_PRS=$(gh api "repos/ankaboot-source/m3llm/pulls?state=open" --jq '.[] | select(.labels[].name=="looper:spec-reviewing") | .number' 2>/dev/null || true)
if [ -n "$SPEC_PRS" ]; then
  for pr in $SPEC_PRS; do
    HAS_REVIEWER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM loops WHERE type='reviewer' AND pr_number=$pr AND repo='ankaboot-source/m3llm';" 2>/dev/null || echo "0")
    if [ "$HAS_REVIEWER" -eq 0 ]; then
      log "spec PR m3llm#$pr has looper:spec-reviewing but no reviewer loop — triggering"
      $LOOPER review "ankaboot-source/m3llm#$pr" >> "$LOG" 2>&1 || log "spec review trigger failed for m3llm#$pr"
    fi
  done
fi

# 6. Spec PRs deadlocked by bug #602 (single-identity self-approval fallback)
# Reviewer loop completed but review state is COMMENTED (not APPROVE) because
# selfApprovalFallback downgrades APPROVE→COMMENT when PR author == reviewer (bot).
# The spec PR never gets promoted from looper:spec-reviewing → looper:spec-ready,
# so the worker discovery lane (keys on looper:worker-ready on the ISSUE) never fires.
# Fix: detect the deadlock and manually promote both the spec PR and the issue.
DEADLOCKED_SPEC_PRS=$(gh api "repos/ankaboot-source/m3llm/pulls?state=open" --jq '
  [.[] | select(.labels[].name=="looper:spec-reviewing") | .number] | .[]
' 2>/dev/null || true)
if [ -n "$DEADLOCKED_SPEC_PRS" ]; then
  for pr in $DEADLOCKED_SPEC_PRS; do
    # Has a completed reviewer loop?
    REVIEWER_DONE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM loops WHERE type='reviewer' AND pr_number=$pr AND repo='ankaboot-source/m3llm' AND status='completed';" 2>/dev/null || echo "0")
    if [ "$REVIEWER_DONE" -eq 0 ]; then
      continue  # reviewer hasn't run yet — section 5 handles triggering
    fi
    # Is the latest review COMMENTED (not APPROVE, not REQUEST_CHANGES)?
    LATEST_REVIEW_STATE=$(gh api "repos/ankaboot-source/m3llm/pulls/$pr/reviews" --jq '[.[] | select(.user.login=="ankaboot-bot")] | if length > 0 then (sort_by(.submitted_at) | last | .state) else "NONE" end' 2>/dev/null || echo "NONE")
    if [ "$LATEST_REVIEW_STATE" != "COMMENTED" ]; then
      continue  # APPROVE → looper promotes automatically; REQUEST_CHANGES → fixer runs
    fi
    # Deadlock confirmed: reviewer completed but only COMMENTED (bug #602).
    # Find the source issue from the spec PR body (planner writes "Closes #N" or title has (#N)).
    SOURCE_ISSUE=$(gh api "repos/ankaboot-source/m3llm/pulls/$pr" --jq '
      (.body | capture("#(?<n>[0-9]+)")?.n // empty) // (.title | capture("\\(#(?<n>[0-9]+)\\)")?.n // empty)
    ' 2>/dev/null || true)
    if [ -z "$SOURCE_ISSUE" ]; then
      log "DRAWBACK: spec PR m3llm#$pr deadlocked by #602 but can't find source issue — skipping"
      echo "## $TS — spec PR #$pr deadlocked by #602, source issue unknown" >> "$DRAWBACKS"
      echo "- **Symptom:** reviewer loop completed, review state COMMENTED (bug #602), but source issue not found in PR body/title" >> "$DRAWBACKS"
      echo "- **Quick-win:** none (needs manual promotion)" >> "$DRAWBACKS"
      echo "- **Root cause:** bug #602 — selfApprovalFallback downgrades APPROVE→COMMENT in single-identity mode" >> "$DRAWBACKS"
      echo "" >> "$DRAWBACKS"
      continue
    fi
    # Verify the issue still has looper:plan (not already promoted/closed)
    ISSUE_HAS_PLAN=$(gh api "repos/ankaboot-source/m3llm/issues/$SOURCE_ISSUE" --jq '[.labels[].name | select(.=="looper:plan")] | length' 2>/dev/null || echo "0")
    if [ "$ISSUE_HAS_PLAN" -eq 0 ]; then
      continue  # issue already promoted or closed — nothing to do
    fi
    log "DRAWBACK: spec PR m3llm#$pr deadlocked by #602 (reviewer COMMENTED) — promoting spec PR #$pr → looper:spec-ready, issue #$SOURCE_ISSUE → looper:worker-ready"
    echo "## $TS — spec PR #$pr deadlocked by #602 (reviewer COMMENTED, not APPROVE)" >> "$DRAWBACKS"
    echo "- **Symptom:** reviewer loop completed on spec PR #$pr but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)" >> "$DRAWBACKS"
    echo "- **Quick-win:** manually promote spec PR #$pr to looper:spec-ready, issue #$SOURCE_ISSUE to looper:worker-ready" >> "$DRAWBACKS"
    echo "- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT" >> "$DRAWBACKS"
    echo "" >> "$DRAWBACKS"
    # Promote spec PR: looper:spec-reviewing → looper:spec-ready
    gh api -X DELETE "repos/ankaboot-source/m3llm/issues/$pr/labels/looper:spec-reviewing" >/dev/null 2>&1 || log "failed to remove looper:spec-reviewing from PR #$pr"
    gh api -X POST "repos/ankaboot-source/m3llm/issues/$pr/labels" -f labels[]="looper:spec-ready" >/dev/null 2>&1 || log "failed to add looper:spec-ready to PR #$pr"
    # Promote issue: looper:plan → looper:worker-ready
    gh api -X DELETE "repos/ankaboot-source/m3llm/issues/$SOURCE_ISSUE/labels/looper:plan" >/dev/null 2>&1 || log "failed to remove looper:plan from issue #$SOURCE_ISSUE"
    gh api -X POST "repos/ankaboot-source/m3llm/issues/$SOURCE_ISSUE/labels" -f labels[]="looper:worker-ready" >/dev/null 2>&1 || log "failed to add looper:worker-ready to issue #$SOURCE_ISSUE"
    log "promoted spec PR #$pr → looper:spec-ready, issue #$SOURCE_ISSUE → looper:worker-ready"
  done
fi

# 7. Spec PRs whose source issue is closed — auto-close the spec PR (planning artifact cleanup)
# Spec PRs are planning artifacts, not implementation. Once the source issue is closed
# (worker PR merged), the spec PR is redundant. looper never closes them — this pollutes
# the GitHub PR list with stale spec PRs. This section auto-closes them.
SPEC_PRS_OPEN=$(gh api "repos/ankaboot-source/m3llm/pulls?state=open" --jq '
  [.[] | select(.labels[].name=="looper:spec-ready" or .labels[].name=="looper:spec-reviewing") | {number, title}] | .[]
' 2>/dev/null || true)
if [ -n "$SPEC_PRS_OPEN" ]; then
  while IFS=$'\t' read -r pr title; do
    [ -z "$pr" ] && continue
    # Extract source issue number from title (format: "... (#NNN)" or "...#NNN")
    SOURCE_ISSUE=$(echo "$title" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    if [ -z "$SOURCE_ISSUE" ]; then
      continue
    fi
    # Is the source issue closed?
    ISSUE_STATE=$(gh api "repos/ankaboot-source/m3llm/issues/$SOURCE_ISSUE" --jq '.state' 2>/dev/null || echo "OPEN")
    if [ "$ISSUE_STATE" != "closed" ]; then
      continue
    fi
    log "DRAWBACK: spec PR m3llm#$pr is stale (source issue #$SOURCE_ISSUE closed) — auto-closing"
    echo "## $TS — spec PR #$pr auto-closed (source issue #$SOURCE_ISSUE closed)" >> "$DRAWBACKS"
    echo "- **Symptom:** spec PR #$pr still open but source issue #$SOURCE_ISSUE is closed" >> "$DRAWBACKS"
    echo "- **Quick-win:** auto-close spec PR with comment + delete branch" >> "$DRAWBACKS"
    echo "- **Root cause:** looper never closes spec PRs after issue completion — no cleanup mechanism" >> "$DRAWBACKS"
    echo "" >> "$DRAWBACKS"
    gh pr close "$pr" --repo ankaboot-source/m3llm \
      --comment "Auto-closing stale spec PR: source issue #$SOURCE_ISSUE is closed. This was a planning artifact, not an implementation PR." \
      --delete-branch >> "$LOG" 2>&1 || log "failed to close spec PR #$pr"
  done < <(echo "$SPEC_PRS_OPEN" | jq -r '(.number|tostring) + "\t" + .title')
fi

log "=== health check end ==="