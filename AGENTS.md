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