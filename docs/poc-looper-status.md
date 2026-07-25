# POC: looper status

> Living document. Updated after every POC run. Captures config state, runs, bugs, and findings.

## 1. Environment

| Component | Value |
|-----------|-------|
| looper version | 0.0.0-dev (built from source @ `/tmp/looper-dev/looper`) |
| looperd binary | `~/.looper/bin/looperd` (dev build; backup at `~/.looper/bin/looperd.v0.11.0.bak`) |
| looper source | `/tmp/looper-src/` (cloned from nexu-io/looper @ HEAD) |
| opencode | 1.17.20 |
| gh | authed as baderdean (scopes: gist, read:org, repo, workflow) |
| OS | Linux x86_64 |
| Daemon mode | detached (no systemd supervision) |

## 2. Config state

File: `~/.looper/config.toml`

### Key settings

```toml
[agent]
vendor = 'opencode'

[agent.env]
OPENCODE_PERMISSION = '{"bash":"allow","edit":"allow","write":"allow","read":"allow","glob":"allow","grep":"allow","list":"allow","external_directory":"allow","task":"allow","skill":"allow","todowrite":"allow","question":"allow","webfetch":"allow","websearch":"allow"}'
GH_TOKEN = "<ankaboot-bot PAT, classic, full scopes>"

[tools]
looperPath = '/tmp/looper-dev/looper'

[roles.coordinator]
enabled = false          # disabled — 422 cascade blocks scheduler in single-user mode

[roles.reviewer.discovery.specReview]
includeReviewingLabel = true
reviewingLabel = 'looper:spec-reviewing'

[roles.reviewer.discovery.triggers]
enableSelfReview = true
labels = ['looper:manual-review-only']   # non-existent label = vacuous match fix
requireReviewRequest = false

[hitl]
enabled = true
answerTransport = 'github'
```

### Projects registered

| Project | Repo | Base branch | Notes |
|---------|------|-------------|-------|
| leadminer | ankaboot-source/leadminer | main | 4 PRs/8 worktrees discovered |
| m3llm | ankaboot-source/m3llm | main | 7 PRs/2 worktrees |
| wikiadviser | ankaboot-source/wikiadviser | main | 14 PRs/1 worktree |
| ~~ansible-supabase~~ | ankaboot-source/ansible-supabase | main | 29 issues — coordinator timeouts, loops paused |

### Labels created (on each repo)

| Label | Color | Purpose |
|-------|-------|---------|
| `looper:plan` | fb8c00 | Planner picks up issue |
| `looper:spec-reviewing` | f9d0c4 | Reviewer picks up spec PR |
| `looper:spec-ready` | e4fc66 | Spec approved, worker picks up |
| `looper:worker-ready` | 2da44e | Worker picks up issue |

## 3. Bot account

| Field | Value |
|-------|-------|
| Login | ankaboot-bot |
| ID | 309060619 |
| Org membership | ankaboot-source (member, active) |
| Repo access | write on leadminer, m3llm, wikiadviser |
| PAT | classic, full scopes (repo, admin:org, workflow, …) |
| PAT storage | `~/.looper/config.toml` `[agent.env] GH_TOKEN` |

**Identity separation**: agent children (planner/worker/reviewer/fixer) use the bot PAT → open PRs and post reviews as `ankaboot-bot`. The daemon/coordinator uses baderdean's `gh auth` → requests review from baderdean. Since bot ≠ baderdean, GitHub allows the review request (no 422).

**⚠️ Security**: the PAT was printed in plaintext in the POC session. It should be rotated if the session log is shared.

## 4. POC runs

### Run 1 — m3llm#146 (engineer tool ezdxf)

**Issue**: #146 — engineer tool ezdxf
**Goal**: full loop issue → spec PR → review → worker → PR → review → fix → merge

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Issue labeled `looper:plan` | — | ✅ | Manual |
| Planner → spec PR #167 | #2 | ✅ | Auto-discovered by label. Spec PR opened on `looper/planner/146-...` |
| **User merged spec PR #167 manually** | — | ⚠️ | **Mistake** — should have let reviewer promote. GitHub auto-closed #146. |
| Issue #146 reopened, label swapped to `looper:worker-ready` | — | ✅ | Manual recovery |
| Worker → implementation PR #172 | #3 | ✅ | +1204/-2, MERGEABLE/CLEAN, worktree-isolated |
| Reviewer → review on PR #172 | #20 | ✅ (after 2 attempts) | See "Reviewer run" below |
| Fixer → fix review comments | #33 | ✅ | Fixed all 3 comments, ran 29 tests (pass), commit `1ba18cd` |
| Reviewer → re-review fixed PR #172 | #34 | ✅ | Confirmed fixes |
| Merge | — | ✅ | **PR #180 merged** (squash, by baderdean, 2026-07-25T15:43:34Z). Issue #146 auto-closed via `Closes #146`. **First complete issue→merge loop.** |

**Reviewer run (loop #20) — 2 attempts:**

- **Attempt 1** (PID 3514873, ~16m): did thorough analysis — ran 26 unit tests (pass), found `browse_cpc` XML parsing bug (text is sibling not child of classification-symbol), verified EPO CPC schema via librarian, checked `_get_token` return-type inconsistency. Ran out of turns before calling `looper review submit`. Status: `review_marker_missing`.
- **Attempt 2** (PID 3540055, ~7m): **succeeded**. Found a more critical blocking bug: Mermaid sequence diagram title syntax invalid (`title: X` before `sequenceDiagram` fails `mmdc`). Verified by rendering both outputs through Mermaid CLI v11.12.0. Also found Mermaid field interpolation not escaped (injection risk), two unused URL constants. Posted 1 review (COMMENTED) + 3 inline comments on engineer.py. Loop status: `completed · success`.

**Findings:**
- Reviewer does genuine deep work: runs tests, renders Mermaid, verifies external API schemas via librarian, finds real bugs with evidence.
- Reviewer needs 2 attempts on complex PRs (turn limit on attempt 1). Daemon auto-retries.
- The dev build (EBADF fix) is required — release binary fails on `looper review submit`.

### Run 2 — m3llm#170 (magic-link passwordless)

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Issue labeled `looper:plan` | — | ✅ | Manual |
| Planner → spec PR #173 | #4 | ✅ | Spec PR opened, +385/-0, MERGEABLE/CLEAN, label `looper:spec-reviewing` |
| Reviewer → review spec PR #173 | #5 | ⏳ | Was paused during DB cleanup, retried — queued |

**Findings:**
- Planner works for spec-only PRs (no implementation).
- Spec PR reviewer auto-discovery by `looper:spec-reviewing` label works.

### Run 3 — ansible-supabase (paused)

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Issues #82, #87, #89 labeled `looper:plan` | — | ✅ | Auto-discovered (ansible-supabase was registered) |
| Planner → spec PRs | #30, #31, #32 | ❌ | Loop #30 backing off: "outbound content safety gate rejected pull request body: contains a high-entropy credential-shaped token" |
| Coordinator | — | ❌ | Discovery times out (15-23s per tick), blocks scheduler (`availableSlots:0`) |

**Findings:**
- ansible-supabase issues contain credential-shaped tokens (Supabase config) that trigger looper's content safety gate.
- Coordinator is too slow with 4 projects — deep triage on every issue every 30s.
- **Decision**: pause ansible-supabase loops, keep the 3 original projects.

### Run 4 — leadminer#2852 (stuck fixer loop cleanup)

**Issue**: PR #2852 (`feat/unified-senders` → `main`) — a stale, conflicting PR that looper's fixer auto-discovered and parked.

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Fixer auto-discovers PR #2852 | loop_828cb1c74fbf00608948a987eaa367d5 | paused | 5 failed runs, all at `prepare-worktree` |
| Fixer classifies conflict as risky | — | ⏸ | "Skipped … because risky conflict fixes require manual intervention". `resumePolicy: manual_intervention`, `retryable: false` |
| Manual cleanup | — | ✅ | Closed PR (superseded — feature already on main), deleted branch, SQLite cleanup |

**What happened:**
- PR #2852 was 5 ahead / 38 behind `main`, `mergeStateStatus: DIRTY`, failing DeepSource checks.
- The feature (SMTP senders) was **already on main** with 2 follow-up migrations — the PR was fully superseded.
- Looper's fixer auto-discovered it (hasConflicts + failing checks), classified the 38-commit-behind conflict as too risky to auto-resolve, and parked the loop with `manual_intervention` resumePolicy. **No agent ever ran** — no commit, comment, or review. Just 5 silent skipped log entries.
- Closing the PR does **not** auto-clear the looper DB row. Manual SQLite cleanup required (see §5.5).

**Findings:**
- Looper has no CLI command to delete a stuck `manual_intervention` loop (see §5.5).
- The fixer's "risky conflict" classifier is conservative — correct here (the PR was superseded), but it means any PR that falls >N commits behind will silently park with no notification.
- No mechanism to detect "superseded PR" — the feature was already merged via a different PR.

### Run 5 — m3llm#179 (engineer tool search_patents 404)

**Issue**: #179 — `search_patents` returns HTTP 404 from EPO OPS (bug in the engineer tool shipped in #174).

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Issue #179 created with `bug` + `looper:plan` | — | ✅ | Manual |
| Assigned to baderdean only | — | ⚠ | Planner did NOT discover (see §5.6) |
| Added ankaboot-bot as assignee | — | ✅ | Planner discovered within 1 tick |
| Planner → spec PR | loop_41ceef090e23c571d75d07a676a3c825 | running | Auto-discovered after bot assignee added |

**Findings:**
- `requireAssigneeCurrentUser = true` in planner config means the issue must be assigned to the **bot account** (ankaboot-bot, the PAT identity), not just baderdean. See §5.6.
- The engineer tool (`plugins/tools/engineer/`) shipped in #174 has a live bug: `search_patents` hits a 404 from EPO OPS. Likely wrong endpoint URL or missing auth header. The full looper pipeline (planner → spec → worker) is now handling the fix.

### Run 6 — m3llm#192 (magic-link 405 + button overflow)

**Issue**: #192 — magic-link 405 Method Not Allowed on POST `/functions/v1/auth-magic-link` + "Recevoir mon lien" button text overflow
**Goal**: top-priority bug fix, full loop to merge

| Step | Loop | Status | Notes |
|------|------|--------|-------|
| Issue #192 created with `bug` + `looper:plan` | — | ✅ | Manual, assigned to ankaboot-bot |
| Planner → spec PR #193 | #63 | ✅ | Auto-discovered within 30s |
| Reviewer → review spec PR #193 | — | ✅ | Manually triggered (specReview didn't fire) |
| Fixer → fix spec | #66 | ✅ | Auto-triggered by review comments |
| Reviewer → re-review, promote to `looper:spec-ready` | — | ✅ | 3 reviews total |
| Worker → implementation PR #195 | #67 | ✅ | 6m, +63/-22, MERGEABLE, bot-authored |
| Reviewer → review PR #195 | #68 | ✅ (after marker bug #599 retries) | non-blocking (`outcome=non_blocking`): PASS on button fix, UNVERIFIABLE on 405 (deployment issue) |
| Merge | — | ✅ | **PR #195 merged manually by baderdean.** Issue #192 auto-closed. |
| Post-deploy E2E | — | ⏳ | 405 is verifiable post-deploy on m3llm.cafe — **E2E browser test gap** (see §5.11, #604). User verified manually. |

**Findings:**
- Reviewer correctly marks deployment-dependent fixes as UNVERIFIABLE — the 405 can't be verified from the diff, only post-deploy.
- The loop ends at merge, but real projects need verified-in-production. This is the E2E browser test gap (bug #604).
- Migration failure root cause: `cron.unschedule('cleanup-pending-signups')` throws XX000 when job never scheduled. Added as comment on issue #192.

## 5. Bugs

### 5.1 EBADF on `looper review submit` (issue #595)

- **Severity**: Blocking
- **Status**: OPEN, no fix PR, no comments (filed by @PerishCode)
- **Symptom**: `read trusted review config snapshot: read trusted-review-config: bad file descriptor`
- **Root cause**: `PersistentPreRunE` auto-upgrade hook calls `loadConfig()` which reads FD 3 (trusted review config pipe) and closes it via `defer file.Close()`. Then `review submit` calls `loadConfig()` again → `os.NewFile(3)` on closed descriptor → EBADF.
- **Deterministic on**: release binaries (classified as `cliInstallSourceRelease`)
- **Workaround**: build from source. Dev build (`cliInstallSourceDev`) short-circuits the auto-upgrade hook at `upgrade.go:162` before `loadConfig()`.
- **Fix suggestion**: memoize `LoadTrustedReviewConfigSnapshot` with `sync.Once`. Complementary guard: skip auto-upgrade when `LOOPER_TRUSTED_REVIEW_PROXY_CHILD` is set.

### 5.2 Worker PR → Reviewer in single-user mode (issue #598)

- **Severity**: Blocking (full autonomy)
- **Status**: Feature request filed — https://github.com/nexu-io/looper/issues/598
- **Symptom**: Worker PR has no label and no review request → reviewer can't auto-discover it.
- **Root cause**: Coordinator's `applyLocalReviewAssignment` (coordinator/runner.go:1205-1228) calls `AddPullRequestReviewers(baderdean)` on a PR authored by baderdean → GitHub 422 "Review cannot be requested from pull request author".
- **Config `enableSelfReview=true`**: only relaxes the reviewer's discovery filter (skips author-equality check at reviewerWorkPending runner.go:1044-1051). Does NOT affect the `AddPullRequestReviewers` API call.
- **Workarounds**:
  1. Bot account (different GitHub identity) — **in progress**
  2. Manual `looper review <repo>#<pr>` — works, not autonomous
  3. Patch worker to label PRs `looper:needs-review` (~5 lines in worker/runner.go) — not yet implemented
  4. `looper takeover <repo>#<pr>` — single-PR lifecycle, not automatic

### 5.3 Reviewer auto-discovery runaway

- **Severity**: High
- **Status**: Config footgun (fixed)
- **Symptom**: Reviewer queued 23 loops across all repos (including dependabot PRs) after setting `requireReviewRequest=false`.
- **Root cause**: `roles.reviewer.discovery.triggers.labels = []` + `labelMode = 'all'` = vacuous match (every PR satisfies "has all zero required labels").
- **Fix**: set `labels = ['looper:manual-review-only']` (non-existent label) so `triggers` never matches. `specReview` remains the only auto-discovery path (handles spec PRs via `looper:spec-reviewing` label).

### 5.4 Coordinator 422 cascade

- **Severity**: High
- **Status**: Design issue
- **Symptom**: Coordinator hits 422 on a self-authored PR → fails the entire scheduler tick → "context canceled" cascades to other in-flight discoveries → `availableSlots:0`.
- **Root cause**: one 422 fails the whole tick (no per-PR error isolation).
- **Workaround**: disable coordinator (current state). Bot account should fix the 422 source.

### 5.5 No CLI to delete stuck loops

- **Severity**: Medium (usability)
- **Status**: Gap — no upstream issue filed yet
- **Symptom**: A loop parked in `manual_intervention` (or otherwise stuck) cannot be deleted via `looper loop`. Closing the target PR does not auto-clear the DB row.
- **CLI surface**: `looper loop list|inspect|start|pause|retry` — **no `delete`**.
- **Workaround**: direct SQLite cleanup on `~/.looper/looper.sqlite`:
  ```sql
  DELETE FROM runs       WHERE loop_id = '<loop_id>';
  DELETE FROM queue_items WHERE loop_id = '<loop_id>';
  DELETE FROM loops      WHERE id      = '<loop_id>';
  ```
  Note: FK cascade from `loops` to `runs` did **not** fire in practice — delete `runs` and `queue_items` explicitly first.
- **Impact on dev-factory-A→Z**: a stuck loop clutters `looper loop list` and, if `retryable`, can resume and burn tokens. An operator needs a clean way to retire a loop without reaching into the DB.
- **Reproduced**: leadminer #2852 (Run 4) and m3llm #173/#174 reviewer/fixer loops (Run 5).

### 5.6 Planner requires assignee = bot account, not just label

- **Severity**: Medium (operability footgun)
- **Status**: Config behavior — documented here
- **Symptom**: An issue labeled `looper:plan` is **not** discovered by the planner if only assigned to baderdean. The scheduler ticks show `availableSlots:2, claimedCount:0` indefinitely.
- **Root cause**: `[roles.planner.triggers] requireAssigneeCurrentUser = true` checks against the **PAT identity** (ankaboot-bot), not the daemon operator (baderdean). The planner discovery runs as the bot.
- **Fix**: assign the issue to `ankaboot-bot` (in addition to or instead of baderdean). Discovery happens within 1 scheduler tick.
- **Impact**: any issue created by a human with `looper:plan` must also be assigned to the bot or the planner will never pick it up. This is undocumented in looper and easy to miss.
- **Reproduced**: m3llm #179 (Run 5) — labeled `looper:plan` + assigned to baderdean → no pickup for 10+ minutes; added ankaboot-bot → picked up in 1 tick.

### 5.7 Reviewer marker idempotencyKey mismatch (issue #599)

- **Severity**: Medium (loop status stuck, but review IS posted)
- **Status**: Bug filed — https://github.com/nexu-io/looper/issues/599
- **Symptom**: Reviewer posts a review successfully but the loop never reaches `completed` — stays `backing_off` with "no matching GitHub review marker was found".
- **Root cause**: `agentNativeReviewID` (reviewer/runner.go:6731) constructs expected marker id as `reviewer:loopID:headSHA`, but the agent (opencode) sometimes posts `id=reviewer:loopID` (dropping the `:headSHA` suffix). The `matches` function (gateway.go:2514-2528) compares expected vs actual → no match. The fallback `agentNativeLoopReviewMarker` uses `id_prefix=reviewer:loopID:` but `strings.HasPrefix("reviewer:loopID", "reviewer:loopID:")` → false (actual ID lacks trailing `:`).
- **Intermittent**: the agent sometimes includes `:headSHA` (loop completes), sometimes drops it (loop stuck). Not deterministic.
- **Impact**: Review IS posted with real findings, fixer IS auto-triggered by review comments, but reviewer loop never reaches `completed` — requires manual cleanup (stop loop, cancel queue items).
- **Reproduced**: m3llm PR #180 (reviewer loop #49, attempt 1 failed, attempt 2 succeeded with `:headSHA`), PR #182 (reviewer loop #48, 7 attempts, all failed), PR #187 (reviewer loop #53, succeeded).

### 5.8 Outbound content safety gate false positive on GitHub asset URLs (issue #600)

- **Severity**: Medium (planner blocked on issues with screenshots)
- **Status**: Bug filed — https://github.com/nexu-io/looper/issues/600
- **Symptom**: Planner backs off with "outbound content safety gate rejected pull request body: contains a high-entropy credential-shaped token" when the issue body contains a GitHub screenshot URL.
- **Root cause**: `internal/outboundguard/guard.go` line 35: `highEntropyCandidateRE = regexp.MustCompile(`[A-Za-z0-9_+/=-]{24,}`)`. The character class includes `/`, so GitHub asset URLs like `https://user-images.githubusercontent.com/.../abcdef123456.png` match as a single 60+ char "high-entropy token". The `gitObjectIDRE`/`uuidRE` exemptions don't cover GitHub asset URLs.
- **Workaround**: none (no config to disable the guard). Planner may succeed on retry (intermittent).
- **Reproduced**: m3llm #188 (planner loop #54, backed off, then succeeded on retry).

### 5.9 Auto-merge blocked for bot-authored PRs (issue #602)

- **Severity**: Blocking (full autonomy — last hop)
- **Status**: Bug filed — https://github.com/nexu-io/looper/issues/602
- **Symptom**: `roles.reviewer.autoMerge.enabled = true` but auto-merge never triggers for bot-authored PRs. GitHub `autoMergeRequest: null`.
- **Root cause**: `submitOrReuseReview` (runner.go:3791) downgrades `APPROVE` → `COMMENT` via `selfApprovalFallback` when PR author == current user (bot). `publishCriteriaApprovedReview` (runner.go:3672) requires `marker.Event == ReviewEventApprove` → returns early on `COMMENT` → `EnableAutoMerge` never called.
- **Same root cause as #598**: single-identity mode — bot can review (COMMENT) but can't approve or auto-merge its own PRs.
- **Workaround**: manual merge (PR #180 merged by baderdean). Or second GitHub account for reviewer.
- **Reproduced**: m3llm PR #180 (reviewer loop #61, auto-merge never triggered).

### 5.10 Fixer self-comment filter in single-identity mode (issue #603)

- **Severity**: Blocking (fixer→reviewer cycle broken)
- **Status**: Bug filed — https://github.com/nexu-io/looper/issues/603
- **Symptom**: Fixer auto-discovery skips all review comments on bot-authored PRs because the review comments are authored by the same bot identity. `claimedCount:0` every tick.
- **Root cause**: `actionableNativeReviewComments` (runner.go:6279-6288): `if comment.IsResolved || sameGitHubLogin(comment.Author, currentUser) { continue }` — skips comments where author == current user. In single-identity mode, reviewer and fixer share the same GitHub identity → all review comments filtered out → 0 fix items → PR skipped.
- **Same root cause as #598 and #602**: single-identity mode.
- **Workaround**: manual `looper fix <repo>#<pr>` (bypasses self-comment filter). Health-check cron automates this.
- **Reproduced**: m3llm PR #189 (fixer never auto-discovered, manual trigger worked).

### 5.11 Post-deploy E2E browser verification gap (issue #604)

- **Severity**: Blocking (verified-in-production)
- **Status**: Feature request filed — https://github.com/nexu-io/looper/issues/604
- **Symptom**: Looper's loop ends at merge. Deployment-dependent fixes (e.g. 405 from undeployed Edge Function) are correctly marked UNVERIFIABLE by the reviewer, but ARE verifiable post-deploy by hitting the live endpoint. Looper has no step for this.
- **Root cause**: the loop is `issue → planner → spec PR → review → worker → impl PR → review → merge`. There is no `→ deploy → E2E verify` step. AGENTS.md mandates browser E2E on m3llm.cafe after deploy (3-30min), but looper can't run browser automation or wait for deploy.
- **Proposed design**: optional post-deploy E2E step — wait for deploy (GitHub Actions/CF Pages/webhook/delay), run browser automation (Playwright/CF Browser Rendering/agent-browser), verify acceptance criteria from issue, post results as comment, reopen issue or open bug on failure.
- **References**: baton's `agent-browser` E2E (verifies before PR), Cursor Background Agents (video recording as verification), CF Browser Rendering binding (serverless browser backend).
- **Reproduced**: m3llm PR #195 (reviewer marked 405 as UNVERIFIABLE, user verified post-deploy manually).

#### 5.11.1 Ecosystem research — post-deploy verification tools (2026-07-25)

A deeper GitHub/web search (beyond the original 22-tool analysis) found that **post-deploy verification is not a missing tool — it is a missing integration layer**. No single off-the-shelf product implements the full `issue → dev → merge → deploy → verify → reopen` loop, but 5 projects ship post-deploy verification as part of a loop, and a stack of building blocks exist.

**Tier 1 — full dev loops that include post-deploy verification:**

| Project | Post-deploy step | Feedback to issue/PR | Closeness |
|---------|------------------|----------------------|-----------|
| [AntaresYuan/claude-devloop](https://github.com/AntaresYuan/claude-devloop) | `curl` live URL + grep for shipped feature | Comments/closes issue, logs to `LOOP-LOG.md`, `ScheduleWakeup` pacing | **85%** — only tool bundling triage→dev→test→review→merge→verify-deploy→update-issue in one skill. Claude-only, no browser E2E, no auto-reopen. |
| [rkaliupin/DAGent](https://github.com/rkaliupin/DAGent) | **Playwright E2E on live deployed app** + integration tests | `TriageDiagnostic` with fault-domain routing, circuit breakers, loops back to agents | **80%** — 12-agent DAG, real browser E2E post-deploy. Azure-bound (Functions/SWA). |
| [Vanja Petreski "Proof of Loop"](https://vanja.io/proof-of-loop/) | Verifies running revision matches pushed image, polls external truth | Done-oracle gates exit; auto-files tickets on drift; self-heal pass rewrites harness | **100% in shape, 70% in tooling** — the design document to reference. 9/11 tickets shipped + verified on dev & prod, 0 prod incidents. |

**Tier 2 — deploy→verify→fix bridge (progressive delivery + AI):**

| Project | What it does |
|---------|--------------|
| [argoproj-labs/rollouts-plugin-metric-ai](https://github.com/argoproj-labs/rollouts-plugin-metric-ai) (Apache-2.0, 13⭐) | Argo Rollouts canary analysis → AI agent (A2A) → promote/rollback → **auto-opens fix PR on GitHub** via `create_github_pr`. K8s-only. |
| AgentPatterns "Self-Healing Production Agent" ([pattern](https://agentpatterns.ai/agent-design/self-healing-production-agent/)) | After deploy, run eval suite, compare to baseline, triage causality, dispatch fix agent → PR. **LangChain GTM Agent** is the cited production case. Circuit breaker on `(repo, failing_test)` after N attempts. |

**Tier 3 — production-grade verify engines (plug-in, not full loops):**

| Project | What it does |
|---------|--------------|
| [team-poem/cairn](https://github.com/team-poem/cairn) | AI discovers a browser flow once, freezes as JSON, replays **deterministically with zero LLM calls** (~$0.50 discovery, $0/replay). Self-heals on UI drift. The cheap-continuous-verify engine. |
| [kensaurus/mushi-mushi](https://github.com/kensaurus/mushi-mushi) (open-core: SDK MIT, server AGPLv3) | Sentry detection → 2-stage LLM classify → sandbox fix → **Playwright verify** (`@mushi-mushi/verify`: screenshot diff + step interpreter) → draft PR. |
| [heymegbyte/claude-skills/agents/deploy-verifier.md](https://github.com/heymegbyte/claude-skills/blob/master/agents/deploy-verifier.md) | Sub-agent spec: `curl + 200 check + console errors + 6-breakpoint screenshots + axe-core audit + SEO + perf`. The minimum-viable verifier shape. |
| [nahuelsoria/prod-playwright-audit](https://github.com/nahuelsoria/prod-playwright-audit) | Cross-agent (Claude/Codex/Cursor/opencode), read-only audit, waits for deploy propagation, network safety belt aborts mutations. |

**Tier 4 — self-healing CI agents (pre-merge, not post-deploy, but reusable auto-fix-PR pattern):**

`ronitanilkumar/Veylor`, `Canepro/pipelinehealer`, `timix648/TALOS`, `AbdulmoizTalpur/self-healing-devops-agent`, Semaphore self-healing CI. All detect CI failures → AI fix → PR, but stop at "fix the failing test", not "verify the deployed app". The auto-fix-PR pattern is identical to what boucle would need on the post-deploy branch.

**Reference design pattern** — [youngju.dev 7-stage loop](https://www.youngju.dev/blog/culture/2026-05-14-issue-to-deploy-autonomous-pipeline-ai-code-review-ci-cd-auto-verify-rollback-deep-dive-guide-2025.en):
`S1 Issue→PR (AI) → S2 AI review → S3 CI gate → S4 human merge → S5 CD (preview→canary→prod) → S6 auto-verify (smoke+E2E+SLO) → S7 monitoring → on S6 failure, S7 creates Issue labeled `ai-ready` → re-enters at S1`. **S6 is exactly looper's gap (#604).**

**Recommended path for boucle:**
1. **Short term (1-2 day POC)** — adopt `heymegbyte/deploy-verifier` shape (curl + axe + screenshot) as a `verifier` sub-agent in opencode/Claude Code.
2. **Mid term** — adopt `cairn`'s discover→freeze→replay for LLM-free continuous browser verification (~$0/replay).
3. **Long term** — add a `verifier` role to looper (or boucle-core) that, on failure, **reopens the issue with evidence** — same shape as `argoproj-labs/rollouts-plugin-metric-ai`'s async remediation agent. File an enriched follow-up on looper#604 referencing the near-misses above.

## 6. What works (confirmed in production)

1. **Issue → Planner → spec PR** — auto-discover by `looper:plan` label ✅
2. **Spec PR → Reviewer → review** — auto-discover by `looper:spec-reviewing` label ✅
3. **Reviewer approves → Worker** — auto-discover by `looper:worker-ready` label ✅
4. **Worker → implementation PR** — worktree-isolated, opencode ✅
5. **Review comments → Fixer → fixes** — auto-discover by review comments ✅
6. **Fixer → tests → push** — ran 29 tests, all pass ✅
7. **Reviewer → deep review with evidence** — runs tests, renders Mermaid, verifies external API schemas via librarian, finds real bugs ✅
8. **HITL via GitHub PR comment** — agent pauses, posts question as comment with marker, human replies, loop resumes ✅
9. **opencode permission propagation** — `OPENCODE_PERMISSION` env var in `[agent.env]` propagates to opencode child ✅
10. **Trusted review proxy** — `LOOPER_TRUSTED_REVIEW_SOCK` set, socket file exists, `looper review submit` succeeds (dev build) ✅
11. **Bot account identity separation** — agent children run as `ankaboot-bot` (via `GH_TOKEN` in `[agent.env]`), daemon runs as bot via launcher script ✅
12. **Full issue→merge loop** — m3llm#146: issue → planner → spec PR → review → worker → PR → fixer → re-review → **merge** ✅ (PR #180 merged 2026-07-25T15:43:34Z)

## 7. What doesn't work

1. **Worker PR → Reviewer (auto)** — needs bot account or patch (#598) ❌
2. **E2E browser test** — not native to looper ❌
3. **GitLab support** — GitHub + Forgejo only ❌
4. **Budget control** — no cap or visibility on coding-model token spend (Ollama Cloud, opencode); only a global 3-concurrent-loops limit ❌
5. **Sub-issue deduction** — planner writes spec, doesn't decompose ❌
6. **Self-hostable serverless** — local daemon only ❌
7. **Coordinator in single-user mode** — 422 cascade blocks scheduler ❌
8. **Loop deletion** — no CLI command; stuck loops require direct SQLite access (§5.5) ❌
9. **Reviewer self-termination** — successful reviews can enter an unbounded marker-verification retry loop (§5.7) ❌
10. **Superseded-PR detection** — fixer parks conflicting PRs but doesn't detect when the feature is already on main (§Run 4) ❌
11. **Auto-merge for bot-authored PRs** — `selfApprovalFallback` downgrades APPROVE→COMMENT, auto-merge path requires APPROVE (§5.9, #602) ❌
12. **Fixer auto-discovery in single-identity mode** — self-comment filter excludes bot-authored reviews (§5.10, #603) ❌
13. **Post-deploy E2E browser verification** — loop ends at merge, no verify-in-production step (§5.11, #604) ❌

## 8. Decision — POC closed (2026-07-25)

**Verdict: Option B — Move to a more reliable solution. looper does not meet the dev-factory-A→Z bar.**

### 8.1 Evaluation against the Option A criteria

AGENTS.md §3 Option A requires: looper handles ≥80% of the dev-factory flow autonomously (issue → merged PR) with no more than 1 manual intervention per loop, and the gaps are patchable or non-blocking.

| Criterion | Required | Observed | Met? |
|-----------|----------|----------|------|
| Autonomous flow coverage | ≥80% | ~57% (4/7 steps fully autonomous: triage→plan→spec→worker; review/fixer need manual triggers; validate/merge is manual) | ❌ |
| Manual interventions per loop | ≤1 | 3-5 per loop (manual `looper review` for worker PRs, manual merge, SQLite cleanup for stuck loops, daemon restarts, bot-assignee workaround) | ❌ |
| GitLab gap patchable | yes or non-blocking | **Blocking** for tyre-call, structurally not patchable (GitHub+Forgejo only) | ❌ |
| E2E browser test gap patchable | yes or non-blocking | Sidecar/Action possible but not native; post-deploy verify is a missing integration layer (#604) | ⚠️ partial |
| Budget control patchable | yes | Patchable (WIP/token log/$ budget) but not shipped | ⚠️ partial |

**Result: 0/2 hard criteria met. Option A rejected.**

### 8.2 Evidence summary (6 runs, 7 bugs filed)

- **6 POC runs** completed across m3llm (4), ansible-supabase (1, paused), leadminer (1, stuck-PR cleanup).
- **2 full issue→merge loops** (m3llm#146, m3llm#192) — both required manual merge by baderdean; auto-merge is blocked for bot-authored PRs (#602).
- **7 upstream bugs filed**: #595 (EBADF), #598 (worker PR review), #599 (marker mismatch), #600 (outbound guard), #602 (auto-merge), #603 (fixer self-comment), #604 (post-deploy E2E). Three (#598, #602, #603) share a single-identity root cause.
- **Single-identity mode is the dominant failure mode**: 3 of 7 bugs stem from looper's assumption that worker, reviewer, and fixer are different GitHub identities. The bot-account workaround reduces 422s but does not fix auto-merge (#602) or fixer self-comment filtering (#603).
- **Operational overhead**: a bash health-check cron + an agent health-check cron were required to keep the daemon alive and clear stuck loops. This is the opposite of "autonomous".

### 8.3 What looper proved

- The **loop shape works**: issue → planner → spec PR → reviewer → worker → implementation PR → fixer → re-review → merge ran end-to-end on real issues with genuine deep review (tests run, Mermaid rendered, EPO schema verified, real bugs found).
- **opencode as harness** is viable: permission propagation, worktree isolation, and HITL via GitHub comments all work.
- **Label-driven state machine** is a clean, observable coordination model.

### 8.4 What looper cannot deliver (structural)

1. **GitLab support** — structurally GitHub+Forgejo only. tyre-call has no path.
2. **Auto-merge / full autonomy** — blocked by single-identity design (#598, #602, #603). A second GitHub account per role is not a scalable fix.
3. **Post-deploy E2E verification** — loop ends at merge; no verify-in-production step (#604).
4. **Budget control** — no cap or visibility on coding-model token spend.
5. **Loop operability** — no CLI to delete stuck loops (§5.5); coordinator 422 cascade (§5.4); reviewer marker retry loops (§5.7).

### 8.4.1 Review gate does not prevent shipping bugged code (critical)

**This is the most fundamental finding of the POC — more decisive than the autonomy bugs.** Even if looper were 100% autonomous (no 422s, auto-merge worked, no manual interventions), it would still ship bugged code because the review gate itself is structurally insufficient.

**Evidence — bugs shipped despite passing spec review + code review + fixer cycle:**

| Shipped PR | Review outcome | Bug shipped | How it escaped review |
|------------|----------------|-------------|----------------------|
| m3llm PR #180 (engineer tool ezdxf) | Reviewer ran 26 unit tests (pass), rendered Mermaid, verified EPO CPC schema, found 3 real bugs → fixer fixed → re-review approved → **merged** | **#179**: `search_patents` returns HTTP 404 from EPO OPS (wrong endpoint URL / missing auth) — filed the same day | Reviewer reviewed the **diff** (code structure, Mermaid syntax, XML parsing) but never **called the EPO API**. Unit tests mocked the HTTP layer. The 404 only manifests on a real API call. |
| m3llm PR #195 (magic-link 405 + button overflow) | Reviewer marked 405 as `UNVERIFIABLE` (deployment-dependent), PASS on button fix → **non-blocking → merged** | **Post-deploy**: `cron.unschedule('cleanup-pending-signups')` throws XX000 when the job was never scheduled — migration crashes on fresh installs | Reviewer correctly identified it couldn't verify the 405 from the diff, but `UNVERIFIABLE` is a **non-blocking** outcome — it does not gate merge. The runtime migration error was invisible to diff review. |

**Root cause — the review model is diff-scoped, not behavior-scoped:**

1. **Static analysis + unit tests only.** The reviewer reads the diff, runs existing unit tests (which mock external dependencies), and checks code structure. It does not perform integration testing against real services (EPO API, Supabase Edge Functions, live deployments).
2. **`UNVERIFIABLE` does not block merge.** When the reviewer correctly identifies that a fix can only be verified post-deploy (e.g. a 405 from an undeployed Edge Function), it marks the outcome `non_blocking` / `UNVERIFIABLE` — and the loop proceeds to merge. The "I can't verify this" signal is recorded but **not acted on**.
3. **No E2E / browser test step.** The loop is `issue → spec → worker → review → merge`. There is no `→ deploy → verify behavior against acceptance criteria` step (#604). Deployment-dependent bugs (405, migration XX000, wrong API endpoint) are structurally invisible to the review gate.
4. **Spec review ≠ behavior contract.** The spec PR review checks the plan's coherence, not whether the acceptance criteria are testable post-implementation. A spec can pass review while defining no verifiable behavior.

**Implication for the next solution:**

The next tool must treat **verified behavior in production** as the merge gate, not **reviewed diff**. Concretely:
- Acceptance criteria in the issue/spec must be **executable** (not prose).
- The loop must include a **post-deploy verification step** that runs the acceptance criteria against the live system (browser E2E, API smoke test, migration dry-run).
- `UNVERIFIABLE` must **block merge** until either (a) the behavior is verified post-deploy, or (b) a human explicitly overrides with a recorded reason.
- The §5.11.1 research (claude-devloop, DAGent, Proof of Loop, cairn, deploy-verifier) defines the shape of this step. `team-poem/cairn` (discover→freeze→replay, $0/replay) is the most cost-effective continuous-verify engine; `rkaliupin/DAGent` (Playwright on live app) is the closest full-loop reference.

This finding alone justifies Option B regardless of the autonomy bugs: **a dev factory that ships buggé code through its own review gate is not a dev factory.**

### 8.5 Decision

**Option B — Adopt another solution.** The POC is closed. looper remains a useful reference for the loop shape (label state machine, worktree isolation, HITL via PR comments, opencode harness integration) but is not reliable enough to serve as the dev-factory orchestrator:

- It requires constant human + cron babysitting (3-5 manual interventions per loop).
- Its single-identity assumption produces a cluster of blocking bugs that a bot account only partially mitigates.
- GitLab and post-deploy E2E are structurally out of scope.

**Next: evaluate more reliable alternatives.** Candidates to re-examine (from README §2): autonomous-dev-team (best harness-agnosticism, conformance suite, GitLab pluggable), baton (agent-browser E2E, but dormant), and the original boucle hexagonal TS+Bun design (Option C) if no existing tool fills enough gaps. The post-deploy verification research in §5.11.1 (claude-devloop, DAGent, Proof of Loop, cairn) informs the E2E requirement for whatever comes next.

### 8.6 Artifacts retained

- `docs/poc-looper-status.md` — this file (full run log, bugs, findings).
- `docs/poc-looper-drawbacks.md` — health-check drawback log.
- `scripts/looper-health-check.sh` — bash cron (reference for operability gaps).
- `scripts/looper-agent-health-check.sh` — agent cron (reference for anomaly detection).
- `README.md` — 22-tool landscape comparison and functional gap matrix.
- `AGENTS.md` — POC charter and decision framework.

### 8.7 Open items closed / carried forward

- [x] E2E browser test strategy — feature request filed as [nexu-io/looper#604](https://github.com/nexu-io/looper/issues/604).
- [x] Bot account setup (`ankaboot-bot`) — verified, but does not fix #602/#603.
- [~] Contribute worker-PR-label patch to looper (#598) — **not contributed**; POC closed, patch no longer prioritized.
- [~] File upstream issues for §5.5/§5.6/§5.7 — §5.7 filed as #599; §5.5 and §5.6 documented here only.
- [→] tyre-call GitLab automation — **carried forward** to the next tool evaluation.
- [→] Budget control — **carried forward** to the next tool evaluation.
- [→] Post-deploy E2E verification — **carried forward**; §5.11.1 research applies to any tool.