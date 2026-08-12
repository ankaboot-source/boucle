# AGENTS.md — Boucle agent guide

> **Maintenance** — This document captures lessons learned, anti-patterns
> and operating principles for agents. **Any new lesson discovered must be
> added here** to avoid repeating the same mistakes. See
> [CONTEXT.md](CONTEXT.md) for the project context and tech stack.

## Reference files (charter files)

Before working on any issue, agents MUST consult these files at the repo root:

- [AGENTS.md](AGENTS.md) — this document. Lessons learned and conventions.
- [README.md](README.md) — project overview and getting started.
- [LOOP.md](LOOP.md) — per-consumer configuration (target repo, cadence, gates, caps).
- [CONTEXT.md](CONTEXT.md) — project context, tech stack, constraints.

**FORBIDDEN** to start any work without first reading [LOOP.md](LOOP.md)
and [CONTEXT.md](CONTEXT.md).

## Agent roles

| Agent   | Model                       | Steps | Temp | Role                                                                                                                |
| ------- | ---------------------------- | ----- | ---- | ------------------------------------------------------------------------------------------------------------------- |
| triage  | ollama-cloud/glm-5.2        | 200   | 0.3  | Analyzes issue, posts structured comment (TL;DR + Analysis + Acceptance criteria + Classification S/M/L + Questions + Disposition) |
| worker  | ollama-cloud/deepseek-v4-flash:0731 | 100   | —    | Implements on branch `boucle/<iid>`, reads `state.md`, uses codebase-memory-mcp, conventional commit                 |
| reviewer| ollama-cloud/deepseek-v4-flash:0731 | 35    | 0.2  | Adversarial review against preview URL, SHA-anchored verdict                                                       |
| e2e     | ollama-cloud/glm-5.2         | 30    | —    | Verifies on production URL, SHA-anchored verdict                                                                    |

See [LOOP.md](LOOP.md) for the pipeline and state machine details.

## MANDATORY operating principles

These principles are **NON-NEGOTIABLE**. Any agent that violates them introduces a
known recurring bug, documented in the "Lessons learned" section.

1. **Post-early rule** — The agent MUST post its comment or verdict **FIRST**, then
   refine it afterward. Step-limit waste (the agent exhausts its budget without ever
   posting) is bug #1. **Rule**: an incomplete draft posted is ALWAYS better than a
   refinement never posted.

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
    - ❌ DO NOT assume the hierarchy PATCH succeeded — on self-managed
      GitLab with `work_item_rest_api` disabled it returns 403 and the
      parent-child relationship becomes invisible in the UI.
    - ✅ DO: use the work-items hierarchy API; check the PATCH HTTP status
      and on non-2xx fall back to a REST `relates_to` issue link (visible
      under "Linked items" on the parent); fall back to the
      `legacy split-parent marker` comment for machine-readable recovery
      when neither API is available.

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

 19. **Refresh the MR description on every iteration**
    - ❌ DO NOT reuse an existing MR on iteration 2+ with a stale
      description (preview URL, Approach, commit summary drift).
    - ✅ DO: update title + description on every iteration via
      `glab mr update`.

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
    - ❌ DO NOT fall back to `git reset --hard` when a rebase CONFLICTS on a
      branch that holds worker commits — the reset orphans the pushed
      commit, empties the MR (`detailed_merge_status=commits_status`) and
      sends the merger/doctor into an infinite escalation loop.
    - ✅ DO: `git rebase origin/master` when worker commits exist; on
      conflict, `git rebase --abort` and PRESERVE the branch (hand the
      conflict to the bounded re-trigger path). Fall back to hard reset
      ONLY on a true clean slate (no worker commits).

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
    - ❌ DO NOT rely on `is_api_down` (empty log / no agent activity) as
      the only fallback trigger. A persistent quota error (HTTP 429/402,
      "you have reached your weekly usage limit") leaves activity traces in
      the agent log, so `is_api_down` reports the provider as "up" and the
      loop escalates to a human instead of falling back — even though
      retrying cannot fix an exhausted quota.
    - ✅ DO: treat persistent quota exhaustion (HTTP 429/402 or explicit
      quota/credit messages, detected by `is_quota_exhausted`) as a
      provider-down condition on the exit-4 path, gated on a non-zero run
      exit so a successful run that merely quotes "429" is not
      misclassified.
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

32. **Detect provider downtime by absence of agent activity**
    - ❌ DO NOT rely on error-pattern greps to decide a provider is down —
      a hung or dead provider produces no error lines at all, only silence,
      so an error-grep passes and the loop waits on a run that will never
      produce output.
    - ✅ DO: `is_api_down` in `bin/jc` returns "down" when the agent log is
      empty or contains no activity traces (tool calls, file reads, git
      operations, source paths, comment markers). A working agent always
      leaves activity in its log; a dead provider leaves silence. This is
      provider-agnostic — it holds for any transcript format, so a working
      run is never false-flagged as "down". On "down", `bin/jc` exits `4`,
      the fallback provider is tried before any human escalation, and a
      diagnostic comment is posted on the issue.

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

36. **Approach MUST use bullet points, not sentences**
    - ❌ DO NOT write the `## Approach` section as a paragraph of
      2-5 sentences. GitLab markdown renders single newlines (soft
      breaks) as spaces, so a paragraph becomes an unreadable wall of
      text in the MR description. The worker prompt said "Write 2-5
      sentences" — the worker wrote one long paragraph, and the MR
      description was a single 500-char block with no visual structure.
    - ✅ DO: write the Approach as 3-6 bullet points (`- item`), one
      per aspect of the implementation. Each bullet cites the charter
      doc section it conforms to (e.g. "Conforms to the visual charter §2 —
      sharp corners via `--radius-sharp`"). Bullet points and blank
      lines render properly in GitLab markdown.

37. **Push consumer fixes upstream in the SAME session**
    - ❌ DO NOT land a fix on the consumer repo (`master`) and defer the
      upstream push to "later". The upstream-first workflow
      (`.jcode/UPSTREAM-FIX-WORKFLOW.md`) says "fix upstream FIRST,
      then update consumer" — but in practice fixes land on consumer
      `master` first (that's where the work happens) and the upstream
      push is forgotten. This grows the divergence between consumer
      `master` and upstream `main` (100+ commits behind/ahead on a
      consumer repo as of 2026-08) until the two lines become
      unmanageable.
    - ❌ DO NOT push consumer `master` directly to upstream
      (`origin/main`). The two repos use different default branches
      (`master` vs `main`) and have divergent histories — a direct
      push is non-fast-forward and will be rejected (or worse,
      force-pushed, destroying upstream history).
    - ❌ DO NOT trust the commit-count divergence as a measure of
      real drift. `bin/update` syncs upstream → consumer via
      `cp -r` (file replacement, not git merge), so each sync creates
      a new commit SHA on consumer that doesn't match the upstream
      SHA. Git then reports upstream commits as "not present" even
      though their **content** is already there. Check file content,
      not commit count, to assess real drift.
    - ✅ DO: when a fix lands on consumer `master`, push it upstream
      **in the same session**: branch from `origin/main`, cherry-pick
      the consumer commit(s), push the branch, open a PR. This is
      mandatory — not optional, not "later".
    - ✅ DO: accept that consumer `master` and upstream `main` are
      **intentionally divergent** — consumer has consumer-specific
      features (`feat:` commits) that will never go upstream, and
      upstream has its own commit history. The goal is not zero
      divergence but **no unpushed fixes** — every fix on consumer
      must have a corresponding upstream PR (merged or open).

38. **Never leak consumer information in upstream contributions**
    - ❌ DO NOT include consumer-identifying information in upstream
      (boucle) contributions — PRs, issues, commits, branch names,
      or any artifact visible on the upstream repo. The upstream
      boucle repo is shared/public; consumer project information is
      private. This includes:
      - Consumer project names (e.g. the consumer domain or repo name)
      - Consumer GitLab hostnames or project paths
      - Consumer issue/MR IIDs (e.g. "#35" on the consumer repo)
      - Consumer-specific configuration values
    - ❌ DO NOT write "fixes from work on <consumer-name>" or
      "found on <consumer-domain>" in PR descriptions. This leaks
      the consumer identity to anyone reading the upstream repo.
    - ✅ DO: use generic language in upstream contributions:
      "consumer work", "a consumer repo", "discovered during
      consumer testing" — never the actual consumer name.
    - ✅ DO: strip consumer issue references from commit messages
      before cherry-picking upstream. A consumer issue `(#35)` becomes
      nothing or a generic `(consumer)` when pushed upstream.
    - ✅ DO: ask the human explicitly if a consumer name MUST be
      shared upstream for context — otherwise it stays private.
    - ✅ DO: keep the origin benchmark documented. Boucle was extracted
      from a real product — a static Astro site (GitLab, Cloudflare Pages).
      The origin-era history has been ANONYMIZED (owner decision, 2026-08):
      all pre-extraction author/committer identities and forge references
      were rewritten to the maintainer's identity in a history rewrite.
      The rules above protect *third-party consumers* — never re-introduce
      consumer-identifying content in upstream contributions.

40. **Split bookkeeping MUST be atomic and label-first**
    - ❌ DO NOT post the human "Split into" comment, the
      `boucle:split-parent` marker, and the `boucle:split` label as
      separate steps in that order — a job failure between steps leaves
      a human comment without its marker, so the retry re-splits:
      duplicate sub-issues and duplicate "Split into" comments.
    - ❌ DO NOT format the sub-issue list with `sed 's/,/#, #/g'` — it
      produces `#38#, #39#, #40` (broken issue links). Use
      `sed 's/,/, #/g'` → `#38, #39, #40`.
    - ✅ DO: set the `boucle:split` label FIRST (dispatch and doctor stop
      re-triaging even if later steps fail), then post ONE merged comment
      containing both the human-readable list and the
`<!-- boucle:split-parent iids=... -->` marker — a single POST is
atomic.

41. **Anchor VERDICT greps to start-of-line**
    - ❌ DO NOT use `grep -E 'VERDICT: (PASS|FAIL|UNCERTAIN)'` without a
      `^` start-of-line anchor in the verdict parsing pipeline. opencode's
      bash tool traces commands with `set -x`-style output (ANSI color +
      `$ ` PS4 prompt) in `agent-output.log`. A trace line like
      `[0m$ [0mglab mr note 36 --message "VERDICT: PASS"` contains the
      substring `VERDICT: PASS` — an unanchored grep matches it inside the
      trace, and the log-scraping fallback posts the trace as a verdict
      note. The result: a malformed note (containing shell trace output)
      appears on the MR, and CI may parse a phantom VERDICT from a command
      the agent echoed but never actually posted as a real verdict.
    - ❌ DO NOT assume the awk `^VERDICT:` exit guard is sufficient. The
      awk exits on `^VERDICT:` (start-of-line), but the trace line starts
      with `[0m$` (ANSI reset + PS4), so awk keeps printing past it. The
      downstream `grep -qiE 'VERDICT: ...'` validation then matches the
      substring inside the trace line — because it is NOT anchored.
    - ✅ DO: anchor EVERY `grep` that validates or extracts a VERDICT with
      `^`: `grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'` for validation
      and `grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)'` for extraction.
      This applies to both the reviewer and e2e jobs, in both the primary
      note-parse and the log-scraping fallback. The `^` anchor ensures the
      grep only matches a real `VERDICT:` line (posted by the agent as a
      verdict), never a substring inside a shell trace or quoted command.

42. **Merger MUST handle "Pipelines must succeed" via MWPS**
    - ❌ DO NOT fail the merger when `detailed_merge_status` is
      `pipeline_status_must_pass` or `checking` after a short poll. The
      force-push (rebase) triggers a new pipeline on the MR branch. If the
      GitLab project has "Pipelines must succeed" enabled, GitLab refuses
      to merge until that pipeline completes — and a 2-minute poll window
      is far too short for a full CI run. The merger fails → `boucle:human`
      → the MR sits approved-but-unmerged even though everything is fine.
    - ❌ DO NOT assume `merge_when_pipeline_succeeds=false` is always the
      right merge mode. It only works when the MR is immediately
      `mergeable`. When a pipeline is running, GitLab rejects the immediate
      merge with a 405 and the merger treats the empty `merge_commit_sha`
      as a hard failure.
    - ✅ DO: poll `detailed_merge_status` for up to 10 min (60×10s),
      tolerating `checking`/`pipeline_status_must_pass`/`pipeline_blocked`
      as transient states. If the pipeline is still running after the poll
      window, switch to `merge_when_pipeline_succeeds=true` (MWPS) — GitLab
      merges automatically once the pipeline passes. Post a note so the
      human knows the merge is scheduled, and exit 0 (the deploy triggered
      by the eventual merge + the doctor's staleness check close the loop).

43. **Never use `UNCERTAIN|*)` as a case catch-all**
    - ❌ DO NOT use `UNCERTAIN|*)` as the catch-all branch in a bash `case`
      statement that switches on `$VERDICT`. In bash, `*)` matches the empty
      string, so when the agent posted no verdict (step-exhausted, crashed,
      or only a draft with no `VERDICT:` line), `VERDICT` is empty and the
      `UNCERTAIN|*)` branch fires — prematurely escalating to
      `boucle:human`, assigning the MR to the human, and posting the
      "unparsable" note. This happens BEFORE the post-case assertion (which
      would have re-triggered the reviewer/e2e for another attempt). The
      result: the MR is assigned to the human while the re-triggered
      reviewer is still running, and 3 duplicate "unparsable" notes appear
      on the issue (one per iteration, because each iteration's case block
      fires the catch-all before the assertion re-triggers). This was
      MR !40 on a consumer repo: the reviewer posted only drafts
      on iterations 1-2, the catch-all fired each time, and the human saw
      "assigned mid-review" + a cascade of failed trigger pipelines.
    - ❌ DO NOT conflate "genuinely UNCERTAIN verdict" (agent posted
      `VERDICT: UNCERTAIN`) with "no verdict found" (agent posted nothing
      parsable). These are two different conditions requiring different
      actions: UNCERTAIN is a terminal human escalation; empty VERDICT is
      a retryable failure that should re-trigger the agent.
    - ✅ DO: use `UNCERTAIN)` (no `|*`) as an explicit branch for the
      genuine UNCERTAIN verdict. Let empty VERDICT fall through the `case`
      without side effects, and handle it exclusively in the post-case
      assertion (`if [ -z "$VERDICT" ]; then ... re-trigger or escalate`).
      The assertion already has the iteration logic (`iter < MAX_ITER` →
      re-trigger, else → escalate to human with MR assignment + note).
      This applies to BOTH the reviewer job and the e2e job — they share
      the same `case "$VERDICT" in ... UNCERTAIN|*) ... esac` +
      `if [ -z "$VERDICT" ]` pattern.

44. **Never run the loop on a closed issue**
    - ❌ DO NOT let the worker, reviewer, or dispatch re-trigger a role on a
      closed issue. A closed issue is terminal — the catchup job closed it
      after a merge (or a human closed it manually). Running the worker on a
      closed issue creates a zombie MR; the reviewer then FAILs the zombie MR
      and re-triggers the worker, which runs again on the closed issue — an
      infinite loop on a corpse. The doctor cannot recover it because its
      main scan filters `state=opened`, so the closed issue with
      `boucle:working` is invisible.
    - ❌ DO NOT assume the worker is safe from closure mid-run. A human can
      merge another MR for the same issue while a worker iteration is in
      flight — the catchup closes the issue, then the worker's
      rebase-conflict handler (master advanced) re-triggers itself on the
      now-closed issue. The rebase-conflict re-trigger path MUST check issue
      state before chaining.
    - ❌ DO NOT let issue webhooks (update/note/emoji) re-trigger the loop on
      a closed issue. Only MR webhooks had a closed-issue guard — issue
      webhooks did not. A label change on a closed issue (e.g. the reviewer
      FAIL setting `boucle:todo`) fires an issue update webhook → dispatch
      no-ops → the EXIT trap flips exit 0 to exit 1 → a cascade of failed
      pipelines. The one exception is `BOT_JUST_ASSIGNED`: a human assigning
      the bot to a closed issue is an explicit re-trigger signal (the human
      wants to reopen and resume work).
    - ✅ DO: add a closed-issue guard at the START of the worker job (before
      `set_boucle_label boucle:working`), in the worker's rebase-conflict
      re-trigger path, in the reviewer FAIL handler (before re-triggering the
      worker), and in the dispatch issue-webhook handler (before label-based
      routing). Each guard fetches the issue state and exits 0 if closed.
    - ✅ DO: extend the doctor to scan `state=closed` issues with
      `boucle:working` or `boucle:review` labels — recover them by closing
      any open zombie MRs and setting `boucle:done`. This is the safety net
      for the case where a guard was missing or bypassed.

45. **Distinguish draft from final by structure, not body text**
    - ❌ DO NOT detect a draft triage/reviewer comment by grepping the body
      for the word "DRAFT". The word "DRAFT" can legitimately appear in
      website content being triaged (e.g. a draft page the author wants
      reviewed), so a body-text grep produces false positives.
    - ❌ DO NOT post a first-pass draft with the FINAL marker
      (`<!-- boucle:triage v=1 -->` or `<!-- boucle:verdict v=1 ... -->`).
      The CI parser acts immediately on the final marker — it sets the
      disposition label, assigns the issue/MR, and pauses the loop before
      the agent can refine. The refinement is wasted. This was issue #42
      on a consumer repo: the triage agent posted a NEEDS-INFO draft with
      the final `<!-- boucle:triage v=1 -->` marker, the CI immediately
      set `boucle:needs-info` + `boucle::status::human` and assigned the
      issue to the reporter, before the agent could post its refined
      comment with the actual blocking questions.
    - ✅ DO: use the dedicated draft marker (`<!-- boucle:draft role=triage -->`
      / `<!-- boucle:draft role=reviewer -->`) for first-pass drafts. The
      CI parser does NOT match `boucle:draft` — it only matches `boucle:triage`
      / `boucle:verdict`. The log-scraping fallback promotes `boucle:draft`
      to the final marker when the agent exhausts its steps.
    - ✅ DO: make the CI parser require a STRUCTURAL section that only
      final comments have. For triage, the final comment starts with
      `## TL;DR` (per the prompt format spec); a draft only has
      `## Disposition`. The jq filter is
      `select(.body | test("## TL;DR")) and select(.body | test("## Disposition"))`.
      This is structural (section header), not body-text — it will not
      false-match website content. This is defense-in-depth: even if the
      agent uses the wrong marker, the parser won't act on a draft that
      lacks `## TL;DR`.

46. **Preserve instructed content**
    - ❌ DO NOT generate placeholders for content the issue instructs. If
      the issue body specifies a video URL, a citation, a text, or an
      image, the worker MUST ship it verbatim — never a generic
      placeholder (e.g. a Rickroll video ID `dQw4w9WgXcQ` in place of the
      instructed URL), never a paraphrase, never a substitute.
    - ❌ DO NOT rewrite the instructed texts. If the issue quotes an
      author verbatim, the worker ships that quote — it does not
      summarize, paraphrase, or generate a new critique.
    - ❌ DO NOT let later amendments override earlier preservation
      instructions. The feedback channel injects the latest human
      amendments (e.g. "fill empty spaces with the brand pattern", "single CTA")
      WITHOUT the earlier preservation context (e.g. "keep the
      texts/visuals/videos already shared", "video in front,
      horizontal"). The worker applies the latest amendment literally
      and degrades the validated layout — replacing the video with
      the brand pattern instead of filling the empty space below it.
    - ✅ DO: inject `BOUCLE_ISSUE_BODY` and `BOUCLE_ISSUE_NOTES` into the
      worker job (mirroring the triage job) so the worker has the
      instructed content and the full discussion history at hand without
      spending steps on `glab issue view`.
    - ✅ DO: inject `BOUCLE_ISSUE_BODY` into the reviewer job so it can
      verify the MR content matches the original spec — a MR with
      placeholder videos or rewritten citations is a FAIL even if it
      satisfies the latest amendments.
    - ✅ DO: add a "Preserve instructed content" instruction to the
      worker prompt stating that amendments AMEND the spec, they do NOT
      replace earlier preservation instructions — conciliate them.

47. **Gate-skip transparency**
    - ❌ DO NOT auto-skip a gate (spec gate, approval gate, any quality
      gate) without leaving a visible, self-explanatory trace on the
      issue. A silent skip — where the loop proceeds past a gate with
      no comment and no flag label — leaves the human unable to
      understand why the gate was not respected. The issue arrives at
      the next state with no indication of WHY the gate was bypassed,
      so the human cannot audit the decision or disable the skip if
      it was unwanted.
    - ❌ DO NOT post a terse one-liner ("spec auto-validé") as the only
      trace. A one-liner states WHAT happened but not WHY (which
      condition triggered the skip), WHAT happens next (the loop
      continues to the MR), or HOW to disable it (the relevant CI
      variable or label to remove).
    - ✅ DO: every gate-skip path MUST (1) post an explanatory comment
      naming the trigger condition (DND window with its active range,
      or the `boucle:autonomous` label), stating what happens next
      (loop continues to the MR, human validates the MR), and how to
      disable it (the CI variable or label to remove); AND (2) apply a
      flag label (`boucle:dnd` / `boucle:autonomous`) that rides along
      to the next state via `set_boucle_label` so the skip reason is
      visible on the board at a glance. The flag label is transient —
      `set_boucle_label` strips `boucle:*` labels on the next state
      transition, so it is a one-step signal, not a persistent state.

17. **Parent-issue attachments not inherited** (issue #34 on a consumer repo)
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
      changed `SYNC_PATHS` (`bin`, `.pi`, `.gitlab-ci.yml`, `.jcode/...`)
      into the consumer repo and bump `.boucle-version` to the upstream SHA.
      Track this limitation here and remove the entry once boucle is public
      and `bin/update` succeeds unauthenticated.

19. **MR description not refreshed on worker re-run** (issue #34 on a consumer repo)
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
      `https://boucle-34.<consumer>.pages.dev` but the MR description
      still pointed at the iteration-1 URL
      `https://b87caf91.<consumer>.pages.dev`. The reviewer tested the
      stale URL and validated anyway. The user saw "logos still invisible"
      because the URL in the MR was wrong.

20. **Worker does not fill the Approach section in state.md** (issue #34 on a consumer repo)
    - ❌ DO NOT leave the `## Approach` section of `state.md` as the seed
      placeholder `(to be determined by worker)`. The Approach section
      becomes the MR description's `### Approach` block, which the reviewer
      reads to verify doc conformance (e.g. visual charter §2 and §4 citations).
      An empty Approach causes repeated reviewer FAIL verdicts on the same
      criterion, wasting the iteration budget (`BOUCLE_MAX_ITERATIONS`).
    - ✅ DO: the worker MUST fill the Approach section with 2-5 sentences
      explaining the implementation approach and citing the specific charter
      doc sections it conformed to (`worker.md` step 8). The CI extraction
      (`APPROACH=$(sed -n '/^## Approach/,/^## /p' state.md ...`) now falls
      back to an explicit note when the section is still the placeholder, so
      the MR description is never the literal seed text.
    - Context: 3 reviewer FAIL verdicts on MR !30, all blocking on the same
      criterion: "MR description does not cite the visual charter §2 and §4". The
      worker (minimax-m3) understood the requirement (visible in the job
      trace) but never wrote it into `state.md`. The reviewer eventually
      PASSed with a lenient interpretation, but the loop wasted 2 iterations.

21. **Preview stale passes HTTP-200-only assertion** (issue #35 on a consumer repo)
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

22. **Destructive `git reset --hard` wipes validated worker commits** (issue #35 on a consumer repo)
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
      On rebase conflict, `git rebase --abort` and PRESERVE the branch —
      NEVER reset it (a destructive reset orphans the pushed commit, empties
      the MR and loops the merger/doctor). Fall back to
      `git reset --hard origin/master` ONLY when the branch has no worker
      commits (true clean slate). This keeps the anti-accumulation property
      (lesson #8) without destroying validated work on non-code FAILs.
    - Context: issue #35 iteration 3 produced commit `6ca8aa33` (full
      FeaturedFeed.astro + index.astro + sections.css + tokens.css, all 5
      human comments addressed). The reviewer FAILed on a stale preview
      (lesson #21), not on the code. The next iteration's `git reset --hard
      origin/master` wiped `6ca8aa33` (now an orphan in the repo), leaving
      only `fa1699f2` (a token-only commit). The next worker spent all 50
      steps reconstituting context and produced no code changes.

23. **Codebase graph indexed in CI but unusable by agents** (issue #35 on a consumer repo)
    - ❌ DO NOT instruct agents to use MCP graph tools (`search_graph`,
      `trace_path`, `get_code_snippet`) without documenting the CLI fallback
      for CI. `bin/jc` strips MCP servers from the jcode config in CI
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
      `trace_path`, but `bin/jc:170` (`strip_mcp_for_ci`) removed those tools
      in CI. The worker (minimax-m3) on issue #35 iteration 4 fell back to
      `ls`/`cat`/`git log` to reconstitute the codebase, burning steps that
      should have gone to implementation. The graph was indexed but unused.

24. **MR description overwritten on no-changes re-runs** (issue #35 on a consumer repo)
    - ❌ DO NOT overwrite the MR description when the worker produces no code
      changes. The previous description may contain a detailed Approach and a
      working preview URL from the last successful iteration — replacing them
      with a "no code changes" placeholder destroys useful information. The
      user reported: "s'il y a pas de résultats pas la peine d'écraser le
      précédent contenu".
    - ✅ DO: update only the MR TITLE to reflect the current iteration (so
      the user sees the real iteration count), but leave the DESCRIPTION
      untouched. The iteration status is already tracked via the issue note
      posted by the no-changes handler. The description from the last
      successful iteration is more useful than a "no commits this iteration"
      placeholder.
    - Context: issue #35 iteration 3 produced a full implementation (FeaturedFeed.astro,
      index.astro, sections.css, tokens.css) with a detailed Approach citing
      the visual charter. A later no-changes run overwrote the description with
      "Issue #35 — iteration 1 (no code changes)" + "(no commits this
      iteration)", wiping the Approach and the working preview URL.

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
      via `.mr-attachments.env`. `bin/jc` sources this and appends the paths
      to the agent prompt so the worker can `Read` reviewer/human screenshots.
      Gated on `MR_FOR_FEEDBACK` being non-empty (no MR on first run).
    - Context: `bin/fetch-issue-attachments` mined issue descriptions + notes +
      parent-issue notes for `/uploads/` paths, but the symmetric MR path
      (`bin/jc:298-315` injecting `BOUCLE_REVIEWER_FEEDBACK` as plain text)
      never resolved embedded image links. A human commenting "this button is
      wrong" with a screenshot got the text through to the worker but the
      screenshot was dropped.

26. **Attachment framing conflates "inspect for context" with "ship as asset"** (issue #35 on a consumer repo)
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
    - ✅ DO: `bin/jc` and `worker.md` frame attachments as dual-nature. The
      worker decides based on the comment's intent: "use this file as the
      separator" → ship-as-asset (`cp` to `public/`, reference in build);
      "this is what's wrong" → inspect-for-context. The worker uses `file
      <path>` (not `Read`) to get dimensions/metadata on binaries — `Read`
      on a PNG returns base64 garbage on text-only models. The worker does
      NOT need to *see* the image to *ship* it — `cp` + reference is enough.
    - Context: issue #35, the human commented "il doit y avoir une séparation
      visuelle entre les colonnes avec le visuel ci-joint" + uploaded
      `vertical_pattern.png`. The worker downloaded it (21251 bytes
      confirmed), was told to "use as context", could not `Read` the PNG
      (minimax-m3 is text-only), and fabricated a fake substitute graphic +
      Unicode symbol instead of `cp`-ing the uploaded file to `public/`.

27. **Log-scraping fallback bypassed when a stale verdict exists** (issue #35 on a consumer repo)
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

28. **Worker state not persisted between iterations** (issue #35 on a consumer repo)
    - ❌ DO NOT assume `.boucle/<issue>/` survives between worker iterations.
      `.boucle/` is gitignored (state.md, iterations.md, agent-output.log
      are NOT committed), and the worker re-triggers itself via the API
      (new pipeline, no `needs` link → no artifact passing). On a shell
      executor `$CI_PROJECT_DIR` may be wiped between runs. Each iteration
      then starts with a fresh seed: `state.md` = "(to be determined by
      worker)", `iterations.md` = absent. The worker rebuilds context from
      scratch — re-discovering the codebase, re-reading charter docs,
      re-trying rejected approaches — and exhausts its step budget before
      implementing. Issue #35 had 2 consecutive iterations produce zero
      code changes for exactly this reason.
    - ✅ DO: the worker job persists `.boucle/<issue>/` to a stable path
      outside `$CI_PROJECT_DIR` (`$BOUCLE_STATE_CACHE/<issue>/`, default
      `$HOME/.boucle-state-cache/<issue>/`) and restores it at startup via
      an EXIT trap. `state.md` and `iterations.md` now survive across
      iterations. The worker is instructed (`worker.md` step 2) to read
      `iterations.md` at startup so it knows what previous iterations
      tried. `iterations.md` is seeded on first run (companion to
      `state.md`).
    - Context: issue #35 iterations 1 and 2 both produced zero code changes.
      The worker (kimi-k2.7-code, 100 steps) spent all its steps
      reconstituting context — re-reading the charter docs,
      re-discovering the codebase via grep — because
      `state.md` was re-seeded to "(to be determined by worker)" and
      `iterations.md` did not exist. The "Tried and rejected" section was
      always "(none yet)". The worker had no memory of what iteration 1
      had already attempted.

29. **Model/API failure misdiagnosed as step-budget exhaustion** (issue #35 on a consumer repo)
    - ❌ DO NOT treat an empty worker log as "agent likely exhausted its
      step budget". When the model API is down or out of credits,
      opencode hangs silently — no stdout, no crash, no tool calls in the
      log. The job appears "running" until the 30 min timeout (which may
      not fire on a shell executor). The generic "no code changes"
      handler then re-triggers the worker into the same wall, wasting
      the iteration budget on a problem that re-triggering cannot fix.
    - ✅ DO: `bin/jc` exits 4 when the worker agent log is empty or shows
      no agent activity (no tool calls, no file reads, no git operations).
      The worker job detects exit 4, posts a diagnostic comment on the
      issue with the available logs (last 2000 chars of agent-output.log),
      and escalates to `boucle:human` immediately — no re-trigger. The
      comment names the model (`$AGENT`) and tells the user to check API
      status and credits. This distinguishes a model outage from a
      step-budget issue and stops the loop from spinning.
    - Context: issue #35 iteration 3, worker (kimi-k2.7-code) hung for
      40 min with an empty log because ollama-cloud credits were
      exhausted. The job was manually cancelled. Without exit 4
      detection, the loop would have re-triggered 2 more times into the
      same wall, then escalated with the misleading "agent likely
      exhausted its step budget" message.

41. **Anchor VERDICT greps to start-of-line**
    - ❌ DO NOT use `grep -E 'VERDICT: (PASS|FAIL|UNCERTAIN)'` without a
      `^` start-of-line anchor in the verdict parsing pipeline. opencode's
      bash tool traces commands with `set -x`-style output (ANSI color +
      `$ ` PS4 prompt) in `agent-output.log`. A trace line like
      `[0m$ [0mglab mr note 36 --message "VERDICT: PASS"` contains the
      substring `VERDICT: PASS` — an unanchored grep matches it inside the
      trace, and the log-scraping fallback posts the trace as a verdict
      note. The result: a malformed note (containing shell trace output)
      appears on the MR, and CI may parse a phantom VERDICT from a command
      the agent echoed but never actually posted as a real verdict.
    - ❌ DO NOT assume the awk `^VERDICT:` exit guard is sufficient. The
      awk exits on `^VERDICT:` (start-of-line), but the trace line starts
      with `[0m$` (ANSI reset + PS4), so awk keeps printing past it. The
      downstream `grep -qiE 'VERDICT: ...'` validation then matches the
      substring inside the trace line — because it is NOT anchored.
    - ✅ DO: anchor EVERY `grep` that validates or extracts a VERDICT with
      `^`: `grep -qiE '^VERDICT: (PASS|FAIL|UNCERTAIN)'` for validation
      and `grep -oE '^VERDICT: (PASS|FAIL|UNCERTAIN)'` for extraction.
      This applies to both the reviewer and e2e jobs, in both the primary
      note-parse and the log-scraping fallback. The `^` anchor ensures the
      grep only matches a real `VERDICT:` line (posted by the agent as a
      verdict), never a substring inside a shell trace or quoted command.

42. **Merger MUST handle "Pipelines must succeed" via MWPS**
    - ❌ DO NOT fail the merger when `detailed_merge_status` is
      `pipeline_status_must_pass` or `checking` after a short poll. The
      force-push (rebase) triggers a new pipeline on the MR branch. If the
      GitLab project has "Pipelines must succeed" enabled, GitLab refuses
      to merge until that pipeline completes — and a 2-minute poll window
      is far too short for a full CI run. The merger fails → `boucle:human`
      → the MR sits approved-but-unmerged even though everything is fine.
    - ❌ DO NOT assume `merge_when_pipeline_succeeds=false` is always the
      right merge mode. It only works when the MR is immediately
      `mergeable`. When a pipeline is running, GitLab rejects the immediate
      merge with a 405 and the merger treats the empty `merge_commit_sha`
      as a hard failure.
    - ✅ DO: poll `detailed_merge_status` for up to 10 min (60×10s),
      tolerating `checking`/`pipeline_status_must_pass`/`pipeline_blocked`
      as transient states. If the pipeline is still running after the poll
      window, switch to `merge_when_pipeline_succeeds=true` (MWPS) — GitLab
      merges automatically once the pipeline passes. Post a note so the
      human knows the merge is scheduled, and exit 0 (the deploy triggered
      by the eventual merge + the doctor's staleness check close the loop).

47. **Anchor log-scraping awk marker patterns to start-of-line**
    - ❌ DO NOT use an unanchored awk regex like
      `$0 ~ "<!-- boucle:verdict v=1 role=reviewer sha=... -->"` to detect
      the start of a drafted verdict in `agent-output.log`. When an agent
      exhausts its step budget mid-draft, its stdout often contains
      **meta-instructions to itself** that quote the marker in prose, e.g.
      `**Post the final verdict** with the \`<!-- boucle:verdict v=1
      role=reviewer sha=abc -->\` marker.` An unanchored `$0 ~` matches
      the marker substring inside that prose sentence, sets `found=1`, and
      the awk scrapes everything from the prose line through the trailing
      `VERDICT: PASS` — promoting a self-referential draft (containing
      instructions like "The next step is to post this final verdict") into
      a real verdict note. This was MR !40 on a consumer repo: the reviewer
      drafted a PASS verdict with the marker quoted in its own
      recommendation prose, the log-scraping fallback matched the prose
      marker, and a malformed PASS verdict was posted — merging a change
      that had NOT addressed the human's latest feedback.
    - ❌ DO NOT assume lesson #41 (anchor `VERDICT:` greps) covers this.
      Lesson #41 anchors the `VERDICT:` extraction/validation greps; this
      lesson anchors the **marker-detection** awk pattern that gates the
      whole scrape. A marker matched in prose feeds a `VERDICT:` line that
      IS at start-of-line (so #41's guard passes), but the surrounding
      block is still prose, not a real verdict.
    - ✅ DO: anchor EVERY awk marker-detection pattern with `^` (start of
      line): `$0 ~ "^<!-- boucle:verdict v=1 role=reviewer sha=" sha " -->"`
      and `/^<!-- boucle:verdict v=1 role=reviewer/` and
      `/^<!-- boucle:draft role=reviewer -->/`. A real marker is always the
      first token on its line (the agent posts it as a bare HTML comment);
      a marker quoted in prose is always preceded by other text. This
      applies to ALL five log-scraping fallbacks: reviewer `boucle:verdict`
      + `boucle:draft`, e2e `boucle:verdict` + `boucle:draft`, and triage
      `boucle:triage` + `boucle:draft`.

48. **Capability-based model routing (vision workaround)**
    - ❌ DO NOT run all agents on a vision model when only some issues/MR
      comments contain images — 3x cost for roles that never touch images.
    - ❌ DO NOT run all agents on a text-only model and accept that they
      crash (jcode #755) or fabricate image content when images are present.
    - ❌ DO NOT swap the worker's entire model to a vision model
      (minimax-m3) when images are present — the vision model is worse at
      code and prone to WASM OOM crashes (`RangeError:
      WebAssembly.instantiate(): Out of memory`). The worker needs image
      CONTEXT, not vision capability during code generation.
    - ✅ DO: describe image attachments via `bin/describe-images <role>`
      (called after `fetch-issue-attachments`/`fetch-mr-attachments`, before
      `bin/jc <role>`). It runs the vision model (minimax-m3) SEPARATELY to
      describe each image as text, writes the descriptions to
      `.boucle-state/$ISSUE/.image-descriptions.md`, and `bin/jc` injects
      them into the agent prompt as text. The worker/reviewer/triage stay on
      their default models (deepseek-v4-flash, glm-5.2) and get image context
      as text, not as raw binaries. Forge controls: `BOUCLE_VISION_ROUTING`
      (enabled/disabled), `BOUCLE_VISION_MODEL` (default minimax-m3),
      `BOUCLE_VISION_ROLES` (default triage,worker,reviewer),
      `BOUCLE_VISION_TIMEOUT` (per-image, default 120s). This is a workaround
      for jcode issues #683 (per-role model) and #819 (capability-based
      routing) — remove when jcode implements native capability-based
      routing. The old `bin/detect-vision-need` (which swapped the entire
      model) has been removed.

49. **Sub-issue dependencies must be gated, not hinted**
    - ❌ DO NOT trigger a sub-issue's worker in parallel with its siblings
      when the triage declared an explicit `Depends on:` — the worker
      cannot express "I need sibling #N's artifact first" and will either
      fabricate the artifact or block silently. A dependency that is not
      enforced at dispatch is a dependency that does not exist.
    - ❌ DO NOT reuse `boucle:todo` for dependency-blocked issues. The
      doctor's capacity-free scan re-triggers `boucle:todo` on every slot
      opening, hitting the dep gate each time, wasting API calls, and
      re-posting the blocked note.
    - ✅ DO: gate the worker trigger on a `## Depends on` section in the
      sub-issue body (portable marker `<!-- boucle:depends-on iids=N,M -->`,
      forge-native "is this issue closed?" primitive only). Set
      `boucle:blocked` (not `boucle:todo`) when a dep is open. Unblock
      via a symmetric `maybe_unblock_dependents()` when a dep closes —
      NOT via the doctor's capacity scan. Detect cycles at split time
      and escalate to a human; never let a cycle deadlock the loop
      silently.

50. **BOUCLE_BOT_ID must be resolvable or bot reassignment silently skips**
    - ❌ DO NOT let `set_boucle_label` swallow a missing `BOUCLE_BOT_ID`.
      Reassignment to the bot is guarded by
      `if [ "$gross" = "boucle::status::bot" ] && [ -n "${BOUCLE_BOT_ID:-}" ]`,
      and the `|| true` + `2>/dev/null` swallow the skip: the issue stays
      assigned to the human with no log line. The detection path (has the
      bot posted?) has a username fallback (`up-bot`), so detection works
      without `BOUCLE_BOT_ID` while assignment does not — a silent
      asymmetry.
    - ❌ DO NOT assume `bin/setup --bot-id <n>` creates the `BOUCLE_BOT_ID`
      CI variable. Older `bin/setup` added the bot as a project member but
      never seeded the variable, so every `boucle::status::bot` transition
      silently skipped reassignment on consumers that even ran `--bot-id`.
    - ✅ DO: seed `BOUCLE_BOT_ID` (when `--bot-id` is given) and
      `BOUCLE_BOT_USERNAME` (always, default `up-bot`) as CI variables in
      `bin/setup`.
    - ✅ DO: resolve `BOUCLE_BOT_ID` by username via the forge users API in
      the `default` before_script when the variable is unset, so the loop
      still works on consumers that never ran `--bot-id` or ran an older
      `bin/setup`. Defense-in-depth: the fallback closes the gap even if a
      future consumer skips `--bot-id`.

51. **Never reset --hard a branch that holds pushed worker commits**
    - ❌ DO NOT let a rebase-fallback `git reset --hard origin/$CI_DEFAULT_BRANCH`
      run on a branch that contains worker commits. The commit becomes
      orphaned (still on the remote, but unreferenced): the MR goes empty
      (`detailed_merge_status=commits_status`), the merger cannot fix it
      (nothing to rebase or merge), escalates to `boucle:human`, and the
      doctor re-triggers the merger forever on the same empty MR — an
      infinite escalation loop.
    - ❌ DO NOT trigger the merger on an MR in `commits_status` — the merger
      cannot repair an empty MR; re-triggering it is precisely the infinite
      loop.
    - ✅ DO: on rebase conflict, `git rebase --abort` and PRESERVE the branch —
      never reset it. Hand the conflict to the bounded re-trigger path
      (worker iteration budget, then `boucle:human`). `git reset --hard` is
      allowed ONLY for a true clean slate (no worker commits).
    - ✅ DO: treat `commits_status` as a worker problem, not a merger problem —
      recover by re-triggering the WORKER (it regenerates the MR content
      from the preserved `state.md`/`iterations.md`), in both the merger and
      the doctor. Admission: class — destructive rebase-fallback reset on a
      committed branch; recurrence — any future backport/refactor may
      reintroduce a reset fallback; stable — no line numbers; distinct from
      lesson #22 which covers the unconditional start-of-run reset (this
      covers the rebase-CONFLICT fallback and the recovery side).

52. **Standalone `merge_request_event` reference required for MR pipelines**
    - ❌ DO NOT gate a GitLab rule as a COMBINED comparison, e.g.
      `if: $CI_PIPELINE_SOURCE == "merge_request_event" && $CI_MERGE_REQUEST_TARGET_BRANCH_NAME == "$CI_DEFAULT_BRANCH"`,
      when the job must run in a merge-request pipeline. The CI lint accepts
      the combined rule (jobs evaluate correctly), but GitLab's MR-pipeline
      CREATION only triggers on the standalone reference
      `$CI_PIPELINE_SOURCE == "merge_request_event"` — with a combined rule
      NO pipeline is created and the job silently never runs (observed on
      framagit 2026-08: same branch, combined rule → no pipeline; pure rule →
      pipeline created instantly). A rule using only MR variables
      (`$CI_MERGE_REQUEST_TARGET_BRANCH_NAME`) also never creates one.
    - ✅ DO: keep the creation rule standalone
      (`- if: $CI_PIPELINE_SOURCE == "merge_request_event"`) and enforce the
      scoping in the job's `script:` instead
      (`if [ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "$CI_DEFAULT_BRANCH" ]; then exit 0; fi`).
    - ✅ DO: prefer `ci/lint` with `merge_request_pipeline=true` to verify
      rule evaluation, but remember it does NOT prove pipeline creation —
      the creation trigger is the standalone-string detection.
    - Admission: class — combined/bare-MR-variable rules silently disable MR
      pipelines; recurrence — any new MR-gated job in this repo or consumer
      shims; stable — GitLab detection behavior, version-independent so far;
      not covered by any existing lesson.

53. **Reviewer MUST verify every human amendment is addressed before PASS**
    - ❌ DO NOT grade the MR against the frozen triage/issue-body acceptance
      criteria alone when the Prior MR discussion contains human amendments —
      a PASS that reports "initiale (first letter) fallback: OK" while the
      human explicitly wrote "pas de logo basé sur la lettre" validates the
      exact thing the human rejected. Initials ARE letters; an amended
      criterion is not satisfied by the original implementation.
    - ❌ DO NOT report a criterion as PASS when a human amendment has changed
      what that criterion requires, even if the pre-amendment text is still
      in the issue body — the human comment wins over the frozen spec.
    - ❌ DO NOT treat human amendments as mere suggestions ("the original
      acceptance criteria are all satisfied, amendments not addressed") and
      PASS anyway — an acknowledged-but-unaddressed amendment is a FAIL.
    - ✅ DO: enumerate EVERY human amendment from the Prior MR discussion
      (comments authored by the human, not the bot's own verdicts), verify
      each is addressed in the deployed code, and FAIL if any is not —
      even when every original criterion is satisfied.
    - Admission: class — reviewer grades against frozen criteria and ignores
      human amendments (3 consecutive PASS verdicts on MR !61 while 3 rounds
      of human amendments were unaddressed, including a PASS that explicitly
      acknowledged "amendments are NOT addressed in this MR"); recurrence —
      the model demonstrably ignored the existing "human comments win" rule
      (deepseek-v4-flash), so the prompt fix alone is not a guarantee; the
      doc contract reinforces the prompt; stable — no line numbers;
      distinct from lesson #16 (feeding reviewer feedback FORWARD to the
      worker) — this is the reviewer's own obligation to APPLY amendments.

54. **The MR feedback channel MUST fail loud on re-runs — a port/sync can
    silently drop it**
    - ❌ DO NOT let a port/rewrite of the CI engine remove the MR feedback
      lookup (`MR_FOR_FEEDBACK` + `BOUCLE_REVIEWER_FEEDBACK` in the worker
      and reviewer jobs) while leaving the orphaned
      `export BOUCLE_MR_IID="$MR_FOR_FEEDBACK"` + `fetch-mr-attachments` call
      behind. The failure is indistinguishable from a first run: every
      worker iteration logs "BOUCLE_MR_IID is empty (no MR on first run)"
      while an MR is open and accumulating human comments. MR !59 on a
      consumer repo: after the jcode port (`.boucle-version 13316ff`, synced
      2026-08-06) all 6+ worker iterations re-ran blind — the human's
      "il faut un exemple d'article" and 3 mockup images never reached the
      worker, which re-implemented the same component ~20 times without
      ever creating the requested example article. The reviewer (which kept
      its own channel) FAILed repeatedly citing the human request, one PASS
      validated the unaddressed amendment, the iteration cap escalated to
      `boucle:human`, and the old engine's per-run `git reset --hard` left
      the MR empty (`commits_status`) for the merger/doctor to loop on.
    - ❌ DO NOT rely on the lookup living in only one place. `.gitlab-ci.yml`
      is replaced wholesale by engine syncs (`chore: sync boucle engine to
      <sha>` = `cp -r`), so a guard embedded only in that file dies with the
      regression it guards.
    - ✅ DO: treat an EMPTY `BOUCLE_REVIEWER_FEEDBACK` on any RE-RUN
      (iteration > 1) as a red flag, not a first run. The worker and reviewer
      before_script WARN loudly and inject a `[boucle:guard]` self-fetch
      fallback into the feedback; `bin/jc` `build_prompt` repeats the same
      guard (it survives CI-file rewrites). The agent then fetches the MR
      notes itself instead of assuming no feedback exists.
    - ✅ DO: verify the feedback channel after every engine port/sync — a
      sync that rewrites the jobs must preserve the `MR_FOR_FEEDBACK`
      lookup, or the guard must fire.
    - Admission: class — an engine port/sync silently drops an integration
      channel while leaving a half-wired remnant, so worker/reviewer re-runs
      go blind to human feedback; recurrence — engine ports and `cp -r`
      syncs are recurring operations and the symptom is designed to be
      silent (the "no MR on first run" message is exactly what a working
      first run prints); stable — no line numbers, no transient values;
      distinct from lesson #16 (which mandates the channel's existence in
      the design) — this lesson covers regression-by-port and the fail-loud
      guard.

55. **Recognise boucle's own writes by a stamp, never by the actor's
    identity**
    - ❌ DO NOT post a comment with a direct API call. Every posting path
      MUST go through the forge note helpers (`forge_issue_note`,
      `forge_mr_note`, and their `_update` variants), which stamp the
      invisible `<!-- boucle:agent -->` marker. A comment posted around
      them carries no marker, so dispatch cannot tell it from a human
      reply: on a paused state it routes, and the loop re-triggers itself.
    - ❌ DO NOT add a new anti-loop guard that asks "who did this?". The
      actor only discriminates while boucle owns a separate account. It
      discriminates nothing when one account owns both the issues and the
      loop, and pointing the guard at that account makes it discard the
      human's own triggers — the loop then goes silent with no error
      anywhere, which is worse than a crash.
    - ❌ DO NOT rely on ordering alone ("post the comment before changing
      the label") to keep a comment from routing. Forges do not guarantee
      webhook delivery order, so the label webhook can overtake the note
      and the note lands on the new, possibly paused, state.
    - ✅ DO: ask "did we write this?" instead of "who wrote this?". Testing
      for a fixed, invisible token is stable, forge-agnostic, and immune to
      both delivery reordering and single-account setups.
    - ✅ DO: keep the guard identical in every copy of the routing while
      the CI paths remain unconverged. A guard that lands in one copy and
      not the other breaks that path silently.
    - Admission: class — it covers any self-recognition guard in an
      event-driven loop, not one incident; recurrence — new comment paths
      and new guards are added routinely, and the natural instinct is to
      filter on the author, so an agent would repeat this without the doc;
      stable — no line numbers, no transient values, true regardless of
      which forge or mode is active; distinct — no existing lesson covers
      anti-loop self-recognition (the nearest, #54, is about a feedback
      channel dropped by a port).

56. **User-facing notes MUST NOT contain literal env var names**
    - ❌ DO NOT interpolate an env var inside a single-quoted `printf`
      format string and expect it to expand. `printf '... onto
      $CI_DEFAULT_BRANCH ...'` posts the literal text `$CI_DEFAULT_BRANCH`
      to the issue/MR — the human sees a raw variable name in the note.
      The reviewer PASS approval message did exactly this: "The merger
      will then rebase the MR onto $CI_DEFAULT_BRANCH" appeared verbatim
      on a consumer issue instead of the real branch name.
    - ❌ DO NOT "preserve" such a literal with a
      `shellcheck disable=SC2016` comment on the assumption that the
      literal was intended. When the reviewer job was ported from
      `.gitlab-ci.yml` into `lib/boucle-ci/reviewer.sh`, the literal
      `$CI_DEFAULT_BRANCH` was copied as `$BOUCLE_DEFAULT_BRANCH` and
      locked in with a SC2016 disable — cementing the bug in BOTH engine
      copies instead of fixing it.
    - ✅ DO: pass the value as a `printf` argument instead of embedding
      the name in the format string:
      `printf '... onto %s ...' ... "${BOUCLE_DEFAULT_BRANCH:-${CI_DEFAULT_BRANCH:-master}}"`.
      The note then shows the actual branch name (`master`, `main`, ...).
    - ✅ DO: when a note/message is duplicated across engine copies
      (`.gitlab-ci.yml` inline + `lib/boucle-ci/*.sh`), grep ALL copies
      for the same message before fixing — a fix in one copy alone
      leaves the bug live on the other path.
    - Admission: class — any env var embedded in a single-quoted printf
      format string posted to a user-facing note, in any engine copy;
      recurrence — the bug already duplicated itself across both engine
      copies, and a fresh agent writing a new note could repeat it
      without the doc; stable — no line numbers, no transient values;
      distinct — no existing lesson covers literal env vars in
      user-facing notes (the nearest, #36, is about markdown formatting
      of the Approach section, not variable expansion).

57. **A closed non-merged MR is NEVER a completion signal**
    - ❌ DO NOT transition an issue to `boucle:done` + close it just
      because a CLOSED (but NOT merged) MR exists on its branch. The
      reviewer "no open MR" guard treats any closed MR as "work done" —
      but a human closes MRs for RECOVERY too: a zombie/empty MR (0
      commits, rebase-conflicted branch, worker drowned in a destructive
      reset) is closed so the loop can start fresh. On a consumer repo,
      the human closed such a zombie MR, the issue was re-queued
      (`boucle:todo`), and 2 minutes later the reviewer guard fired —
      "no open MR found, but a closed MR exists" → `boucle:done` +
      issue closed. The recovery was undone, the loop was killed, and
      only a manual reopen + re-queue (again) restored it.
    - ❌ DO NOT assume a closed MR implies the human rejected the work
      and wants the issue archived. "Closed" is ambiguous between
      "reviewed and discarded" and "stale garbage in the way of a fresh
      start" — only a MERGE or a review-state issue (boucle:review /
      boucle:approval) legitimizes the done-transition.
    - ✅ DO: in the reviewer "no open MR" guard, distinguish three
      cases: (1) a MERGED MR exists → `boucle:done` + close (unchanged);
      (2) a CLOSED (not merged) MR exists AND the issue carries
      `boucle:review` or `boucle:approval` → `boucle:done` + close
      (unchanged — this is the original issue-#34 loop-breaker); (3) a
      CLOSED (not merged) MR exists while the issue is queued for work
      (`boucle:todo`/`boucle:working`) → post an informational note and
      exit 0 WITHOUT touching the issue — the worker will create a fresh
      MR on its next run.
    - ✅ DO: keep the guard IDENTICAL in every engine copy
      (`lib/boucle-ci/reviewer.sh` + the inline reviewer job in
      `.gitlab-ci.yml`) — a fix in one copy alone leaves the bug live on
      the other (a consumer runs whichever copy its engine uses).
    - Admission: class — any auto-"done" transition triggered by a
      closed-but-not-merged MR while the issue is queued for work;
      recurrence — the done-transition pattern exists in the reviewer
      guard on both engine copies, and a future port or new guard could
      reintroduce the naive "any closed MR = done" check without the
      doc; stable — no line numbers, no transient values; distinct —
      lesson #44 covers running roles on CLOSED issues, #53 covers
      grading human amendments; neither covers treating a recovery
      artifact as a completion signal.

58. **Never draft verdicts in fixed shared temp paths**
    - ❌ DO NOT let agents draft their verdict/triage comment to a
      fixed path like `/tmp/verdict.md`. Shell executors are shared
      between jobs AND issues: a leftover file from a previous job
      survives, and the next agent that posts
      `forge-note --message-file /tmp/verdict.md` ships the PREVIOUS
      job's verdict as its own. Observed on a consumer MR: the
      reviewer's own draft write (`cat > /tmp/verdict.md`) was blocked
      by the runtime guard (command substitution), the file still held
      a keffiyeh PASS from another issue (anchored to an orphaned SHA),
      and the reviewer posted that foreign verdict TWICE before
      noticing and re-posting its real one. The SHA-anchor guard
      (lesson #27) stopped the loop from acting on the phantom PASSes,
      but the MR shows three "PASS" verdicts to the human, two of them
      for content that was never reviewed.
    - ❌ DO NOT rely on the agent checking a file's content before
      posting it — the incident shows a stale file posted without being
      read, twice.
    - ✅ DO: `bin/jc` exports `BOUCLE_VERDICT_FILE` — a per-job unique
      path (`mktemp`, with a job/issue-scoped fallback) — and the
      reviewer/e2e/triage prompts (`.jcode/agents/*.md` + the
      `build_prompt` reminder) instruct agents to write drafts there
      with their Write tool (bash redirection to a variable target is
      blocked by the runtime guard) and to read the file back
      immediately before posting. Posting directly with
      `--message`/`--message-stdin` is preferred over any file.
    - ✅ DO: any agent whose file post fails, or who finds a missing or
      foreign file, MUST re-post directly with `--message` — an
      incomplete own verdict beats a foreign verdict (post-early rule,
      lesson #1).
    - ❌ DO NOT limit this rule to agent drafts — ENGINE SCRIPTS and
      operator commands fall in the same class. A fixed `/tmp` path in
      `.gitlab-ci.yml`/`lib/boucle-ci/*` shared across jobs
      (`/tmp/subissues.parsed`, `/tmp/node.tar.xz`, `/tmp/glab.tar.gz`,
      `/tmp/jcode.tar.gz`, `/tmp/node_modules`) lets two concurrent
      jobs overwrite or `rm -f` each other's in-flight file; a fixed
      worktree path (`git worktree add /tmp/boucle-push`) collides with
      any other session that picks the same name, and a
      `worktree remove --force` on a reused path deletes a foreign
      session's work.
    - ✅ DO: use `mktemp -d`/`mktemp` (unique per invocation) or a
      `CI_JOB_ID`-scoped path in every script and every ad-hoc command
      that stages a temp file or worktree — the same rule
      `bin/jc`'s `BOUCLE_VERDICT_FILE` follows.
    - Admission: class — fixed shared temp paths on shared executors,
      whether chosen by an agent prompt, an engine script, or an
      operator command; recurrence — agents, scripts and operators all
      pick `/tmp/<name>` paths routinely and each new script/prompt
      could reintroduce the habit without the doc; stable — no line
      numbers, no transient values; distinct — lesson #27 handles stale
      verdict SHA parsing, this lesson prevents the foreign-content
      post at the source.

59. **Notes of terminal transitions MUST be verified before the label**
    - ❌ DO NOT post an escalation/catchup note with a
      `... > /dev/null 2>&1 || true` swallow (helpers) or a bare
      `glab api ... notes ... > /dev/null` (inline jobs) and set the
      terminal label (`boucle:human` / `boucle:done`) regardless of
      whether the POST actually landed. Observed on a consumer work
      item (2026-08): the labels flipped to `boucle:human` at 14:55:50
      while the explanation note POST was silently dropped — the human
      saw a state with no message, and had to reconstruct from the CI
      logs WHY the issue landed on them. A terminal transition without
      its note is a silent failure (lesson #2) wearing a success label.
    - ❌ DO NOT assume the note POST internals are reliable: they can
      fail transiently (network, token, rate limit) and the
      `|| true` + `>/dev/null` pattern in `forge_issue_note` /
      `forge_mr_note` (gitlab.sh, github.sh) historically swallowed
      every failure code.
    - ✅ DO: order the transition **note FIRST, label SECOND**: post
      the explanation, and only after a verified successful POST —
      `if ! forge_issue_note "$BOUCLE_ISSUE" "..."; then ... exit 1; fi`
      — apply `set_boucle_label ... boucle:human ...`. If the note
      cannot be posted, exit non-zero WITHOUT the label: the issue
      stays in a retryable state and the job fails loudly (CI red +
      stderr) instead of stranding a mute escalation.
    - ✅ DO: keep `forge_issue_note` / `forge_mr_note` fail-loud by
      contract: they return the real POST exit code and WARN on stderr
      on failure (never `|| true`-swallowed). Callers that genuinely
      want a best-effort note (progress notes like "🔄 re-running")
      must append `|| true` EXPLICITLY — never rely on the helper
      swallowing for them.
    - ✅ DO: apply the same pattern to the INLINE copies (`.gitlab-ci.yml`
      jobs) and the extracted copies (`lib/boucle-ci/*.sh`) — the two
      copies must stay in sync (lesson #56 greps ALL copies).
    - Admission: class — any terminal state transition whose
      explanation note is treated as optional; recurrence — new
      escalation sites are added routinely and the natural instinct is
      to post-then-label with a swallowed POST; stable — no line
      numbers, no transient values; distinct — lesson #2 detects
      silent agents, lesson #55 covers the marker stamping, this
      lesson covers the POST-result contract of the note helpers.

60. **An empty `BOUCLE_DEPLOY_CMD` is a valid mode, not a failure**
    - ❌ DO NOT let a stage `eval "$BOUCLE_DEPLOY_CMD"` unconditionally and
      FAIL on a missing URL. In GitLab Pages declarative mode
      (`BOUCLE_DEPLOY_PROVIDER=gitlab-pages`) the consumer sets
      `BOUCLE_DEPLOY_CMD` to an empty project variable (which OVERRIDES the
      YAML default), so `eval ""` exits 0 with no output and every stage
      that asserts "no preview/URL → FAIL" dies. Observed on a consumer
      (2026-08): the deploy job had the empty-cmd guard but the worker
      did not — every worker iteration pushed the MR then failed with
      `FAIL: no preview URL`, stranding the issue at `boucle:working`
      while the reviewer PASSed MRs on the same commit were blocked behind
      it. The MR description showed a blank `Preview:` line, making the MR
      look like a duplicate of a sibling.
    - ❌ DO NOT port the guard to ONE copy only. The inline jobs
      (`.gitlab-ci.yml`) and the extracted functions
      (`lib/boucle-ci/*.sh`) must stay symmetric — the consumer ran the
      inline copy, which had no guard, while the extracted one (used by
      the GitHub port) had the shared `boucle_worker_should_deploy`
      helper. A fix in one copy leaves the bug live on the other
      (lesson #56 greps ALL copies).
    - ✅ DO: treat an empty `BOUCLE_DEPLOY_CMD` as a first-class mode: the
      worker skips the preview deploy, the reviewer falls back to diff
      review when no preview URL could be extracted, the deploy job skips
      cleanly, and post-merge/e2e resolve the live URL to `$CI_PAGES_URL`
      (gitlab-pages) instead of the `pages.dev` fallback. Document the
      mode in LOOP.md alongside `self`/`external`.
    - ✅ DO: display the GitLab Pages URL even though the mechanics differ
      from Cloudflare: when `BOUCLE_DEPLOY_PROVIDER=gitlab-pages` and
      `$CI_PAGES_URL` is set, the worker writes
      `Site (GitLab Pages): $CI_PAGES_URL — no per-branch preview; reviewed
      via diff` in the MR description instead of a blank `Preview:` line.
      The reviewer's `pages.dev` extraction regex cannot match the forge's
      Pages domain (frama.io/gitlab.io/...), so it stays in diff review and
      never probes the production site as a preview.
    - ❌ DO NOT ship `pages.path_prefix`-based branch previews on CE
      instances. Parallel deployments (`pages.path_prefix`, GitLab ≥ 17.9)
      are a **Premium** feature: CE accepts the keyword at CI-lint time but
      ignores it at RUNTIME — the branch job publishes at the ROOT and
      clobbers the production deployment. Verified empirically on framagit
      (GitLab CE 19.2.1, 2026-08): lint `valid: true`, deployment created
      with `path_prefix: null` at the site root.
    - ✅ DO: centralize the decision in `boucle_worker_should_deploy`
      (`lib/boucle.sh`) so the extracted worker gets it for free, and
      mirror it in the inline worker job with the identical guard.
    - Admission: class — any stage that runs or asserts on a deploy
      command without checking it exists first; recurrence — every new
      deploy-adjacent stage (worker preview, deploy, post-merge, e2e)
      is a candidate, and providers without a CLI (GitLab Pages, static
      hosters) are common; stable — no line numbers, no transient
      values; distinct — lesson #21 covers stale previews (a deployed
      but old URL), this lesson covers NO deploy at all (no URL by
      design).

61. **Doctor re-trigger must NOT be skipped by a stale closed MR**
    - ❌ DO NOT `continue` in the doctor's stuck-issue loop when a closed
      (or merged) MR coexists with an open MR on the same branch. The
      "skipping close" branch is meant to avoid CLOSING the issue — but
      the `continue` also skips the re-trigger logic below, stranding the
      issue at `boucle:working` forever. Observed on a consumer (2026-08):
      issue #55 had a closed MR from a previous iteration (!59) plus the
      current open MR (!93); the doctor logged "closed MR exists but an
      open MR also exists — skipping close" every 10 minutes and never
      re-triggered the stuck worker. With `BOUCLE_MAX_PARALLEL_ISSUES=1`
      the stranded issue occupied the single worker slot, so a second
      queued issue (`boucle:todo`) was never started either — two issues
      blocked by one `continue`.
    - ❌ DO NOT fix only one copy. The guard lives in BOTH the extracted
      `lib/boucle-ci/doctor.sh` and the inline doctor job in
      `.gitlab-ci.yml`, in TWO branches each (merged-MR and closed-MR).
      A fix in one copy leaves the bug live on the other (lesson #56
      greps ALL copies).
    - ✅ DO: on "open MR also exists", fall THROUGH to the re-trigger
      logic (active-pipeline check → staleness check → `chain_to_role`)
      instead of `continue` — the open MR is active work, so a stuck
      worker/reviewer on it MUST be recovered. Only the terminal branches
      (MR merged / MR closed with NO open MR) may `continue`.
    - Admission: class — any future guard that conflates "don't close the
      issue" with "skip recovery"; recurrence — the natural instinct when
      adding a "don't close on reopen" check is to `continue`, and both
      copies have two such branches; stable — no line numbers, no
      transient values; distinct — lesson #57 covers the reviewer's
      closed-MR done-transition, lesson #44 covers roles on closed
      issues; this lesson covers the doctor's re-trigger path.

## Documentation self-maintenance

Boucle self-maintains its own documentation as part of the autonomous loop.
Documentation is **code**: a doc that drifts from the system it describes is a
bug. The four agents share the responsibility of keeping the charter docs
(`AGENTS.md`, `CONTEXT.md`, `LOOP.md`) in sync
with reality. `README.md` is excluded — it is for human readers, not agents.

### Distributed workflow

- **Triage** — Adds a `Docs impact: <docs>` line to the `Analysis` section of
  the structured comment, listing which charter docs the issue touches
  (e.g. `Docs impact: AGENTS.md, LOOP.md`).
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
  (e.g. `[AGENTS.md](AGENTS.md)`).

See [AGENTS.md](AGENTS.md) section "Documentation
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

## See also

- [CONTEXT.md](CONTEXT.md) — Project context, tech stack, constraints
- [README.md](README.md) — Overview, getting started, usage
- [LOOP.md](LOOP.md) — Per-consumer configuration
- [.jcode/UPSTREAM-FIX-WORKFLOW.md](.jcode/UPSTREAM-FIX-WORKFLOW.md) — Upstream fix workflow
