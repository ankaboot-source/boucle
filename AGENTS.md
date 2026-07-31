# AGENTS.md

Instructions for AI agents working on the **boucle** project.

## Bug resolution workflow

The upstream-first bug fix workflow is defined in
[`.opencode/UPSTREAM-FIX-WORKFLOW.md`](.opencode/UPSTREAM-FIX-WORKFLOW.md).

That file is portable: it ships with boucle when installed in consumer
projects (via the `.opencode/` directory). Read it and follow it for any
bug reported on a consumer project.

Summary: **fix upstream in boucle first, then update boucle in the
consumer, then remediate existing data.** Never patch a consumer to
work around a boucle defect.

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