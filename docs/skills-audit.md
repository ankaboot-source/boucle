# Skills audit — what the catalogue actually does, and what to change

> **Source.** *Demystifying Agent Skills: Why They Work—Until They Don't*
> (Jiang, Huang, Xing, Wu, Gao, Cao, Wang, Liu, Li — Princeton / UC San Diego /
> Stanford / USC / Johns Hopkins, arXiv 2608.14036). 8,135 normalised trial
> records over Terminal-Bench 2.0, Terminal-Bench-Pro and SkillsBench; 528
> paired Raw / Workflow-Memory / Skill triples; a 12-mode taxonomy human-checked
> at 95.8% agreement (Cohen's κ = 0.952). **Every boucle-side number is measured
> in this repo** with the command shown next to it.

## 0. What the paper actually claims

Three corrections to the popular summary of this paper, because they change
which boucle work is worth doing:

- **The headline +6.06 pp is Skill over *Workflow Memory*, not over Raw.** In
  the paired sample, Skill vs Raw is **+2.84 pp, 95% CI [−2.27, +7.95]** — it
  crosses zero. Workflow Memory vs Raw is **−3.22 pp**, also crossing zero. The
  only interval that clears zero is Skill vs WM: **+6.06 pp, CI [+0.76,
  +11.36]** (Table 10). The paper establishes that *distilling* beats *dumping*.
  It does not establish, in that sample, that having skills beats having none.
  The main grid does show large Skill-over-Raw gains — 79.2% vs 50.0% on 26
  Terminal-Bench-2 tasks (Table 12) — but only when the source trajectories are
  mostly successful, which is the next point.
- **Source-trajectory quality dominates representation.** Distil from
  failure-only pools (`0s5f`) and Skill lands *below* the Raw baseline almost
  everywhere: 0.5161 vs 0.5935 (Codex/TB2), 0.4095 vs 0.4762 (Gemini/SkillsBench),
  0.4303 vs 0.5394 (Codex/TB-Pro) — Table 1. A skill distilled from failures is
  not a weak skill, it is a **negative** one.
- **Retrieval precision collapse does not move downstream success.** Actual-use
  precision falls 29.6% → 3.3% from pool size 5 to 100, while success moves only
  36.4% → 39.3%; recall stays 54.3–73.6% at k=100 (§5.5, Table 4). The paper's
  own words: "exact ground-truth invocation is neither sufficient nor necessary."

## 1. The four findings, mapped

| # | Finding (paper) | Boucle's exposure | Measured here |
| --- | --- | --- | --- |
| 1 | Failure-only source pools make distilled artifacts **worse than no artifact** | Lesson candidates are emitted **only at escalation** — boucle distils exclusively from runs the loop failed | 100% of the lesson pipeline is `0s5f` |
| 2 | Distilled skill beats inlined workflow memory by **+6.06 pp**; WM's own penalty is process overload (`timeout_budget_exhaustion` 10.6% vs 1.7% Raw) | Skills load from the environment (correct); `LESSONS.yml` is **inlined into the prompt** (the WM arm) by a stopword grep | **59 of 107** lessons "match" one sticky-header issue |
| 3 | Withholding outcome labels hurts **only once failures enter the pool** (Gemini TB2 `3s2f`: 0.7462 → 0.4000) | `skills-used.json` records which skills loaded, never whether the iteration passed | **0** outcome fields in the schema |
| 4 | `procedural_anchor` 65.7% vs `knowledge_injection` 4.5%; `environment_infrastructure_failure` 5.3% → 0.2% | Catalogue is overwhelmingly reference material, and covers none of boucle's own environment | **46 of 62** skills have no `## Verification` |

Boucle already went further here than most: `bin/skills-index` exists precisely
because 41 of 62 skills were unreachable, `bin/doctor --audit` already advises on
missing trigger and verification sections, and skills are placed in the
environment for on-demand loading rather than inlined — which is exactly the
protocol the paper's Skill arm uses (§3.2). What follows is what remains.

---

## 2. Boucle distils lessons only from failures — the paper's worst regime

This is the finding that moved to the top once the full paper was available.

`.jcode/agents/reviewer.md` emits a lesson candidate when `BOUCLE_ITERATION`
equals `BOUCLE_MAX_ITERATIONS` — the final iteration, when the loop is about to
escalate to `boucle:human`. `lib/boucle-ci/reviewer.sh` scrapes it; `bin/jc`
injects it into the next worker prompt for validation and commit. Every entry
in `LESSONS.yml` therefore originates from a run that **failed**.

In the paper's grid that is the `0s5f` cell, and it is the one cell where
distillation is net harmful:

| Setting | Raw | Skill @ `5s0f` | Skill @ `0s5f` |
| --- | ---: | ---: | ---: |
| Codex / Terminal-Bench 2 | 0.5935 | 0.7548 | **0.5161** |
| Codex / SkillsBench | 0.5083 | 0.7250 | **0.4500** |
| Gemini / SkillsBench | 0.4762 | 0.7429 | **0.4095** |
| Gemini / Terminal-Bench-Pro | 0.5615 | 0.6692 | **0.4615** |

Two mitigations already in place matter here, and neither is complete. The
`❌ / ✅` schema forces each lesson to state the failure *and* the corrective
behaviour, which is the outcome annotation of §4 — that is why `LESSONS.yml` is
not simply the `0s5f` disaster. And the four-point admission test (class not
instance, recurs without the doc, stable, not already covered) filters
instance-level noise. But the `✅` half is **written from the reviewer's
inference, never from an observed successful trajectory** — nothing in the
pipeline pairs a failed run with the run that later succeeded.

**Proposed change.** Give the lesson pipeline a success arm:

1. Emit a lesson candidate on the **first-pass** case too — when a worker
   iteration goes green on iteration 1 after a class of issue that previously
   escalated. That is the `s` side boucle has never collected.
2. When an escalated issue is later solved (by a human, or by a re-run), pair
   the failed and successful trajectories and distil the lesson from **both**.
   The state directory already carries the iteration history needed to do this.
3. Until that exists, keep the admission test strict and treat `LESSONS.yml`
   growth as a cost, not an achievement. 107 keys, 98 live, and every one of
   them distilled from a loss.

---

## 3. The lesson retriever injects noise, not memory

`bin/jc` takes every word of four or more characters from the issue body,
dedupes, keeps twenty, joins them with `|`, and greps `LESSONS.yml`. Stop words
survive that filter — `should`, `when`, `user`, `page`, `down` are all four-plus
characters — so the regex matches most of the file.

```console
$ K=$(printf '%s' "The header on the homepage should be sticky when the user scrolls down the page" \
    | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{4,}' | sort -u | head -20 | paste -sd'|' -)
$ echo "$K"
down|header|homepage|page|scrolls|should|sticky|user|when
$ awk -v kw="$K" 'BEGIN{IGNORECASE=1} /^[0-9]+:/ {if(buf&&buf~kw)c++; buf=$0"\n"; next} {buf=buf$0"\n"} END{if(buf&&buf~kw)c++; print c}' LESSONS.yml
59
$ grep -cE '^[0-9]+:' LESSONS.yml
107
```

59 of 107 lessons match. The block is then cut with `head -80` — **80 lines,
not 80 lessons** — so what reaches the prompt is the first few matching lessons
in *file order*, meaning the oldest ones, with the last one severed mid-entry.
Relevance plays no part in the selection.

The paper names the cost of exactly this shape. Inlined workflow memory
"preserves useful procedural evidence but carries irrelevant exploration, failed
branches, and verbose process noise" (§1), and its signature failure is
`timeout_budget_exhaustion` at **10.6%** of WM cases against 1.7% for Raw
(Table 11) — the agent spends its budget on procedural residue. Boucle's
lessons block is that residue, and a lesson cut mid-entry loses its `✅` half,
which is the half that says what to do.

**Proposed change** (`bin/jc`, lesson injection block):

1. Filter stop words before building the regex.
2. Require **two** distinct keyword hits per lesson, and score by hit count.
3. Cap by **whole lessons** (top 5), never by lines.
4. Log the selection — `[boucle:metrics] lessons_injected=<n> ids=<list>` — so
   the retriever becomes measurable instead of assumed.

The fallback path (inject lessons 1, 2, 5, 6, 99 when nothing matches) is sound
and should stay: it is the closest thing boucle has to a procedural anchor.

**Related:** `BOUCLE_MAX_PROMPT_CHARS` defaults to `0` (disabled) with a comment
saying "measure first". The measurement now exists in the literature — WM's
timeout rate is six times Raw's — and the `[boucle:prompt] total` line already
reports the number needed to pick a ceiling. Set one.

---

## 4. Skill usage is recorded without its outcome — IMPLEMENTED

Withholding success/failure labels during distillation drops downstream success
sharply — Gemini on Terminal-Bench-2 at `3s2f` falls from 0.7462 to 0.4000
(Table 16). The paper's own qualification is the part that matters for boucle:
the no-hint penalty is **negligible when the pool is success-only** (Codex
`5s0f`: 0.7548 normal vs 0.7677 no-hint) and grows as failed trajectories enter.
Boucle's pool is *entirely* failures (§2), so outcome annotation is not a
refinement here — it is the load-bearing element.

`LESSONS.yml` has it, in the `❌ / ✅` schema. `skills-used.json` did not: it
recorded *which* skills loaded while nothing recorded *how the run went*, so the
two could never be joined.

### What was built

**The join is now local to one file.** `health.jsonl` already carried the run
record (role, iteration, exit code, prompt size, tokens, cost, model). It now
also carries, on the same line, the three things that were missing:
`skills` (what the agent loaded), `arm` (what the prompt was given), and
`setup_fail` (whether the environment blocked the run). `skills-used.json`
survives as a projection for anything already reading it.

**Graded outcomes, not a verdict.** Per issue: worker iterations, `human_spec`
(human comments on the issue — a triage-quality signal), `human_delivery`
(human comments on the MR plus mid-work amends — a worker-quality signal, and
the one skills act on), and `setup_fail` runs. A binary pass/fail carries almost
no information per issue, and no consumer has the volume to detect a 3–6 point
effect on one.

**Iterations are censored, and stay marked as such.** An escalated issue did not
take N iterations, it took *at least* N. `iterations_censored` rides on every
row and `bin/skills-stats` never averages escalated with completed issues —
that average is wrong in a direction the reader cannot see from the result.

**`setup_fail` is the leading indicator.** It classifies runs the *environment*
blocked before the agent reached the task, in four families: `dependency`,
`toolchain`, `path`, `permission`. Service-lifecycle signatures (`EADDRINUSE`
and friends) are deliberately excluded — the paper measures those as a separate
mode with a much smaller effect (2.7% → 0.8% against 5.3% → 0.2%), and folding
them in would dilute the signal. It is orthogonal to the `build-fail` outcome
rather than a competitor: a run can be both, and `build-fail` stays
authoritative for "the code did not build".

**The confound is broken by randomising, not by hoping.** The agent chooses when
to load a skill, and it chooses on the issues it judges hard — which take more
iterations whatever the prompt says. Correlating the two over the logs reports
skills making things *worse* even when they help; this is why the paper built
528 matched triples instead of correlating its own 8,135 records. With
`BOUCLE_EXPERIMENT=on`, each issue is assigned `full` / `lessons` / `none` by a
hash of its id — stable across every role and iteration of that issue, and
independent of difficulty. **Off by default**: two arms out of three ship a
deliberately degraded prompt, which costs the consumer real iterations, so it
is their call. `bin/skills-stats` prints the confound warning next to the
observed split rather than trusting the reader to remember it.

**A durable sink, because there was none.** One row per issue is appended to
`metrics.jsonl` on an orphan `boucle/metrics` branch at the terminal transition,
hooked inside `set_boucle_label` — the same "hook here, not at the ~19 call
sites" reasoning the notification and board-refresh hooks already use, so it
fires exactly once per issue and only when iterations and human touches are
final. Orphan so the log never enters the consumer's history or triggers their
CI; fail-open throughout, so a metrics write can never be what stops an issue
reaching done.

### Two pre-existing bugs found while wiring this

1. **`health.jsonl` never received a single run record.** `bin/jc` is *executed*
   as its own process (`"$BOUCLE_HOME/bin/jc" worker`), not sourced, and never
   sourced `lib/boucle.sh` — so its call to `boucle_health_record` resolved to
   `command not found` and was swallowed by its own `|| true`. Only the stage
   outcomes, written from the sourced CI stages, ever landed in the file. That
   is why the half-empty file went unnoticed: it was never empty, just missing
   every row that mattered. `bin/jc` now sources the library defensively
   (guarded on the function being absent, so a caller that already sourced it
   pays nothing).

2. **The metrics files were never uploaded.** `lib/boucle.sh` said `cost.json`
   and `skills-used.json` "belong in the job artifacts" — and neither was ever
   listed in the artifact paths, on either forge. On an ephemeral runner every
   run collected them and then destroyed them with the container. Both, plus
   `health.jsonl`, are now in the artifact paths on GitLab and in all four
   GitHub upload steps.

### Reading it

```bash
bin/skills-stats                # observed split (confounded, always available)
bin/skills-stats --experiment   # arm split (causal; needs BOUCLE_EXPERIMENT runs)
bin/skills-stats --per-skill    # one row per skill
bin/skills-stats --json         # raw aggregate for a dashboard
```

### The limit this does not remove

The paper's effects are 3–6 points. Detecting 5 points on a binary at 80% power
needs roughly 1,500 issues **per arm**, which no single consumer has. A
per-consumer read will be **directional, not significant**, except on the
environment indicator whose effect is ~25× larger. Making it significant means
pooling across consumers, and that is an opt-in telemetry decision — a product
question, not a technical one, and deliberately not answered here.

## 5. Three-quarters of the catalogue is a tutorial, not a runbook

Skills work by *stabilising execution*: `procedural_anchor` accounts for 65.7%
of skill mechanisms against 4.5% for `knowledge_injection` (§5.1). Boucle's own
audit already measures the gap, in advisories nobody has acted on:

```console
$ bin/doctor --audit
  ✓ all 62 skills are reachable via the generated index
  · ADVISORY 35 of 62 skills have no '## When to use' section
  · ADVISORY 46 of 62 skills have no '## Verification' section
```

The runbook-shaped ones are a single upstream family:

```console
$ for f in .jcode/skills/*/SKILL.md; do grep -qi '^## *Verification' "$f" && basename $(dirname $f); done
ci-cd-and-automation         code-review-and-quality       code-simplification
debugging-and-error-recovery frontend-ui-engineering       git-workflow-and-versioning
incremental-implementation   observability-and-instrumentation
performance-optimization     planning-and-task-breakdown   security-and-hardening
shipping-and-launch          simplify                      spec-driven-development
test-driven-development
```

Every design skill, every GSAP skill, `prototype`, `research`, `taste-skill`,
`ui-ux-pro-max` — 47 of 62 — carry no verification step, and 35 no trigger
section either.

**The contract to adopt is the paper's own.** Appendix B.1 publishes the exact
`skill-creator` template behind every Skill-arm result, and it has two sections
boucle would not have thought to require — `Preconditions`, and a recovery
procedure distinct from the failure list:

```markdown
## Use This Skill When        — trigger conditions
## Preconditions              — what must be true before starting
## Steps                      — concrete and actionable, never vague
## Common Failure Modes To Avoid  — each as "signal and mitigation"
## If A Failure Happens       — stop, inspect, map to a mode above, re-verify
## Verify                     — how to confirm the skill completed successfully
```

Its rules are worth copying verbatim into `AGENTS.md`: one skill per file,
general enough to apply to similar tasks rather than the exact source task, and
**no task-specific file paths or data — use placeholders**. That last rule is
the same admission test `bin/check-lessons` already enforces on lessons (no
issue numbers, no SHAs, no line numbers). Boucle has the discipline; it has
simply never applied it to skills.

Vendored upstream skills should not be rewritten — they re-sync on every
`bin/update` and the NOTICE files require fidelity. Instead: add a
boucle-authored `RUNBOOK.md` *beside* the vendored `SKILL.md` for the handful
agents actually load and have the index prefer it; and promote the two
`doctor --audit` advisories to a blocker **for boucle-authored skills only**.

---

## 6. Retrieval: real defects, but the confusability worry was overstated

Four outright defects, all the same class `bin/skills-index` was written to kill
— a skill that ships in every clone and can structurally never be chosen:

1. **`effective-ui-design` publishes `|` as its description.** Its frontmatter
   uses a YAML block scalar; the `frontmatter()` awk parser reads same-line
   values only, so the published line is literally `- effective-ui-design: |`.
2. **`composition-patterns` publishes an empty description** — same cause, a
   multi-line plain scalar folded onto the following lines.
3. **`boucle` publishes a bare name.** `.jcode/skills/boucle/SKILL.md` is a
   symlink to the root `SKILL.md`, which carries no YAML frontmatter (it opens
   on an `#` heading). This is the skill that *defines the loop protocol* —
   markers, labels, state machine — and no agent is ever told what it is for.
   The fix has to respect `bin/check-doc-sync`, which asserts the symlink and
   treats root `SKILL.md` as the real file: prepend frontmatter to the root
   file (it is inert to every other consumer) rather than replacing the symlink.
4. **Two skills are invisible at depth 3.** The index globs `*/SKILL.md`, so
   `trailofbits/differential-review` and `trailofbits/insecure-defaults` ship,
   re-sync on every update, and are unreachable.

```console
$ find .jcode/skills -name SKILL.md | wc -l      # 65 on disk
$ bin/skills-index | wc -l                        # 62 published
```

Fixes 1–2 need a block-scalar-aware `frontmatter()`; 3 needs four lines on the
root `SKILL.md`; 4 needs the glob widened to depth 3 with the parent directory
as a name prefix (and `skill_manage` verified to resolve a nested name first).

### Why domain bucketing is now a P3, not a P2

Boucle publishes 62 entries flat, and has two large look-alike clusters —
15 design/UI skills (`frontend-design`, `frontend-ui-engineering`,
`effective-ui-design`, `high-end-visual-design`, `minimalist-ui`,
`web-design-guidelines`, `ui-styling`, `ui-ux-pro-max`, `taste-skill`,
`emil-design-eng`, `bergside-design-systems`, `redesign-existing-projects`,
`image-to-code`, `web-artifacts-builder`, `prototype`) and 13 animation skills
(8 × `gsap-*`, plus `animation-vocabulary`, `find-animation-opportunities`,
`improve-animations`, `review-animations`, `react-view-transitions`), plus
`simplify` and `code-simplification` with near-identical descriptions.

On a first reading this looked like boucle's biggest retrieval liability. The
full paper says otherwise, and the distinction is architectural. Semantic
confusability wrecks the paper's **offline** arms — embedding top-1 precision on
similar pools falls to 53.4%, explicit agent selection to 31.9% (Table 4). But
boucle does not do offline selection: it publishes the whole catalogue and lets
the agent load during execution, which is the paper's **Arm 3**. There,
precision collapses in every regime while downstream success stays flat, recall
stays at 54–74%, and related non-ground-truth skills "still provide useful
procedural support." Boucle's design already sits in the regime where
confusability is least costly.

Bucketing therefore stays worth doing — a `domain:` frontmatter key, the index
grouped by it, and a one-line disambiguator naming each cluster's default — as
a **display and cost** improvement, not a fix for measured harm. The one
concrete unlock is `e2e`: it is excluded from the catalogue entirely on a
30-step-budget argument that was correct for a 62-entry flat list. Once buckets
exist it should get its own bucket — three or four verification skills, ~400
characters — because e2e operates in the environment §7 says skills protect best.

---

## 7. Skills introduce their own failure surface, and boucle pushes on it

`skill_guidance_misapplied_or_ignored` appears in **10.0%** of skill-arm cases
against 0.8% for Raw (Table 11). The whole SC3 category — invocation,
applicability and boundary failures — rises from 19/528 in Raw to 78/528 with
skills. The paper is precise about the cause: "the skill contains plausible
guidance, but the agent applies it mechanically, misses a condition, or carries
over assumptions that no longer hold" (§5.3).

Boucle's prompts push in exactly that direction. The phrase **"You are NOT
excused from loading skills"** appears in all four agent files, `worker.md` adds
"**This is not optional**", and the metrics channel emits a `WARN` when an agent
loads zero skills. The intent was to fix non-adoption (41 of 62 skills were
unreachable, and adoption was the real bug). But the same pressure, applied
after the reachability fix, manufactures mechanical application — the SC3 mode.

**Proposed change.** Pair every load imperative with an abandonment clause:
*"Load the skill before working in its domain. If its preconditions do not hold
for this issue, say so on stdout and proceed without it — a skill applied
against its own preconditions is worse than no skill."* This is why the paper's
template puts `## Preconditions` immediately after the trigger section, and it
costs one sentence per agent file.

Related: the `0 skills loaded` soft gate should not become a hard gate. §4's
`outcome` field turns it into a hypothesis that can be tested; until then, an
agent that correctly declined to load anything is indistinguishable from one
that ignored the catalogue.

---

## 8. Skills boucle does not have, and should

`environment_infrastructure_failure` drops from 5.3% in Raw to 1.7% with
workflow memory to **0.2%** with skills (Table 11) — the largest single
reduction in the taxonomy. The paper's reading: "environment and tooling
problems are highly skillable. Once a reliable setup sequence, dependency
workaround, or path convention has been discovered, it can be encoded as
reusable procedural guidance."

Boucle's environment is CI, a forge API, a preview deployment and a shell
codebase. The catalogue covers none of it. Every gap below is boucle-authored,
so all four can be written to §5's contract rather than retrofitted.

| Proposed skill | Why it is missing today |
| --- | --- |
| **`shell-and-bats`** | Boucle *is* a shell codebase — bats, shellcheck, shfmt, `set -euo pipefail` — and the worker's domain skills are `astro`, `typescript-magician` and 15 design skills. The engine's own stack has no skill at all |
| **`preview-verification`** | Reviewer and e2e verify a deployed URL, and the only skill either is told about is `verification-before-completion`. Squarely the environment-infrastructure category |
| **`forge-recovery`** | Rate limits, note-post failures, `409` conflicts and the mono-user approval dance are recurring classes already in `LESSONS.yml`, with no procedural anchor |
| **`loop-protocol`** | The content exists — it is defect 3 in §6. Needs frontmatter and a `## Use This Skill When`, not authoring |

These four are also the best candidates for the success-arm distillation in §2:
a green CI run *is* an observed successful trajectory for `shell-and-bats`, and
boucle already produces them on every pipeline.

---

## 9. Order of work

| P | Change | Effort | Why here |
| --- | --- | --- | --- |
| **P0** | The four index defects (§6) | ~1 h | Skills the catalogue already claims to ship. Independent of the study |
| **P0** | Stopword filter + whole-lesson cap on the retriever (§3) | ~2 h | The WM arm's `timeout_budget_exhaustion` is 6× Raw's |
| ~~P1~~ **done** | Measurement: skills + arm + `setup_fail` on the run record, graded per-issue rows on an orphan metrics branch, `bin/skills-stats` (§4) | — | Shipped. Also fixed two pre-existing bugs: `bin/jc` never sourced the library so no run record was ever written, and the metrics files were never uploaded as artifacts |
| **P1** | Abandonment clause on the load imperatives (§7) | ~1 h | `skill_guidance_misapplied_or_ignored` is 10.0% vs 0.8% Raw |
| **P2** | Success arm for the lesson pipeline (§2) | ~1 day | Every lesson boucle owns was distilled from a loss — the one regime that goes below baseline |
| **P3** | Runbook contract, the paper's 6-section template + `doctor --audit` blocker for boucle-owned skills (§5) | ~1 day | The 65.7% mechanism |
| **P3** | `domain:` buckets + e2e's own bucket (§6) | ~1 day | Display and cost. Demoted: Arm 3 success is insensitive to precision collapse |
| **P4** | The four new skills (§8) | ~2 days | 5.3% → 0.2% on the environment class |

P0 and P1 are worth doing whether or not the study replicates: they fix things
that are broken and replace assumptions with measurements. P2–P4 are the study's
thesis, and belong behind P1 so their effect is observable rather than asserted.

## 10. What this audit does not establish

- Boucle has **no measured baseline** of its own skill effectiveness. That is
  §4, and it means none of the paper's effect sizes can be predicted for boucle
  — only the defects can.
- The paper's taxonomy comes from open coding over ~3% of the normalised records
  (238 valid labels over 528 paired triples). Human validation is strong on the
  labels that exist (κ = 0.952); rare modes may be underrepresented, and the
  authors say so.
- Its agent–model pairings are Codex/GPT-5.3-Codex and Gemini CLI/Gemini-3.1-Pro.
  Boucle runs glm-5.2 and deepseek-v4-flash. Whether open-weight models at a
  third of the intelligence index show the same procedural-anchoring benefit is
  untested, and the paper's own limitations section flags scaffold and model
  generalisation as open.
- RQ4's Codex pairing uses GPT-5.4 rather than GPT-5.3-Codex, so retrieval
  numbers are within-pairing comparisons only and are not comparable with the
  RQ1–RQ3 figures quoted elsewhere here.
- Dogfooding is suspended (`CONTEXT.md` §1), so these changes will be validated
  on real consumers rather than in-repo. P1 is what makes that validation legible.
