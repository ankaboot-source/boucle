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

## 2026-07-26T09:10:00Z — worker PR ankaboot-source/m3llm#202 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#202 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#202`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-26T09:20:00Z — worker PR ankaboot-source/m3llm#204 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#204 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#204`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-26T09:25:00Z — queue item stuck (6 attempts)
- **Symptom:** queue item c4c8d847-7c7d-494c-9307-e3a7257738c4 for loop 0a3458d0-7fdb-4621-b640-6b85552a1da7 stuck in queued with 6 attempts
- **Quick-win:** cancel queue item to free scheduler slot
- **Root cause:** likely bug #599 marker mismatch or #595 EBADF

## 2026-07-26T09:40:00Z — worker PR ankaboot-source/m3llm#205 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#205 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#205`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-26T10:45:00Z — spec PR #208 deadlocked by #602 (reviewer COMMENTED, not APPROVE)
- **Symptom:** reviewer loop completed on spec PR #208 but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)
- **Quick-win:** manually promote spec PR #208 to looper:spec-ready, issue #207 to looper:worker-ready
- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT

## 2026-07-26T11:00:00Z — worker PR ankaboot-source/m3llm#209 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#209 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#209`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## 2026-07-26T14:55:00Z — spec PR #211 deadlocked by #602 (reviewer COMMENTED, not APPROVE)
- **Symptom:** reviewer loop completed on spec PR #211 but review state is COMMENTED (selfApprovalFallback downgraded APPROVE→COMMENT, bug #602)
- **Quick-win:** manually promote spec PR #211 to looper:spec-ready, issue #210 to looper:worker-ready
- **Root cause:** bug #602 — single-identity mode, bot authored PR and bot is reviewer, APPROVE downgraded to COMMENT

## 2026-07-26T15:10:00Z — worker PR ankaboot-source/m3llm#212 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#212 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#212`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

## Pattern — looper planner misunderstands business needs (issue #210)
- **Pattern:** looper's planner investigated issue #210 (search_patents returns HTTP 403 from EPO OPS) and produced a spec + worker implementation (PR #212: "authenticate with EPO OPS via OAuth2, load creds from env"). The work was **technically coherent** (correct diagnosis of 403 as auth failure, correct OAuth2 client_credentials flow) but **business-irrelevant** — the planner misunderstood the actual business need behind the issue. The user fixed it manually in an interactive opencode session with correct understanding.
- **Root cause:** looper's planner operates from the issue text alone, with no access to the broader business context, prior conversations, or the user's mental model. An issue title like "search_patents returns HTTP 403" reads as a technical bug, but the underlying business need may be different (e.g. the patents feature itself may be the wrong approach, or the 403 is a symptom of a deeper product decision). The planner optimizes for the literal issue text, not the intent behind it.
- **Impact:** wasted a full loop (planner → spec → reviewer → worker → PR) on irrelevant work. The user had to manually fix the issue anyway. This is worse than the #602 deadlock — at least #602 just stalls; this produces confidently-wrong output that wastes review time.
- **Workaround:** none automated. The user must verify the planner's spec matches the actual business intent before the worker implements it. This breaks the autonomy promise — if every spec needs human validation against unstated intent, the loop is not autonomous.
- **Code-level fix needed:** the planner prompt should require explicit restatement of the business need (not just the technical symptom) and flag when the issue text is ambiguous about intent. Alternatively, the planner should ask the issue author a clarifying question before writing the spec. This is a prompt-engineering problem in the planner role, not a code bug.

## Pattern — looper's waterfall model blocks mid-loop course correction (structural)
- **Pattern:** looper's flow is strictly phase-gated (waterfall): Issue → Planner (writes spec) → Reviewer (approves spec) → Worker (implements spec) → Reviewer (reviews impl) → Merge. Each gate is a phase boundary. Once a phase starts, it runs to completion against its frozen input. There is **no mechanism for the user to interrupt or redirect a running loop by commenting on the issue**. If the planner misunderstood the business need (see #210 above), the entire downstream work (spec → worker → PR) is wasted because nothing re-reads the issue after the planner starts.
- **Root cause (structural):** looper's loop model is discover → claim → execute → complete. Once a loop is claimed, it runs to completion against the spec it was given. The fixer role reacts to review comments on PRs, but **nothing reacts to comments on the issue itself**. The planner reads the issue once at discovery; the worker reads the spec PR, not the issue; the reviewer reads the diff, not the issue. There is no event channel for mid-loop feedback from the issue.
- **What the user needs (agile flow):** the capacity to interrupt at any time by commenting on the issue — like a chat-based dev process. If the user realizes mid-implementation that the approach is wrong, they comment on the issue, and the loop should incorporate that feedback (re-plan, adjust the spec, or stop the worker). looper cannot do this.
- **Impact:** this is the structural version of the #210 finding. #210 showed the symptom (planner misunderstood intent); this is the root cause (no mid-loop feedback channel). Together they mean looper requires the issue to be perfectly complete and perfectly understood upfront — a waterfall assumption that doesn't match how real development works, where requirements are discovered during implementation.
- **Workaround:** none. The user must get the issue text perfect before labeling `looper:plan`, and must manually stop loops (`looper loop stop` / DB update) if the direction is wrong. This is the opposite of agile.
- **Code-level fix:** structural, not patchable in a small change. Would require: (1) an issue-comment event handler that interrupts running loops, (2) a re-planning mechanism that incorporates new issue comments into an in-flight spec, (3) a worker interrupt-and-redirect mechanism. This is a fundamental workflow model change — closer to Option C (build from scratch) or adopting a tool with an agile loop model (e.g. chat-driven dev). See AGENTS.md §3 Option D.
- **POC implication:** this is a strong signal toward Option B/D. A dev factory that requires perfect upfront specification and cannot incorporate mid-loop feedback is not matching the user's actual development workflow. The #210 incident (wasted loop on misunderstood intent) and this structural limitation (no way to correct it mid-loop) together suggest looper's waterfall model is a poor fit for the user's agile, chat-driven style.

## Pattern — spec PR pollution (looper never closes spec PRs)
- **Pattern:** looper creates spec PRs as planning artifacts (planner writes spec, pushes as PR with `looper:spec-reviewing` → `looper:spec-ready`). These PRs are NEVER closed by looper — not when the worker implements the fix, not when the source issue is closed, not when the worker PR is merged. Result: stale spec PRs accumulate and pollute the GitHub PR list. At peak, 8 of 10 open PRs in m3llm were stale spec PRs from completed issues.
- **Root cause (code):** `ClosePullRequest` gateway method (`internal/infra/github/gateway.go:1670`) is dead code — zero non-test callers. The worker `create-pr` branch (`internal/worker/runner.go:2218`) overwrites `loop.PRNumber` with the new implementation PR number, losing the spec PR reference. No cleanup mechanism exists.
- **Workaround (automated, added 2026-07-26):** `scripts/looper-health-check.sh` section 7 runs every 5 min via cron. For each open spec PR (with `looper:spec-ready` or `looper:spec-reviewing`), it extracts the source issue from the PR title, checks if the issue is closed, and if so auto-closes the spec PR with a comment and deletes the branch. Verified 2026-07-26: 6 stale spec PRs closed (#187, #189, #193, #197, #208, #182).
- **Code-level fix (upstream, ~1h, low risk):** In `internal/worker/runner.go` `create-pr` branch (~line 2197), before `persistPullRequestReference` overwrites `loop.PRNumber`, capture the spec PR number; after creating the implementation PR, call `r.github.ClosePullRequest(ctx, ClosePullRequestInput{Repo, PRNumber: specPRNumber, CWD})`. ~8 lines, reuses existing idempotent gateway method. Guard: only close when `specPRNumber != created.Number` and spec PR has `looper:spec-ready` label.

## Pattern — worktree pollution (orphaned worktrees never cleaned)
- **Pattern:** looper creates git worktrees under `~/.looper/worktrees/repo-<hash>/m3llm/looper-<issue>-<title>-<hash>`. The `worktreeCleanup` daemon lane is enabled but `includeOrphans=false` — so detached-HEAD worktrees (`looper-fix-m3llm-pr-*-detached`) and orphaned planner worktrees are never cleaned. With 7-day retention, worktrees accumulated to 29 at peak (including 6 detached-HEAD orphans), consuming disk and cluttering `git worktree list`.
- **Root cause (code):** `IncludeOrphans: false` default (`internal/config/defaults.go:148`), gated at `internal/worktreecleanup/service.go:202-208` — orphans (zero references in loops/runs/queue) are skipped permanently. Cleanup runs on a 24h ticker only (`internal/runtime/worktree_cleanup.go:89-99`); no trigger on loop completion (`OnRunCompleted` at `internal/runtime/scheduler.go:3482` only sends a notification).
- **Workaround (applied 2026-07-26):** Config changed: `includeOrphans=true`, `retentionDays=2`, `interval=6h`, `maxPerTick=20`. Manually pruned 25 stale worktrees (29 → 4: 2 for active loop #210 + main + 3 user worktrees).
- **Code-level fix (upstream):**
  - **Patch A (5 min, low risk):** Flip `IncludeOrphans` default to `true` at `defaults.go:148`. Orphans are exactly the worktrees that *should* be cleaned. Safety floor already covered by `worktreesafety.Validate` and dirty-check.
  - **Patch B (~3h, upstream with design review):** Add `TriggerWorktreeCleanup()` non-blocking channel to `Runtime` (`internal/runtime/runtime.go:~180`), wire into cleanup goroutine select loop (`worktree_cleanup.go:91-100`), call from `OnRunCompleted` (`scheduler.go:3482`) when `input.Status == "success"`. Avoids blocking scheduler tick on `git worktree remove`.

## Pattern — opencode session pollution (headless sessions bury manual sessions)
- **Pattern:** looper runs opencode headless (`opencode run` / `opencode serve`) for each agent loop. These sessions are stored in `~/.local/share/opencode/opencode.db` (6.4GB) alongside the user's manual sessions. The user's manual opencode sessions in `~/Projects/ankaboot-source/m3llm` are buried under 41+ looper headless sessions with cwd `~/.looper/worktrees/.../m3llm/...`. This makes manual use of opencode in the m3llm folder painful — slow session loading, cluttered session list.
- **Root cause (code):** `XDG_DATA_HOME` is in the inherited env whitelist (`internal/agent/executor.go:76`), so looper's headless opencode subprocess inherits the user's `XDG_DATA_HOME` → writes to the same `opencode.db`. Not overridden for the opencode vendor in `buildCommandEnv` (`executor.go:2127`).
- **Workaround:** Not implemented (user chose to document and pursue code-level fix). Options: (A) config-only — set `XDG_DATA_HOME` in `[agent.env]` to isolate (2 min, zero risk, but also affects codex/claude vendors — though neither uses `XDG_DATA_HOME` for sessions); (B) periodic cleanup script deleting sessions with cwd matching `~/.looper/worktrees/*`.
- **Code-level fix (upstream, ~4h, low risk):** In `buildCommandEnv` (`executor.go:2127`), when vendor is opencode and `XDG_DATA_HOME` not explicitly set in `agent.env`, override it to `filepath.Join(looperHomeDir, "agent-data", "opencode")`. Requires: signature change to `buildCommandEnv` (add `vendor` param), update 3 call sites (`executor.go:502, 562, 1101`), create dir at startup. What breaks: nothing — `XDG_CONFIG_HOME` (providers/MCP config) still inherited; native resume works (session ID stored in looper's `agent_executions` table); only risk is an MCP server storing data in `XDG_DATA_HOME` (rare, would re-initialize).

## 2026-07-26T15:25:00Z — daemon not running
- **Symptom:** pgrep looperd empty
- **Quick-win:** restarted daemon
- **Root cause:** unknown (no systemd supervision)

## 2026-07-26T15:25:00Z — reviewer loop #81 stuck (bug #599)
- **Symptom:** loop status backing_off/paused, but 1 review(s) posted by ankaboot-bot on ankaboot-source/m3llm#203
- **Quick-win:** cancel stuck queue items, mark loop completed
- **Root cause:** bug #599 — agent posts marker without :headSHA suffix, daemon expects it
- **Intermittent:** yes — agent sometimes includes :headSHA, sometimes drops it

## 2026-07-26T21:50:00Z — spec PR #173 auto-closed (source issue #170 closed)
- **Symptom:** spec PR #173 still open but source issue #170 is closed
- **Quick-win:** auto-close spec PR with comment + delete branch
- **Root cause:** looper never closes spec PRs after issue completion — no cleanup mechanism

## 2026-07-26T21:55:00Z — spec PR #211 auto-closed (source issue #210 closed)
- **Symptom:** spec PR #211 still open but source issue #210 is closed
- **Quick-win:** auto-close spec PR with comment + delete branch
- **Root cause:** looper never closes spec PRs after issue completion — no cleanup mechanism

## 2026-07-26T22:20:00Z — worker PR ankaboot-source/m3llm#217 needs manual review (issue #598)
- **Symptom:** worker completed PR ankaboot-source/m3llm#217 but no reviewer loop auto-triggered
- **Quick-win:** manual `looper review ankaboot-source/m3llm#217`
- **Root cause:** issue #598 — coordinator disabled (422 on self-review-request), worker doesn't label PRs

