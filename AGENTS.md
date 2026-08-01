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

17. **Parent-issue attachments not inherited** (issue #34 on up/urgence-palestine.fr)
    - ❌ DO NOT mine only the current issue for uploads when the issue is a
      sub-issue. Assets (logos, zips, mockups) are often uploaded to the
      parent issue only, and a worker that cannot find them improvises
      (fabricated monochrome logos instead of the real brand assets).
    - ✅ DO: `bin/fetch-issue-attachments` resolves the parent IID from the
      `## Parent issue\n#N` section (same awk pattern as `maybe_close_parent`
      and `resolve_reporter_id`) and appends the parent's description + notes
      to the text mined for `/uploads/...` paths. One level only, gated by
      `BOUCLE_PARENT_ATTACHMENTS_DISABLE` (default `false` = enabled).
    - Context: issue #34 (sub-issue of #33) needed the logo .zip uploaded to
      #33. `fetch-issue-attachments` fetched only #34's description + notes,
      never saw the .zip, and the worker fabricated fake logos. The parent
      link was already parsed by 5 other call sites in `.gitlab-ci.yml` —
      only `fetch-issue-attachments` missed it.

18. **bin/update requires GitHub auth (boucle not yet public)**
    - ❌ DO NOT assume `bin/update` works out of the box on a consumer.
      `boucle` is not yet a public GitHub repository. `bin/update` fetches a
      tarball from `https://codeload.github.com/ankaboot-source/boucle/...`
      without credentials, which 401s on a private repo. The consumer's
      dispatch pipeline silently fails-open (stays on the current version)
      and never picks up upstream fixes.
    - ✅ DO: until boucle is public, propagate upstream fixes to consumers
      **manually** — push the fix to `origin` on GitHub, then copy the
      changed `SYNC_PATHS` (`bin`, `.pi`, `.gitlab-ci.yml`, `.opencode/...`)
      into the consumer repo and bump `.boucle-version` to the upstream SHA.
      Track this limitation here and remove the entry once boucle is public
      and `bin/update` succeeds unauthenticated.

19. **MR description not refreshed on worker re-run** (issue #34 on up/urgence-palestine.fr)
    - ❌ DO NOT reuse an existing MR on iteration 2+ without updating its
      description. The worker deploys to a branch-based preview URL that
      changes between iterations, and the MR description carries the preview
      URL the reviewer tests against. A stale description points the
      reviewer at the wrong (old) URL — the reviewer may PASS a deployment
      that no longer exists, or FAIL a deployment that was never tested.
    - ✅ DO: the worker job calls `glab mr update` on the reused MR to
      refresh both the title and the description (new preview URL + new
      Approach + new commit summary) on every iteration. The reuse branch
      in `.gitlab-ci.yml` now updates the MR instead of silently reusing it.
    - Context: MR !30 iteration 2 deployed to
      `https://boucle-34.urgence-palestine.pages.dev` but the MR description
      still pointed at the iteration-1 URL
      `https://b87caf91.urgence-palestine.pages.dev`. The reviewer tested the
      stale URL and validated anyway. The user saw "logos still invisible"
      because the URL in the MR was wrong.

20. **Worker does not fill the Approach section in state.md** (issue #34 on up/urgence-palestine.fr)
    - ❌ DO NOT leave the `## Approach` section of `state.md` as the seed
      placeholder `(to be determined by worker)`. The Approach section
      becomes the MR description's `### Approach` block, which the reviewer
      reads to verify doc conformance (e.g. DESIGN.md §2 and §4 citations).
      An empty Approach causes repeated reviewer FAIL verdicts on the same
      criterion, wasting the iteration budget (`BOUCLE_MAX_ITERATIONS`).
    - ✅ DO: the worker MUST fill the Approach section with 2-5 sentences
      explaining the implementation approach and citing the specific charter
      doc sections it conformed to (`worker.md` step 8). The CI extraction
      (`APPROACH=$(sed -n '/^## Approach/,/^## /p' state.md ...`) now falls
      back to an explicit note when the section is still the placeholder, so
      the MR description is never the literal seed text.
    - Context: 3 reviewer FAIL verdicts on MR !30, all blocking on the same
      criterion: "MR description does not cite DESIGN.md §2 and §4". The
      worker (minimax-m3) understood the requirement (visible in the job
      trace) but never wrote it into `state.md`. The reviewer eventually
      PASSed with a lenient interpretation, but the loop wasted 2 iterations.

21. **Preview stale passes HTTP-200-only assertion** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT trust an HTTP 200 on the preview URL as proof that the deployed
      content matches the head commit. Three failure modes produce a 200
      with stale content: (a) the deploy step's exit code is swallowed by a
      `$(...) | grep | head` pipeline under `set +o pipefail`, so a failed
      redeploy is silently treated as success; (b) the CDN edge keeps serving
      cached content for seconds-to-minutes after a new deployment; (c) if the
      build output is byte-identical to the previous iteration (Astro/Vite
      cache hit on the shell executor), `wrangler pages deploy` returns the
      same content-hash URL and the preview never updates.
    - ✅ DO: the worker job writes a commit-SHA marker into the build output
      (`__boucle_commit__.txt` + an HTML comment in `index.html`) right after
      the build, captures the wrangler exit code separately from the URL
      extraction (subshell + log file, not a swallowing pipeline), and the
      deploy assertion fetches the marker from the preview URL with a retry
      loop (`BOUCLE_PREVIEW_PROPAGATION_WAIT`, default 60s, 5s backoff) until
      the deployed SHA matches the head SHA. A stale preview now FAILs the
      worker job instead of passing through to the reviewer.
    - Context: issue #35 iteration 3 deployed commit `6ca8aa33` but the
      preview kept serving the iteration-2 content (cards with titles, wrong
      grid, wrong links). The reviewer FAILed 3 times on "preview doesn't
      match the commit" while the worker kept re-running blind. The MR
      description refresh (lesson #19) fixed the wrong-URL path, but the
      stale-content path remained open until this marker + retry assertion
      was added.

22. **Destructive `git reset --hard` wipes validated worker commits** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT unconditionally `git reset --hard origin/master` at the start
      of every worker iteration. When the reviewer FAILs on a non-code issue
      (stale preview, missing doc citation, MR description placeholder), the
      worker's code from the previous iteration is correct and committed —
      a hard reset wipes it, forcing the next worker to re-implement from
      scratch in its 50-step budget. The worker exhausts its steps
      reconstituting context and produces an empty or trivial MR.
    - ✅ DO: preserve worker commits and rebase. If
      `git log origin/master..$BRANCH --oneline` shows worker commits, run
      `git rebase origin/master` to keep the work on top of the latest master.
      Fall back to `git reset --hard origin/master` ONLY when the rebase
      conflicts or the branch has no worker commits (clean slate). This keeps
      the anti-accumulation property (lesson #8) without destroying validated
      work on non-code FAILs.
    - Context: issue #35 iteration 3 produced commit `6ca8aa33` (full
      FeaturedFeed.astro + index.astro + sections.css + tokens.css, all 5
      tahrir comments addressed). The reviewer FAILed on a stale preview
      (lesson #21), not on the code. The next iteration's `git reset --hard
      origin/master` wiped `6ca8aa33` (now an orphan in the repo), leaving
      only `fa1699f2` (a token-only commit). The next worker spent all 50
      steps reconstituting context and produced no code changes.

23. **Codebase graph indexed in CI but unusable by agents** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT instruct agents to use MCP graph tools (`search_graph`,
      `trace_path`, `get_code_snippet`) without documenting the CLI fallback
      for CI. `bin/oc` strips MCP servers from the opencode config in CI
      (lesson #3, MCP handshake hangs within 30s), so the tools the agent
      prompts reference do not exist at runtime. The graph is built every run
      (`codebase-memory-mcp cli index_repository`) but never queried — wasted
      compute and blind agents that fall back to `grep`/`glob`.
    - ✅ DO: document the CLI fallback in every agent prompt that references
      graph tools. The CLI is available in CI as
      `codebase-memory-mcp cli <tool> '<json>'` (e.g.
      `codebase-memory-mcp cli search_graph '{"name_pattern":".*FeaturedFeed.*"}'`).
      Agent prompts (`worker.md`, `triage.md`, `reviewer.md`) now list both
      the MCP tools (local dev) and the CLI fallback (CI) with concrete
      examples, so the agent knows how to query the graph in both
      environments.
    - Context: `worker.md:12-20` told the worker to use `search_graph` and
      `trace_path`, but `bin/oc:170` (`strip_mcp_for_ci`) removed those tools
      in CI. The worker (minimax-m3) on issue #35 iteration 4 fell back to
      `ls`/`cat`/`git log` to reconstitute the codebase, burning steps that
      should have gone to implementation. The graph was indexed but unused.

24. **MR description frozen at iteration 1 on no-changes re-runs** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT skip the MR description refresh when the worker produces no
      code changes. The "no changes" handler (`exit 1` before the build/deploy
      block) runs BEFORE the `glab mr update` that refreshes the description
      with the new iteration number and preview URL. When the worker exhausts
      its step budget across iterations 2 and 3 without committing, the MR
      description stays frozen at "iteration 1" with the original preview URL
      — the reviewer and the user see a misleading description that does not
      reflect the actual loop state.
    - ✅ DO: refresh the MR description in the "no changes" handler itself,
      before the `exit 1`. Fetch the existing MR by source branch, preserve
      its current preview URL (if any), and update title + description to
      reflect the current iteration and the "no code changes" status. The
      reviewer and the user now see the real iteration count and a clear
      "no commits this iteration" status instead of a stale "iteration 1".
    - Context: issue #35 iterations 2 and 3 both exhausted the step budget
      before committing (the destructive reset of lesson #22 wiped the
      prior validated work, forcing re-implementation from scratch). The MR
      !31 description stayed at "iteration 1" with the original preview URL
      throughout, misleading the user who reported "la description de la MR
      indique toujours iteration 1 avec la preview URL initiale".

25. **MR comment attachments not extracted** (issue discovered 2026-08-01)
    - ❌ DO NOT fetch MR notes as text-only (`.body` field) and silently drop
      embedded `/uploads/...` image links. A reviewer or human who attaches a
      screenshot of a bug or a mockup to an MR comment has their text passed
      to the worker but the image is invisible — the worker cannot see the
      very evidence that prompted the feedback.
    - ✅ DO: `bin/fetch-mr-attachments` mirrors `bin/fetch-issue-attachments`
      for merge requests. It mines `/uploads/` paths from MR notes
      (`/projects/<id>/merge_requests/<iid>/notes`), downloads them to
      `.boucle/<issue>/mr-attachments/`, and exports `BOUCLE_MR_ATTACHMENTS`
      via `.mr-attachments.env`. `bin/oc` sources this and appends the paths
      to the agent prompt so the worker can `Read` reviewer/human screenshots.
      Gated on `MR_FOR_FEEDBACK` being non-empty (no MR on first run).
    - Context: `bin/fetch-issue-attachments` mined issue descriptions + notes +
      parent-issue notes for `/uploads/` paths, but the symmetric MR path
      (`bin/oc:298-315` injecting `BOUCLE_REVIEWER_FEEDBACK` as plain text)
      never resolved embedded image links. A human commenting "this button is
      wrong" with a screenshot got the text through to the worker but the
      screenshot was dropped.

26. **Attachment framing conflates "inspect for context" with "ship as asset"** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT frame all attachments (issue + MR) as "Read each file to
      inspect them… use them as context for addressing reviewer feedback".
      Attachments have a **dual nature**: they may be (a) source assets the
      user wants shipped (logos, photos, illustrations — copy to `public/`
      and reference in the build), OR (b) mockups/screenshots for context
      (reviewer feedback, bug reports — inspect for guidance, do not ship).
      A single "use as context" framing primes the worker to *consult* the
      file, not to *adopt* it. When the worker cannot see the image (text-only
      model — `Read` on a PNG returns garbage), it fabricates a substitute
      instead of copying the uploaded file.
    - ✅ DO: `bin/oc` and `worker.md` frame attachments as dual-nature. The
      worker decides based on the comment's intent: "use this file as the
      separator" → ship-as-asset (`cp` to `public/`, reference in build);
      "this is what's wrong" → inspect-for-context. The worker uses `file
      <path>` (not `Read`) to get dimensions/metadata on binaries — `Read`
      on a PNG returns base64 garbage on text-only models. The worker does
      NOT need to *see* the image to *ship* it — `cp` + reference is enough.
    - Context: issue #35, tahrir commented "il doit y avoir une séparation
      visuelle entre les colonnes avec le visuel ci-joint" + uploaded
      `vertical_keffiyeh.png`. The worker downloaded it (21251 bytes
      confirmed), was told to "use as context", could not `Read` the PNG
      (minimax-m3 is text-only), and fabricated a fake Palestinian flag +
      Unicode symbol instead of `cp`-ing the uploaded file to `public/`.

27. **Log-scraping fallback bypassed when a stale verdict exists** (issue #35 on up/urgence-palestine.fr)
    - ❌ DO NOT gate the log-scraping fallback on `if [ -z "$VERDICT" ]` alone.
      The SHA-unanchored fallback (which finds the newest `boucle:verdict`
      regardless of SHA) may set VERDICT to a **stale** verdict from a previous
      iteration (different SHA than the current MR head). Once VERDICT is
      non-empty, the log-scraping is skipped — the current run's drafted
      verdict in stdout (which is fresher and SHA-correct) is lost.
    - ✅ DO: track whether the found verdict matches the current MR head SHA
      (`VERDICT_SHA_MATCHED` flag). Run the log-scraping if VERDICT is empty
      OR if `VERDICT_SHA_MATCHED=false` (stale verdict). If the log-scraping
      finds a fresher verdict (SHA-anchored in stdout), override the stale
      verdict. This recovers the current run's verdict even when an old
      verdict note exists on the MR.
    - Context: issue #35 iteration 4, reviewer 3830247 posted a FAIL verdict
      in stdout (4/5 criteria PASS, 1 FAIL on MR description) but exhausted
      its 35 steps before posting via `glab mr note`. The SHA-anchored parse
      found nothing (not posted). The SHA-unanchored fallback found the old
      UNCERTAIN verdict (note 2417731, sha=28071e46 ≠ head 0c2f979b), set
      VERDICT=UNCERTAIN, and the log-scraping was skipped. The CI escalated
      to `boucle:human` with "Verdict unparsable or uncertain" instead of
      acting on the FAIL verdict that was sitting in stdout.

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
