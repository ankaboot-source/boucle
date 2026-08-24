# Skills audit — what the catalogue actually does, and what to change

> **Source.** Prompted by a study of 8,135 agent trial records across
> Terminal-Bench 2.0 and SkillsBench (arXiv 2608.14036). The paper itself was
> not reachable from this environment (`arxiv.org` is egress-blocked here), so
> every claim attributed to it below comes from the summary supplied with the
> request and is labelled as such. **Every boucle-side number is measured in
> this repo** with the command shown next to it — reproduce before acting.

## 0. The four claims, and what they cost boucle

| # | Claim (from the study summary) | Boucle's exposure | Measured |
| --- | --- | --- | --- |
| 1 | A distilled skill beats raw workflow memory by **+6.06 pp** — *how* experience is formatted matters as much as having it | `LESSONS.yml` is injected by a stopword-driven grep: it is raw memory, retrieved almost at random | **59 of 107 lessons** "match" a sticky-header issue |
| 2 | **65.7%** of successful skill cases are *procedural anchoring*; **4.5%** are knowledge injection | The catalogue is overwhelmingly reference material | **46 of 62** skills have no `## Verification`; **35 of 62** no `## When to use` |
| 3 | Distilling without success/failure hints drops success **74.6% → 40.0%** | `skills-used.json` records *which* skills were loaded, never *whether the iteration passed* | 0 outcome fields in the schema |
| 4 | Retrieval precision falls **29.6% → 3.3%** as a pool grows 5 → 100; the real danger is *semantic confusability* | 62 entries, flat, no buckets, with two large look-alike clusters | **28 of 62** skills sit in the design/UI (15) or animation (13) clusters |

Boucle already went further than most of the field on this: `bin/skills-index`
exists precisely because 41 of 62 skills were unreachable, and `bin/doctor
--audit` already advises on missing trigger and verification sections. The
findings below are what remains.

---

## 1. The lesson retriever injects noise, not memory

`bin/jc` extracts every word of 4+ characters from the issue body, dedupes,
keeps 20, joins them with `|`, and greps `LESSONS.yml` with that regex. Stop
words survive the filter — `should`, `when`, `user`, `page`, `down` are all
4+ characters — so the regex matches most of the file.

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
not 80 lessons** — so what reaches the prompt is the first handful of matching
lessons in *file order*, i.e. the oldest ones, with the last one truncated
mid-entry. Relevance plays no part in the selection.

This is exactly the study's "workflow memory" arm: noisy history injected raw.
It is also worse than doing nothing on two counts — it spends prompt budget,
and it teaches the agent that the lessons block is background noise, which is
what makes the *genuinely* relevant lesson skippable when it does appear.

**Proposed change** (`bin/jc`, lesson injection block):

1. Drop a stopword list before building the regex (`should|when|this|that|with|from|have|will|been|would|there|their|which|about|into|your|user|page|make|need|only|also|than|then|some|more|most|does|done`).
2. Require **two** distinct keyword hits per lesson instead of one, and score by hit count.
3. Cap by **whole lessons** (top 5), never by lines — a truncated lesson is a lesson whose `✅` half is missing, which inverts its meaning.
4. Log the selection: `[boucle:metrics] lessons_injected=<n> ids=<list>`, so the retriever becomes measurable instead of assumed.

The fallback path (inject lessons 1, 2, 5, 6, 99 when nothing matches) is
sound and should stay — it is the closest thing boucle has to a procedural
anchor today.

---

## 2. Three-quarters of the catalogue is a tutorial, not a runbook

The study's central mechanism is that skills work by *stabilising execution*,
not by supplying facts. Boucle's own audit already measures the gap:

```console
$ bin/doctor --audit
  ✓ all 62 skills are reachable via the generated index
  · ADVISORY 35 of 62 skills have no '## When to use' section
  · ADVISORY 46 of 62 skills have no '## Verification' section
```

Which skills *are* runbook-shaped is striking — they are one family, from one
upstream author:

```console
$ for f in .jcode/skills/*/SKILL.md; do grep -qi '^## *Verification' "$f" && basename $(dirname $f); done
ci-cd-and-automation        code-review-and-quality      code-simplification
debugging-and-error-recovery frontend-ui-engineering     git-workflow-and-versioning
incremental-implementation  observability-and-instrumentation
performance-optimization    planning-and-task-breakdown  security-and-hardening
shipping-and-launch         simplify                     spec-driven-development
test-driven-development
```

Every design skill, every GSAP skill, `prototype`, `research`, `taste-skill`,
`ui-ux-pro-max` — 47 of 62 — carry no verification step and, for 35 of them,
no trigger section either. By the study's split, that puts three-quarters of
the catalogue in the 4.5% bucket rather than the 65.7% one.

**Proposed change.** Define a *runbook contract* in `AGENTS.md` and enforce it
where boucle controls the content:

```markdown
## When to use     — trigger conditions, phrased as observable states
## Steps           — ordered, imperative, each step independently checkable
## Verification    — the command to run and the output that counts as evidence
## Failure modes   — the two or three ways this goes wrong, and the recovery
```

Vendored upstream skills should not be rewritten (they re-sync on every
`bin/update` and the NOTICE files require fidelity). Instead:

- add a boucle-authored `RUNBOOK.md` **beside** the vendored `SKILL.md` for
  the handful that agents actually load, and have `bin/skills-index` prefer it;
- promote the two `doctor --audit` advisories to a **blocker for
  boucle-authored skills only**, so the contract holds where it can.

---

## 3. Skill usage is recorded without its outcome

The study's sharpest number is the no-hint ablation: distilling from
trajectories whose success and failure are *not* annotated drops downstream
success from 74.6% to 40.0%. Boucle is currently building exactly that
un-annotated corpus.

`bin/jc` writes, per role invocation:

```json
{"timestamp": "…", "role": "worker", "iteration": 2, "observable": true,
 "skills": ["ui-ux-pro-max", "test-driven-development"]}
```

There is no field saying whether that iteration ended in a reviewer `PASS`, a
reviewer `FAIL`, an e2e verdict, or an escalation. So the file can answer
"were skills loaded?" and can never answer "did loading them help?" — which
is the only question that justifies a 62-skill catalogue.

**Proposed change.** The verdict is already in state by the time the next
stage runs; join it back:

1. Add `outcome: pass | fail | escalated | unknown` to each `skills-used.json`
   entry, back-filled by `lib/boucle-ci/reviewer.sh` and `e2e.sh` when they
   post their verdict (the iteration index is the join key).
2. Keep `unknown` explicit and distinct from `fail` — the same discipline that
   already makes `observable` a separate field from an empty skill list.
3. Add `bin/skills-index --stats` reading the accumulated files: per skill,
   `loaded_n`, `pass_rate`, and `pass_rate_delta` against runs that did not
   load it.

This is the cheapest of the five proposals and it is the one that unlocks the
rest: pruning, bucketing and runbook retrofits are all guesses until this
exists. It also converts the existing "0 skills loaded" soft gate from a
warning nobody acts on into a measurable hypothesis.

---

## 4. Retrieval: a flat list with two look-alike clusters

The index publishes 62 entries as one undifferentiated list — deliberately, and
the reasoning in `bin/skills-index` is right that a keyword pre-filter would
trade a 9% prompt cost for a miss rate. But the study's failure mode is not
list length, it is **semantic confusability**, and boucle has it concentrated:

| Cluster | Count | Members |
| --- | ---: | --- |
| Design / UI | 15 | `frontend-design`, `frontend-ui-engineering`, `effective-ui-design`, `high-end-visual-design`, `minimalist-ui`, `web-design-guidelines`, `ui-styling`, `ui-ux-pro-max`, `taste-skill`, `emil-design-eng`, `bergside-design-systems`, `redesign-existing-projects`, `image-to-code`, `web-artifacts-builder`, `prototype` |
| Animation | 13 | 8 × `gsap-*`, `animation-vocabulary`, `find-animation-opportunities`, `improve-animations`, `review-animations`, `react-view-transitions` |
| Simplification | 2 | `simplify` and `code-simplification` — near-identical descriptions |

An agent asked to "make the header sticky" faces 15 design skills whose
descriptions differ in tone, not in trigger condition. The study's remedy —
domain bucket first, strict trigger second — is a *display* change, which is
compatible with the index's existing "publish everything" principle:

```
Skill catalogue (62 skills, grouped by domain — load any of them at any time):

### ui — load ONE, then stop
- ui-ux-pro-max: … (DEFAULT for any UI work; run its search.py first)
- minimalist-ui: … (only when the charter specifies an editorial/monochrome direction)
…
### verification
### process
```

Concretely: add a `domain:` frontmatter key (boucle-owned, one line per skill,
no upstream conflict), group the index by it, and give each cluster a one-line
**disambiguator** stating which member is the default and what makes the others
fire. That is the "strict trigger" level, and it costs no reachability.

### Four defects found while measuring this

These are outright bugs of the same class `bin/skills-index` was written to
kill — a skill that ships in every clone and can structurally never be chosen.

1. **`effective-ui-design` publishes `|` as its description.** Its frontmatter
   uses a YAML block scalar (`description: |`); the `frontmatter()` awk parser
   in `bin/skills-index` reads same-line values only, so the index line is
   literally `- effective-ui-design: |`.
2. **`composition-patterns` publishes an empty description** — same cause, a
   multi-line plain scalar folded onto following lines.
3. **`boucle` publishes a bare name.** `.jcode/skills/boucle/SKILL.md` is a
   symlink to the root `SKILL.md`, which carries no YAML frontmatter (it opens
   on an `#` heading). This is the skill that *defines the loop protocol* —
   markers, labels, state machine — and no agent is ever told what it is for.
   The fix has to respect `bin/check-doc-sync`, which asserts the symlink and
   treats root `SKILL.md` as the real file: prepend the frontmatter to the root
   file (frontmatter is inert to every consumer of that document) rather than
   replacing the symlink with a wrapper.
4. **Two skills are invisible at depth 3.** The index globs `*/SKILL.md`, so
   `trailofbits/differential-review` and `trailofbits/insecure-defaults` are
   shipped, synced on every update, and unreachable — the exact 41-of-62 bug,
   recurring one directory deeper.

```console
$ find .jcode/skills -name SKILL.md | wc -l      # 65 on disk
$ bin/skills-index | wc -l                        # 62 published
```

Fixes 1–2 need a block-scalar-aware `frontmatter()`; 3 needs four lines of
frontmatter on the root `SKILL.md`; 4 needs the glob widened to depth 3 with the
parent directory as a name prefix (and `skill_manage` verified to resolve a
nested name before the index advertises one). All four are small, and all four are load-bearing:
they are skills the catalogue claims to have.

---

## 5. Skills boucle does not have, and should

The study's most transferable result is that skills fix *environment
infrastructure* failures best — 5.3% → 0.2%. Boucle's environment is CI, a
forge API, a preview deployment and a shell codebase, and the catalogue covers
none of it. Every one of these gaps is boucle-authored content, so all four
can be written to the runbook contract from §2 rather than retrofitted.

| Proposed skill | Why it is missing today | Shape |
| --- | --- | --- |
| **`shell-and-bats`** | Boucle *is* a shell codebase — bats, shellcheck, shfmt, `set -euo pipefail` — and the worker's domain skills are `astro`, `typescript-magician` and 15 design skills. The engine's own stack has no skill. | Runbook: write the bats case first, `make lint`, the shellcheck directives that are allowed, the `run`/`assert_*` idioms |
| **`preview-verification`** | The reviewer and e2e verify a deployed URL, and the only skill either is told about is `verification-before-completion`. This is precisely the environment-infrastructure category. | Runbook: fetch the preview, what a 404 vs a stale build looks like, which evidence goes in the verdict |
| **`forge-recovery`** | Rate limits, note-post failures, `409` conflicts and the mono-user approval dance are recurring failure classes recorded in `LESSONS.yml`, with no procedural anchor. | Runbook: detect, retry, and the never-leave-without-a-verdict rule |
| **`loop-protocol`** | The content exists (`.jcode/skills/boucle/SKILL.md`) but is invisible — see §4.3. It needs frontmatter and a `## When to use`, not authoring. | Fix, not new work |

**`e2e` is excluded from the catalogue entirely** (`bin/jc`, the `triage |
worker | reviewer` case) on a 30-step budget argument. That argument was
correct for a 62-entry flat list. Once §4's buckets exist, e2e should receive
its bucket only — three or four verification skills, ~400 characters — because
e2e is the role operating in the environment the study says skills protect
best.

---

## 6. Order of work

| P | Change | Effort | Unblocks |
| --- | --- | --- | --- |
| **P0** | The four index defects (§4) | ~1h | Skills the catalogue already claims to ship |
| **P0** | Stopword filter + whole-lesson cap on the retriever (§1) | ~2h | Stops the prompt budget being spent on noise |
| **P1** | `outcome` on `skills-used.json` + `--stats` (§3) | ~half a day | Every later decision; ends guessing |
| **P2** | `domain:` buckets + cluster disambiguators (§4) | ~1 day | e2e catalogue access |
| **P3** | Runbook contract + `doctor --audit` blocker for boucle-owned skills (§2) | ~1 day | The 65.7% mechanism |
| **P4** | The four new skills (§5) | ~2 days | Environment-failure class |

P0 and P1 are worth doing regardless of whether the study replicates: they fix
things that are broken, and they replace an assumption with a measurement.
P2–P4 are the study's actual thesis and should be sequenced *behind* P1, so
their effect is observable rather than asserted.

## 7. What this audit does not establish

- The study was read through a second-hand summary, not the paper. The
  mechanism (procedural anchoring) is plausible and matches boucle's own
  observations; the specific percentages are not independently verified here.
- Boucle has **no measured baseline** of its own skill effectiveness — that is
  finding §3, and it means none of the effect sizes above can be predicted for
  boucle, only the defects.
- Dogfooding is suspended (`CONTEXT.md` §1), so these changes will be validated
  on real consumers rather than in-repo. P1 is what makes that validation
  legible.
