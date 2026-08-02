# LOOP — <target repo>

Purpose: Autonomous dev loop for the target static site.
Cadence: webhook (primary); jobs chain to the next role via the trigger token.
Human gates: spec validation (configurable, default: Size M+ via BOUCLE_SPEC_PROFILE=product) + MR approval.
Do-Not-Disturb: when BOUCLE_DND_ENABLED=true, the spec gate is auto-validated during the quiet window (default 22:00–07:00, configurable via BOUCLE_DND_START/END/TZ). The loop runs autonomously up to the MR without contacting the human. MR approval stays human-gated.
Iteration cap: 3 worker runs per issue.
Budget cap: (not set at MVP — token-cost logging deferred to post-MVP).
Escalate when: cap hit | criteria unclear | size:L | destructive change proposed.
Out of bounds: .boucle/ state files must not be deleted by agents.
Bug policy: see `.opencode/UPSTREAM-FIX-WORKFLOW.md` — fix upstream in boucle first, then update the consumer, then remediate existing data. Never patch a consumer to work around a boucle defect.
