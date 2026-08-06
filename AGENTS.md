# AGENTS.md

Instructions for AI agents working on the **boucle** project.

<!-- codebase-memory-mcp:start -->
## Codebase Knowledge Graph (codebase-memory-mcp)

This project uses codebase-memory-mcp to maintain a knowledge graph of the codebase.
ALWAYS prefer MCP graph tools over grep/glob/file-search for code discovery.

The graph is built once (by CI or locally) and auto-syncs on changes. If `search_graph`
returns no results, run `index_repository` with the repo path, then retry.

### Priority Order
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
- Find a page component: `search_graph(name_pattern=".*PrisesDeParole.*")`
- Who calls a helper: `trace_path(function_name="getCategory", direction="inbound")`
- Read source: `get_code_snippet(qualified_name="src/pages/prises-de-parole.astro")`
- Architecture overview: `get_architecture(aspects=["all"])`
<!-- codebase-memory-mcp:end -->

## Bug resolution workflow

The upstream-first bug fix workflow is defined in
[`.opencode/UPSTREAM-FIX-WORKFLOW.md`](.opencode/UPSTREAM-FIX-WORKFLOW.md).

That file is portable: it ships with boucle when installed in consumer
projects (via the `.opencode/` directory). Read it and follow it for any
bug reported on a consumer project.

Summary: **fix upstream in boucle first, then update boucle in the
consumer, then remediate existing data.** Never patch a consumer to
work around a boucle defect.

## Lessons learned

Hard-won lessons from running boucle on real consumer projects. Each
lesson is stable (true regardless of code state), recurrent (would
recur without the doc), and not already covered elsewhere.

### Lesson #1 — BOUCLE_BOT_ID must be resolvable or bot reassignment silently skips

**Class:** silent skip / asymmetry between detection and assignment.

`set_boucle_label` reassigns an issue to the bot when the label
transitions to `boucle::status::bot`, but only when `BOUCLE_BOT_ID` is
non-empty:

```sh
if [ "$gross" = "boucle::status::bot" ] && [ -n "${BOUCLE_BOT_ID:-}" ]; then
  curl ... --data-urlencode "assignee_ids[]=$BOUCLE_BOT_ID" 2>/dev/null || true
fi
```

The `|| true` and `2>/dev/null` swallow the skip, so the issue stays
assigned to the human with no log line. Meanwhile the detection path
(has the bot posted on this issue?) has a username fallback
(`up-bot`), creating an asymmetry: detection works without
`BOUCLE_BOT_ID`, assignment does not.

**Root cause:** `bin/setup` added the bot as a project member when
`--bot-id` was provided, but never created the `BOUCLE_BOT_ID` CI
variable. So even consumers that ran `bin/setup --bot-id <n>` had the
member but not the variable, and every `boucle::status::bot`
transition silently skipped reassignment.

**Fix (two-part, defense-in-depth):**
1. `bin/setup` now seeds `BOUCLE_BOT_ID` (when `--bot-id` is given)
   and `BOUCLE_BOT_USERNAME` (always, default `up-bot`) as CI
   variables.
2. The `default` before_script resolves `BOUCLE_BOT_ID` by username
   via the GitLab users API when the variable is unset, so the loop
   still works on consumers that never ran `--bot-id` or ran an older
   `bin/setup`.

**Recurrence:** yes — a new consumer that skips `--bot-id` or runs an
old `bin/setup` hits this silently. The before_script fallback closes
the gap.

## Committing changes

**Always commit your changes before finishing.** Edits that are not
committed are not durable — they can be lost if the working tree is
reset, checked out, or if the session ends. After completing any work:

1. Stage the files you changed: `git add <paths>` (be specific; avoid
   `git add -A` unless you have verified `git status` is clean of
   unrelated changes).
2. Commit with a concise conventional-commit message matching the repo
   style (e.g. `feat: add image reading from issues`, `fix: ...`,
   `docs: ...`, `chore: ...`).
3. Verify the commit landed: `git log --oneline -1` and
   `git status` (working tree should be clean).

Do not push unless explicitly asked. Do not amend or force-push unless
explicitly asked. If a commit fails (e.g. a pre-commit hook rejects
it), fix the issue and create a new commit — do not amend the failed
one.
