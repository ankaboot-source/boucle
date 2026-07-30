# LOOP — <target repo>

Purpose: Autonomous dev loop for the target static site.
Cadence: webhook (primary); jobs chain to the next role via the trigger token.
Human gates: spec validation (configurable, default: Size M+ via BOUCLE_SPEC_PROFILE=product) + MR approval.
Iteration cap: 3 worker runs per issue.
Budget cap: (not set at MVP — token-cost logging deferred to post-MVP).
Escalate when: cap hit | criteria unclear | size:L | destructive change proposed.
Out of bounds: .boucle/ state files must not be deleted by agents.
