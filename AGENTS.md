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
| e2e     | ollama-cloud/kimi-k2.7-code  | 30    | —    | Verifies on production URL, SHA-anchored verdict                                                                    |

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

## Lessons learned (forward-looking operating principles)

Each entry below is a **contract** that every agent and CI step MUST honor
going forward. The `❌ DO NOT / ✅ DO` pair is the rule; the incident that
produced it is not recorded here — it lives in git history. Any new
regression MUST be added in the same format: state the principle, not the
bug. Numbers are stable (cross-referenced from `.gitlab-ci.yml`, `bin/oc`
and agent prompts); never renumber.

1. **Post before refining**
   - ❌ DO NOT refine a comment in a loop before posting it.
   - ✅ DO: post the comment **FIRST** (even incomplete), then refine in a
     follow-up. An incomplete post always beats a refinement never posted.

2. **Detect silent failures**
   - ❌ DO NOT let a no-output agent pass silently.
   - ✅ DO: treat no posted/drafted comment as a hard failure (exit `3`)
     and escalate to a human.

3. **No MCP in CI**
   - ❌ DO NOT rely on `codebase-memory-mcp` tools in CI (handshake hangs).
   - ✅ DO: strip MCP in CI; use native `glob`/`grep`/`read` and the
     `codebase-memory-mcp cli` fallback. Every prompt that cites graph tools
     MUST document both interfaces.

4. **Idempotent label writes**
   - ❌ DO NOT `PUT` a label that is already present.
   - ✅ DO: check current state before writing — GitLab records an event on
     every `PUT`, even a no-op.

5. **Always write to stdout**
   - ❌ DO NOT produce output only in memory or via tool calls.
   - ✅ DO: the agent MUST write to stdout so CI can scrape
     `agent-output.log` as a fallback for unposted drafts.

6. **SHA-anchored verdicts**
   - ❌ DO NOT post a verdict without a bare-hex SHA.
   - ✅ DO: `<!-- boucle:verdict v=1 role=reviewer sha=abc123def456 -->` —
     no quotes, no whitespace, no angle brackets around the SHA.

7. **Webhooks must produce work**
   - ❌ DO NOT let a webhook consume a runner without producing work.
   - ✅ DO: fail `dispatch` when no `.boucle-issue` is written.

8. **Serial merges only**
   - ❌ DO NOT parallelize merges (rebase against a stale `master`).
   - ✅ DO: serialize merges via `resource_group: boucle-merge` so each
     rebase includes previously merged MRs.

9. **Adequate output token budget**
   - ❌ DO NOT cap `OUTPUT_TOKEN_MAX` below what a complete structured
     comment needs.
   - ✅ DO: 4000 tokens for triage, matching reviewer/e2e.

10. **Rebase before build**
    - ❌ DO NOT build before rebase (`public/` dirties the tree).
    - ✅ DO: rebase **BEFORE** build, always.

11. **Assignment is a valid trigger**
    - ❌ DO NOT treat only the `boucle:queued` label as a trigger.
    - ✅ DO: dispatch MUST also detect issue **assignment** to the bot.

12. **Honor the concurrency cap**
    - ❌ DO NOT disable `BOUCLE_MAX_PARALLEL_ISSUES`.
    - ✅ DO: let the cap defer worker triggers to prevent runner saturation
      and rebase races.

13. **Resolve parent-child via the hierarchy API**
    - ❌ DO NOT infer parent-child links ad hoc.
    - ✅ DO: use the work-items hierarchy API; fall back to the
      `legacy split-parent marker` when unavailable.

14. **Safety-net commit is CI's job**
    - ❌ DO NOT panic over a missed commit before rebase.
    - ✅ DO: CI auto-stages+commits before rebase. The agent only MUST avoid
      unstageable changes (binaries, local configs).

15. **A worker must produce at least one commit**
    - ❌ DO NOT ship an empty MR (`base_sha == head_sha`).
    - ✅ DO: land at least one commit per worker run; CI re-triggers or
      escalates otherwise.

16. **Feed reviewer feedback forward**
    - ❌ DO NOT re-trigger the worker after a FAIL without passing the
      verdict and human MR comments to the next run.
    - ✅ DO: export all non-system MR notes as `BOUCLE_REVIEWER_FEEDBACK`
      and inject them into the worker prompt; address every actionable item
      before claiming done.

17. **Inherit parent-issue attachments**
    - ❌ DO NOT mine only the current issue for uploads when it is a
      sub-issue.
    - ✅ DO: resolve the parent IID and append its description + notes when
      mining `/uploads/`. One level only; gated by
      `BOUCLE_PARENT_ATTACHMENTS_DISABLE`.

18. **`bin/update` needs GitHub auth until boucle is public**
    - ❌ DO NOT assume `bin/update` works unauthenticated on a consumer.
    - ✅ DO: until boucle is public, propagate upstream fixes manually
      (push to `origin`, copy `SYNC_PATHS`, bump `.boucle-version`). Remove
      this entry once `bin/update` succeeds unauthenticated.

19. **Refresh the MR description on every iteration**
    - ❌ DO NOT reuse an existing MR on iteration 2+ with a stale
      description (preview URL, Approach, commit summary drift).
    - ✅ DO: update title + description on every iteration via
      `glab mr update`.

20. **Fill the Approach section in state.md**
    - ❌ DO NOT leave `## Approach` as the seed placeholder.
    - ✅ DO: fill it with 2-5 sentences citing the charter doc sections
      conformed to; CI falls back to an explicit note if the placeholder
      remains.

21. **Assert preview content matches the head SHA**
    - ❌ DO NOT trust an HTTP 200 on the preview URL (swallowed exit codes,
      CDN cache, byte-identical builds all serve stale content).
    - ✅ DO: write a commit-SHA marker into the build, capture the deploy
      exit code separately, and retry-fetch the marker until the deployed
      SHA matches the head SHA. A stale preview FAILs the worker job.

22. **Prefer rebase over hard reset**
    - ❌ DO NOT unconditionally `git reset --hard origin/master` at the
      start of every worker iteration — it wipes validated commits on
      non-code FAILs.
    - ✅ DO: `git rebase origin/master` when worker commits exist; fall back
      to hard reset only on conflict or a clean slate.

23. **Document the CLI fallback for graph tools**
    - ❌ DO NOT reference MCP graph tools in prompts without the CI fallback.
    - ✅ DO: every prompt citing `search_graph`/`trace_path`/
      `get_code_snippet` also documents
      `codebase-memory-mcp cli <tool> '<json>'`.

24. **Do not overwrite the MR description on no-changes runs**
    - ❌ DO NOT replace a useful description with a "no code changes"
      placeholder.
    - ✅ DO: update only the MR title (iteration count); leave the last
      successful description intact.

25. **Extract MR comment attachments**
    - ❌ DO NOT fetch MR notes as text-only and drop embedded `/uploads/`
      links.
    - ✅ DO: mine `/uploads/` from MR notes, download them, and export
      `BOUCLE_MR_ATTACHMENTS` for the worker prompt.

26. **Treat attachments as dual-nature**
    - ❌ DO NOT frame all attachments as "inspect for context".
    - ✅ DO: decide by intent — "use this file as X" → ship-as-asset
      (`cp` to `public/`, reference in build); "this is what's wrong" →
      inspect-for-context. Use `file <path>` for binary metadata; `cp` +
      reference ships an image without seeing it.

27. **Re-scrape logs when the found verdict is stale**
    - ❌ DO NOT gate log-scraping on `if [ -z "$VERDICT" ]` alone — a stale
      verdict blocks recovery of the current run's stdout.
    - ✅ DO: track `VERDICT_SHA_MATCHED`; re-scrape when empty OR SHA
      mismatched; let a fresher SHA-anchored stdout verdict override the
      stale one.

28. **Persist worker state across iterations**
    - ❌ DO NOT assume `.boucle/<issue>/` survives between iterations
      (gitignored, no artifact passing, `$CI_PROJECT_DIR` may be wiped).
    - ✅ DO: persist `.boucle/<issue>/` to `$BOUCLE_STATE_CACHE/<issue>/`
      and restore it at startup; the worker reads `iterations.md` to know
      what was already tried.

29. **Distinguish API outage from step exhaustion**
    - ❌ DO NOT treat an empty worker log as "agent exhausted its step
      budget".
    - ✅ DO: exit `4` on empty log / no agent activity → post a diagnostic
      naming the model, escalate to `boucle:human`, do not re-trigger.

30. **Fall back to a second provider before escalating**
    - ❌ DO NOT escalate to a human the moment the primary provider is down.
    - ✅ DO: when `BOUCLE_FALLBACK_PROVIDER` is set, retry with
      `$BOUCLE_FALLBACK_MODEL_<ROLE>` on the exit-4 condition; mark the
      iteration `[FALLBACK: provider/model]`. Escalate only if the fallback
      also fails. Each attempt is wrapped in `timeout` (per-role
      `AGENT_TIMEOUT`) so a hanging primary is killed before the job
      timeout eats the whole run — without this, the fallback block never
      executes because `run_with_retry` never returns.

31. **Download uploads via the GitLab API, not the raw /uploads/ URL**
    - ❌ DO NOT `curl -H "PRIVATE-TOKEN: $TOKEN" "https://$HOST/uploads/..."`
      to download attachments from issue/MR notes. The `/uploads/` endpoint
      uses cookie-based session auth — the `PRIVATE-TOKEN` header is ignored
      and the response is a GitLab login page (HTML), not the binary blob.
      The worker sees `file <path>` → "HTML document" and correctly refuses
      to ship it, falling back to a synthetic asset.
    - ✅ DO: use `glab api --method GET "/projects/$PROJECT_ID/uploads/:secret/:filename"
      -H "Accept: application/octet-stream"` which returns the binary blob
      with proper token-based auth. Applies to both `bin/fetch-issue-attachments`
      and `bin/fetch-mr-attachments`.

32. **Use DB-growth as the provider-agnostic "API down" signal**
    - ❌ DO NOT rely solely on log grep patterns to detect whether a provider
      is down — some providers (e.g. `opencode-go`) emit a transcript format
      the grep doesn't match, so a working run is false-flagged as "down" and
      the loop escalates to a human even though the plan still has tokens.
    - ✅ DO: `is_api_down` MUST also check the opencode SQLite DB growth
      delta (snapshot before the run vs. after). A dead run leaves the DB at
      the SQLite page-size baseline (4096b); a working run grows it well
      beyond. If the DB grew by more than 16KB, the agent did real work and
      the provider is NOT down — regardless of log patterns.

33. **Doctor MUST check active pipelines before re-triggering**
    - ❌ DO NOT use issue `updated_at` as a proxy for "is a pipeline
      running" — it is bumped by any issue activity (bot notes, label
      writes), not just pipeline runs. DO NOT set
      `BOUCLE_STALENESS_THRESHOLD` below the longest job timeout — the
      doctor will fire while a worker/reviewer is legitimately still
      running, producing parasitic duplicate triggers that queue
      unbounded via `resource_group`.
    - ✅ DO: the doctor MUST call `issue_has_active_pipeline` (which
      lists active pipelines and fetches each one's variables via
      `GET /projects/:id/pipelines/:pipeline_id/variables` to match
      `BOUCLE_ISSUE=<iid>`) before every re-trigger, and MUST apply a
      per-issue dedup timestamp (`$BOUCLE_STATE_CACHE/doctor-triggers/
      <iid>`) as a secondary backstop. `BOUCLE_STALENESS_THRESHOLD`
      MUST be strictly greater than the longest job timeout (default
      2400s vs worker/reviewer 30 min).

34. **Dispatch MUST skip system notes**
    - ❌ DO NOT treat GitLab system notes (assignee changes, label
      changes, branch additions) as human replies. A system note has
      `.object_attributes.system = true` and `.user.username` = the
      human who triggered the system action — so the ACTOR guard
      passes, but the note is NOT a human reply. Without a system-note
      filter, creating an issue + assigning the bot in the same form
      fires BOTH an `issue` webhook (open → triage) AND a `note`
      webhook (system "assigned to @up-bot" → triage again),
      double-triggering triage. The triage job has no `resource_group`
      (BOUCLE_ISSUE is not available at pipeline eval time), so the two
      pipelines run in parallel → congestion.
    - ✅ DO: the dispatch note-event handler MUST check
      `.object_attributes.system` and `exit 0` on system notes. The
      `BOT_JUST_ASSIGNED` path already handles assignment via the issue
      update webhook, so the system note is pure redundancy. The
      codebase already filters `system == false` when fetching notes
      via the API (worker/reviewer feedback) — the webhook handler
      MUST apply the same filter.

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
