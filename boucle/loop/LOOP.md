# LOOP — urgence-palestine.fr

Purpose: Autonomous dev loop for the urgence-palestine.fr static site.
Cadence: webhook (primary); jobs chain to the next role via the trigger token.
Human gates: MR approval (only).
Iteration cap: 3 worker runs per issue.
Budget cap: (not set at MVP — token-cost logging deferred to post-MVP).
Escalate when: cap hit | criteria unclear | size:L | destructive change proposed.
Out of bounds: .boucle/ state files must not be deleted by agents.
