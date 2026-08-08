# LOOP — <target repo>

Per-consumer configuration for the boucle autonomous dev loop: target repo,
cadence, gates, caps. Read this file before touching the loop; it is
consumer-specific and never synced from upstream.

## Purpose

Autonomous dev loop for the target static site.

## Cadence

- **Trigger:** webhook (primary); jobs chain to the next role via the trigger
  token.

## Human gates

- **Spec validation** — configurable; default: Size M+ via
  `BOUCLE_SPEC_PROFILE=product`.
- **MR approval** — always human-gated.

## Do-Not-Disturb (DND)

When `BOUCLE_DND_ENABLED=true`, the spec gate is auto-validated during the
quiet window (default 22:00–07:00, configurable via
`BOUCLE_DND_START`/`BOUCLE_DND_END`/`BOUCLE_DND_TZ`). The loop runs
autonomously up to the MR without contacting the human. The skip is
transparent: triage posts an explanatory comment (active window + how to
disable) and applies the `boucle:dnd` flag label so the board shows WHY the
gate was skipped. MR approval stays human-gated.

## Caps

- **Iteration cap:** 3 worker runs per issue.
- **Budget cap:** not set at MVP — token-cost logging deferred to post-MVP.

## Escalation

Escalate to a human when:

- iteration cap hit,
- acceptance criteria unclear,
- size:L,
- destructive change proposed.

## Out of bounds

- `.boucle/` state files must not be deleted by agents.

## Bug policy

See `.jcode/UPSTREAM-FIX-WORKFLOW.md` — fix upstream in boucle first, then
update the consumer, then remediate existing data. Never patch a consumer to
work around a boucle defect.
