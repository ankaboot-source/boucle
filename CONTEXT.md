# CONTEXT.md — Boucle project context

> **Maintenance** — This document captures the context, identity, tech stack
> and constraints of boucle. Any change to scope, stack, or constraints must
> update it. See [AGENTS.md](AGENTS.md) for contribution conventions.

## 1. Identity

Boucle is a **loop engineering** tool for **Product Builders**. It turns a
forge issue (GitLab, soon GitHub) into a deployed product, without
continuous human intervention — the human stays in the loop at decision
points (spec validation, MR approval).

Boucle **lowers the barrier to entry** for building websites and applications,
while integrating with **developer CI/CD practices**. Unlike SaaS platforms
that lock the user into a closed UI, boucle lives in the forge — no new
frontend, no server to maintain, no computer to keep running.

Boucle **frees the user from interactive chats** that demand a permanent
presence in front of the screen — a dynamic that is often toxic. Work
happens asynchronously, driven by labels and comments.

## 2. Features

- **Self-maintaining documentation** — boucle keeps its charter docs
  (`ARCHITECTURE.md`, `AGENTS.md`, `CONTEXT.md`, `DESIGN.md`, `LOOP.md`) in
  sync with the code as part of each work cycle. The triage identifies
  impacted docs, the worker updates them in the same MR, the reviewer
  verifies doc conformance and completeness, and the e2e verifies docs
  match production reality. A doc that drifts from the system it describes
  is treated as a bug.

## 3. Target audience

- **Product Builders**: those who build products (websites, applications) but
  are not necessarily full-time developers.
- Refinement (triage) and end-to-end testing make boucle accessible to those
  who do not master the entire CI/CD chain.
- The human stays in the loop: spec validation (readable TL;DR), MR approval.

## 4. Tech stack

| Layer | Technology |
| --- | --- |
| Forge | GitLab (MVP), GitHub (planned) |
| CI/CD | GitLab CI (8 stages) |
| AI agents | opencode (4 agents: triage, worker, reviewer, e2e) |
| Models | minimax-m3 (triage, worker), glm-5.2 (reviewer), kimi-k2.7-code (e2e) — open-weight preference |
| Coding agent | pi (`.pi/agents/*.md`) |
| Knowledge graph | codebase-memory-mcp |
| Deployment | Cloudflare Pages (wrangler) — MVP, other targets planned |
| Tests | bats (shell), shellcheck, shfmt |
| Hooks | pre-commit |

Boucle is designed to be **forge-agnostic and deploy-agnostic**. Current
limitations (GitLab only, Cloudflare only) are due to the MVP, not
definitive choices.

## 5. Philosophy

### Open-source and open-weight

Boucle favors **open-source** in the spirit of libre — not merely technicist
open-source. This includes a **preference for open-weight models**: boucle's
agents use accessible models, in the spirit of technological sovereignty and
accessibility.

### Technological ethics

Technology must not serve:

- **autonomous weapons** (weapon systems without human supervision),
- **mass surveillance** (population-wide cyber-surveillance),
- **human rights violations** and war crimes,
- **colonialism** and recolonization,
- **environmental destruction** (ecocide),
- **genocide**.

This ethic is not a technical constraint but a **guiding principle**.
Contributions to boucle must align with this line.

## 6. Governance

- **ankaboot team**: decides on evolution (new features, architectural
  changes, breaking changes).
- **External contributors**: can propose via issues and MRs. The ankaboot
  team validates.
- **Contribution policy**: open to all. Anyone can contribute via MRs.
  Review is required, no restriction on who can propose.

## 7. Technical constraints

- **Fail-open**: auto-update must NEVER block the pipeline. Any error →
  warning + exit 0. A stale version is always better than a broken pipeline.
- **Upstream-first**: fix in boucle FIRST, then update consumer, then
  remediate data. You must NEVER patch a consumer to work around a boucle
  defect.
- **Label-driven**: the state machine is driven by forge labels. No
  external database, no separate state API. Labels are the source of truth.
- **Post-early**: agents must post FIRST, refine AFTER. Step waste is bug
  #1. An incomplete draft posted is ALWAYS better than a refinement never
  posted.
- **Idempotence**: all `bin/*` scripts (`setup`, `doctor`, `update`, `oc`)
  must be idempotent. Re-running a script must produce no additional side
  effects.
- **Serial merge**: `resource_group: boucle-merge` serializes all merges.
  You must NEVER parallelize merges — a concurrent rebase against a stale
  `master` produces conflicts and race conditions.
- **Anti-feedback-loop**: auto-update must skip push-source pipelines
  (`CI_PIPELINE_SOURCE == "push"`), otherwise the system enters an
  `update → commit → update → commit…` loop.
- **SHA-anchored verdict**: `reviewer` and `e2e` verdicts must include the
  SHA in raw hex, with no quotes, no whitespace, no angle brackets. Exact
  format: `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->`. The
  CI parser FAILS if the format is not respected to the letter.
- **Forge-native**: boucle lives in the forge. You must NEVER introduce a
  new frontend, a server, or a computer to keep running.

## 8. Known limitations (MVP)

- **GitLab only**: GitHub is planned but not yet implemented.
- **Cloudflare Pages only**: other deployment targets are planned.
- **codebase-memory-mcp hang in CI**: the MCP handshake can exceed the
  30-second runner window. `bin/oc` strips MCP servers from the opencode
  config in CI; agents fall back to native `glob`/`grep`/`read` tools.
- **Steps exhausted before commit**: the worker can run out of steps before
  committing. CI applies an automatic safety-net commit before rebase to
  avoid losing work. Agents must avoid unstaged changes (binaries, local
  configs).
- **Verdict without SHA**: if the reviewer agent posts a verdict that does
  not match the SHA-anchored format, CI attempts a SHA-unanchored parsing
  fallback. This fallback is best-effort and must not be considered a
  guarantee.
- **No-op label writes**: the forge records a *Resource Label Event* on
  every PUT, even if the label is unchanged. All label-manipulation code
  must check the current state before writing, otherwise the event history
  explodes and can distort state machine transitions.
- **Empty MR**: if the worker produces zero changes, CI detects
  `base_sha == head_sha` and re-triggers or escalates. The worker MUST
  produce at least one commit (even trivial) to pass this guard.
- **Webhook without work**: a webhook that does not produce a
  `.boucle-issue` file must NEVER consume a runner silently. The
  `dispatch` EXIT trap fails the job if no work is produced.

## 9. See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — System architecture, pipeline, Mermaid diagrams
- [AGENTS.md](AGENTS.md) — Agent guide, lessons learned, anti-patterns
- [README.md](README.md) — Overview, getting started, usage
- [LOOP.md](LOOP.md) — Per-consumer configuration
- [.opencode/UPSTREAM-FIX-WORKFLOW.md](.opencode/UPSTREAM-FIX-WORKFLOW.md) — Upstream fix workflow
