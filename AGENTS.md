# AGENTS.md — Boucle agent guide

> **Maintenance** — This document captures mandatory principles. Lessons are in LESSONS.yml (machine-readable YAML, validated by bin/check-lessons). Anti-patterns
> and operating principles for agents. **Any new lesson discovered must be
> added here** to avoid repeating the same mistakes. See
> [CONTEXT.md](CONTEXT.md) for the project context and tech stack.

## Reference files (charter files)

Before working on any issue, agents MUST consult these files at the repo root:

- [AGENTS.md](AGENTS.md) — this document. Lessons (in LESSONS.yml) and conventions.
- [README.md](README.md) — project overview and getting started.
- [LOOP.md](LOOP.md) — per-consumer configuration (target repo, cadence, gates, caps).
- [CONTEXT.md](CONTEXT.md) — project context, tech stack, constraints.

**FORBIDDEN** to start any work without first reading [LOOP.md](LOOP.md)
and [CONTEXT.md](CONTEXT.md).

## Agent roles

| Agent   | Model                       | Steps | Temp | Role                                                                                                                |
| ------- | ---------------------------- | ----- | ---- | ------------------------------------------------------------------------------------------------------------------- |
| triage  | ollama-cloud/glm-5.2        | 200   | 0.3  | Analyzes issue, posts structured comment (TL;DR + Diagram + Analysis + one `## Criteria` section: acceptance, must-haves, non-goals + Questions + one collapsed `## Metadata` section: impacts, impacted files, size S/M/L, validation, disposition) |
| worker  | ollama-cloud/deepseek-v4-flash:0731 | 100   | —    | Implements on branch `boucle/<iid>-<slug>`, reads `state.md`, uses codebase-memory-mcp, conventional commit          |
| reviewer| ollama-cloud/deepseek-v4-flash:0731 | 35    | 0.2  | Adversarial review against preview URL, SHA-anchored verdict                                                       |
| e2e     | ollama-cloud/glm-5.2         | 30    | —    | Verifies on production URL, SHA-anchored verdict                                                                    |

See [LOOP.md](LOOP.md) for the pipeline and state machine details.

## Interactive agents (harness) — issue-driven work

An **interactive agent** (a.k.a. "harness" — an orchestrator/agent session
driven by a human in the loop, e.g. an OpenCode/Claude Code session running
in this repo) is **NOT** a boucle CI agent. It does not run under `bin/jc`,
does not consume a runner, and is not triggered by a webhook. But it works
in the same repo and its changes flow through the same review/merge path.

### Two modes: dispatch the loop vs work interactively

A harness has **two distinct modes**, and the choice is made at issue-creation
time by which labels are applied:

| Mode | Labels at creation | Who implements | When to use |
|------|-------------------|----------------|-------------|
| **Dispatch** | `boucle:triage` (+ assign to bot) | The boucle loop (triage → worker → reviewer → e2e) | The human wants the autonomous loop to own the issue end-to-end |
| **Interactive** | No boucle labels, no bot assignee | The harness itself (or its specialist subagents) | The human wants to drive the work interactively, with the harness as the worker |

**The `boucle:triage` label is the dispatch trigger.** Adding it to an issue
tells the loop to take over. A harness that adds `boucle:triage` and then
implements the work itself produces a **race condition**: the loop triages,
splits, and dispatches workers in parallel with the harness's own work —
duplicated effort, conflicting branches, and wasted CI runners.

### Rule: choose the mode explicitly

When a harness creates an issue, it MUST decide upfront:

- **To dispatch the loop**: add `boucle:triage`, assign to the bot. The
  harness's job ends at issue creation. It does NOT implement.
- **To work interactively**: create the issue with NO boucle labels and NO
  bot assignee. The harness owns the issue end-to-end (spec, implementation,
  review, MR). The loop never touches it.

A harness MUST NOT add `boucle:triage` to an issue it intends to implement
itself. If the human later asks to hand the issue to the loop, the harness
adds `boucle:triage` at that point — not before.

```mermaid
flowchart LR
    A[Human request] --> B{Trivial?}
    B -- Yes --> C[Direct edit + verify]
    B -- No --> D{Dispatch loop or work interactively?}
    D -- Dispatch --> E[Create issue + boucle:triage + assign bot]
    D -- Interactive --> F[Create issue, NO boucle labels]
    E --> G[Loop owns it end-to-end]
    F --> H[Harness implements: spec → code → review → MR]
    C --> I[Done]
    G --> I
    H --> I
```

### Issue format (boucle standard)

Either mode, the issue MUST follow the boucle triage structure so it is
legible to both humans and any future boucle run:

- **Contexte** — what exists today, what the user wants.
- **Objectif** — the precise change, broken into numbered changes.
- **Critères d'acceptation** — `Given/When/Then` checklist (happy path,
  edge case, error state, non-functional).
- **Questions** — open questions for the human (clarifications,
  decisions needed).
- **Docs impact** — which charter docs the change touches (so the
  worker/reviewer knows what to update).

### Interactive workflow (harness as worker)

Once the issue is created (interactive mode), the harness follows the
boucle workflow adapted for interactive execution:

1. **Spec** — the issue body IS the spec. If the human answers the
   questions, amend the issue body (or a comment) — do not keep the spec
   only in the chat session.
2. **Implementation** — the harness may implement directly (it is the
   worker) or delegate to a specialist subagent. Either way, it commits
   on the worker branch `boucle/<iid>-<slug>` (the name `bin/boucle pause`
   prints; or a feature branch) with conventional commits referencing the
   issue (`(#<iid>)`).
3. **Lessons** — if the harness discovers a new class of mistake, it adds
   a `LESSONS.yml` entry (running the four-point admission test, stating
   the justification on stdout/inline).
4. **Review** — the harness reviews its own work against the acceptance
   criteria. For UI changes, it MUST produce a **preview screenshot**
   (browser screenshot of the rendered page) and attach it to the issue
   or MR. The review verdict follows the SHA-anchored format:
   `<!-- boucle:verdict v=1 role=reviewer sha=<hex> -->`.
5. **MR/PR** — the harness creates the MR/PR with a description following
   the boucle MR format: TL;DR, What changed (per file), Preview URL or
   screenshot, Cost (if tracked), Acceptance criteria checklist.
6. **Docs** — the harness updates impacted charter docs (AGENTS.md,
   DESIGN.md, LOOP.md, CONTEXT.md) in the same MR as the code.

### FORBIDDEN for interactive agents

- **NEVER** implement non-trivial work without creating an issue first.
- **NEVER** keep the spec only in the chat session — the forge issue is
  the durable record.
- **NEVER** add `boucle:triage` (or any boucle status label) to an issue
  the harness intends to implement itself — that dispatches the loop and
  creates a race condition. Add `boucle:triage` ONLY to hand an issue to
  the autonomous loop.
- **NEVER** assign an issue to the boucle bot unless dispatching the loop.
- **NEVER** skip the review step (preview screenshot + SHA-anchored
  verdict) for UI changes.
- **NEVER** bypass the `LESSONS.yml` admission test when adding a lesson.

### Why

The repo runs boucle autonomously on some issues. An interactive agent
that implements directly (without an issue) produces work that is
invisible to the loop, has no acceptance criteria, no review trail, and
no doc-impact analysis. When boucle later touches the same area, it has
no context for what the interactive agent did. The issue is the seam
between interactive and autonomous work.

Conversely, an interactive agent that adds `boucle:triage` and then
implements the work itself races the loop: the loop triages, splits, and
dispatches workers on the same issue, producing duplicated branches and
wasted CI runners. The `boucle:triage` label is a **dispatch trigger**,
not a tag — it means "loop, take this", not "I am working on this".

## MANDATORY operating principles

These principles are **NON-NEGOTIABLE**. Any agent that violates them introduces a
known recurring bug, documented in LESSONS.yml.

1. **Post-early rule** — The agent MUST post its comment or verdict **FIRST**, then
   refine it afterward. Step-limit waste (the agent exhausts its budget without ever
   posting) is bug #1. **Rule**: an incomplete draft posted is ALWAYS better than a
   refinement never posted. **BUT**: the draft MUST contain at least the content the
   human needs to act on it — for triage, a rough `## Analysis` section (2-3 sentences
   restating the issue) and a `## Metadata` section carrying a `Disposition`. An empty placeholder ("DRAFT —
   first-pass triage, refining next.") is noise, not a draft (lesson #99). "Post
   early" means minimal but meaningful, not "post nothing early".

2. **Silent-failure detection** — `bin/jc` exits with code `3` if the agent has
   produced no posted or drafted comment. CI then escalates to a human.
   An agent that produces nothing MUST be detected, **NEVER** ignored.

3. **Log-scraping fallback** — CI scrapes the agent stdout from `agent-output.log`.
   If the agent drafts a comment but exhausts its steps before posting, CI posts it
   on the agent's behalf. **The agent MUST therefore ALWAYS produce its output on
   stdout** (not only in memory, not only via tool calls).

4. **SHA-anchored verdict** — The reviewer/e2e verdict MUST include the SHA as
   **bare hex**: no quotes, no whitespace, no angle brackets.
   Exact format: `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->`.
   The CI parser **FAILS** if the format is not respected to the letter.

5. **Label idempotence** — GitLab records a *Resource Label Event* on every PUT,
   **even if the label is unchanged**. ALWAYS check whether the label is already
   present before writing it. A no-op write pollutes the history and may skew the
   state machine transitions.

6. **Anti-accumulation** — The `dispatch` EXIT trap fails if no `.boucle-issue` file
   is written. A webhook that produces no work MUST fail, **NEVER** silently consume
   a runner.

7. **Rebase before build** — Build dirties the working tree (`public/`).
   Rebase **REFUSES** a dirty tree. ALWAYS rebase **BEFORE** building,
   **NEVER** the reverse.

8. **Safety-net commit** — The agent may exhaust its steps before committing. CI
   stages+commits uncommitted changes automatically before rebase. The agent does
   **NOT** need to worry about committing perfectly — but it MUST avoid unstageable
   changes (binaries, local configs).

9. **Empty-MR guard** — The worker may produce zero changes (steps exhausted).
   CI detects `base_sha == head_sha` and re-triggers the worker or escalates.
   A worker MUST produce at least one commit (even trivial) to avoid this branch.

10. **Serial merge** — `resource_group: boucle-merge` serializes all merges.
    Each rebase is against a `master` that includes previously-merged MRs.
    **NEVER** parallelize merges.

11. **Doc self-maintenance** — Boucle maintains its own documentation as part
    of its loop. The triage identifies which charter docs an issue impacts,
    the worker updates them in the same MR as the code, the reviewer verifies
    conformance and completeness, the e2e verifies docs match production.
    Doc updates use Mermaid diagrams, explicit/imperative tone, and
    cross-references. **NEVER** let docs drift from code — a doc that
    describes a system that no longer exists is a bug.

## Lessons learned (forward-looking operating principles)

Each entry below is a **contract** that every agent and CI step MUST honor
going forward. The `❌ DO NOT / ✅ DO` pair is the rule; the incident that
produced it is not recorded here — it lives in git history. Numbers are
stable (a few are cross-referenced from `.gitlab-ci.yml`, `bin/jc` and
agent prompts); never renumber — a pruned entry leaves a gap, not a shift.

### What is NOT a lesson

A lesson prevents a **class** of mistakes from recurring. It is NOT:

- A bug report for an incident now fixed in code — the code fix prevents
  recurrence, not the doc.
- A change of mind or preference shift — that belongs in the relevant
  charter doc, not here.
- A one-off discovery ("directory X was missing from `SYNC_PATHS`") — if
  the fix is a one-line code change, the doc adds noise.

### Admission test (a new entry MUST pass all four)

1. **Class, not instance** — it describes a *class* of mistakes, not one
   incident. If it only makes sense with the incident's specifics (line
   numbers, variable names, SHAs), it is a bug report.
2. **Recurrence without the doc** — an agent or CI step would plausibly
   repeat this mistake *without* reading this doc. If the code fix alone
   prevents recurrence, do not add a lesson.
3. **Stable** — true regardless of current code state. No line numbers, no
   transient config values, no "until X" clauses.
4. **Not already covered** — not a restatement of an existing lesson or a
   charter-doc rule.

If an entry fails any test, fix the code and move on — do not add a
lesson. The worker MUST justify a new entry against this test (state the
justification on stdout); the reviewer MUST reject entries that fail it.

### Which file (a fifth question, only in a consumer repo)

Lessons live in **two** files and both are injected into every prompt
(see [LOOP.md](LOOP.md) § "Lessons — two files, one name"):

5. **Repo-specific or universal?** Would this entry be *noise* in another
   repository — does it name this project's stack, test harness or deploy?
   - **Yes, noise elsewhere** → `LESSONS.yml` at the repo root. That file is
     the consumer's own. Validate with
     `bin/check-lessons LESSONS.yml --against .boucle/LESSONS.yml`, which
     rejects an entry that merely restates an engine lesson.
   - **No, it would hold anywhere** → it belongs to the engine. **NEVER**
     commit it to `.boucle/LESSONS.yml` — that directory is engine-owned and
     the write is discarded. State the entry on stdout for upstreaming per
     [.jcode/UPSTREAM-FIX-WORKFLOW.md](.jcode/UPSTREAM-FIX-WORKFLOW.md).

   In the engine repo itself there is one file and this question does not
   arise.

### When a lesson is proposed

Two triggers, and **silence is the expected outcome of both**:

- **At escalation** — the reviewer emits a candidate on the final iteration;
  the worker validates and commits it.
- **On recovery** — the worker is asked for one when it is fixing a failed
  iteration (iteration ≥ 2), where the delta between what failed and what
  worked is visible in `iterations.md` and `state.md`'s *Tried and rejected*.

A **first-pass success proposes nothing**. Distilling from a run that simply
worked fills the file with restatements of the charter, and distilling only
from runs that *failed* — which is all boucle used to do — produces artifacts
measured as worse than no artifact at all
([docs/skills-audit.md](docs/skills-audit.md) § 1).

> Each lesson that states a *current protocol invariant* cross-references
> [SKILL.md](SKILL.md) §I<N> for the normative text. The lesson keeps the
> incident context (the ❌/✅ pair and the explanation) but defers the rule
> statement to SKILL.md to avoid dual-maintenance drift. Lessons that are
> pure incident catalogs (the bug is fixed in code) stay as-is.


The lessons are maintained in [LESSONS.yml](LESSONS.yml) — a machine-readable
YAML file where each lesson is a numbered entry with `title`, `❌` (DO NOT),
and `✅` (DO) keys. The YAML format enables automated validation
(`bin/check-lessons`) and duplicate detection in CI.

**How to read a lesson:**
- `title` — short label for the class of mistake.
- `❌` — the anti-pattern (one or more DO NOT entries).
- `✅` — the correct pattern (one or more DO entries).
- `pruned: true` — the lesson is obsolete (gap preserved, never renumber).
- `merged_into: N` — the lesson was merged into lesson #N (gap preserved).

**How to add a lesson** (worker → reviewer → CI gate):
1. The worker runs the four-point admission test above and states on stdout
   which tests the new lesson passes.
2. The worker adds the entry to LESSONS.yml with the next available number
   (or reuses a pruned/merged gap only if the class is identical).
3. The reviewer verifies the admission test passes and the format is correct.
4. `bin/check-lessons` (CI gate) validates: format (title + ❌ + ✅), no
   `Context:` narratives, no SHA/issue/line numbers, sequential numbering,
   cross-references valid, and flags potential duplicates by keyword overlap.

**Never renumber** — a pruned or merged entry leaves a gap, not a shift.
Cross-references from `.gitlab-ci.yml`, `bin/jc`, and agent prompts use
stable lesson numbers.

The `/boucle` interactive command (see [ARCHITECTURE.md](ARCHITECTURE.md) §12
and [LOOP.md](LOOP.md) §"Interactive commands") is governed by two lessons:
**#100** (commands are recognized by marker, authorized by author — never by
actor identity alone) and **#101** (inline dispatch operations hold the
`boucle-dispatch` lock — slow work MUST be a separate job).

## Documentation self-maintenance

Boucle self-maintains its own documentation as part of the autonomous loop.
Documentation is **code**: a doc that drifts from the system it describes is a
bug. The four agents share the responsibility of keeping the charter docs
(`AGENTS.md`, `CONTEXT.md`, `LOOP.md`, `README.md`) in sync
with reality.

### Distributed workflow

- **Triage** — Adds a `Docs impact: <docs>` line to the `Analysis` section of
  the structured comment, listing which charter docs the issue touches
  (e.g. `Docs impact: AGENTS.md, LOOP.md`).
- **Worker** — Reads the impacted charter docs **before** implementing. Conforms
  to them. If the change requires updating a doc (new state, new variable, new
  agent responsibility, new seam), the worker updates the doc **in the same
  MR** as the code change. When discovering a new bug or anti-pattern, the
  worker adds a lesson entry to `LESSONS.yml`.
- **Reviewer** — Verifies two things: (1) the worker respected the charter docs
  during implementation (doc conformance), and (2) the worker updated the docs
  when required (doc completeness). On `FAIL`, the reviewer may require the
  worker to add a `LESSONS.yml` entry to capture the regression.
- **E2E** — Verifies that charter docs match production reality: after
  deployment, the e2e agent confirms that the documented pipeline, agent
  responsibilities, and seams still hold.

### Doc rules

- Use **Mermaid syntax** (` ```mermaid ` fenced blocks) for all diagrams.
- **Every Mermaid fence MUST parse.** `bin/check-mermaid` runs the real Mermaid
  parser over the repo's own docs (`make test`) and over every spec comment the
  triage posts; a fence it rejects renders as an error box, not a diagram. The
  grammar traps that actually break a render are listed in
  [`templates/diagram-theme.md`](templates/diagram-theme.md) § Syntax rules.
- **Draw the change, never the files.** Pick the diagram type from the decision the
  reader validates — a navigation change on the visitor's path, a data model on its
  entities. Nodes named after the files being edited are the most common wrong diagram:
  they parse, they cannot be faulted, and they say nothing a file list does not. Nothing
  in CI checks this — it is a judgement, and it is yours.
- Use **explicit/imperative tone** ("MUST", "NEVER", "ALWAYS") — not descriptive
  prose.
- Keep docs **up to date with the code** — never let a doc describe a system
  that no longer exists.
- **Cross-reference** related docs with relative markdown links
  (e.g. `[AGENTS.md](AGENTS.md)`).

See [AGENTS.md](AGENTS.md) section "Documentation
self-maintenance" for the pipeline diagram and the per-agent responsibilities.

<!-- codebase-memory-mcp:start -->
## Codebase Knowledge Graph (codebase-memory-mcp)

This project uses `codebase-memory-mcp` to maintain a knowledge graph of the codebase.
**ALWAYS** prefer MCP graph tools over `grep`/`glob`/`file-search` for code discovery.

The graph is built once (by CI or locally) and auto-syncs on changes. If
`search_graph` returns nothing, run `index_repository` with the repo path, then
retry. In CI, `bin/jc` auto-indexes the repo before the agent starts (triage,
worker, reviewer roles) if the `.codebase-memory/` index doesn't exist.

> **Consumer repos:** `LESSONS.yml`, `.jcode/agents/`, `.jcode/skills/`, and
> `bin/` live under `.boucle/` (the engine dir) but are symlinked to the repo
> root by `bin/setup`, `bin/update`, and `bin/jc` (runtime fallback). If
> `Read LESSONS.yml`, `skill(...)`, or an agent prompt fails, check that the
> symlinks exist:
> `ls -la LESSONS.yml .jcode/agents .jcode/skills bin` — they should point to
> `.boucle/LESSONS.yml`, `.boucle/.jcode/agents`, `.boucle/.jcode/skills`,
> `.boucle/bin` respectively. A real dir at the root for an engine-owned path
> is an orphan from the old copy-based install: `bin/setup`/`bin/update`
> migrate it to a symlink (a stale `.jcode/agents` means a stale triage
> prompt).

### Priority order

1. `search_graph` — find functions, classes, routes, variables by pattern
2. `trace_path` — trace who calls a function or what it calls
3. `get_code_snippet` — read specific function/class source code
4. `query_graph` — run Cypher queries for complex patterns
5. `get_architecture` — high-level project summary

### When to fall back to grep/glob

- Searching for string literals, error messages, config values
- Searching non-code files (Dockerfiles, shell scripts, configs)
- When MCP tools return insufficient results

### Examples

- Find a handler: `search_graph(name_pattern=".*OrderHandler.*")`
- Who calls it: `trace_path(function_name="OrderHandler", direction="inbound")`
- Read source: `get_code_snippet(qualified_name="pkg/orders.OrderHandler")`
- Architecture overview: `get_architecture(aspects=["all"])`
<!-- codebase-memory-mcp:end -->

## Commit conventions

**ALWAYS** commit changes before finishing. Uncommitted edits are **NOT** durable —
they can be lost if the working tree is reset, checked out, or if the session ends.

### Format

- Mandatory format: `feat: <description> (#<iid>) [skip ci]`
- Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`
- **NEVER** rebase, merge, push or deploy from the worker — CI handles that.
- **ALWAYS** verify `git log --oneline -1` and `git status` (clean working tree)
  after each commit.

### Procedure

1. Stage modified files: `git add <paths>` (be specific, **NEVER** `git add -A`
   unless `git status` is verified clean).
2. Commit with a concise conventional-commit message.
3. Verify the commit landed: `git log --oneline -1` and `git status`.

**NEVER** push unless explicitly requested. **NEVER** amend or force-push unless
explicitly requested. If a commit fails (pre-commit hook rejected), fix the issue
and create a **NEW** commit — **NEVER** amend the failed commit.

## Upstream fix workflow

The upstream-first workflow is defined in
[`.jcode/UPSTREAM-FIX-WORKFLOW.md`](.jcode/UPSTREAM-FIX-WORKFLOW.md).

That file is **portable**: it ships with boucle when installed in consumer projects
(via the `.jcode/` directory).
### Golden rule

**Fix upstream in boucle FIRST, then update boucle in the consumer, THEN remediate
existing data.** Mandatory order:

1. Fix the bug in the boucle upstream repo.
2. Update the boucle installation in the consumer project.
3. Remediate existing data impacted by the bug.

### FORBIDDEN

- **NEVER** patch a consumer to work around a boucle defect.
- **NEVER** introduce a local workaround that won't be reported upstream.
- **NEVER** mask a boucle bug with a consumer config.

A bug on a consumer project MUST be traced to its root cause in boucle and fixed
there first.

## `.boucle/` ownership — what agents can and cannot modify

`.boucle/` is the **engine directory**, 100% owned by `bin/update`. Agents
MUST NOT modify files under `.boucle/` directly. The CI guard
`bin/check-boucle-sync` rejects any commit touching `.boucle/` that is not a bot
`chore(boucle):` commit (produced by `bin/update`). A manual edit to `.boucle/`
is a bug: `bin/update` will overwrite it on the next sync, silently discarding
the change.

`.boucle-state/` is **runtime state** (gitignored) — agents write there freely
(`state.md`, `iterations.md`, etc.). It is never committed and never synced.

To change **consumer config** (deploy mode, build command, review mode, ...):
use **CI variables** (Settings → CI/CD → Variables) or the **root
`.gitlab-ci.yml` shim** — NEVER `.boucle/.gitlab-ci.yml`.

To fix an **engine bug**: fix it in the **upstream boucle repo**
(`ankaboot-source/boucle`), then `bin/update` syncs it to consumers.

```mermaid
flowchart LR
    A[Consumer wants a change] --> B{What kind?}
    B -- Config (deploy mode, build cmd, review mode) --> C[CI variables or root .gitlab-ci.yml shim]
    B -- Engine bug --> D[Fix in upstream boucle repo]
    D --> E[bin/update syncs to consumers]
    B -- Runtime state --> F[.boucle-state/ — write freely]
    C --> G[NEVER .boucle/ — bin/update overwrites it]
```

See [LOOP.md](LOOP.md) for the per-consumer configuration seams.

## See also

- [CONTEXT.md](CONTEXT.md) — Project context, tech stack, constraints
- [README.md](README.md) — Overview, getting started, usage
- [LOOP.md](LOOP.md) — Per-consumer configuration
- [.jcode/UPSTREAM-FIX-WORKFLOW.md](.jcode/UPSTREAM-FIX-WORKFLOW.md) — Upstream fix workflow
