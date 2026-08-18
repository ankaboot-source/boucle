# CONTEXT.md — Boucle project context

> **Maintenance** — This document captures the context, identity, tech stack
> and constraints of boucle. Any change to scope, stack, or constraints must
> update it. See [AGENTS.md](AGENTS.md) for contribution conventions.

## 1. Identity

Boucle is a **loop engineering** tool for **Product Builders**. It turns a
forge issue (GitLab or GitHub) into a deployed product, without
continuous human intervention — the human stays in the loop at decision
points (spec validation, MR/PR approval).

Boucle **lowers the barrier to entry** for building websites and applications,
while integrating with **developer CI/CD practices**. Unlike SaaS platforms
that lock the user into a closed UI, boucle lives in the forge — no new
frontend, no server to maintain, no computer to keep running.

Boucle **frees the user from interactive chats** that demand a permanent
presence in front of the screen — a dynamic that is often toxic. Work
happens asynchronously, driven by labels and comments.

Boucle was extracted from a real benchmark: the maintenance of a static
Astro website (GitLab-hosted, deployed to Cloudflare Pages). The failure
modes observed there — and in the *looper* POC that preceded boucle —
shaped the design.

> **Dogfood status (2026-08):** The engine repo no longer dogfoods on a
> consumer (the origin Astro site was split out to its own repo to separate
> engine from consumer). Dogfooding is **suspended voluntarily** — the
> existing mix of engine and consumer code in one repo was untenable. A
> dedicated test consumer will be re-introduced once the engine/consumer
> separation is stable. Until then, new classes of bugs are discovered on
> real consumers; the 73 lessons in LESSONS.yml catalog the forward-looking operating principles.

## 2. Features

- **Self-maintaining documentation** — boucle keeps its charter docs
  (`AGENTS.md`, `CONTEXT.md`, `LOOP.md`) in
  sync with the code as part of each work cycle. The triage identifies
  impacted docs, the worker updates them in the same MR, the reviewer
  verifies doc conformance and completeness, and the e2e verifies docs
  match production reality. A doc that drifts from the system it describes
  is treated as a bug.
- **Do-Not-Disturb mode** — an **opt-in** quiet window (disabled by default; `BOUCLE_DND_ENABLED=true`, default 22:00–07:00) during which the spec-validation gate is auto-validated, letting the loop run autonomously up to the MR without contacting the human. Preserves the human's quality of life; MR approval stays human-gated (in mono-user mode via a 👍 emoji on the reviewer's PASS comment on the PR — native self-approval is unreliable when the author is the bot). Autonomy must be explicit: opt-in globally, or per issue via the `boucle:autonomous` label. See [LOOP.md](LOOP.md) §Do-Not-Disturb (`BOUCLE_DND_*` variables).

## 3. Target audience

- **Product Builders**: those who build products (websites, applications) but
  are not necessarily full-time developers.
- Refinement (triage) and end-to-end testing make boucle accessible to those
  who do not master the entire CI/CD chain.
- The human stays in the loop: spec validation (readable TL;DR), MR approval.
- A solo builder should not have to run a second forge account just to use
  boucle. Mono-user mode (the default when no `--bot-id` is given) supports
  that: one account carries the issues, the MRs and the loop's own actions.
  It costs degraded notifications (the forge stops signalling "your turn"
  once there is no assignee change, and does not notify you about your own
  activity by default), so a dedicated bot identity stays the recommended
  install — automated on GitLab via project service accounts, manual on GitHub
  (create an account at https://github.com/signup, a PAT at
  https://github.com/settings/tokens/new, then pass `--bot-token <pat> --bot-id <id>`).

## 4. Tech stack

| Layer | Technology |
| --- | --- |
| Forge | GitLab, GitHub |
| CI/CD | GitLab CI (8 stages) / GitHub Actions (8 stages) — shared shell library `lib/boucle-ci/` |
| AI agents | jcode (4 agents: triage, worker, reviewer, e2e) |
| Models | glm-5.2 (triage, e2e), deepseek-v4-flash:0731 (worker, reviewer) — open-weight preference |
| Knowledge graph | codebase-memory-mcp |
| Deployment | Pluggable: Cloudflare Pages (default), GitHub Pages, GitLab Pages, external (consumer's own CI) |
| Tests | bats (shell), shellcheck, shfmt |
| Hooks | pre-commit |
| Vendored skills | `.jcode/skills/` — content borrowed from the maintainer's skill library, synced from upstream. Only one component ships executable code: `ui-ux-pro-max` (Python stdlib-only, engine of the worker's design skill). No boucle-authored Python. |
| Design charter | `.jcode/DESIGN-template.md` — per-site design system file (product context → tokens → motion → components → content/iconography/visual foundations), derivative of superdesign-skill DESIGN.md (MIT) and named after that concept. Consumer sites keep their own `DESIGN.md`; the worker reads it before any UI work and it overrides generic design recommendations. `bin/check-design-charter` validates the charter structure (sections, tokens, no placeholders) before UI work. |

Boucle is designed to be **forge-agnostic and deploy-agnostic**. The forge
abstraction layer (`bin/forge/${BOUCLE_FORGE}.sh`) and the shared CI shell
library (`lib/boucle-ci/`) let the same loop run on GitLab CI or GitHub
Actions. Deployment is Cloudflare Pages for the MVP, with other targets
planned.

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
- **Idempotence**: all `bin/*` scripts (`setup`, `doctor`, `update`, `jc`)
  must be idempotent. Re-running a script must produce no additional side
  effects.
- **Serial merge**: `resource_group: boucle-merge` serializes all merges.
  You must NEVER parallelize merges — a concurrent rebase against a stale
  `master` produces conflicts and race conditions.
- **Anti-feedback-loop**: auto-update must skip push-source pipelines
  (`CI_PIPELINE_SOURCE == "push"`), otherwise the system enters an
  `update → commit → update → commit…` loop. **The guard lives in
  `bin/update` itself** (`BOUCLE_PIPELINE_SOURCE = push` → skip self-update),
  backed by the job rules: every loop job requires
  `CI_PIPELINE_SOURCE == "trigger"`, so a push can never start one. It is
  **not** provided by `[skip ci]` in commit messages — that marker was
  redundant for the loop while silently disabling the `check` job, which let
  37 of 40 consecutive commits reach the default branch unlinted and
  untested (issue #51). Do not reintroduce it "to be safe": the safety is
  elsewhere, and the marker only removes the quality gate.
- **The loop's own commits meet the same bar**: boucle writes almost all of
  its own code, so a worker commit must pass `check` (shellcheck, shfmt,
  bats) exactly like a human's. A rule that exempts the agent from the gate
  the project is built on is not a shortcut, it is the gate not existing.
- **SHA-anchored verdict**: `reviewer` and `e2e` verdicts must include the
  SHA in raw hex, with no quotes, no whitespace, no angle brackets. Exact
  format: `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->`. The
  CI parser FAILS if the format is not respected to the letter.
- **Forge-native**: boucle lives in the forge. You must NEVER introduce a
  new frontend, a server, or a computer to keep running.

## 8. Known limitations (MVP)

- **GitLab + GitHub**: both forges are supported. GitLab remains the
  reference implementation; GitHub (GitHub Actions, `BOUCLE_FORGE=github`)
  is functional but less battle-tested.
- **Cloudflare Pages only**: other deployment targets are planned. However, `BOUCLE_REVIEW_MODE=screenshot` enables token-less visual review: the worker builds locally, serves via `python3 -m http.server`, captures screenshots of impacted pages, and the reviewer grades them via vision-model descriptions guided by acceptance criteria. No deploy command, no token — ideal for GitLab CE (no per-branch Pages).
- **codebase-memory-mcp hang in CI**: the MCP handshake can exceed the
  30-second runner window. `bin/jc` disables MCP servers in CI via
  `JCODE_RUN_MCP=0`; agents fall back to native `glob`/`grep`/`read` tools.
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

- [AGENTS.md](AGENTS.md) — Agent guide, mandatory principles. Lessons in LESSONS.yml
- [README.md](README.md) — Overview, getting started, usage
- [LOOP.md](LOOP.md) — Per-consumer configuration
- [.jcode/UPSTREAM-FIX-WORKFLOW.md](.jcode/UPSTREAM-FIX-WORKFLOW.md) — Upstream fix workflow
