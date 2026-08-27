# boucle metrics

Append-only measurement log.

- `metrics.jsonl` — one JSON object per finished issue.
- `raw/<issue>.jsonl` — the raw per-run health
  lines that row was computed from, pushed as they are written so
  they outlive the ephemeral job that produced them.

Read with `bin/skills-stats`. Safe to delete: it is measurement,
never decision state.
