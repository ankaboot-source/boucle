# Scheduled maintenance templates (`.boucle/schedules/*.md`)

Opt-in: set `BOUCLE_SCHEDULES_ENABLED=true`. Each file is an issue body with
YAML frontmatter. When the cron is due, boucle creates the issue with
`boucle:triage` and the normal loop takes over — nothing about it is
special-cased downstream.

Granularity is **hourly**: the doctor sweeps every few minutes, so the
minute field is parsed and ignored. Times are UTC.

## `dependency-refresh.md`

```markdown
---
cron: "0 6 * * 1"
title: "chore: refresh dependencies"
labels: "chore"
enabled: false
---

Update the project's dependencies to their latest compatible versions.

Acceptance criteria:
- `npm ci && npm run build` succeeds.
- No major-version bump without a note in the MR explaining the migration.
- The deployed preview renders the home page unchanged.
```

## `accessibility-audit.md`

```markdown
---
cron: "0 7 1 * *"
title: "audit: accessibility sweep"
labels: "a11y"
enabled: false
---

Audit the live site against WCAG AA and fix what can be fixed safely.

Acceptance criteria:
- Every image has a meaningful `alt`.
- Colour contrast meets AA on body text and interactive elements.
- The page is fully navigable by keyboard.
```

Both ship disabled (`enabled: false`): they are examples, not defaults.
