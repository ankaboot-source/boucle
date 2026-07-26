## 2026-07-25T15:13:35Z — worker PR ankaboot-source/m3llm#174 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#174 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#174`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-25T15:13:35Z — worker PR ankaboot-source/m3llm#185 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#185 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#185`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-25T15:35:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-25T21:40:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-25T21:45:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-25T22:00:00Z — worker PR ankaboot-source/m3llm#198 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#198 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#198`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-25T23:47:18Z — spec PR #197 deadlocked by #602 (reviewer COMMENTED, not APPROVE)
- **Symptom:** reviewer loop completed on spec PR #197 but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)
- **Quick-win:** manually promote spec PR #197 to looper:spec-ready, issue #196 to looper:worker-ready
- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT

## 2026-07-25T23:47:18Z — spec PR #187 deadlocked by #602 (reviewer COMMENTED, not APPROVE)
- **Symptom:** reviewer loop completed on spec PR #187 but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)
- **Quick-win:** manually promote spec PR #187 to looper:spec-ready, issue #186 to looper:worker-ready
- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT

## 2026-07-25T23:47:18Z — spec PR #183 deadlocked by #602 (reviewer COMMENTED, not APPROVE)
- **Symptom:** reviewer loop completed on spec PR #183 but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)
- **Quick-win:** manually promote spec PR #183 to looper:spec-ready, issue #181 to looper:worker-ready
- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT

## Pattern — #602 spec-review→worker deadlock (single-identity self-approval fallback)
- **Pattern:** In single-identity mode (bot is both planner/worker author and reviewer), `selfApprovalFallback` downgrades the reviewer's APPROVE to COMMENT to avoid GitHub's self-review block. The spec PR is never promoted `looper:spec-reviewing` → `looper:spec-ready`, so the source issue never gets `looper:worker-ready`, so the worker discovery lane never fires. The scheduler ticks with `availableSlots:3, claimedCount:0` indefinitely. Same single-identity root cause as #598 and #603.
- **Detection signature:** open spec PR with `looper:spec-reviewing` + completed reviewer loop in DB + latest review state = COMMENTED from ankaboot-bot.
- **Workaround (automated, added 2026-07-25):** `scripts/looper-health-check.sh` section 6 (lines 119-173) runs every 5 min via cron. For each open spec PR with `looper:spec-reviewing`, it checks the DB for a completed reviewer loop and the GitHub API for the latest review state. If COMMENTED, it extracts the source issue from the PR body/title, verifies the issue still has `looper:plan`, then promotes the spec PR to `looper:spec-ready` and the issue to `looper:worker-ready`. This unblocks the worker discovery lane automatically. Verified 2026-07-25T23:47:18Z: 3 deadlocks broken in one run, 3 worker loops spawned within ~1 min.
- **Limitation:** section 6 only handles open spec PRs. If the spec PR was closed without merge (e.g. PR #194 for issue #190), the planner loop has already completed and won't re-trigger via label discovery — requires manual `looper plan --issue N --project P` to re-plan.

