# POC #2: Head-to-head — autonomous-dev-team vs compozy

> Living document. Updated after every POC run. Captures config state, runs, bugs, and findings.
>
> **POC #2** — started 2026-07-26, after closing POC #1 (looper, Option B — see `poc-looper-status.md` §8).
>
> **Design**: head-to-head comparison of two dev-loop tools on two repos, in parallel, with the same harness (opencode) and the same model (glm-5.2).
>
> | Repo | Tool | Verify gate | Dispatch | Merge |
> |------|------|-------------|----------|-------|
> | `ankaboot-source/m3llm` | autonomous-dev-team (29⭐, Shell) | **Behavior-verified** (E2E_MODE=command, host runs verify, dual-signal `(rc==0) AND (evidence==1)`) | Automatic (cron + `autonomous` label) | Automatic (wrapper does `gh pr merge`) |
> | `ankaboot-source/leadminer` | compozy (2,384⭐, Go) | **LLM-judge** (`cy-final-verify` is a prompt, not a programmatic gate — agent self-reports, host trusts) | Manual (`compozy tasks run <slug>`) | Manual (human opens/merges PR) |
>
> **Critical requirement carried from POC #1**: the review gate must verify BEHAVIOR in production, not just review the DIFF. looper shipped bugged code (PR #180 `search_patents` 404, PR #195 migration XX000) because its review was diff-scoped and `UNVERIFIABLE` did not block merge. This POC tests whether autonomous-dev-team's E2E gate actually prevents that failure mode, and whether compozy's structured pipeline (PRD→TechSpec→Tasks→Code→Review) can compensate for lacking a programmatic gate.

## 1. Environment

| Component | Value |
|-----------|-------|
| Tool | zxkane/autonomous-dev-team |
| Source | `/tmp/autonomous-dev-team-src` (cloned from github.com/zxkane/autonomous-dev-team @ HEAD `3610c2b`) |
| Stars | 29 (as of 2026-07-26) |
| Last commit | 2026-07-25 (very active: ~50 commits in 6 months, 4 in last 7 days) |
| Language | Shell |
| License | None declared (repo default) |
| Versioning | No git tags — rolling `main` is the deliverable |
| opencode | 1.17.20 (adapter validated against opencode v1.14.46) |
| gh | authed as baderdean |
| OS | Linux x86_64 |

## 2. Config state

> **Status: INSTALLED on both test repos (2026-07-26).** Each repo has its own independent dispatcher instance — own `.claude/skills/` install, own `scripts/autonomous.conf`, own GitHub labels, own cron. This is the "one loop per repo" architecture the user mandated.

### Test repos (two independent loops, running in parallel)
| Repo | Forge | Stack | Issues | E2E verify strategy |
|------|-------|-------|--------|---------------------|
| `ankaboot-source/m3llm` | GitHub | Python + Supabase + Docker + Open WebUI | 23 | `pytest -m unit` (unit tests only — integration needs external services) |
| `ankaboot-source/leadminer` | GitHub | Node monorepo (backend Jest + frontend Vitest + emails-fetcher) | 200 | Mirror CI: backend `test-ci:unit`+lint+prettier, frontend lint+prettier, emails-fetcher `test:unit` (change-scoped) |

### Install path used

**Migrated from claude-code → opencode target (2026-07-26).** Originally installed via `npx skills add zxkane/autonomous-dev-team -a claude-code -y` (skills landed in `.claude/skills/`). Migrated to opencode target:

1. `npx skills@latest add zxkane/autonomous-dev-team -a opencode -y` → installed 5 skills to `.agents/skills/` (cross-agent convention; opencode reads from here)
2. Re-pointed `hooks` symlink: `.claude/skills/autonomous-common/hooks` → `.agents/skills/autonomous-common/hooks`
3. Re-pointed all 25 `scripts/` symlinks from `.claude/skills/autonomous-dispatcher/scripts/` → `.agents/skills/autonomous-dispatcher/scripts/`
4. Verified 0 broken symlinks, `dispatcher-tick.sh` executable, `autonomous.conf` preserved (1264 lines)
5. Removed claude-code install: `npx skills@latest remove -a claude-code -s autonomous-common -s autonomous-dev -s autonomous-dispatcher -s autonomous-review -s create-issue -y`
6. `.claude/skills/` now empty, `skills-lock.json` repopulated with 5 skills + correct hashes

> ⚠️ Did NOT use the naive `ln -sf .claude/skills/autonomous-dispatcher/scripts scripts` from installation.md — that would clobber existing `scripts/` dirs. Used `install-project-hooks.sh` instead (symlinks only entry `*.sh`, skips `lib-*.sh` and real project files). After migration, the symlinks point to `.agents/skills/` instead.

### Key settings (`scripts/autonomous.conf` — ACTUAL, both repos)
```bash
# Harness
AGENT_CMD="opencode"
AGENT_DEV_MODEL="opencode-go/glm-5.2"     # confirmed available in opencode
AGENT_REVIEW_MODEL="opencode-go/glm-5.2"  # same model for dev + review (first run)
AGENT_PERMISSION_MODE="auto"              # --dangerously-skip-permissions NOT wired for opencode → sandbox required

# Forge (GitHub, PAT mode — first run)
GH_AUTH_MODE="token"                      # single GitHub account (baderdean), gh keyring auth

# E2E behavior gate (ENABLED — the reason we're POCing this tool)
E2E_ENABLED="true"
E2E_MODE="command"
E2E_COMMAND='bash scripts/e2e-verify.sh ${PR_NUMBER}'           # single-quoted! ${PR_NUMBER} is runtime placeholder
E2E_COMMAND_EVIDENCE_PARSER='bash scripts/e2e-evidence.sh'

# Token budget (warn mode — hard mode REFUSES opencode)
TOKEN_BUDGET_MODE="warn"
REVIEW_BOTS=""                            # no external bot reviewers
```

> ⚠️ **Gotcha hit during install:** `E2E_COMMAND` MUST be single-quoted. Double quotes cause `set -u` to fail at source time (`PR_NUMBER: unbound variable`) because the shell eagerly expands `${PR_NUMBER}`. The conf's own comment documents this but the example file ships with the placeholder unquoted in a comment. Fixed in both repos.

### Per-repo identity vars
| Var | m3llm | leadminer |
|-----|-------|-----------|
| `PROJECT_ID` | `m3llm` | `leadminer` |
| `REPO` | `ankaboot-source/m3llm` | `ankaboot-source/leadminer` |
| `REPO_OWNER` | `ankaboot-source` | `ankaboot-source` |
| `REPO_NAME` | `m3llm` | `leadminer` |
| `PROJECT_DIR` | `/home/badreddine/Projects/ankaboot-source/m3llm` | `/home/badreddine/Projects/ankaboot-source/leadminer` |

### Labels (9, provisioned on both repos via `setup-labels.sh`)
| Label | Hex | Meaning |
|-------|-----|---------|
| `autonomous` | `#0E8A16` | Required precondition — issue should be processed |
| `in-progress` | `#FBCA04` | Dev agent actively working |
| `pending-review` | `#1D76DB` | Dev complete, awaiting review |
| `reviewing` | `#5319E7` | Review agent actively reviewing |
| `pending-dev` | `#E99695` | Review failed, dev retry wanted |
| `approved` | `#0E8A16` | Review passed (merged or manual) |
| `no-auto-close` | `#d4c5f9` | Skip auto-merge (maintainer opt-out) |
| `stalled` | `#B60205` | Pipeline halted (retries/liveness/convergence) |
| `run-live-smoke` | `#006B75` | CI gate for live agent smoke (maintainer-gated) |

All 9 created on both repos (confirmed via `gh label list`).

### E2E verify scripts (project-supplied, per repo)
- **m3llm** `scripts/e2e-verify.sh` (38 lines): `pytest -m unit` + `main.py` syntax smoke. Exit 0=pass, non-zero=fail.
- **m3llm** `scripts/e2e-evidence.sh` (24 lines): emits markdown with last 50 log lines + `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` marker.
- **leadminer** `scripts/e2e-verify.sh` (109 lines): mirrors `prepush-ci-check.sh` — change-scoped (backend/frontend/emails-fetcher), runs `test-ci:unit`+lint+prettier per area. Exit 0=pass, 1=any-check-failed.
- **leadminer** `scripts/e2e-evidence.sh` (24 lines): same structure as m3llm.

### Smoke test (passed)
`bash -n` syntax check on `autonomous-dev.sh`, `autonomous-review.sh`, `dispatcher-tick.sh`, `e2e-verify.sh`, `e2e-evidence.sh` — all OK on both repos.

### Dispatcher scheduling (STARTED 2026-07-26)
Cron entry added (m3llm):
```cron
*/5 * * * * cd /home/badreddine/Projects/ankaboot-source/m3llm && PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash scripts/dispatcher-tick.sh >> /tmp/m3llm-autonomous-dispatcher.log 2>&1
```

> ⚠️ **PATH gotcha (hit + fixed):** cron's minimal PATH excludes linuxbrew where `gh` lives (v2.96.0 at `/home/linuxbrew/.linuxbrew/bin/gh`). First two ticks FATAL'd with `ADT_CFG_GH_VERSION_TOO_OLD` (tick 01:45) and `gh: commande introuvable` in `itp-github.sh:89` (tick 01:50). Setting `REAL_GH` in the conf only fixes the version check, not the actual `gh` invocations in provider scripts. Fix: prepend linuxbrew to PATH in the cron entry itself. Tick 01:55 ran clean.

**opencode provider login**: not needed — `opencode providers list` showed 9 credentials already at `~/.local/share/opencode/auth.json`, including **OpenCode Go** (api) matching `AGENT_DEV_MODEL="opencode-go/glm-5.2"`. Smoke test `opencode run --model opencode-go/glm-5.2 "Reply with exactly: PONG"` → returned `PONG` (exit 0).

## 3. Identity model

**PAT mode (CHOSEN for first run)** — `GH_AUTH_MODE="token"`, single GitHub account (baderdean), gh keyring auth (scopes: gist, read:org, repo, workflow). Simpler setup, no App creation/PEM management. Same single-identity limitation as looper in theory, BUT autonomous-dev-team has no coordinator (dispatcher is a stateless bash cron) so the 422 cascade that blocked looper should not occur. If self-review-request 422 appears on PR review, switch to GitHub App mode.

**GitHub App mode (fallback if 422 hits)** — solves the single-identity 422 problem from looper:
- 3 separate GitHub Apps (dev, review, dispatcher) with PEM files.
- Wrapper holds full-write App token (label flips, `gh pr review --approve`, `gh pr merge`).
- Agent subprocess receives **down-scoped** installation token (`pull_requests: read`) — **cannot** approve/merge even if it tries.
- Two-token split is INV-79 (`docs/github-app-setup.md:120-198`).

**GitLab** (for tyre-call in a later POC run) — 3 separate PATs give 3 bot identities (no GitHub App equivalent on GitLab).

## 4. The E2E behavior verification step (CRITICAL — the reason we're POCing this tool)

**Status: implemented and gating.** This is the key differentiator vs looper.

### Modes (`E2E_MODE`)
- **`none`** (default) — no E2E. ⚠️ If we leave this default, we repeat looper's failure (diff-only review).
- **`browser`** — Chrome DevTools MCP UI smoke test (for SaaS web apps with per-PR preview URL).
- **`command`** — project-supplied verify command (for backend/CLI/infra/Workers).

### Architectural property (pre-merge, not post-deploy)
E2E lane runs **ONCE before the review fan-out** (INV-46). Review agents read the posted E2E report as input. This is a **pre-merge hard gate** in Phase A of the review wrapper.

### Gate enforcement
- `_classify_e2e_gate` dual-signal: `(rc == 0) AND (evidence_present == 1)` → `pass`. Either alone → `fail` or `block-nonsubstantive` (re-queue).
- E2E FAIL → `reviewing → pending-dev` (NO review fan-out).
- Repeated gate fail (same head + same rc) ≥ `GATE_FAIL_STALL_THRESHOLD` (default 2) → `reviewing → stalled`.
- SHA-bound marker `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` is load-bearing for idempotency.

### What this means for the POC
- **If we enable E2E_MODE=command with a real verify script**, the review gate becomes behavior-scoped — directly closing the looper PR-180/PR-195 failure class.
- **If we leave E2E_MODE=none**, we get the same diff-scoped review as looper. **We must enable E2E for the POC to be meaningful.**
- The verify script is **project-supplied** — we have to write it for each test repo.

## 5. Pipeline / flow structure

```
Issue (autonomous label)
   │
   ▼
Dispatcher (cron tick) ──▶ Dev Agent ──────────▶ Review Agent
   scan + dispatch          worktree + TDD         Phase A: E2E verify (if enabled)
   concurrency + retry      implement + test       Phase B: review fan-out
                             open PR                approve + merge (or pending-dev)
```

### Per-tick dispatcher steps
1. Concurrency gate — abort if `count(in-progress + reviewing) >= MAX_CONCURRENT` (default 5).
2. scan-new — find `autonomous`-only issues, check `## Dependencies`, dispatch dev-new.
3. scan-pending-review — find `pending-review` issues, dispatch review.
4. scan-pending-dev — find `pending-dev` issues, retry-counter check, dispatch dev-resume (or stalled).
5. Stale detection — probe wrapper PID for `in-progress` / `reviewing` issues.

### Agent roles
- **Dispatcher**: bash script, no LLM, no harness. Pure state-machine.
- **Dev Agent**: per-issue wrapper `autonomous-dev.sh`. Worktree + TDD + implement + open PR.
- **Review Agent**: per-issue wrapper `autonomous-review.sh`. Phase A (E2E) + Phase B (review fan-out).
- **Fixer**: not a separate role — dev-resume does the fix work on the existing session.

### End-to-end loop
`Issue (autonomous) → in-progress (dev-new) → pending-review → reviewing (Phase A: E2E) → reviewing (Phase B: review) → approved (merged) | pending-dev (loop back) | stalled`

## 6. Token budget / cost control

**Most mature part of the project.** Directly addresses looper's "no budget control" gap.

### Caps
- `AGENT_TOKEN_BUDGET` — per dev attempt OR per review fan-out member.
- `ISSUE_TOKEN_BUDGET` — cumulative dev + review usage for an issue.
- `TOKEN_BUDGET_MODE` — `warn` (default, posts breadcrumb, preserves routing) or `hard` (routes to `stalled`, blocks dispatch).
- `AGENT_TIMEOUT=4h` — per dev/review invocation.
- `AGENT_REVIEW_TIMEOUT=1h` — smaller for review.
- `E2E_BROWSER_TIMEOUT_SECONDS=4h` — separate cap for browser E2E lane.

### ⚠️ opencode limitation
**Hard mode REFUSES opencode** — `token_budget_adapter_accountable` only returns true for `claude` and `codex`. opencode is NOT in the accountable set. `TOKEN_BUDGET_MODE=hard` with opencode → dispatch refused before agent starts. **Must use `warn` mode with opencode.**

### Visibility
- `metrics.jsonl` — append-only JSONL events (token_usage, pr_opened, verdict, merge, etc.).
- `accounting/<issue>/` — crash-consistent authoritative store.
- `metrics-report.sh` — produces cost-per-merged-PR, incidents/month, quota-failure rate.
- Per-issue `token_usage` events include input/output/total tokens.

## 7. What works (from @explorer mapping — to confirm in POC)

1. **E2E behavior gate** — pre-merge, dual-signal, gating (not advisory) ✅ (design)
2. **GitHub App two-token split** — agent cannot approve/merge ✅ (design)
3. **GitLab first-class** — `ISSUE_PROVIDER=gitlab` + `CODE_HOST=gitlab` ✅ (design)
4. **opencode adapter** — `--format json`, stdin prompt, session capture ✅ (design)
5. **Token budget** — per-loop + per-issue caps, metrics, accounting ✅ (design, warn mode only for opencode)
6. **Worktree isolation** — mandatory, hooks block commits outside worktrees ✅ (design)
7. **Label state machine** — 9 labels, provider-neutral ✅ (design)
8. **Auto-merge** — wrapper does `gh pr review --approve` + `gh pr merge` (or `no-auto-close` opt-out) ✅ (design)

## 8. What doesn't work / caveats (from @explorer mapping)

1. **opencode hard token budget** — refused (only claude+codex accountable) → must use `warn` mode ❌
2. **`--dangerously-skip-permissions` not wired for opencode** — must run in sandbox ❌
3. **E2E is optional by default** (`E2E_MODE=none`) — if not configured, diff-only review (same as looper) ⚠️
4. **E2E is pre-merge, not post-deploy** — for deployment-dependent bugs, need command mode with stage deploy ⚠️
5. **No triage / sub-issue deduction** — issue gets one-shot dispatch, no decomposition ❌
6. **No git tags / rolling main** — no version pinning (can pin via commit SHA with `npx skills`) ⚠️
7. **opencode no default model** — must set `AGENT_DEV_MODEL` + `AGENT_REVIEW_MODEL` explicitly ⚠️
8. **E2E browser lane requires Chrome DevTools MCP installed** — not auto-installed ⚠️
9. **Turn-limit control** — only Claude ≥ 2.1.215 in warn mode supported; opencode not supported ⚠️

## 9. POC runs

### Run #0 — Install + config (2026-07-26) ✅

#### m3llm — autonomous-dev-team
- Installed via `npx skills add` + `install-project-hooks.sh --no-git-hook` (safe symlink into existing `scripts/`).
- Configured `scripts/autonomous.conf`: opencode + `opencode-go/glm-5.2` + PAT mode + E2E command mode.
- Created 9 pipeline labels on GitHub (`autonomous`, `in-progress`, `pending-review`, `reviewing`, `pending-dev`, `approved`, `no-auto-close`, `stalled`, `run-live-smoke`).
- Wrote `scripts/e2e-verify.sh` (pytest -m unit + main.py syntax smoke) + `scripts/e2e-evidence.sh` (markdown + SHA-bound marker).
- Smoke test passed (`bash -n` on all entry + e2e scripts).
- Hit + fixed: `E2E_COMMAND` must be single-quoted (double quotes → `set -u` unbound var error at source time).
- Dispatcher cron NOT yet started — next step is run #1.

#### leadminer — compozy
- Built from source (`make build` + `make install`) → binary at `~/.local/bin/compozy` (v0.2.15-2-gc202311).
- `compozy setup --agent opencode --yes` → 10 core skills installed to `.agents/skills/`.
- Created `.compozy/config.toml`: opencode + `opencode-go/glm-5.2` + full access mode + timeout 10m.
- `compozy daemon start` (PID 451413, port 2323) + `compozy workspaces register` → `ws-7380eefb45c0dfb2`.
- **Permissions blocker resolved**: compozy's OpenCode adapter doesn't wire `--dangerously-skip-permissions`. Workaround: set `OPENCODE_PERMISSION='{"edit":"allow","bash":"allow","webfetch":"allow","external_directory":"allow"}'` in shell before starting daemon — `subprocess.MergeEnvironment` (process.go:280) inherits `os.Environ()`, so the env propagates to `opencode acp`.
- **Smoke test PASSED**: created trivial task (create empty marker file), `compozy tasks run smoke-test --stream` → agent executed via opencode acp → `compozy-smoke-test.txt` created (0B). Full stack verified: daemon → acp → permissions → agent → file.
- Smoke test artifacts cleaned up.

### Run #1 — First real dispatch (2026-07-26, COMPLETED)

#### m3llm — autonomous-dev-team (issue #199 "OpenSource Architecture")
- User labelled #199 `autonomous`. Dispatcher cron picked it up, dispatched dev-new.
- **Dev agent (10 min, fully autonomous)**: agent log `/tmp/agent-m3llm-issue-199.log` (142 lines) proves the full autonomous-dev loop:
  - Created worktree `feat/faq-architecture`, wrote test-cases doc (TC-FAQ-001 through TC-FAQ-005)
  - Generalized `ObfuscatedEmail.tsx` to accept optional `email` prop (splitEmail function, DEFAULT_PARTS fallback)
  - Edited `FAQ.tsx` renderAnswer to obfuscate both `aslema@m3llm.cafe` and `contact@ankaboot.io` via regex
  - Added new FAQ entry to `content.ts` (qFr "Comment avez-vous construit m3llm ?", qAr "كيفاش بنيتو m3llm؟", full architecture description: Rtiba hackathon, OpenWebUI > LiteLLM, docling RAG, local arabophone STT, Supabase, security layer, Oxahost Tunisia, OpenSource, no Google/Apple/Facebook/Microsoft, ankaboot.io offer)
  - Ran `npm run build` → passed (4 pages built, 11.94s)
  - Verified email obfuscation: `grep -c "contact@ankaboot.io\|aslema@m3llm.cafe" dist/aslema/index.html dist/ar/aslema/index.html` → 0 occurrences ✅
  - Self-reviewed via oracle (ses_0645aa61): findings M1 (pointless btoa/atob round-trip), M2 (typo OBTECTED→OBFUSCATED), L1 (misleading comment) — all fixed in follow-up commit `8e4b362`
  - Posted summary comment to issue #199, exited code 0
  - **PR #200 created** (`feat/faq-architecture`, closes #199, +98 lines across 4 files)
- **Review dispatched**: issue flipped `pending-review → reviewing`. Review wrapper ran E2E gate.
- **E2E gate RAN + BLOCKED merge (CRITICAL — the gate works!)**: `pytest -m unit` returned rc=2 (collection errors: duplicate `test_unit.py` basenames in gardener/openstreetmap/tunisian_news plugins — pre-existing, NOT a PR #200 regression). Gate correctly flipped `reviewing → pending-dev`, posted failure evidence as PR #200 comment. **This is the behavior-verified gate that looper lacked.**
- **False positive**: verify script ran the WHOLE test suite, not change-scoped. PR #200 (landing TSX + docs) couldn't have caused pytest collection errors in unrelated Python plugins.
- **Fix applied**: rewrote `scripts/e2e-verify.sh` to be change-scoped (like leadminer's): `landing/*` → `astro build` + `lint`; `plugins/<area>/*` → pytest on that plugin's `test_unit.py` only; `docs/*` → skip. Tested on PR #200 → exit 0 (PASS). Next cron tick will re-review with fixed script.
- **dev-resume dispatched**: picked up `pending-dev` #199, re-flipped to `pending-review`.
- **Review re-ran with fixed E2E script (23:45:33)**: E2E verify hard-failed again (rc=2) — **same pre-existing pytest collection error** (the fix to `e2e-verify.sh` was not picked up because the review wrapper runs the script from the worktree, not the main branch — the worktree was created before the fix). E2E hard gate FAIL → review wrapper attempted to submit REQUEST_CHANGES review.
- **422 self-review-request block (23:46:09)**: `FAILED: "Review Can not request changes on your own pull request"` (HTTP 422). **Same bug looper hit** — in `GH_AUTH_MODE=token`, the agent uses baderdean's PAT, so PR #200 is authored by baderdean, and baderdean cannot request changes on their own PR. Issue #199 moved to `pending-dev`.
- **Stale markers cleared + third review run (23:59:05)**: cleared stale `.attempt-*` markers + lane dirs blocking re-dispatch. Manual dispatcher tick re-dispatched review. E2E gate ran the FIXED change-scoped verify script — but produced a **FALSE NEGATIVE**: `git diff origin/main...HEAD` found "No changes detected" (verify script ran in repo root on `main`, not on the PR's worktree code) → exit 0 → gate=pass. Review agent (opencode) exited code 1 but wrapper resolved verdict=pass from the artifact file. Wrapper attempted `gh pr review --approve` → **422 self-approve block** ("Review Can not approve your own pull request"). Issue #199 flipped to `approved` (manual merge required).

**Run #1 terminal state**: ✅ **Complete issue→merge loop.** Issue #199 CLOSED/COMPLETED (2026-07-26T00:03:35Z), PR #200 MERGED (squash, 2026-07-26T00:03:34Z by baderdean, branch deleted). Three issues hit during the loop:
1. **E2E false positive** (first review, 23:45:33) — verify script ran whole test suite, caught pre-existing `__pycache__` collection errors unrelated to the landing-only PR. Fixed by making verify script change-scoped (`landing/*` → astro build+lint, `plugins/<area>/*` → per-plugin pytest).
2. **E2E false negative** (third review, 23:59:10) — the change-scoped verify script ran from `PROJECT_DIR` (main branch), so `git diff origin/main...HEAD` found no changes → exit 0 → gate=pass WITHOUT actually verifying the PR's code. The verify script doesn't check out the PR head before diffing. **Open issue: `e2e-verify.sh` must `git checkout` the PR branch or run from the worktree before diffing.** The review fan-out (opencode agent) still did a real code review and returned verdict=pass, so the PR was correctly approved despite the E2E false negative.
3. **422 self-review + self-approve** (all reviews) — `GH_AUTH_MODE=token` has no identity separation. `gh pr review --approve` 422s ("can not approve your own pull request"). The wrapper falls back to "manual merge required" WITHOUT calling `gh pr merge` (which WOULD work — GitHub allows merging your own PR). **Workaround applied: `scripts/merge-helper.sh` cron** (see §11.1) auto-merges PRs whose issues are labeled `approved`. Long-term fix: switch to `GH_AUTH_MODE=app` (GitHub App two-token split, INV-79).

**Why PR #200 author shows as baderdean**: `GH_AUTH_MODE=token` in `autonomous.conf` — the agent uses baderdean's PAT, so all commits/PRs appear under baderdean's identity. No identity separation in token mode. The "oracle review ses_0645aa61" in the PR body was the agent itself invoking an oracle review as part of the autonomous-dev skill's code simplification step — NOT a manual human review.

#### leadminer — compozy (issue #2831 "reduce mapToPerson cyclomatic complexity")
- Created PRD + task_01.md in `.compozy/tasks/reduce-maptocomplexity/`. Plan: split `mapToPerson` (complexity 33→≤20) into 7 per-field helpers.
- `compozy tasks run reduce-maptocomplexity --stream` launched.
- **Slow start**: 11+ min in planning/reading phase, no code written. Compared to m3llm dev agent (committed + pushed + PR in ~5 min). compozy's structured pipeline (PRD→TechSpec→Tasks→Code→Review) adds overhead.
- **Now writing code (18 min)**: `contacts-api.ts` -120 lines, new `contacts-mappers.ts` created, +101 lines `googleContacts.test.ts` (writing tests). Refactor in progress.
- **No forge integration**: compozy has no GitHub issue polling, no PR creation, no auto-merge. Human will need to open + merge PR manually.
- **Task COMPLETED (exit=0, ~25 min total)**: `task_01.md` status → `completed`, acceptance criteria checkboxes marked done. Code refactored: `contacts-api.ts` -120/+22 lines, new `contacts-mappers.ts`, `googleContacts.test.ts` +106 lines.
- **Validation PASSED (manual run)**: `npm run test-ci:unit -- -- googleContacts` → 591/591 tests pass. `npm run lint` → clean. `npm run prettier --check .` → "All matched files use Prettier code style!". Refactor is correct.
- **BUT: changes uncommitted, no branch, no PR** — compozy wrote the code to the working tree and marked the task complete, but never committed, never created a branch, never opened a PR. Human must: `git checkout -b refactor/mapToPerson`, `git add`, `git commit`, `git push`, `gh pr create`, `gh pr merge`. This is the "manual merge" limitation confirmed in practice.

#### Run #1 findings (terminal)
1. **autonomous-dev-team E2E gate is REAL and BLOCKING** ✅ — ran pytest, got non-zero rc, blocked merge, flipped to pending-dev, posted evidence. This is the behavior-verified gate that looper lacked. The gate mechanism works as designed.
2. **E2E gate produced a false positive** ⚠️ — ran whole test suite, caught pre-existing collection errors unrelated to the PR. Fixed by making verify script change-scoped. **BUT the fix didn't propagate** (§10.2) — the review wrapper runs the verify script from the stale worktree, not main. POC insight: the gate is only as good as the verify script, AND the verify script must be version-pinned to the PR head or re-fetched on each review.
3. **E2E gate produced a false negative** ⚠️ — on the third review run (with fixed script), `git diff origin/main...HEAD` found "No changes detected" because the verify script ran in the repo root on `main`, not on the PR's worktree code → exit 0 → gate=pass without verifying anything. The verify script doesn't know where the PR's code is. POC insight: the gate mechanism is sound, but the verify script contract needs a defined CWD (the PR's worktree/checkout, not the repo root).
4. **422 self-review + self-approve in token mode** ❌ — same bug as looper. `GH_AUTH_MODE=token` has no identity separation. The agent creates the PR (as baderdean) and then tries to review/approve it (as baderdean) → 422. Fix: switch to `GH_AUTH_MODE=app` (two-token split). This is the next config change before Run #2.
5. **m3llm dev agent quality was good** ✅ — focused PR, reverted unrelated changes, ran tests + lint, created test-cases doc, self-reviewed via oracle and fixed findings (btoa/atob round-trip, OBFUSCATED typo, misleading comment). Full autonomous dev loop: explore → worktree → TDD → implement → build → verify → self-review → fix → commit → PR → comment.
6. **Looper contamination found + cleaned** ⚠️ — POC #1's looperd was still running (started yesterday), dispatched 3 workers on m3llm issues #196/#186/#181. Stopped daemon + workers, removed 2 looper health-check cron entries. POC #2 now clean (only autonomous-dev-team dispatcher-tick + job-ops-daily in crontab).
7. **Dev agent identity shows as baderdean** ⚠️ — in token mode, all commits/PRs appear under the PAT owner. No identity separation. The "oracle review" in the PR body is the agent's own self-review step, not a human review.
8. **compozy completed the task but didn't ship it** ⚠️ — refactor is correct (591/591 tests pass, lint+prettier clean), but changes are uncommitted in the working tree. No branch, no PR, no merge. Human must do 5 manual git/gh steps. This is compozy's "manual merge" limitation confirmed in practice — the head-to-head shows autonomous-dev-team got to a (blocked) PR autonomously, compozy stopped at uncommitted code.
9. **compozy is 5x slower to first code** ⚠️ — 11+ min planning vs m3llm's ~5 min to committed PR. compozy's structured pipeline (PRD→TechSpec→Tasks→Code→Review) adds overhead that may not pay off for small refactors.

### Run #2 — Second dispatch (2026-07-26, COMPLETED with FLOW VIOLATION)

#### m3llm — autonomous-dev-team (issue #201 "bug(model): buggy conversation")
- User created #201 at 00:06:58Z with `autonomous` label. Body: `Buggy conversation: https://m3llm.cafe/s/a187b902-b8a9-414f-ab62-f3e033db0e07 use account: ops@ankaboot.io and AGENTS.md to fix it`. Sparse — no `## Requirements`/`## Acceptance Criteria` checkboxes.
- **00:10 tick**: dispatcher found #201, dispatched dev-new (PID 530463). **FAILED immediately**: `ADT_CFG_AGENT_BINARY_MISSING` — `opencode` binary not on cron's PATH (lives at `/home/badreddine/.opencode/bin/opencode`, not in linuxbrew or standard paths). Agent posted error envelope comment to issue. Issue → `pending-dev`.
- **Fix**: updated crontab to prepend `/home/badreddine/.opencode/bin` to PATH in both dispatcher-tick and merge-helper entries.
- **00:15 tick**: dispatcher re-dispatched #201 as `dev-resume` (PID 534225, session 3edba9c7, opencode ses_0643906aaffehMKlyBmIDkFwvr). Lane-GC reaped dead lane from failed 00:10 dispatch.
- **Dev agent (00:15–00:34, ~19 min)**: agent log `/tmp/agent-m3llm-issue-201.log` (291 lines, 529.8K):
  - Authenticated to m3llm.cafe API (signin ops@ankaboot.io), fetched buggy conversation share_id=a187b902, saved /tmp/chat_a187b902.json (10 messages), walked message tree.
  - **Root cause of the bug**: `MSA_TO_TUNISIAN` dict in `plugins/functions/msa_tunisien_filter/msa_tunisien_filter.py` had two wrong entries: `"عربية":"كرهبة"` (Arabic language → car) and `"العربية":"الكرهبة"` (the Arabic language → the car). In MSA, car = `سيارة` (already correctly mapped). These corrupted every conversation about Arabic language — `البلدان العربية` → `البلدان الكرهبة` (Arab car countries), `بالعربية` → `بالكرهبة` (by the car).
  - Removed both entries, added 7 regression tests (`TestArabicLanguageNotCarRegression`), all pass.
  - **🚨 FLOW VIOLATION: committed directly to main and pushed** — commit `92b7529 fix(msa-filter): stop corrupting "Arabic language" into "car" (#201)`, pushed `fe4012b..92b7529 main -> main` at 00:21:32Z. The `Fixes #201` in commit message auto-closed issue #201 at 00:21:33Z. **No worktree, no PR, no review gate, no E2E gate.** This bypassed the entire review pipeline.
  - `sync_plugins.yml` workflow completed successfully (sha 92b7529) at 00:22:15. Agent detected this and proceeded to browser E2E.
  - **Browser E2E (post-hoc, 00:25–00:34)**: agent ran E2E on m3llm.cafe after sync_plugins.yml deployed the fix. Took screenshots, waited for responses, verified the buggy conversation now works. E2E **passed**. But this is the wrong order — E2E should gate the merge, not verify after it.
  - Agent posted final E2E verification comment to issue #201, exited code 0 at 00:34:47Z.
- **Final state**: issue #201 CLOSED/COMPLETED (00:21:33Z), labels `autonomous,pending-dev` (stale — should be terminal `approved`). Commit `92b7529` on main. sync_plugins.yml success. **Unexpected new commit on main: `e589545 fix(magic-link): send redirect_to as query param, not JSON body`** at 00:25:18Z — not in the agent log, touches unrelated file (`supabase/functions/auth-magic-link/index.ts`), origin unknown (possibly a parallel opencode session or manual work; reflog shows it as a local commit during the agent's run but no dispatcher dispatch for it).

#### Run #2 findings (terminal)
1. **🚨 FLOW VIOLATION: dev agent pushed directly to main, bypassing review gate** ❌ — no worktree, no PR, no review, no E2E gate. The `Fixes #201` auto-closed the issue. This contrasts with Run #1 (#199) where the agent correctly created a worktree + PR + went through review. The issue body "use account: ops@ankaboot.io and AGENTS.md to fix it" may have influenced the agent to "fix it directly" — but the autonomous-dev skill should enforce worktree+PR regardless. **This is a behavioral bug in the agent's adherence to the skill, not a pipeline bug.** The pipeline's enforcement is agent-dependent, not structural.
2. **Browser E2E was post-hoc verification, not a pre-merge gate** ⚠️ — the agent ran E2E on m3llm.cafe AFTER pushing to main and AFTER sync_plugins.yml deployed the fix. E2E passed, but it verified production, not a pre-merge PR. This is the same "verify after ship" anti-pattern that looper had. The E2E gate only works if the agent goes through the PR flow.
3. **Stale labels** ⚠️ — issue closed with `pending-dev` label (should be terminal `approved` or similar). Label state machine not cleanly resolved because the review pipeline never ran.
4. **The fix itself is correct** ✅ — MSA_TO_TUNISIAN dict entries removed, 7 regression tests added, all pass. The bug was real and the fix addresses it. Browser E2E on m3llm.cafe confirmed the fix works in production.
5. **Contrast with Run #1** ⚠️ — Run #1 (#199) followed the full pipeline (worktree → PR → review → E2E gate → fix → re-review → pass → 422 on approve → manual merge). Run #2 (#201) skipped everything and pushed to main. **Same tool, same config, same cron — different agent behavior.** The pipeline's enforcement is agent-dependent, not structural. This is the single most important POC finding: the gate only works if the agent chooses to use it.
6. **opencode binary PATH fixed** ✅ — the 00:10 dispatch failure (`ADT_CFG_AGENT_BINARY_MISSING`) was fixed by prepending `/home/badreddine/.opencode/bin` to the cron PATH. The 00:15 dispatch succeeded.

### Run #3 — Third dispatch (2026-07-26, COMPLETED)

#### m3llm — autonomous-dev-team (issue #206 "Replace fake conversations with real agent captures (corrected re-do of #186 / PR #205)")
- User created #206 at 10:14:47Z with `autonomous` label. Issue is a corrected re-do of PR #205 which failed 3 ways: (1) conversations were still fake (lightly reworded, not real captures), (2) Yassine image was hand-crafted SVG not agent output, (3) worker invented its own prompts instead of using OpenWebUI prompt suggestions.
- **10:20 tick**: dispatcher found #206, dispatched dev-new. Agent started correctly (opencode-go/glm-5.2, 4h timeout).
- **Dev agent (10:15–16:47, ~6.5h)**: agent wrote a Python capture script (`/tmp/opencode/capture.py`) that calls m3llm.cafe API (signin ops@ankaboot.io) for all 16 capabilities × Fr/Ar = 32 conversations, ~64 API calls. Captured all 32/32 real agent conversations to `/tmp/opencode/captures.json` (incremental save for crash resilience). Addressed 9 review findings on PR #214 (commit f6cc1ec pushed to `feat/aslema-real-captures`). PR #215 is a follow-up fix.
- **Agent exited code 0 at 16:47:05Z**. Wrapper warned "no PR was created" (PR #214 already existed from earlier in the run — false alarm).
- **Final state**: issue #206 CLOSED at 16:41:35Z (stale `pending-dev` label — should be terminal). No merge — PR #214/#215 remain open.

#### Run #3 findings (terminal)
1. **Real agent captures worked** ✅ — the agent correctly used the m3llm.cafe API to capture 32 real conversations, fixing PR #205's "still fake" failure. This is the first run where the agent did substantive API-driven work, not just code edits.
2. **Stale labels again** ⚠️ — issue closed with `pending-dev` (same as Run #2 #201). The label state machine doesn't cleanly resolve when the agent doesn't go through the full review pipeline.
3. **Long-running agent (6.5h)** ⚠️ — the 4h timeout was appropriate but the agent ran close to it. For complex capture tasks, the wall-clock cap may need to be higher.
4. **PR #214 not merged** — the run produced a PR but didn't reach merge. The review gate didn't fire (issue auto-closed via commit, similar to Run #2 pattern but with a PR this time).

### Run #4 — ansible-supabase parallel dispatch (2026-07-26, PARTIAL — 1/3 merged)

#### ansible-supabase — autonomous-dev-team (issues #82, #87, #89 — former looper issues)
- Setup: installed skills to `.agents/skills/` (opencode target), wired `hooks` + `scripts` symlinks, copied `autonomous.conf` from m3llm with `PROJECT_ID=ansible-supabase`, `E2E_ENABLED=false`, `E2E_MODE=""`, `REAL_GH=/home/linuxbrew/.linuxbrew/bin/gh`. Ran `setup-labels.sh` (9 labels created). Added cron: `*/5 * * * * cd /home/badreddine/Projects/ankaboot-source/ansible-supabase && PATH="/home/badreddine/.opencode/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash scripts/dispatcher-tick.sh >> /tmp/ansible-supabase-autonomous-dispatcher.log 2>&1`. Tagged #82, #87, #89 with `autonomous`.
- **Dev phase (all 3 completed)**:
  - #82 → PR #95 (feat(mcp): secure MCP remote access via SSH tunnel) — Kong ip-restriction plugin, SSH tunnel docs, 13 test assertions
  - #87 → PR #96 (setup.sh deterministic config-based installer) — 12 shell tests, config.example.yml, docs
  - #89 → PR #94 (README secure-by-default) — SSO provider setup, Caddyfile protected dashboard, security roles
- **#82 review + merge ✅**: review PASSED (verdict=pass, MERGEABLE, CI green). 422 on approve (token mode self-review block). `gh pr merge 95 --squash --delete-branch` failed: "base branch policy prohibits merge" (branch protection on ansible-supabase main). Merged with `--admin`: PR #95 MERGED at 18:00:35Z, issue #82 CLOSED at 18:00:36Z.
- **#87 review — FAILED twice**:
  - First (18:00): reviewed wrong PR #92 (looper spec, branch `looper/planner/87-...`) instead of PR #96. Wrapper picks lowest-numbered PR referencing the issue. **Fix**: closed obsolete looper spec PRs #92 and #91.
  - Second (18:15): correct PR #96, review agent (glm-5.2, session d06141cc) exited code 0 at 18:17:01 but posted ZERO comments. Wrapper polled 6×5s for 'Review Session' verdict comment → found nothing → `INV-78: verdict-source=none; resolved unavailable` → `INV-144: unavailable review round 1/3` → sent to pending-dev. 422 on REQUEST_CHANGES.
- **#89 review — FAILED**: first review crashed (agent exited code 1 in ~1m40s, verdict=fail from artifact). dev-resume dispatched, completed 18:16:26, flipped to pending-review. Awaiting next review dispatch — will likely hit the same review reliability issue as #87.
- **Dispatch marker bug**: #87/#89 reviews were blocked by stuck dispatch markers at `/run/user/1000/autonomous-ansible-supabase/dispatch-marker-<issue>-review` (directories, NOT files, TTL=600s). Cleared with `rmdir`. The `.attempt-review-*` files in `$HOME/.local/state/autonomous-<PROJECT_ID>/lanes/` are a different mechanism — clearing those doesn't unblock dispatch.

#### Run #4 findings (terminal)
1. **1/3 merged** ⚠️ — only #82 reached merge. #87 and #89 are stuck in the review dispatch loop due to model-dependent review reliability (glm-5.2 doesn't reliably post verdict comments).
2. **Branch protection on ansible-supabase main** ✅ — this is the structural guardrail §10.7 recommended. It blocked the direct merge (required `--admin`). But it also blocks `merge-helper.sh` from auto-merging — the helper will need `--admin` or the branch protection needs adjustment.
3. **Wrong-PR review from looper spec PRs** ⚠️ — the review wrapper picks the lowest-numbered PR referencing the issue. Obsolete looper spec PRs (#91, #92) shadowed the autonomous implementation PRs (#94, #96). Fix: close obsolete spec PRs.
4. **Review gate is model-dependent** 🚨 — glm-5.2 doesn't reliably post the verdict comment format the wrapper expects. #82's review worked (simpler PR, clean verdict). #87's second review: agent exited code 0 but posted zero comments. The wrapper's 30s verdict-poll (6×5s) is too short, and the format instructions aren't followed reliably by glm-5.2. This is a NEW class of failure: the gate fails not because the agent bypasses it (Run #2) but because the review agent silently produces no output.
5. **Dispatch markers at XDG_RUNTIME_DIR** ⚠️ — the dispatch markers are directories at `$XDG_RUNTIME_DIR/autonomous-<PROJECT_ID>/dispatch-marker-<issue>-<mode>` with 600s TTL, not the `.attempt-review-*` files in `$HOME/.local/state/`. Clearing the wrong one doesn't unblock dispatch. This is a config/ops gotcha, not a bug.

#### Run #4 update (20:10–22:04 UTC, post-18:18)
- 20:10 UTC — ansible-supabase dispatcher cron BROKE. The #82 dev agent had committed `verify-secure-mcp.py` into the `scripts/` directory, which destroyed the whole-dir symlink to `.agents/skills/autonomous-dispatcher/scripts/`. All 20+ script symlinks + `autonomous.conf` lost. Cron log: `bash: scripts/dispatcher-tick.sh: Aucun fichier ou dossier de ce nom` repeating.
- Both #87 and #89 went `stalled` because the dispatcher stopped running.
- 22:04 UTC — Fix: re-symlinked all individual scripts + `adapters/` + `providers/` subdirs from `.agents/skills/autonomous-dispatcher/scripts/` into the existing `scripts/` dir (alongside the real `verify-secure-mcp.py`). Recreated `scripts/autonomous.conf`.
- 22:04 UTC — After fix, #87 dispatched as dev-new → silently exited in 28s (worktree `feat/deterministic-installer` already exists, PR #96 OPEN). #89 dispatched review → review agent (glm-5.2) exited code 0 but posted ZERO verdict comments → `INV-78: verdict-source=none` → `INV-144: unavailable` → pending-dev.
- Both #87 and #89 are now stuck in a dev↔review loop: review fails (model silence) → pending-dev → dev tries worktree (conflict) → pending-dev → ... will exhaust MAX_RETRIES=3 and re-stall.
- **Final state:** #87 `pending-dev` (PR #96 OPEN), #89 `pending-dev` (PR #94 OPEN). Both have working implementations but the review gate is broken (model-dependent silence §10.12) and the dev gate is broken (worktree conflict §10.15).

### Run #5 — m3llm #216 (worktree conflict stall)

- **Issue:** #216 "Fix chat capture quality: markdown in text, conversation endings, repetition, missing tool-output images" — follow-up to PR #214/#215 from Run #3
- **Created:** 2026-07-26T18:20:14Z with `autonomous` label
- **Outcome:** STALLED — worktree conflict caused silent agent exit + retry loop
- **Timeline:**
  - 18:25 — Dispatcher dispatched dev-new. Agent silently exited in ~17s (code 0, no PR, no error comment). Root cause: worktree `feat/aslema-real-captures` already existed (PR #215 merged but worktree not cleaned).
  - 18:30, 18:45 — Dispatcher retried same dead session 3× (MAX_RETRIES=3). Each retry: "no captured opencode sessionID → starting a new opencode session → Agent exited with code: 0" in ~17s.
  - 19:00:16Z — Marked `stalled` after 3 no-PR retries.
  - 22:00 — User removed `stalled` label. Dispatcher re-dispatched. Same silent exit in 22s.
  - 22:02 — Fix: `git worktree remove --force .worktrees/feat/aslema-real-captures` + `git worktree prune` + `git branch -D feat/aslema-real-captures` + cleared dispatch markers at `/run/user/1000/autonomous-m3llm/dispatch-marker-216-*`.
  - Issue #216 now `pending-dev`, waiting for clean re-dispatch.
- **Findings:**
  1. Worktree conflict causes silent agent exit (code 0, no error, no PR) — the agent crashes on startup before reaching any error-reporting step
  2. The dispatcher retries the same dead session ID 3× instead of detecting the worktree conflict
  3. A nudge comment with worktree instructions was posted but never read — the agent crashes before the comment-reading step, and even if it didn't, the skill filters comments for review-feedback tokens (`Review findings:`/`BLOCKING`/`[P1]`), so general human instructions are invisible
  4. PR #215 was merged but the worktree was never cleaned — the pipeline has no post-merge worktree cleanup step

## 10. Bugs

### 10.1 Cron PATH excludes linuxbrew → `gh` not found (FATAL `ADT_CFG_GH_VERSION_TOO_OLD`)

- **Severity**: Blocking (dispatcher can't run)
- **Status**: Fixed (cron entry prepends linuxbrew to PATH)
- **Symptom**: Tick 01:45 FATAL `ADT_CFG_GH_VERSION_TOO_OLD`; tick 01:50 `itp-github.sh:89: gh: commande introuvable`
- **Root cause**: cron's minimal PATH excludes `/home/linuxbrew/.linuxbrew/bin` where `gh` v2.96.0 lives. Setting `REAL_GH` in `autonomous.conf` only fixes the version check, not the actual `gh` invocations in provider scripts (`itp-github.sh` calls `gh` directly, not `$REAL_GH`).
- **Fix**: prepend linuxbrew to PATH in the cron entry itself:
  ```cron
  PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash scripts/dispatcher-tick.sh
  ```
- **Reproduced**: m3llm ticks 01:45, 01:50. Fixed at tick 01:55.

### 10.2 E2E verify script false positive on first review (FIXED, not a stale-worktree issue)

- **Severity**: Medium (one wasted dev-resume cycle)
- **Status**: Fixed — change-scoped `e2e-verify.sh` resolved it
- **Symptom**: First review (23:45:33) ran the pre-fix `e2e-verify.sh` (full pytest, hit pre-existing `__pycache__` collection collision) → E2E gate hard-failed (rc=2) → `reviewing → pending-dev`.
- **Initial wrong diagnosis**: I thought the review wrapper ran the verify script from the stale worktree (created before the fix). **This was incorrect.** The review wrapper runs `bash scripts/e2e-verify.sh` from `PROJECT_DIR` (main branch), not the worktree.
- **Actual root cause**: the first review ran BEFORE the change-scoped fix to `e2e-verify.sh` was committed. The fix was applied between the first review (23:45:33, failed) and the second review (23:59:10, passed). The second review picked up the fixed script from main and the E2E gate passed (`lane_rc=0, evidence_present=1 → gate=pass`).
- **Fix**: rewrote `scripts/e2e-verify.sh` to be change-scoped: `landing/*` → `astro build` + `lint`; `plugins/<area>/*` → pytest on that plugin's `test_unit.py` only; `*.py` fallback → full pytest. Tested on PR #200 → exit 0 (PASS). Second review confirmed the fix worked.
- **Lesson**: the E2E gate is only as good as the verify script. A bad verify script = false positives = wasted dev-resume cycles. The change-scoped approach is the right pattern for monorepos with pre-existing test-infrastructure issues.
- **Reproduced**: m3llm PR #200 (first review 23:45:33 failed, second review 23:59:10 passed with fixed script).

### 10.3 422 self-review-request in token mode (same as looper #598)

- **Severity**: Blocking (review cannot post REQUEST_CHANGES, loop stuck at `pending-dev`)
- **Status**: Open — known limitation of `GH_AUTH_MODE=token`
- **Symptom**: `[autonomous-review] FAILED: "Review Can not request changes on your own pull request"` (HTTP 422)
- **Root cause**: `GH_AUTH_MODE=token` uses baderdean's PAT for both dev (PR creation) and review (review submission). GitHub forbids requesting changes on your own PR. Same root cause as looper's #598/#602/#603 cluster.
- **Fix**: switch to `GH_AUTH_MODE=app` (GitHub App two-token split, INV-79). The wrapper holds full-write App token (label flips, approve, merge); the agent subprocess receives a down-scoped installation token (`pull_requests:read`) that physically cannot approve/merge. This creates the identity separation needed.
- **Reproduced**: m3llm PR #200 (review 23:46:09).

### 10.4 Pre-existing pytest `__pycache__` collection collision (m3llm, NOT a pipeline bug)

- **Severity**: High (blocks E2E gate on any PR that falls through to full pytest)
- **Status**: Pre-existing m3llm test-infrastructure issue — NOT caused by autonomous-dev-team
- **Symptom**: `pytest -m unit` fails during COLLECTION (not execution) with duplicate module basenames: 4 plugin test files share `test_integration.py`/`test_unit.py` across `plugins/tools/flashcards/`, `gardener/`, `openstreetmap/`, `tunisian_news/`. pytest imports the first `test_integration` module it finds (flashcards) and rejects the others as mismatches.
- **Root cause**: m3llm's plugin test files don't use unique module names. `--import-mode=importlib` mitigates but the collection still errors on basename collision.
- **Impact**: any PR that doesn't touch a specific plugin (e.g. landing-only PRs) falls through to the full pytest fallback, which hits this collision. The E2E gate then hard-fails on a pre-existing issue unrelated to the PR.
- **Fix (m3llm side)**: rename the duplicate test files to be unique per plugin (e.g. `test_flashcards_integration.py`, `test_gardener_unit.py`), OR add `conftest.py` per plugin with `pythonpath` isolation.
- **Reproduced**: m3llm PR #200 (landing-only PR, fell through to full pytest, hit collision).

### 10.5 E2E verify script runs in repo root, not PR worktree (false negative)

- **Severity**: High (gate passes without verifying PR code)
- **Status**: Open — verify-script contract gap
- **Symptom**: Third review run (23:59:05) with the fixed change-scoped verify script produced "No changes detected against origin/main" → exit 0 → gate=pass. The verify script ran `git diff origin/main...HEAD` in the repo root (on `main`), where HEAD == origin/main, so the diff is empty.
- **Root cause**: the review wrapper runs `bash scripts/e2e-verify.sh $PR_NUMBER` but does NOT `cd` into the PR's worktree/checkout first. The verify script inherits the repo root as CWD. `git diff origin/main...HEAD` in the repo root finds nothing because the repo root is on `main`.
- **Impact**: the E2E gate passes without verifying the PR's actual code. This is a false negative — the gate says "pass" but nothing was verified. Worse than the false positive (§10.2) because it's silent.
- **Fix**: the verify script contract needs a defined CWD. Either (a) the review wrapper should `cd` into the PR's worktree before running E2E_COMMAND, or (b) the verify script should `git fetch origin pull/$PR_NUMBER/head && git checkout FETCH_HEAD` before diffing. Option (a) is cleaner but requires a wrapper change; option (b) is a verify-script workaround.
- **Reproduced**: m3llm PR #200 (third review run, 23:59:05).

### 10.6 compozy writes code but doesn't commit/branch/PR (by design)

- **Severity**: Medium (human must do 5 manual git/gh steps to ship)
- **Status**: By design — compozy has no forge integration
- **Symptom**: compozy task `reduce-maptocomplexity` completed (exit=0, status=completed, acceptance criteria marked done), code refactored + tests pass + lint/prettier clean. BUT changes are uncommitted in the working tree. No branch, no PR, no merge.
- **Root cause**: compozy has no GitHub issue polling, no PR creation, no auto-merge. It's a task runner, not a forge-aware dev factory. The `cy-final-verify` skill tells the agent to run the verify command and self-report, but nothing commits the result.
- **Impact**: every compozy task requires human intervention to ship: `git checkout -b <branch>`, `git add`, `git commit`, `git push`, `gh pr create`, `gh pr merge`. This is ≥5 manual steps per task — worse than looper's 3-5.
- **Fix**: none within compozy. Would need a wrapper script that watches `.compozy/tasks/*/` for completed status and auto-commits + PRs. This is the "manual merge" limitation confirmed in practice.
- **Reproduced**: leadminer issue #2831 (task completed, code uncommitted).

### 10.8 Dev agent copy-pasted issue body instead of rewriting in brand voice (QUALITY GAP)

- **Severity**: Medium (shipped low-quality user-facing copy that doesn't match the project's defined voice)
- **Status**: Open — agent didn't follow project writing guidelines
- **Symptom**: Run #1 (#199) asked the agent to add an FAQ entry: "Dans les FAQ, rajoute l'information de l'architecture de m3llm **en la réécrivant de façon attractive**." The agent copy-pasted the issue body nearly verbatim into `landing/src/i18n/content.ts` — a 150-word wall of technical jargon ("best-of-breed", "routeur intelligent de modèles", "base de connaissances RAG docling", "STT local arabophone") that reads like a tech blog, not a Tunisian café server.
- **Expected voice** (from `config/SYSTEM_PROMPT.md`): "Concis, expressif. Humilité en apparence, sagesse qui émerge." The existing FAQ entries follow this — short, warm, 3-4 sentences max (e.g. "Oui, sur l'essentiel. m3llm est souverain : pas d'alignement à la politique étrangère américaine..."). The agent's entry is 5x longer than every other FAQ answer and uses none of the brand's warmth.
- **Root cause**: the autonomous-dev skill + the dev agent's prompt context did not include the project's writing guidelines. The agent had access to `AGENTS.md` (which defines plugin architecture, coding rules, E2E procedure) and `config/SYSTEM_PROMPT.md` (which defines the m3llm voice for chat responses), but neither document explicitly governs **landing page copy**. The agent treated the issue body as the source of truth and formatted it rather than rewriting it. The review agent (opencode) also didn't catch this — it reviewed the diff for correctness (email obfuscation, build pass) but not for brand-voice compliance.
- **Impact**: user-facing copy on m3llm.cafe doesn't match the brand voice. The FAQ is the first thing visitors read. A jargon wall undermines the "Tunisian café server" identity. The issue explicitly asked for an attractive rewrite; the agent delivered a formatted paste.
- **Why the review gate didn't catch it**: the E2E gate verifies behavior (build passes, tests pass, email obfuscation works) — it has no concept of copy quality or brand voice. The review fan-out (opencode agent) reviewed the diff for code correctness, not for writing quality. **Neither gate checks user-facing copy against the project's voice guidelines.** This is a class of quality gap that no current gate covers.
- **Fix (suggested)**:
  1. **Short-term**: add a "copy review" step to the review fan-out prompt — instruct the review agent to check user-facing text against `config/SYSTEM_PROMPT.md` voice rules and existing copy patterns (e.g. compare new FAQ entry length/tone against the 8 existing entries).
  2. **Medium-term**: add a project-level writing guide for landing copy (a `landing/WRITING.md` or a section in `AGENTS.md`) that defines the voice, max length per FAQ entry, banned jargon, and reference examples. The agent needs an explicit contract for non-chat copy.
  3. **Structural**: add a lint-style check to the E2E verify script for landing copy — e.g. flag FAQ answers >80 words, flag banned terms ("best-of-breed", "routeur intelligent"), flag entries that deviate >2x from the median answer length. This makes copy quality a programmatic gate, not a prompt.
- **Reproduced**: m3llm PR #200 (Run #1, issue #199). The FAQ entry shipped to production on m3llm.cafe.

### 10.9 E2E config mismatch — `ADT_CFG_E2E_MODE_MISMATCH` (ansible-supabase)

- **Severity**: Blocking (all reviews fail)
- **Status**: Fixed — cleared `E2E_COMMAND` and `E2E_COMMAND_EVIDENCE_PARSER` to empty string
- **Symptom**: ansible-supabase reviews all failed with `ADT_CFG_E2E_MODE_MISMATCH`. The conf had `E2E_ENABLED=false` + `E2E_MODE=""` but left `E2E_COMMAND='bash scripts/e2e-verify.sh ${PR_NUMBER}'` and `E2E_COMMAND_EVIDENCE_PARSER="bash scripts/e2e-evidence.sh"` populated (copied from m3llm). The wrapper detects command-mode config present under mode=none.
- **Fix**: set `E2E_COMMAND=""` and `E2E_COMMAND_EVIDENCE_PARSER=""` (conf lines 1230, 1264).
- **Reproduced**: ansible-supabase #82, #87, #89 first review attempts (2026-07-26).

### 10.10 Wrong-PR review from obsolete looper spec PRs (ansible-supabase)

- **Severity**: High (reviews the wrong code)
- **Status**: Fixed — closed obsolete looper spec PRs #91, #92
- **Symptom**: #87 review found PR #92 (looper spec, branch `looper/planner/87-...`) instead of PR #96 (autonomous implementation). Both PRs referenced issue #87; the wrapper picks the lowest-numbered.
- **Root cause**: looper and autonomous-dev-team both create PRs referencing the same issue. The review wrapper's PR selection (lowest number) picks the looper spec PR, which is a markdown spec, not code.
- **Fix**: close obsolete looper spec PRs with explanatory comments. Going forward, remove looper labels before tagging `autonomous` to avoid dual-PR ambiguity.
- **Reproduced**: ansible-supabase #87 first review (2026-07-26 18:00).

### 10.11 Dispatch marker stuck at XDG_RUNTIME_DIR (ansible-supabase)

- **Severity**: Medium (blocks re-dispatch for 10 min)
- **Status**: Fixed — `rmdir` the marker directories
- **Symptom**: #87/#89 reviews wouldn't re-dispatch despite the dispatcher log saying "Dispatched: 87 89". The dispatch markers are **directories** at `/run/user/1000/autonomous-ansible-supabase/dispatch-marker-<issue>-<mode>` (XDG_RUNTIME_DIR), TTL=600s. They persisted and blocked re-dispatch.
- **Root cause**: the dispatch markers live at `$XDG_RUNTIME_DIR/autonomous-<PROJECT_ID>/dispatch-marker-<issue>-<mode>` (directories, not files). The `.attempt-review-*` files in `$HOME/.local/state/autonomous-<PROJECT_ID>/lanes/` are a different mechanism. Clearing the wrong one doesn't unblock dispatch.
- **Fix**: `rmdir /run/user/1000/autonomous-ansible-supabase/dispatch-marker-87-review dispatch-marker-89-review`.
- **Reproduced**: ansible-supabase #87, #89 (2026-07-26 18:00–18:15).

### 10.12 Review agent posts no verdict comment — model-dependent gate (CRITICAL)

- **Severity**: **CRITICAL** — the review gate silently fails when the review agent produces no output
- **Status**: Open — model-dependent, not a pipeline bug
- **Symptom**: #87 second review (18:15): opencode review agent (glm-5.2, session d06141cc) exited code 0 at 18:17:01 but posted ZERO comments to the PR or issue. The wrapper polled 6×5s for a comment containing 'Review Session' + verdict marker → found nothing → `INV-78: verdict-source=none; resolved unavailable` → `INV-144: unavailable review round 1/3` → sent to pending-dev.
- **Root cause**: the opencode review agent (glm-5.2) doesn't reliably execute the autonomous-review skill's comment-posting step. The agent exited cleanly (code 0) but produced no PR/issue comments. This is NOT wrong format — it's zero output. Contrast with #82 where the same model/config produced a clean verdict.
- **Impact**: the review gate is both agent-dependent (Run #2 main-push bypass) AND model-dependent (glm-5.2 doesn't reliably post verdict comments). The wrapper's 30s verdict-poll (6×5s) is too short, and the format instructions aren't followed reliably by glm-5.2. This is a NEW class of failure: the gate fails not because the agent bypasses it but because the review agent silently produces no output.
- **Fix (suggested)**: (a) switch `AGENT_REVIEW_MODEL` to a more instruction-following model (e.g. claude-sonnet-4-6) for the review fan-out. (b) Lengthen the verdict-poll window. (c) Add a fallback: if the review agent exits code 0 with no verdict comment, treat as FAIL (not unavailable) and re-dispatch with a stricter prompt. (d) Harden the autonomous-review skill prompt to make the verdict-comment step non-negotiable.
- **Reproduced**: ansible-supabase #87 second review (2026-07-26 18:15–18:17).

### 10.13 Branch protection blocks merge-helper.sh (ansible-supabase)

- **Severity**: Medium (merge-helper can't auto-merge)
- **Status**: Open — merge-helper needs `--admin` flag or branch protection adjustment
- **Symptom**: `gh pr merge 95 --squash --delete-branch` failed with "base branch policy prohibits merge" (branch protection on ansible-supabase main). Merged with `--admin`. But `merge-helper.sh` doesn't pass `--admin`, so it can't auto-merge on repos with branch protection.
- **Root cause**: ansible-supabase main has branch protection (the structural guardrail §10.7 recommended). This is correct for blocking direct pushes, but it also blocks the merge-helper workaround.
- **Fix (suggested)**: (a) add `--admin` to `merge-helper.sh`'s `gh pr merge` call. (b) Or: configure branch protection to allow the bot account to merge without admin override. (c) Or: use `GH_AUTH_MODE=app` with a GitHub App that has merge permissions on protected branches.
- **Reproduced**: ansible-supabase #82 merge (2026-07-26 18:00).

### 10.14 Dev agent committing real files into scripts/ destroys symlink-based install (CRITICAL)

- **Severity**: Critical
- **Status**: Open
- **Symptom**: The #82 dev agent committed `verify-secure-mcp.py` into the `scripts/` directory. Since `scripts/` was a symlink to `.agents/skills/autonomous-dispatcher/scripts/`, the commit replaced the symlink with a real directory containing only `verify-secure-mcp.py`, destroying all 20+ script symlinks + `autonomous.conf`. The dispatcher cron broke for ~2 hours.
- **Root cause**: The skills install pattern uses a whole-dir symlink (`scripts/` → `.agents/skills/autonomous-dispatcher/scripts/`). When a dev agent commits a new file into `scripts/`, git replaces the symlink with a real directory. This is a structural flaw in the symlink-based install pattern — the dev agent's worktree has the symlink resolved as a real directory by git.
- **Impact**: The entire pipeline stops running. All in-flight issues go `stalled`.
- **Fix applied**: Re-symlinked all individual scripts + subdirs into the existing `scripts/` dir (alongside the real file). This is fragile — a future commit could break it again.
- **Recommended fix**: Use `--copy` mode instead of symlinks for `scripts/` (the skills CLI supports `--copy`), OR add `scripts/` to `.gitignore` so dev agents can't commit into it, OR use individual file symlinks instead of a whole-dir symlink (the fix applied, but should be the default install pattern).

### 10.15 Worktree conflict causes silent agent exit + retry loop → stall (CRITICAL)

- **Severity**: Critical
- **Status**: Open
- **Symptom**: When a worktree for the issue's branch already exists (e.g. PR merged but worktree not cleaned, or PR still open), the dev agent silently exits in ~20s (code 0, no PR, no error comment). The dispatcher retries 3× → `stalled`.
- **Root cause**: The dev agent tries to create a worktree with `git worktree add .worktrees/<branch> -b <branch>`, which fails if the worktree or branch already exists. The agent crashes on startup before reaching any error-reporting step. The dispatcher doesn't detect the worktree conflict and retries the same dead session.
- **Impact**: Any issue whose PR was merged but worktree not cleaned, or whose PR is still open, will stall on the next dev dispatch.
- **Affected runs**: m3llm #216 (PR #215 merged, worktree not cleaned), ansible-supabase #87 (PR #96 open, worktree exists)
- **Recommended fix**: (1) Add post-merge worktree cleanup to the pipeline (after PR merge, remove `.worktrees/<branch>` + prune + delete branch). (2) Detect worktree creation failure and report it as a blocker comment instead of silent exit. (3) In dev-resume mode, reuse existing worktree instead of trying to create a new one.

### 10.16 dev-new vs dev-resume dispatch confusion when worktree already exists (Medium)

- **Severity**: Medium
- **Status**: Open
- **Symptom**: When an issue has an OPEN PR (worktree exists) and is sent back to `pending-dev` (e.g. review failed), the dispatcher sends `dev-new` (tries to create new worktree) instead of `dev-resume` (reuses existing). This causes the worktree conflict from §10.15.
- **Root cause**: The label state machine sends `dev-new` after `pending-dev` regardless of whether a worktree/PR already exists. The dispatcher doesn't check for existing worktrees before choosing dev-new vs dev-resume.
- **Impact**: Issues with open PRs that fail review will loop: review fails → pending-dev → dev-new (worktree conflict) → pending-dev → ... → stall.
- **Recommended fix**: The dispatcher should check for an existing worktree or open PR before choosing dev-new vs dev-resume. If a worktree exists, use dev-resume.

### 10.17 Verdict-poll budget tied to E2E_MODE — 30s for E2E_MODE=none (CRITICAL)

- **Severity**: Critical
- **Status**: Fixed (ansible-supabase) / Open (upstream)
- **Symptom**: Repos with `E2E_MODE=none` (no E2E tests) get only 30s (6 attempts × 5s) for the review agent to post a verdict comment. The review agent (opencode) typically needs 1-6 minutes to run and post. After 30s, the wrapper declares `INV-78: verdict-source=none; resolved unavailable` → after 3 rounds → `INV-144: review-unavailable-cap breaker TRIPPED` → `stalled`.
- **Root cause**: The `_resolve_verdict_poll_attempts()` function in `lib-review-poll.sh:55` returns the legacy floor (6 attempts = 30s) when `E2E_MODE != "command"`. When `E2E_MODE == "command"`, it returns `ceil(E2E_COMMAND_TIMEOUT_SECONDS / 5)` = 720 attempts = 1h. The budget is tied to E2E mode, not to the review agent's actual needs.
- **Affected runs**: ansible-supabase #87, #89, #99 — all stalled because the review agent couldn't post a verdict in 30s. On m3llm (E2E_MODE=command), the review agent gets 1h and succeeds.
- **Fix applied (ansible-supabase)**: Set `E2E_MODE=command` with a no-op `E2E_COMMAND='true'` and `E2E_COMMAND_EVIDENCE_PARSER='echo "<!-- e2e-evidence: complete sha=\"${PR_HEAD_SHA}\" -->"'`. This gives the full 720×5s=1h verdict-poll budget without running real E2E. ansible-supabase has no E2E tests, so the command is a no-op.
- **Recommended upstream fix**: Decouple the verdict-poll budget from E2E_MODE. Add a `VERDICT_POLL_TIMEOUT_SECONDS` config key that defaults to 300s (5 min) regardless of E2E mode. The E2E-scaled budget should be a max(), not a replacement.

### 10.18 4h dev timeout hit on complex multi-step tasks (Medium)

- **Severity**: Medium
- **Status**: Open
- **Symptom**: The m3llm #216 dev agent hit the 4h `AGENT_TIMEOUT` while rendering tool-output images (chess board, flashcards, map) via headless chromium. The agent was doing real work but ran out of time. After timeout (exit code 124), the dispatcher retried but the PR HEAD had already consumed its one bounded self-heal → marked `stalled`.
- **Root cause**: Complex tasks that involve rendering images via headless browser, running multiple API captures, and doing code review can exceed 4h. The timeout is a hard cap with no checkpoint/resume mechanism.
- **Impact**: Issues requiring long-running tasks (image rendering, multi-step E2E, large refactors) will stall.
- **Recommended fix**: (1) Increase `AGENT_TIMEOUT` to 8h for projects with complex tasks. (2) Add a checkpoint mechanism so the agent can resume from where it left off after a timeout. (3) Break complex issues into smaller sub-issues.

### 10.7 Dev agent pushed directly to main, bypassing review gate (FLOW VIOLATION)

- **Severity**: **CRITICAL** — the entire review/E2E gate pipeline was bypassed
- **Status**: Open — agent behavioral bug, not a pipeline bug
- **Symptom**: Run #2 (#201) dev agent committed `92b7529` directly to main and pushed at 00:21:32Z. No worktree, no PR, no review, no E2E gate. The `Fixes #201` auto-closed the issue. Browser E2E ran post-hoc on production (after sync_plugins.yml deployed), not as a pre-merge gate.
- **Root cause**: the autonomous-dev skill instructs the agent to create a worktree + PR, but enforcement is prompt-based, not structural. The agent decided to "fix it directly" — possibly influenced by the issue body "use account: ops@ankaboot.io and AGENTS.md to fix it" which reads as "go fix it", or by the sparse issue body (no `## Requirements`/`## Acceptance Criteria` checkboxes). The pipeline has no structural guardrail preventing a push to main.
- **Impact**: **the gate only works if the agent chooses to use it.** Run #1 (#199) followed the full pipeline (worktree → PR → review → E2E gate → fix → re-review → pass → merge). Run #2 (#201) skipped everything. Same tool, same config, same cron — different agent behavior. This is the single most important POC finding: the review/E2E gate is agent-dependent, not structural. A determined or confused agent can bypass it entirely by pushing to main.
- **Fix (structural)**: (a) protect `main` with branch protection rules requiring PR + status checks — GitHub would reject the direct push. (b) Use `GH_AUTH_MODE=app` with a down-scoped agent token that lacks `contents:write` on main (the agent can create branches but cannot push to main). (c) Harden the autonomous-dev skill prompt to make the worktree+PR flow non-negotiable. Option (a) is the simplest and most reliable — branch protection is a GitHub-native structural guardrail, not a prompt.
- **Reproduced**: m3llm issue #201 (Run #2).

## 11. Workarounds applied

### 11.1 merge-helper.sh cron — auto-merge approved PRs (works around §10.3 422)

**Problem**: In `GH_AUTH_MODE=token`, the review wrapper's `gh pr review --approve` 422s ("can not approve your own pull request") because the PR author and reviewer share the same GitHub identity (baderdean's PAT). The wrapper then falls back to "manual merge required" WITHOUT calling `gh pr merge` — even though GitHub DOES allow merging your own PR (only approval is blocked).

**Workaround**: `scripts/merge-helper.sh` (added 2026-07-26) is a cron-driven script that:
1. Lists open issues labeled `approved` (set by the review wrapper when verdict=pass).
2. For each, finds the open PR with `Closes #<issue>` in its body.
3. Checks the PR is OPEN + MERGEABLE.
4. Runs `gh pr merge --squash --delete-branch`.

**Cron entry** (runs every 5 min, same PATH prefix as dispatcher-tick):
```cron
*/5 * * * * cd /home/badreddine/Projects/ankaboot-source/m3llm && \
  PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH" \
  bash scripts/merge-helper.sh >> /tmp/m3llm-merge-helper.log 2>&1
```

**Idempotent**: filters to OPEN PRs, checks MERGEABLE state, re-running on already-merged PR is a no-op.

**Limitation**: this is a token-mode workaround. The proper fix is `GH_AUTH_MODE=app` (GitHub App two-token split, INV-79) which gives identity separation — the wrapper holds full-write App token (approve + merge), the agent subprocess gets a down-scoped token (cannot approve/merge). When App mode is configured, `merge-helper.sh` becomes unnecessary (the wrapper's own `gh pr merge` will work).

### 11.2 E2E verify script false negative — PR-head checkout (FIXED)

**Problem**: The change-scoped `e2e-verify.sh` ran from `PROJECT_DIR` (main branch). When it did `git diff origin/main...HEAD`, HEAD was main (not the PR branch), so it found no changes → exit 0 → gate=pass WITHOUT verifying the PR's actual code. False negative: the gate passed but nothing was verified.

**Root cause**: the review wrapper (`autonomous-review.sh:1831-1833`) exports `PR_NUMBER` and `PR_HEAD_SHA` and invokes `bash scripts/e2e-verify.sh <PR_NUMBER>` from `PROJECT_DIR` on main, but the verify script assumed HEAD was the PR branch.

**Fix applied** (`scripts/e2e-verify.sh`):
- Added `trap cleanup EXIT` that restores the original branch on exit.
- Before diffing: `git fetch -q origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"` then `git checkout -q "$PR_HEAD_SHA"`. Falls back to HEAD with a WARN if checkout fails.
- After diffing/running checks: the EXIT trap checks out `ORIG_BRANCH` (captured at script start), so the repo is left on main.

**Verification** (2026-07-26, against merged PR #200 sha=8e4b362):
- `bash -n scripts/e2e-verify.sh` → SYNTAX OK
- Manual run with `PR_NUMBER=200 PR_HEAD_SHA=8e4b3627...`:
  - ORIG_BRANCH captured = `main`
  - `git fetch origin pull/200/head:pr-200` → OK
  - `git checkout 8e4b362` → OK (HEAD now at PR head)
  - `git diff --name-only origin/main...HEAD` → 4 files: `docs/test-cases/faq-architecture.md`, `landing/src/components/ObfuscatedEmail.tsx`, `landing/src/components/blocks/FAQ.tsx`, `landing/src/i18n/content.ts` ✅ (all PR #200's actual changes)
  - EXIT trap restored HEAD to `main` (465dd76) ✅

**Status**: fixed. The E2E gate now sees the PR's actual changes before deciding which lanes to run. The gate is trustworthy on the change-scoped path.

## 12. Decision

> TODO — after sufficient runs, evaluate against the dev-factory-A→Z criteria.
>
> **Key questions this head-to-head POC must answer:**
> 1. **Does the E2E verification step actually gate merge with a real verify script?** (looper's `UNVERIFIABLE` was non-blocking — is autonomous-dev-team's dual-signal gate different?)
> 2. **Does compozy's LLM-judge verify ship bugged code?** (Same failure mode as looper — `cy-final-verify` is a prompt, not a programmatic gate. If the agent lies, the host trusts the verdict.)
> 3. **Does the behavior gate matter?** (Head-to-head: does autonomous-dev-team catch bugs that compozy ships?)
> 4. **Does OpenCode integration work end-to-end** (plan → dev → review → fix → merge) without manual intervention? (autonomous-dev-team: automatic; compozy: manual trigger + manual merge)
> 5. **How many manual interventions per loop?** (looper: 3-5; target: ≤1; autonomous-dev-team: 0 if cron works; compozy: ≥2 by design — manual trigger + manual merge)
> 6. **Does GitLab work for tyre-call?** (looper couldn't — autonomous-dev-team has first-class GitLab; compozy has no forge awareness)
> 7. **Does the GitHub App mode solve the 422 identity problem?** (looper's single-identity → 3 bugs; autonomous-dev-team's two-token split; compozy: no review-request → no 422 risk but no auto-merge either)
>
> **Landscape finding (from @librarian + @explorer)**: autonomous-dev-team is the ONLY open-source tool found with a real behavior-verified merge gate. Every other tool (looper, AutoShip, compozy) uses LLM-judge verification — the exact failure mode that sank looper. If autonomous-dev-team's gate works in practice, it may be the only viable Option A tool. If it doesn't, Option C (build from scratch) becomes the default.

### Run #2 critical insight (2026-07-26)

**The E2E/review gate is agent-dependent, not structural.** Run #2 (#201) proved that a dev agent can bypass the entire review pipeline by pushing directly to main — no worktree, no PR, no review, no E2E gate. The `Fixes #201` auto-closed the issue. Same tool, same config, same cron as Run #1 (#199) which followed the full pipeline. The difference was agent behavior, not pipeline configuration.

**Implication for the decision**: the gate mechanism (§10.2, §10.5, the dual-signal E2E+review) is sound WHEN the agent goes through the PR flow. But the pipeline has no structural guardrail preventing a direct push to main. A determined or confused agent can ship unreviewed code to production. **This is the same class of failure as looper's "review gate ships bugged code" — the gate exists but doesn't structurally block bad behavior.**

### Run #3/#4 critical insights (2026-07-26)

**Three classes of gate failure identified:**

1. **Agent-dependent bypass** (Run #2, §10.7): the dev agent pushes directly to main, skipping the PR flow entirely. The gate only works if the agent chooses to use it. Fix: branch protection on main (structural).

2. **Model-dependent review silence** (Run #4, §10.12): the review agent (glm-5.2) exits code 0 but posts zero comments. The wrapper can't find a verdict → treats as unavailable → sends back to dev. The gate fails not because it's bypassed but because the reviewer silently produces no output. Fix: switch review model to a more instruction-following one, or harden the review skill prompt.

3. **Wrong-PR review** (Run #4, §10.10): the review wrapper picks the lowest-numbered PR referencing the issue. Obsolete looper spec PRs shadow autonomous implementation PRs. Fix: close obsolete spec PRs, or remove looper labels before tagging `autonomous`.

**Scorecard so far (4 runs):**
- Run #1 (m3llm #199): ✅ full pipeline (worktree → PR → review → E2E gate → fix → re-review → pass → 422 → manual merge)
- Run #2 (m3llm #201): 🚨 FLOW VIOLATION (direct push to main, no PR, no review)
- Run #3 (m3llm #206): ⚠️ PR created but not merged (issue auto-closed via commit, stale labels)
- Run #4 (ansible-supabase #82/#87/#89): ⚠️ 1/3 merged (#82 ✅, #87 + #89 stuck in review dispatch loop due to model-dependent review silence)

**Autonomous flow coverage**: 2/4 runs reached merge (Run #1 with manual merge, Run #4 #82 with --admin). 1/4 bypassed the gate entirely (Run #2). 1/4 produced a PR but didn't merge (Run #3). 2/4 stuck in review failure loop (Run #4 #87/#89).

**Manual interventions per loop**: Run #1: 1 (manual merge due to 422). Run #2: 0 (bypassed everything). Run #3: 0 (auto-closed, no merge). Run #4 #82: 1 (--admin merge). Run #4 #87/#89: 2+ (close obsolete PRs, clear dispatch markers, still stuck). Average: ~1.5 for the runs that followed the pipeline, 0 for the one that bypassed it.

**Open questions for the decision**:
- Does switching `AGENT_REVIEW_MODEL` to claude-sonnet-4-6 fix the review silence (§10.12)?
- Does `GH_AUTH_MODE=app` (two-token split) solve both the 422 (§10.3) AND the branch-protection merge block (§10.13)?
- Does branch protection on m3llm main prevent the Run #2 bypass (§10.7)?
- Is the review gate trustworthy enough to be a merge gate, or does it need a programmatic backup (like looper's missing post-deploy verify)?

### Run #5 + Run #4 update critical insights

**4-run scorecard updated (5 runs):**
| Run | Issue | Repo | Reached merge? | Gate held? | Manual interventions |
|-----|-------|------|---------------|------------|---------------------|
| #1 | #199 | m3llm | ✅ (manual merge) | ✅ (review caught real bug) | 2 (E2E fix, manual merge) |
| #2 | #201 | m3llm | ❌ (pushed to main) | ❌ (bypassed) | 1 (revert main push — not done) |
| #3 | #206 | m3llm | ❌ (PR not merged) | ⚠️ (review ran, stale labels) | 2 (worktree cleanup, stale labels) |
| #4 | #82/#87/#89 | ansible-supabase | 1/3 (#82 merged with --admin) | 1/3 (#82 held, #87/#89 broken) | 5+ (E2E config, wrong PR, markers, dispatcher rebuild, --admin merge) |
| #5 | #216 | m3llm | ❌ (stalled) | N/A (never reached review) | 1 (worktree cleanup) |

**Autonomous flow coverage:** 2/5 reached merge (40%), 1/5 bypassed the gate entirely, 2/5 stalled. Of the 2 that merged, both required manual intervention (merge-helper.sh or --admin flag).

**New structural findings:**
1. **The symlink-based install is fragile** (§10.14) — a dev agent committing into `scripts/` destroys the entire pipeline. This is a structural flaw in the install pattern, not a bug in the tool.
2. **The pipeline has no post-merge worktree cleanup** (§10.15) — merged PRs leave worktrees that cause future stalls.
3. **The dev↔review loop is a dead trap** (§10.16 + §10.12) — once an issue has an open PR and the review gate fails (model silence), the issue will loop dev-new (worktree conflict) → pending-dev → ... → stall. There is no escape without manual intervention.
4. **The gate is agent-dependent, model-dependent, AND install-pattern-dependent** — three independent failure modes, any one of which breaks the pipeline.

**Open questions for decision:**
1. Should we switch to `--copy` install mode to avoid §10.14?
2. Should we add post-merge worktree cleanup to the pipeline?
3. Should we swap `AGENT_REVIEW_MODEL` to a more instruction-following model (e.g. claude-sonnet) to fix §10.12?
4. Is the 40% merge rate with 100% manual intervention acceptable for a "dev factory A→Z"?

### Stall root cause analysis + best practices

**Stall root causes (5 runs, 7 stalls):**

| Run | Issue | Stall cause | Bug |
|-----|-------|------------|-----|
| #5 | m3llm #216 | 4h timeout during image rendering | §10.18 |
| #4 | ansible-supabase #87 | Wrong-PR review (closed PR #92) + verdict-poll 30s | §10.10, §10.17 |
| #4 | ansible-supabase #89 | Verdict-poll 30s (E2E_MODE=none) | §10.17 |
| #4 | ansible-supabase #99 | Verdict-poll 30s (E2E_MODE=none) | §10.17 |
| #5 | m3llm #216 (retry) | Worktree conflict (PR #224 CONFLICTING) | §10.15 |
| #4 | ansible-supabase #87 (retry) | Worktree conflict (PR #96 OPEN) | §10.15 |
| #4 | ansible-supabase #87 (2nd retry) | opencode-go 403 (provider auth) | §10.17 (misdiagnosed as model-dependent) |

**Best practices to avoid stalls:**

1. **Set `E2E_MODE=command` even for repos without E2E tests.** Use a no-op command (`E2E_COMMAND='true'`) to get the full 1h verdict-poll budget. The 30s default for `E2E_MODE=none` is too short for any review agent. (§10.17)

2. **Clean up worktrees after PR merge.** The pipeline has no post-merge worktree cleanup. After a PR is merged, manually run `git worktree remove --force .worktrees/<branch> && git worktree prune && git branch -D <branch>`. (§10.15)

3. **Close obsolete PRs that reference the issue.** The review wrapper picks the lowest-numbered PR that references the issue, regardless of PR state. Close obsolete looper spec PRs to avoid the wrong-PR review bug. (§10.10)

4. **Monitor the opencode provider auth.** opencode silently exits 0 with no output when the provider returns 403. There is no error message, no stderr. Smoke-test the provider before each dispatch cycle: `echo "Reply with: PONG" | opencode run --model <provider/model> --title smoke --auto`. (§10.17 misdiagnosis)

5. **Increase `AGENT_TIMEOUT` for complex tasks.** The default 4h is insufficient for tasks involving image rendering, multi-step E2E, or large refactors. Set to 8h for projects with complex tasks. (§10.18)

6. **Use `--copy` install mode, not symlinks.** The symlink-based install (`scripts/` → `.agents/skills/autonomous-dispatcher/scripts/`) is destroyed when a dev agent commits a file into `scripts/`. Use `npx skills add --copy` or add `scripts/` to `.gitignore`. (§10.14)

7. **Clear dispatch markers when unblocking.** Dispatch markers live at `$XDG_RUNTIME_DIR/autonomous-<PROJECT_ID>/dispatch-marker-<issue>-<mode>` (directories, 600s TTL). Clear them with `rmdir` when manually unblocking an issue. (§10.11)

8. **Don't let the dev↔review loop exhaust MAX_RETRIES.** Once an issue has an open PR and the review gate fails, the issue will loop: review fails → pending-dev → dev-new (worktree conflict) → pending-dev → ... → stall. Intervene before MAX_RETRIES=3 is exhausted: either fix the review gate (§10.17) or manually review and merge. (§10.16)

**Required fix before this tool can be trusted as a dev factory**: enable GitHub branch protection on `main` requiring PR + status checks. This is a GitHub-native structural guardrail that makes the direct push impossible — the agent would be forced to create a PR. Combined with `GH_AUTH_MODE=app` (down-scoped agent token that cannot push to main), this closes the bypass structurally. Without branch protection, the gate is a convention, not a guarantee.