# boucle

Research and POC: autonomous dev loop orchestrators — can [looper](https://github.com/nexu-io/looper) serve as a **dev factory A→Z** (issue → merged PR) with human validators only at each gate?

> **Status**: POC phase — running looper in production on real repos. See [`AGENTS.md`](./AGENTS.md) for the charter and decision framework, [`docs/poc-looper-status.md`](./docs/poc-looper-status.md) for the current POC state.

## Repo structure

```
boucle/
├── AGENTS.md                      # POC charter — goal, methodology, decision framework
├── README.md                      # This file — research: tool comparison and functional gaps
└── docs/
    └── poc-looper-status.md       # Current POC state — runs, config, bugs, findings
```

## TL;DR

We analyzed 22 tools/projects (looper, loop-engineering, autonomous-dev-team, baton, oc-ralph, autocode, loom, loop-harness, LoopEngineer, LoopX, next-task, crew, OpenHands, SAM, CF Project Think, Conductor, Sweep, Aider, Cursor, Claude Code headless, 12-Factor Agents, loop-engineering-architecture). We adopted **looper** for GitHub repos (leadminer, m3llm, wikiadviser) and are running a POC to decide whether to stay with looper (with patches), adopt another tool, build from scratch, or change the approach.

**Blocking gaps**: GitLab support (tyre-call), E2E browser test (m3llm AGENTS.md), worker PR → reviewer in single-user mode (#598, workaround: bot account).

**Working**: issue → planner → spec PR → reviewer → worker → implementation PR → fixer → re-review. The full loop ran end-to-end on m3llm#146 with genuine deep review (tests run, Mermaid rendered, EPO schema verified, real bugs found).

---

## 1. Goal

A tool that, without developers, takes a GitHub/GitLab issue tagged `boucle` (configurable) from status `todo`, and:

1. **Triage** — analyze the issue *in place* (not a separate doc), deduce sub-issues if needed (enabler, rework, UX…), tag by category, evaluate complexity.
2. **Ready-to-dev** — push to a ready-to-dev column, triggering dev in a git worktree.
3. **Develop** — implement in the worktree.
4. **Test** — run tests + E2E agentic browser test on shared fixtures (e.g. test account).
5. **Review** — push to review after dev+test.
6. **Notify** — notify the issue owner at each transition.
7. **Validate** — human validator approves; tool merges.

Constraints:
- **Harness-agnostic** — start with opencode, extensible to Claude Code, Codex, etc.
- **Forge-agnostic** — GitHub or GitLab (via `glab`).
- **Models configurable**.
- **WIP limit** to bound bandwidth.
- **Log token consumption per step** in the issue.
- **Agnostic of skills and orchestrator** (oh-my-opencode-slim style).

---

## 2. Landscape — tools analyzed

### 2.1 Directly comparable orchestrators

| # | Tool | Lang | Forge | Harness | Daemon | License | Stars | Verdict |
|---|------|------|-------|---------|--------|---------|-------|---------|
| 1 | **nexu-io/looper** | Go | GitHub + Forgejo | opencode, claude-code, codex, cursor-cli, grok-build | yes (`looperd`) | MIT | 92 | **Adopted** |
| 2 | **cobusgreyling/loop-engineering** | TS (CLI) | GitHub only | harness-agnostic (meta) | no (cron) | MIT | 9,331 | Meta-framework, no dev-loop pattern shipped |
| 3 | **devshop-software/crew** | TS | GitHub | Claude Code plugin | no | — | 1 | Claude-only, plugin not daemon |
| 4 | **agent-sh/next-task** | TS | GitHub + GitLab + local | plugin | no | — | 4 | 12-phase, heavy |
| 5 | **zxkane/autonomous-dev-team** | TS | GitHub + GitLab (pluggable) | claude, codex, kiro, opencode, cursor, antigravity | cron | MIT (README) | 29 | Best harness-agnosticism, no daemon |
| 6 | **mraza007/baton** | Python | GitHub | `claude -p` | no | — | 19 (dormant) | WORKFLOW.md config, agent-browser E2E |
| 7 | **BenceBertalan/oc-ralph** | TS | GitHub | opencode | no | — | 0 (dead) | Live status table in issue, self-healing tests |
| 8 | **ajsai47/autocode** | TS | GitHub | claude | cron (GH Actions) | — | 8 (dormant) | Rich local memory, budget controls |
| 9 | **rjwalters/loom** | Go | GitHub + Gitea | claude | daemon + MCP | — | 11 | ForgeClient abstraction (21 methods) |
| 10 | **lSAAGl/loop-harness** | bash | GitHub | claude | cron | — | 9 (dormant) | Skeptical verifier agent |
| 11 | **botondcsereklye/loopengineer** | TS | GitHub | claude, codex | local | — | 0 | Most directly comparable (TS, worktree, per-issue) |
| 12 | **huangruiteng/loopx** | TS | GitHub | claude, codex | local | — | 150 | Control plane above executor, not autonomous |

### 2.2 Reference architectures (not direct competitors)

| # | Project | Why it matters |
|---|---------|----------------|
| 13 | **OpenHands SDK V1** | Canonical hexagonal reference: event-sourced state, stateless components, factory pattern (Local vs Remote conversation), StuckDetector, security analyzer. 61% reduction in system-attributable failures vs V0. |
| 14 | **Cloudflare Project Think** (Apr 2026) | Platform blueprint for serverless orchestration: Durable Objects, fibers, sub-agents, persistent sessions, Dynamic Workers (sandboxed V8, capability-based security), execution ladder (Worker → +npm → +Workspace → +Browser → +Sandbox). |
| 15 | **simple-agent-manager (SAM)** | Canonical control-plane-on-CF + compute-off-CF: Hono on Workers + TaskRunner DO (control) → Hetzner VMs + Go VM Agent + Docker devcontainers (compute). BYOC. |
| 16 | **ensemble-edge/conductor** | Edge-native orchestration on CF Workers: YAML workflows, Durable Objects, Cron Triggers, HITL with resumption. |
| 17 | **Sweep AI** | Validated board-as-source-of-truth + analysis-in-issue pattern. SaaS-only (the gap boucle fills with self-hostable). |
| 18 | **Aider Architect/Editor** | Two-stage reasoning→editor model split. Repo Map (Tree-sitter AST + PageRank). Maps to planner/implementer split + per-stage cost logging. |
| 19 | **Cursor Background Agents** | Five-layer harness. THE RACE PATTERN: dispatch same problem to multiple models in parallel, pick best PR. Video recording as verification. |
| 20 | **Claude Code headless** | `-p`/`--print`, `--bare`, `--allowedTools`, `--permission-mode`, `--max-turns`. Critical failure mode #1462: agent ends turn with "waiting…" and process reports success with NO deliverable. Fix #1465: disallow ScheduleWakeup/SendMessage/background subagents in headless. Lesson: assert declared side effect EXISTS before reporting success. |
| 21 | **12-Factor Agents** (humanlayer) | Discipline to anchor on, particularly #8 (own your control flow) and #3 (own your context window). |
| 22 | **hhamja/loop-engineering-architecture** | Most rigorous pattern for boucle-core: deterministic orchestrator (loop/run.sh state machine: PLAN→EXECUTE→VERIFY→STOP) with LLM worker making only judgments. File-based state bus. Maker/checker with deterministic verify. Contract enforcement via hooks. Harness-agnostic via WORKER_CMD injection. |

---

## 3. looper — deep analysis (adopted tool)

### 3.1 What looper delivers

- **Daemon** (`looperd`): polls GitHub/Forgejo continuously, 3 concurrent loops max (configurable).
- **4 roles, each a loop**: Planner (issue → spec PR), Reviewer (review spec/worker PRs), Worker (spec → implementation PR), Fixer (address review comments).
- **Issue → PR → merge end-to-end**: the full pipeline is delivered, not aspirational.
- **Worktree per loop**: parallel-safe, isolated.
- **Label state machine**: `looper:plan` → `looper:spec-reviewing` → `looper:spec-ready` → `looper:worker-ready` → (worker PR) → review → merge.
- **Harness support**: opencode (auto-detected), claude-code, codex, cursor-cli, grok-build via `--agent-vendor`.
- **HITL**: agent can pause (`running → awaiting_human`) by writing `.looper/ask.json`; question delivered via GitHub PR comment with marker `<!-- looper:hitl:ask v=1 loop=N -->`, human replies on PR, poll lane detects answer.
- **Coordinator**: scans fresh issues, picks disposition `valid`/`out-of-scope`/`unclear`; `unclear` → `needs-info` label + asks author.
- **`looper takeover`**: single-PR lifecycle (review + fix + merge) without full registration.
- **loopernet**: multi-node mode (1 control-plane container on VPS + N looperd nodes as compute).

### 3.2 What works automatically (single-user mode)

1. Issue `looper:plan` → Planner auto-discovers by label → spec PR ✅
2. Spec PR `looper:spec-reviewing` → Reviewer auto-discovers by label (`specReview` mechanism) ✅
3. Reviewer approves spec PR → adds `looper:spec-ready` → Worker auto-discovers issue by `looper:worker-ready` label ✅
4. Reviewer posts comments on PR → Fixer auto-discovers by review comments ✅

### 3.3 What does NOT work automatically (single-user mode)

**Worker PR → Reviewer.** The worker creates a PR but does NOT label it. The Coordinator is *supposed* to assign reviews to worker PRs via `AddPullRequestReviewers`, but in single-user mode (one GitHub account for both worker and reviewer), GitHub blocks self-review-request:

```
HTTP 422: Review cannot be requested from pull request author
```

The `enableSelfReview = true` config only relaxes the reviewer's *discovery filter* (skips the author-equality check) — it does NOT affect the Coordinator's `AddPullRequestReviewers` API call. GitHub blocks that at the API level regardless of looper config.

**Root cause** (source at `/tmp/looper-src/internal/coordinator/runner.go:1205-1228`): `applyLocalReviewAssignment` calls `GetCurrentUserLoginForRepo` → returns the daemon's gh-authed user (baderdean) → `AddPullRequestReviewers(baderdean)` → 422 because the PR was authored by the same user (looper opens PRs as the current user).

**Fundamental design assumption**: looper expects either a **bot account** (different GitHub identity for reviewer) or **loopernet multi-node** (different node's GitHub identity). In single-user mode, the worker PR → reviewer hop requires manual `looper review <repo>#<pr>`.

### 3.4 Known bugs hit in production

1. **EBADF on `looper review submit`** (issue #595, OPEN, no fix PR): the `PersistentPreRunE` auto-upgrade hook calls `loadConfig()` which reads and closes FD 3 (the trusted review config pipe). Then `review submit` calls `loadConfig()` again → `os.NewFile(3)` on a closed descriptor → `EBADF`. Deterministic on release binaries. **Workaround**: build from source (dev build short-circuits the auto-upgrade hook, never burns FD 3). Fix suggestion: memoize `LoadTrustedReviewConfigSnapshot` with `sync.Once`.

2. **Reviewer auto-discovery runaway** (config footgun): `roles.reviewer.discovery.triggers.labels = []` + `labelMode = 'all'` = vacuous match (every PR satisfies "has all zero required labels"). Setting `labels` to a non-existent label (`looper:manual-review-only`) prevents the runaway.

3. **Coordinator blocks scheduler on 422**: when the Coordinator hits a 422 on any PR, it fails the entire scheduler tick (`looperd scheduler tick failed`), cascading "context canceled" to other in-flight discoveries. `availableSlots:0` until the 422 source is resolved.

4. **Reviewer marker idempotencyKey mismatch** (issue #599, OPEN): the agent sometimes posts `id=reviewer:loopID` (dropping the `:headSHA` suffix) but the daemon expects `id=reviewer:loopID:headSHA`. Intermittent — when the agent includes `:headSHA`, the loop completes; when it drops it, the loop stays `backing_off` (review IS posted, just not verified). Feature request filed.

5. **Outbound content safety gate false positive on GitHub asset URLs** (issue #600, OPEN): `highEntropyCandidateRE` matches GitHub screenshot URLs (`user-images.githubusercontent.com/...`) as "high-entropy tokens", blocking the planner. No config to disable. Planner may succeed on retry (intermittent).

6. **Auto-merge blocked for bot-authored PRs** (issue #602, OPEN): `selfApprovalFallback` downgrades APPROVE→COMMENT (GitHub blocks self-approval), but `publishCriteriaApprovedReview` requires `marker.Event == ReviewEventApprove` → `EnableAutoMerge` never called. Same single-identity root cause as #598.

7. **Fixer self-comment filter in single-identity mode** (issue #603, OPEN): `actionableNativeReviewComments` skips comments where author == current user. In single-identity mode, reviewer and fixer share the same bot identity → all review comments filtered out → fixer never auto-discovers. Same single-identity root cause as #598 and #602.

8. **Post-deploy E2E browser verification gap** (issue #604, OPEN): looper's loop ends at merge. Deployment-dependent fixes (405 from undeployed function) are correctly marked UNVERIFIABLE by the reviewer but ARE verifiable post-deploy. Feature request filed for an optional `→ deploy → E2E verify` step.

---

## 4. Functional gaps vs the boucle goal

| Requirement | looper | loop-engineering | autonomous-dev-team | baton | oc-ralph | Gap |
|-------------|--------|------------------|---------------------|-------|----------|-----|
| Issue → merged PR end-to-end | ✅ delivered | ❌ no dev-loop pattern | ✅ | ✅ (tested) | ✅ | — |
| Daemon (continuous) | ✅ `looperd` | ❌ cron manual | ❌ cron | ❌ | ❌ | — |
| opencode harness | ✅ `--agent-vendor opencode` | ✅ (meta) | ✅ pluggable | ❌ `claude -p` | ✅ | — |
| GitLab support | ❌ GitHub + Forgejo only | ❌ GitHub only | ✅ pluggable CODE_HOST | ❌ | ❌ | **All tools fail** |
| E2E browser test | ❌ not native | ❌ | ❌ | ✅ agent-browser | ❌ | **Only baton** |
| Analysis in issue (not doc) | ⚠️ spec PR (doc) | ✅ STATE.md | ⚠️ | ❌ | ✅ live table | **Partial** |
| Sub-issue deduction | ❌ | ❌ | ✅ `blocked_by` edges | ❌ | ✅ Sculptor | **Partial** |
| Budget control (cap + visibility on coding-model token spend) | ❌ (3 concurrent loops, no $ cap) | ❌ | ❌ | ❌ | ❌ | **None** (autocode has $5/session, $10/day) |
| Notify owner at each transition | ⚠️ (PR comments) | ❌ | ❌ | ❌ | ✅ Discord webhook | **Partial** |
| Harness interface first-class | ❌ (vendor flag) | ✅ (meta) | ✅ conformance suite | ❌ | ❌ | **Partial** |
| Self-hostable serverless | ❌ (local daemon) | ❌ (cron) | ❌ (cron) | ❌ | ❌ | **None** |

### 4.1 Gaps looper doesn't fill (and boucle would need to add)

1. **GitLab support** — looper is GitHub + Forgejo only. tyre-call (Framagit/GitLab) has no automation path. Would need a `glab` adapter or a forge abstraction layer (loom's `ForgeClient` with 21 methods is the reference).

2. **E2E browser test** — looper's loop ends at PR opened/reviewed. AGENTS.md-mandated browser E2E (e.g. on https://m3llm.cafe after deploy) lives outside looper's scope. baton's agent-browser pattern (open/snapshot/click/fill/type to verify acceptance criteria before PR) is the reference. Cloudflare Browser Rendering binding is the serverless option.

3. **Budget control** — looper has a global `3 concurrent loops` limit but no way to cap or make visible the coding-model token spend (Ollama Cloud, opencode, etc.) per loop/day/project. The need is to bound cost and surface it to the approver — specific mechanisms (WIP limit, token log in issue, hard $ budget) are solutions, not the requirement. autocode ($5/session, $10/day) is the closest reference.

4. **Sub-issue deduction** — looper's planner writes a spec PR but doesn't decompose into sub-issues with dependency edges. autonomous-dev-team's `blocked_by` edges and oc-ralph's Sculptor role are the references.

5. **Self-hostable serverless** — no loop-eng tool runs on Cloudflare Workers. looper is a local Go daemon. The hybrid architecture (control plane serverless on CF Workers+DOs for scheduler/state/budget-control/notifier; compute plane non-serverless on CF Containers/VM/local daemon for opencode+worktree+tests) is the path. SAM and CF Project Think execution ladder are the references.

### 4.2 Gaps looper fills that others don't

- **Daemon** — only looper has a continuous daemon; all others are cron or manual.
- **opencode support** — looper supports opencode natively; most others are Claude Code-only.
- **End-to-end delivered** — looper ships issue→spec PR→review→worker→PR→review→fix→merge. loop-engineering (9,331⭐) ships only maintenance patterns (triage, babysit, sweep); the dev-loop pattern is supported by design but uncontributed.

---

## 5. Decision

**Adopt looper** for leadminer, m3llm, wikiadviser (GitHub, opencode, dev end-to-end delivered).

**Blockers**:
- tyre-call (GitLab/Framagit) — no looper support. Needs a GitLab adapter or a different tool.
- Worker PR → Reviewer in single-user mode — needs either a bot account (different GitHub identity) or a patch (worker labels its PRs `looper:needs-review`, reviewer discovers by label). Feature request filed: [nexu-io/looper#598](https://github.com/nexu-io/looper/issues/598).
- EBADF bug — workaround: run dev build of looper/looperd.

**Not adopted**:
- **loop-engineering** (9,331⭐): meta-framework, no dev-loop pattern shipped, no daemon, GitHub-only. Opportunity to contribute the dev-loop pattern, but looper already delivers it.
- **autonomous-dev-team** (29⭐): best harness-agnosticism (conformance suite) but no daemon, no license file at root.
- **baton** (19⭐, dormant): only one with agent-browser E2E, but Python + dormant.
- **Building from scratch** (original boucle hexagonal TS+Bun design): deferred. The looper adoption proves the loop works; if looper's gaps (GitLab, E2E, serverless) become blocking, the hexagonal design remains a viable future path.

---

## 6. Open items

- [x] Bot account setup (`ankaboot-bot`) — PAT in `[agent.env]`, daemon runs as bot via launcher script. Full issue→merge loop verified (m3llm#146, m3llm#192).
- [x] E2E browser test strategy — feature request filed as [nexu-io/looper#604](https://github.com/nexu-io/looper/issues/604). Implementation TBD.
- [ ] tyre-call GitLab automation — needs a different tool or a GitLab adapter.
- [ ] Budget control — cap and make visible coding-model token spend (Ollama Cloud, opencode) per loop/day/project. Mechanism TBD (WIP limit / token log / hard $ budget).
- [ ] Contribute the worker-PR-label patch to looper (issue #598, Option A: ~5 lines in `worker/runner.go`).
- [ ] 7 looper issues filed total: #595 (EBADF), #598 (worker PR review), #599 (marker mismatch), #600 (outbound guard), #602 (auto-merge), #603 (fixer self-comment), #604 (post-deploy E2E). Three (#598, #602, #603) share single-identity root cause.

---

## 7. References

- looper: https://github.com/nexu-io/looper
- loop-engineering: https://github.com/cobusgreyling/loop-engineering
- autonomous-dev-team: https://github.com/zxkane/autonomous-dev-team
- baton: https://github.com/mraza007/baton
- oc-ralph: https://github.com/BenceBertalan/oc-ralph
- autocode: https://github.com/ajsai47/autocode
- loom: https://github.com/rjwalters/loom
- loop-harness: https://github.com/lSAAGl/loop-harness
- LoopEngineer: https://github.com/botondcsereklye/loopengineer
- LoopX: https://github.com/huangruiteng/loopx
- next-task: https://github.com/agent-sh/next-task
- crew: https://github.com/devshop-software/crew
- OpenHands: https://github.com/All-Hands-AI/OpenHands
- 12-Factor Agents: https://github.com/humanlayer/12-factor-agents
- loop-engineering-architecture: https://github.com/hhamja/loop-engineering-architecture
- Feature request (worker PR review): https://github.com/nexu-io/looper/issues/598
- EBADF bug: https://github.com/nexu-io/looper/issues/595
- Worker PR review gap: https://github.com/nexu-io/looper/issues/598
- Marker idempotencyKey mismatch: https://github.com/nexu-io/looper/issues/599
- Outbound guard false positive: https://github.com/nexu-io/looper/issues/600
- Auto-merge blocked: https://github.com/nexu-io/looper/issues/602
- Fixer self-comment filter: https://github.com/nexu-io/looper/issues/603
- Post-deploy E2E verification: https://github.com/nexu-io/looper/issues/604