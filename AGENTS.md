# AGENTS.md — boucle POC

> This file is the charter for the boucle proof-of-concept. It defines the goal, methodology, evaluation criteria, and decision framework. Anyone (human or agent) working in this repo should read this first.

## 1. POC goal

Determine, through hands-on usage, whether [looper](https://github.com/nexu-io/looper) can serve as the autonomous dev-loop orchestrator for our repos — a **dev factory A→Z** that takes an issue from `todo` to a merged PR with human validators only at each gate.

### What "dev factory A→Z" means

1. **Triage** — analyze the issue *in place* (not a separate doc), deduce sub-issues if needed, tag by category, evaluate complexity.
2. **Ready-to-dev** — push to a ready-to-dev state, triggering dev in a git worktree.
3. **Develop** — implement in the worktree.
4. **Test** — run tests + E2E agentic browser test on shared fixtures.
5. **Review** — push to review after dev+test.
6. **Notify** — notify the issue owner at each transition.
7. **Validate** — human validator approves; tool merges.

### Constraints

- **Harness-agnostic** — start with opencode, extensible to Claude Code, Codex, etc.
- **Forge-agnostic** — GitHub or GitLab (via `glab`).
- **Models configurable**.
- **WIP limit** to bound bandwidth.
- **Log token consumption per step** in the issue.
- **Agnostic of skills and orchestrator** (oh-my-opencode-slim style).

## 2. Methodology

### 2.1 Approach

Run looper in production on real repos with real issues. Observe what works, what breaks, what requires manual intervention. Log every finding. After sufficient evidence, make a decision.

### 2.2 Test repos

| Repo | Forge | Stack | Notes |
|------|-------|-------|-------|
| `ankaboot-source/leadminer` | GitHub | Node + Supabase + Docker | backend+frontend+microservices, 12 worktrees, 200 issues |
| `ankaboot-source/m3llm` | GitHub | Supabase + Docker + LiteLLM | 23 issues, AGENTS.md mandates browser E2E on m3llm.cafe |
| `ankaboot-source/wikiadviser` | GitHub | Node + Docker + Supabase | 200 issues, 14 PRs |
| `ankaboot-source/ansible-supabase` | GitHub | Ansible | 29 issues — caused coordinator timeouts, paused |
| `up/tyre-call` (Framagit) | **GitLab** | Cloudflare Workers + Pages + Supabase | **looper doesn't support GitLab** — no automation path |

### 2.3 Harness

- **opencode** (v1.17.20) — the only harness the user runs. looper supports it via `--agent-vendor opencode`.
- Permission mode: `OPENCODE_PERMISSION` env var (all tools allowed) injected via `[agent.env]` in looper config.

### 2.4 Identity model

- **Single-user mode** (initial): one GitHub account (baderdean) for both worker and reviewer. Hits GitHub's self-review-request block (HTTP 422).
- **Bot account** (current transition): `ankaboot-bot` with a PAT in `[agent.env]`. Agent children (planner/worker/reviewer/fixer) act as the bot; the daemon/coordinator runs as baderdean. This creates the identity separation needed for review requests.

### 2.5 Evidence collection

Every POC run is logged in `docs/poc-looper-status.md` with:
- What was tested
- What worked
- What broke (bug ID, error, workaround)
- What required manual intervention
- Config changes applied

## 3. Decision framework

After sufficient POC evidence, choose one:

### Option A — Stay with looper

**Criteria**: looper handles ≥80% of the dev-factory flow autonomously (issue → merged PR) with no more than 1 manual intervention per loop, and the gaps (GitLab, E2E, token logging, WIP gate) are patchable or non-blocking.

**If chosen**: contribute patches upstream (worker-PR-label #598, EBADF #595), add a GitLab adapter or sidecar, add E2E as a post-merge step.

### Option B — Adopt another tool

**Criteria**: another tool fills more gaps than looper without introducing worse ones, and has comparable or better traction/maintenance.

**Candidates**: autonomous-dev-team (best harness-agnosticism, conformance suite), baton (only one with agent-browser E2E, but dormant + Python), loop-engineering (9,331⭐ but no dev-loop pattern shipped).

### Option C — Build from scratch

**Criteria**: no existing tool fills enough gaps, and the gaps are structural (not patchable). The original boucle hexagonal TS+Bun design (boucle-core + boucle-cf + boucle-local adapters, Harness interface, session-branch pattern, CF Workers control plane + Containers compute plane) remains the reference architecture.

**Risk**: high — building a dev orchestrator from scratch is months of work. Only justified if looper's gaps are structural and no other tool fills them.

### Option D — Change the approach

**Criteria**: the dev-factory-A→Z goal itself is wrong — e.g. maybe human validators at every gate is too much friction, or maybe the loop should be narrower (e.g. only triage + review, not full implementation).

**If chosen**: redefine the goal and re-evaluate.

### Decision triggers

Re-evaluate when any of these is true:
- 10 loops completed (enough sample size)
- A blocking gap confirmed unfixable (e.g. GitLab support is structurally impossible in looper)
- A competitor tool demonstrably fills more gaps
- 30 days of POC usage

## 4. Gap documentation

### 4.1 Gaps looper doesn't fill

| Gap | Severity | Patchable? | Reference |
|-----|----------|------------|-----------|
| GitLab support | **Blocking** for tyre-call | No (GitHub+Forgejo only) | loom's ForgeClient (21 methods) |
| E2E browser test | **Blocking** for m3llm AGENTS.md | Sidecar/Action | baton's agent-browser, CF Browser Rendering |
| Per-step token log in issue | Medium | Patch (comment writer) | boucle requirement |
| WIP gate at board level | Medium | Patch or CI check | hhamja hook pattern |
| Sub-issue deduction | Low | Patch (planner prompt) | autonomous-dev-team `blocked_by`, oc-ralph Sculptor |
| Self-hostable serverless | Low (v1) | No (local daemon) | SAM, CF Project Think |

### 4.2 Bugs hit in production

| Bug | Severity | Status | Workaround |
|-----|----------|--------|------------|
| EBADF on `looper review submit` (#595) | **Blocking** | OPEN, no fix PR | Dev build (skips auto-upgrade hook) |
| Worker PR → Reviewer in single-user mode | **Blocking** | Feature request #598 | Bot account OR manual `looper review` OR patch |
| Reviewer auto-discovery runaway | High | Config footgun | `triggers.labels = ['looper:manual-review-only']` |
| Coordinator 422 cascade blocks scheduler | High | Design issue | Disable coordinator OR bot account |

### 4.3 What works

| Flow step | Status | Notes |
|-----------|--------|-------|
| Issue `looper:plan` → Planner → spec PR | ✅ | Auto-discover by label |
| Spec PR → Reviewer → review | ✅ | Auto-discover by `looper:spec-reviewing` label |
| Reviewer approves → `looper:spec-ready` → Worker | ✅ | Auto-discover by `looper:worker-ready` label |
| Worker → implementation PR | ✅ | Worktree-isolated, opencode |
| Review comments → Fixer → fixes | ✅ | Auto-discover by review comments |
| Fixer → tests → push | ✅ | Ran 29 tests, all pass |
| Reviewer → deep review with evidence | ✅ | Ran tests, rendered Mermaid, verified EPO schema via librarian |
| Worker PR → Reviewer (auto) | ❌ | Needs bot account or patch (#598) |
| E2E browser test | ❌ | Not native to looper |
| GitLab | ❌ | Not supported |

## 5. Repo structure

```
boucle/
├── AGENTS.md                      # This file — POC charter
├── README.md                      # Research: tool comparison and functional gaps
└── docs/
    └── poc-looper-status.md       # Current POC state — runs, config, bugs
```

## 6. Operating instructions

- **Do not** merge spec PRs manually — let the reviewer promote to `looper:spec-ready`, then the worker implements on the same issue.
- **Do not** enable the coordinator in single-user mode without a bot account — it 422s on self-review-request and blocks the scheduler.
- **Do** run the dev build of looper/looperd (EBADF workaround).
- **Do** log every POC run in `docs/poc-looper-status.md`.
- **Do** update this AGENTS.md when the decision is made.