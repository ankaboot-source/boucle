---
name: grill-me
description: Sharpen a plan or design through self-interrogation when no human reviewer is available.
disable-model-invocation: true
---

# Self-Grill

**CI mode:** no human is available to interview. The agent runs a self-grill: it generates the design or plan, then plays both the interviewer and the answerer to stress-test it, recording every question and answer inline so the result is auditable.

## Process

1. **State the artifact.** Write down the plan, spec, or design being grilled — one paragraph at the top of the response. If the input is a loose idea rather than a written plan, draft the plan first.
2. **Generate the questions.** Produce a numbered list of tough, specific questions a skeptical reviewer would ask: edge cases the plan doesn't cover, terms left undefined, contradictions, missing acceptance criteria, unstated assumptions, scope leaks, prior-art opportunities. Generate at least 10; stop when no new questions surface.
3. **Answer them honestly.** For each question, give the most plausible answer grounded in the codebase, the issue body, and any linked material. If the question genuinely cannot be answered without a human, mark it `needs-human` and list the missing input. Do not invent answers; flagging the gap is a valid resolution.
4. **Apply the answers.** For every answered question, update the artifact so it absorbs the answer — tighten the wording, add the missing edge case, define the undefined term, narrow the scope. Show the before/after in the response.
5. **Surface open items.** Conclude with the list of `needs-human` questions and any decisions you marked with low confidence. These are the items a human reviewer would still need to confirm.

The output is the hardened plan, plus an audit trail of the questions and answers that produced it.
