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
| Merge | — | ⏳ | Pending — PR #172 has blocking review resolved, awaiting merge decision |

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

## 7. What doesn't work

1. **Worker PR → Reviewer (auto)** — needs bot account or patch (#598) ❌
2. **E2E browser test** — not native to looper ❌
3. **GitLab support** — GitHub + Forgejo only ❌
4. **Budget control** — no cap or visibility on coding-model token spend (Ollama Cloud, opencode); only a global 3-concurrent-loops limit ❌
5. **Sub-issue deduction** — planner writes spec, doesn't decompose ❌
6. **Self-hostable serverless** — local daemon only ❌
7. **Coordinator in single-user mode** — 422 cascade blocks scheduler ❌

## 8. Next steps

- [ ] Test bot account full loop: label a fresh issue `looper:plan`, let planner (bot) open spec PR, reviewer (bot) review, worker (bot) implement, coordinator (baderdean) request review from baderdean, reviewer (bot) review worker PR — verify no 422.
- [ ] Re-enable coordinator with bot account.
- [ ] Choose E2E browser test strategy (post-merge GitHub Action / CF Browser Rendering / looper fixer with browser MCP).
- [ ] Decide on tyre-call (GitLab) — no looper path; needs a different tool or a GitLab adapter.
- [ ] Contribute worker-PR-label patch to looper (#598, Option A).
- [ ] Budget control — design a mechanism to cap and surface coding-model token spend per loop/day/project (WIP limit / token log / hard $ budget — solution TBD).
- [ ] After 10 loops or 30 days, evaluate decision (Option A/B/C/D).