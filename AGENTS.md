# AGENTS.md — Boucle agent guide

> **Maintenance** — This document captures lessons learned, anti-patterns
> and operating principles for agents. **Any new lesson discovered must be
> added here** to avoid repeating the same mistakes. See
> [ARCHITECTURE.md](ARCHITECTURE.md) for the full system architecture.

## Reference files (charter files)

Before working on any issue, agents MUST consult these files at the repo root:

- [DESIGN.md](DESIGN.md) — consumer site visual charter. Any visual component MUST conform to it.
- [AGENTS.md](AGENTS.md) — this document. Lessons learned and conventions.
- [README.md](README.md) — project overview and getting started.
- [LOOP.md](LOOP.md) — per-consumer configuration (target repo, cadence, gates, caps).
- [ARCHITECTURE.md](ARCHITECTURE.md) — full system architecture.
- [CONTEXT.md](CONTEXT.md) — project context, tech stack, constraints.

**FORBIDDEN** to start any work without first reading [ARCHITECTURE.md](ARCHITECTURE.md)
and [LOOP.md](LOOP.md).

## Agent roles

| Agent   | Model                       | Steps | Temp | Role                                                                                                                |
| ------- | ---------------------------- | ----- | ---- | ------------------------------------------------------------------------------------------------------------------- |
| triage  | ollama-cloud/minimax-m3      | 200   | 0.3  | Analyzes issue, posts structured comment (TL;DR + Analysis + Acceptance criteria + Classification S/M/L + Questions + Disposition) |
| worker  | ollama-cloud/minimax-m3      | 50    | —    | Implements on branch `boucle/<iid>`, reads `state.md`, uses codebase-memory-mcp, conventional commit                 |
| reviewer| ollama-cloud/glm-5.2         | 35    | 0.2  | Adversarial review against preview URL, SHA-anchored verdict                                                       |
| e2e     | ollama-cloud/kimi-k2.7-code  | 20    | —    | Verifies on production URL, SHA-anchored verdict                                                                    |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full pipeline and state machine details.

## MANDATORY operating principles

These principles are **NON-NEGOTIABLE**. Any agent that violates them introduces a
known recurring bug, documented in the "Lessons learned" section.

1. **Post-early rule** — The agent MUST post its comment or verdict **FIRST**, then
   refine it afterward. Step-limit waste (the agent exhausts its budget without ever
   posting) is bug #1. **Rule**: an incomplete draft posted is ALWAYS better than a
   refinement never posted.

2. **Silent-failure detection** — `bin/oc` exits with code `3` if the agent has
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

## Lessons learned (anti-patterns to never reproduce)

This is **THE MOST IMPORTANT** section of the document. It catalogs the 15 errors
already committed and resolved. Any new regression MUST be added here in the same
`❌ DO NOT / ✅ DO` format.

1. **Step waste by iterative refinement** (issue #27)
   - ❌ DO NOT refine the comment in a loop before posting.
   - ✅ DO: post the comment **FIRST** (even incomplete), then refine in a second
     comment if steps remain.
   - Context: 6 repeated triage notes, infinite doctor re-trigger loop.

2. **Silent failure undetected**
   - ❌ DO NOT ignore an agent that produces no output.
   - ✅ DO: `bin/oc` exit `3` → escalate to human. Breaks the doctor re-trigger loop.

3. **MCP hang in CI**
   - ❌ DO NOT rely on `codebase-memory-mcp` in CI (MCP handshake fails within 30s).
   - ✅ DO: `bin/oc` strips MCP servers from the opencode config in CI. The agent
     uses native `glob`/`grep`/`read` tools instead.

4. **No-op label write**
   - ❌ DO NOT `PUT` a label that is already present.
   - ✅ DO: check the current state before writing. GitLab records an event on every
     `PUT` — a no-op pollutes the history.

5. **Log-scraping missed**
   - ❌ DO NOT produce output only in memory.
   - ✅ DO: the agent MUST write to stdout. CI scrapes `agent-output.log` as fallback
     to catch unposted drafts.

6. **Verdict without SHA**
   - ❌ DO NOT post a verdict without bare hex SHA.
   - ✅ DO: `<!-- boucle:verdict v=1 role=reviewer sha=abc123 -->` —
     no quotes, no whitespace, no angle brackets around the SHA.

7. **Webhook without work**
   - ❌ DO NOT let a webhook consume a runner without producing work.
   - ✅ DO: `dispatch` EXIT trap fails if no `.boucle-issue` is written.

8. **Parallel merge**
   - ❌ DO NOT parallelize merges (rebase against a stale `master`).
   - ✅ DO: `resource_group: boucle-merge` serializes. Each rebase includes the
     previously merged MRs.

9. **OUTPUT_TOKEN_MAX too small**
   - ❌ DO NOT use 1200 tokens max for triage (too small for a complete structured comment).
   - ✅ DO: 4000 tokens (must match reviewer/e2e).

10. **Build before rebase**
    - ❌ DO NOT build before rebase (`public/` dirties the tree, rebase fails).
    - ✅ DO: rebase **BEFORE** build, always.

11. **Bot assignment detection**
    - A human can trigger boucle by **assigning** the issue to the bot
      (no label required). Dispatch MUST detect assignment as a valid trigger,
      in addition to the `boucle:queued` label.

12. **Concurrency cap**
    - `BOUCLE_MAX_PARALLEL_ISSUES` defers the worker trigger if too many issues are
      in progress. **NEVER** disable this cap — it prevents runner saturation and
      race conditions on rebase.

13. **Sub-issue hierarchy**
    - Use the work-items hierarchy API for parent-child.
    - **Fallback**: `legacy split-parent marker` if the API is not available on
      the target GitLab instance.

14. **Safety-net commit**
    - The agent may exhaust its steps before committing. CI stages+commits
      automatically before rebase. **NO NEED** to panic on a missed commit — but
      unstageable changes (binaries) will be lost.

15. **Empty MR**
    - The worker may produce zero changes (steps exhausted). CI detects
      `base_sha == head_sha` → re-trigger or escalate. A worker MUST produce at
      at least one commit to clear this guard.

16. **Blind re-run after reviewer FAIL** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT re-trigger the worker after a reviewer FAIL without passing
      the reviewer's verdict and human MR comments to the next run. A worker
      that starts blind repeats the same mistakes and exhausts the iteration
      budget (`BOUCLE_MAX_ITERATIONS`) without ever addressing the root cause.
    - ✅ DO: the worker job fetches ALL non-system MR notes (reviewer verdicts
      carry the `boucle:verdict` marker; human comments are plain text) and
      exports them as `BOUCLE_REVIEWER_FEEDBACK`. `bin/oc` injects them into
      the worker's prompt as a "Prior feedback on the MR" section. The worker
      MUST address every actionable item before claiming done.
    - Context: 3 reviewer FAIL verdicts on MR !31, same root cause (MR
      description did not cite `DESIGN.md` §2 and §4), never fixed across
      iterations. The re-trigger curl passed only `BOUCLE_ISSUE` +
      `BOUCLE_ROLE` + `BOUCLE_ITERATION` — no feedback channel existed.

## Documentation self-maintenance

Boucle self-maintains its own documentation as part of the autonomous loop.
Documentation is **code**: a doc that drifts from the system it describes is a
bug. The four agents share the responsibility of keeping the charter docs
(`ARCHITECTURE.md`, `AGENTS.md`, `CONTEXT.md`, `DESIGN.md`, `LOOP.md`) in sync
with reality. `README.md` is excluded — it is for human readers, not agents.

### Distributed workflow

- **Triage** — Adds a `Docs impact: <docs>` line to the `Analysis` section of
  the structured comment, listing which charter docs the issue touches
  (e.g. `Docs impact: ARCHITECTURE.md, AGENTS.md`).
- **Worker** — Reads the impacted charter docs **before** implementing. Conforms
  to them. If the change requires updating a doc (new state, new variable, new
  agent responsibility, new seam), the worker updates the doc **in the same
  MR** as the code change. When discovering a new bug or anti-pattern, the
  worker adds a `Lessons learned` entry here in `AGENTS.md`.
- **Reviewer** — Verifies two things: (1) the worker respected the charter docs
  during implementation (doc conformance), and (2) the worker updated the docs
  when required (doc completeness). On `FAIL`, the reviewer may require the
  worker to add a `Lessons learned` entry to capture the regression.
- **E2E** — Verifies that charter docs match production reality: after
  deployment, the e2e agent confirms that the documented pipeline, agent
  responsibilities, and seams still hold.

### Doc rules

- Use **Mermaid syntax** (` ```mermaid ` fenced blocks) for all diagrams.
- Use **explicit/imperative tone** ("MUST", "NEVER", "ALWAYS") — not descriptive
  prose.
- Keep docs **up to date with the code** — never let a doc describe a system
  that no longer exists.
- **Cross-reference** related docs with relative markdown links
  (e.g. `[ARCHITECTURE.md](ARCHITECTURE.md)`).

See [ARCHITECTURE.md](ARCHITECTURE.md) section "Documentation
self-maintenance" for the pipeline diagram and the per-agent responsibilities.

<!-- codebase-memory-mcp:start -->
## Codebase Knowledge Graph (codebase-memory-mcp)

This project uses `codebase-memory-mcp` to maintain a knowledge graph of the codebase.
**ALWAYS** prefer MCP graph tools over `grep`/`glob`/`file-search` for code discovery.

The graph is built once (by CI or locally) and auto-syncs on changes. If
`search_graph` returns nothing, run `index_repository` with the repo path, then
retry.

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
[`.opencode/UPSTREAM-FIX-WORKFLOW.md`](.opencode/UPSTREAM-FIX-WORKFLOW.md).
That file is **portable**: it ships with boucle when installed in consumer projects
(via the `.opencode/` directory).

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

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — System architecture, pipeline, Mermaid diagrams
- [CONTEXT.md](CONTEXT.md) — Project context, tech stack, constraints
- [README.md](README.md) — Overview, getting started, usage
- [DESIGN.md](DESIGN.md) — Consumer site visual charter
- [LOOP.md](LOOP.md) — Per-consumer configuration
- [.opencode/UPSTREAM-FIX-WORKFLOW.md](.opencode/UPSTREAM-FIX-WORKFLOW.md) — Upstream fix workflow
