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

## Deploy targets & review modes

Boucle supports two deploy modes and two review modes, orthogonal and composable.

### Deploy modes (`BOUCLE_DEPLOY_MODE`)

| Mode | Behavior |
|------|----------|
| `self` (default) | Boucle runs `BOUCLE_DEPLOY_CMD` to deploy a preview (worker) and production (post-merge). URL is derived from deploy output via `BOUCLE_DEPLOY_URL_REGEX`, then falls back to `https://${BOUCLE_DEPLOY_PROJECT}.pages.dev`. |
| `external` | Boucle does NOT deploy. Post-merge waits for the consumer's own CI/CD on the merged commit (via `forge_commit_check_suites`), then hands `BOUCLE_LIVE_URL` to e2e. `BOUCLE_LIVE_URL` is **required**. |

### Review modes (`BOUCLE_REVIEW_MODE`)

| Mode | Behavior |
|------|----------|
| `preview` (default) | Worker deploys preview, reviewer tests against `BOUCLE_PREVIEW_URL` extracted from MR description via `BOUCLE_DEPLOY_URL_REGEX`. SHA-anchored freshness assertion. |
| `diff` | Worker skips preview deploy. Reviewer runs code-review mode: fetches PR diff via `forge_mr_diff`, waits for PR check suites via `forge_mr_check_suites` (bounded by `BOUCLE_REVIEW_CHECKS_WAIT`, default 900s), plus instructed-content fidelity checks. Verdict stays SHA-anchored. |

### Per-provider URL regex defaults

| Provider | `BOUCLE_DEPLOY_URL_REGEX` default |
|----------|-----------------------------------|
| Cloudflare Pages | `https://[a-z0-9.-]+\.pages\.dev` |
| GitHub Pages | `https://[a-z0-9-]+\.github\.io(?:/[\w-]+)?` |
| GitLab Pages | Prefer `$CI_PAGES_URL` (predefined); fallback regex: `https://[a-z0-9-]+\.[a-z0-9-]+\.gitlab\.io(?:/[\w-]+)*` |

GitLab Pages unique-domain mode uses random 6-char IDs — use `BOUCLE_LIVE_URL` or `$CI_PAGES_URL` instead of regex.

## CI/CD variables

Complete reference of all boucle CI/CD variables (set as repo secrets/variables). Defaults shown; override per-consumer. `bin/setup` seeds defaults where possible (e.g. `BOUCLE_DND_TZ` from the installing machine's timezone, fallback model variables).

| Variable | Default | Purpose |
|----------|---------|---------|
| `BOUCLE_ENABLED` | `true` | Master switch: `true` or `false` (pause boucle). |
| `BOUCLE_FORGE` | `gitlab` | Active forge: `gitlab` or `github`. |
| `BOUCLE_SPEC_PROFILE` | `product` | Spec validation profile: `product` (default, gates Size M only), `strict` (gates all sizes), `off` (never); unknown → `product`. |
| `BOUCLE_DND_ENABLED` | `true` | Do-Not-Disturb master switch: `true` or `false`. |
| `BOUCLE_DND_START` / `BOUCLE_DND_END` | `22:00` / `07:00` | Quiet-hours window: HH:MM 24h start/end. |
| `BOUCLE_DND_TZ` | `UTC` | Quiet-hours timezone (IANA name, e.g. `Europe/Paris`); seeded by `bin/setup` from the machine's timezone. |
| `BOUCLE_DND_EXCLUDE_DAYS` | *(empty)* | Comma-separated weekday names never in DND (e.g. `Fri,Sat`). |
| `BOUCLE_DEPLOY_MODE` | `self` | Deploy mode: `self` (boucle runs `BOUCLE_DEPLOY_CMD`) or `external` (consumer's own CI/CD deploys). |
| `BOUCLE_REVIEW_MODE` | `preview` | Review mode: `preview` (tests deployed preview) or `diff` (reviews PR diff + check suites). |
| `BOUCLE_DEPLOY_CMD` | `npx wrangler pages deploy ...` | Deploy command (self mode). |
| `BOUCLE_DEPLOY_URL_REGEX` | `https://[a-z0-9.-]+\.pages\.dev` | Regex to extract URL from deploy output. |
| `BOUCLE_DEPLOY_PROJECT` | `""` | Cloudflare Pages project name (self mode). |
| `BOUCLE_LIVE_URL` | `""` | Production/live URL (overrides regex/pages.dev fallback; **required** in external mode). |
| `BOUCLE_PRODUCTION_URL` | `""` | Production URL fallback for e2e. |
| `BOUCLE_PREVIEW_MARKER_PATH` | `__boucle_commit__.txt` | SHA marker probe path (relative to URL root). |
| `BOUCLE_PREVIEW_PROPAGATION_WAIT` | `60` | Seconds to wait for preview CDN propagation. |
| `BOUCLE_PREVIEW_DISABLE` | `false` | Skip Chromium visual preview in triage: `true` or `false`. |
| `BOUCLE_PREVIEW_VIEWPORTS` | `390x844,1440x900` | Viewports rendered for the triage mockup, comma-separated `WxH`. One screenshot per entry, labelled by device class in the triage comment. Total bytes respect `BOUCLE_IMAGE_TOTAL_MAX_BYTES`; a malformed entry is skipped, and one failing viewport never loses the others. |
| `BOUCLE_EXTERNAL_DEPLOY_WAIT` | `600` | Max seconds to wait for consumer's own CI on merged commit. |
| `BOUCLE_REVIEW_CHECKS_WAIT` | `900` | Max seconds to wait for PR check suites in diff mode. |
| `BOUCLE_BUILD_CMD` | `npm ci && npm run build` | Build command. |
| `BOUCLE_BUILD_OUTPUT` | `public` | Build output directory. |
| `BOUCLE_RUNNER_TAG` | `boucle` | Runner tag for agent jobs (GitLab; `bin/setup --runner-tag`). |
| `BOUCLE_RUNS_ON` | `ubuntu-latest` | Runs-on expression (GitHub; forge-agnostic — maps to tags on GitLab). |
| `BOUCLE_MAX_PARALLEL_ISSUES` | `5` | Max concurrent boucle:working issues (`0` = unlimited). |
| `BOUCLE_MAX_ITERATIONS` | `3` | Max worker re-runs per issue before escalation. |
| `BOUCLE_STALENESS_THRESHOLD` | `2400` | Seconds before a stuck issue is re-triggered (must exceed max job timeout, 30 min). |
| `BOUCLE_UPDATE_MODE` | `release` | Update mode: `release` (pinned engine release) or `dev` (tracking branch). |
| `BOUCLE_LLM_BASE_URL` | — | LLM API endpoint (any OpenAI-compatible). |
| `BOUCLE_LLM_API_KEY` | — | LLM API key (masked secret). |
| `BOUCLE_VISION_ROUTING` | `enabled` | Vision model routing: `enabled` or `disabled`. |
| `BOUCLE_VISION_MODEL` | `minimax-m3` | Vision model for image-enabled roles. |
| `BOUCLE_VISION_ROLES` | `triage,worker,reviewer` | Roles eligible for vision model routing (comma-separated). |
| `BOUCLE_FALLBACK_PROVIDER` | *(empty)* | Fallback provider profile name; empty = disabled. Requires `BOUCLE_FALLBACK_BASE_URL` + `BOUCLE_FALLBACK_API_KEY` (masked). Retries on exit-4 (provider down / quota exhausted) before escalating. |
| `BOUCLE_FALLBACK_BASE_URL` | *(empty)* | Fallback provider endpoint (OpenAI-compatible). |
| `BOUCLE_FALLBACK_API_KEY` | *(empty)* | Fallback provider key (masked secret). |
| `BOUCLE_FALLBACK_MODEL_TRIAGE` | `glm-5.2` | Per-role fallback model overrides. |
| `BOUCLE_FALLBACK_MODEL_WORKER` | `deepseek-v4-flash` | |
| `BOUCLE_FALLBACK_MODEL_REVIEWER` | `glm-5.2` | |
| `BOUCLE_FALLBACK_MODEL_E2E` | `deepseek-v4-flash` | |
| `BOUCLE_PROVIDER_PROFILE` | `boucle` | jcode provider profile name. |
| `BOUCLE_IMAGE_MAX_BYTES` | `10485760` | Max bytes per attachment (10 MiB). |
| `BOUCLE_IMAGE_TOTAL_MAX_BYTES` | `52428800` | Max total bytes per issue (50 MiB). |
| `BOUCLE_QUOTA_PROBE` | `true` | Ask the provider whether it can answer before spinning up an agent run. |
| `BOUCLE_QUOTA_PROBE_TTL` | `300` | Seconds a probe result is reused, so parallel jobs probe once. |
| `BOUCLE_NOTIFY_URL` | *(empty)* | Send-only webhook for human gates and escalations. Empty = disabled. Set as a **masked** variable. |
| `BOUCLE_NOTIFY_FORMAT` | `slack` | Payload envelope: `slack` (also Discord via a `/slack` endpoint), `ntfy`, `telegram`, `raw`. |
| `BOUCLE_NOTIFY_EVENTS` | `spec-review,approval,human,blocked` | Which transitions fire a notification. |
| `BOUCLE_REVIEW_ANCHORING` | `full` | How much of a prior reviewer verdict reaches the next review pass: `full`, `criteria-only`, `none`. See §Anti-anchored re-review. |
| `BOUCLE_MAX_NOTE_CHARS` | `1500` | Per-note cap when a note thread is injected into a prompt. Every note survives — only its tail is elided. `0` disables trimming (escape hatch). |
| `BOUCLE_MAX_PROMPT_CHARS` | `0` | Thread-level ceiling on the **assembled** prompt. `0` = disabled. See §Prompt budget. |
| `BOUCLE_PROMPT_WARN_CHARS` | `0` | Log a warning above this assembled size without altering the prompt. `0` = never warn. |

### Bot token (GitHub)

On GitHub the bot **is** the account that owns the `BOUCLE_TOKEN` PAT. Create it at
[https://github.com/settings/tokens/new](https://github.com/settings/tokens/new)
with **`repo` + `workflow`** scopes (optionally `admin:org` for
branch-protection checks) — see
[Scopes for OAuth apps](https://docs.github.com/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps).
Select a sensible expiration (fine-grained or classic PATs both work; classic
with the two scopes is the simplest).

`bin/setup --forge github` resolves the PAT's account, seeds
`BOUCLE_BOT_USERNAME` with it and stores the PAT as `BOUCLE_TOKEN` (secret). A
**missing, invalid, or expired PAT fails setup with an explicit message** —
the loop never runs half-configured. Renew the PAT and re-run `bin/setup`
(idempotent) when the stored token expires.

## Provider probe

Boucle used to discover an exhausted quota the expensive way: provision the
runner, clone the repo, build the prompt, run the agent, burn the retry
budget, *then* fall back. With `BOUCLE_MAX_PARALLEL_ISSUES=5` that waste is
multiplied by five before anyone notices.

The probe asks first — one cheap request to `<base_url>/models`:

| Response | Meaning | Action |
|---|---|---|
| `2xx` | ok | Run normally |
| `429`, `402` | quota exhausted | Switch to the fallback **before** the run, consuming no retry budget |
| `5xx` | provider down | Same |
| `401`, `403` | auth problem | Same, and the status is named in the escalation |
| unreachable | unknown | **Run anyway** |

When neither provider can answer, boucle does not start the agent: it exits
with the established provider-down code (4), CI posts a diagnostic and
escalates. Burning a runner to produce nothing is the worst outcome.

**This does not replace the reactive path.** A quota can be exhausted
mid-run, and only the in-flight fallback catches that. The probe removes the
waste in the case that was knowable in advance.

**Fail-open by construction.** An unreachable or unparseable probe runs the
agent anyway — a runner with flaky egress must not stop the loop. The probe
is an optimisation; it must never become a new failure mode.

## Notifications

The loop is asynchronous by design — you are not meant to watch it. But the
forge's own emails arrive with the same weight as any other repository
activity, so the two moments that actually need you (spec gate, MR gate)
look identical to a label tweak.

Set `BOUCLE_NOTIFY_URL` and boucle POSTs to it on four transitions:
`spec-review`, `approval`, `human`, `blocked`. Narrow the list with
`BOUCLE_NOTIFY_EVENTS`. Routine transitions (`working`, `review`, `todo`,
`done`, `merging`) never fire — a channel that pings on every state change
gets muted within a day, which is worse than silence.

**Send-only, on purpose.** `CONTEXT.md` §7 forbids a new frontend, a server,
or a machine to keep running. boucle POSTs; nothing listens. To reply, you
comment on the issue or the MR — the loop already reads those.

| Format | Endpoint | Body |
|---|---|---|
| `slack` (default) | Slack incoming webhook, or a Discord webhook with `/slack` appended | `{"text": "…"}` |
| `telegram` | `https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<ID>` | `{"text": "…"}` |
| `ntfy` | `https://ntfy.sh/<topic>` | plain text |
| `raw` | anything | `{"event","issue","title","url","waiting_for"}` |

Two guarantees:

- **Fail-open.** A webhook that times out, 404s or 500s logs a warning and
  the job continues. A dead webhook must never block the loop.
- **Silent during DND.** Notifications are suppressed inside the quiet
  window — not being contacted is the entire point of it.

Notifications fire on the **transition**, never on the state: the doctor
sweep re-applies labels that are already set, and notifying on presence
would re-fire on every sweep.

## Anti-anchored re-review

On iteration N the reviewer reads its **own** iteration N-1 verdict. That
invites two opposite failures:

- **ratification** — the previous reasoning gets re-endorsed, and a
  regression introduced *by* the fix slips through unexamined;
- **tunnel vision** — only the previously failed criteria get re-checked.

| `BOUCLE_REVIEW_ANCHORING` | What the reviewer sees of a prior verdict |
|---|---|
| `full` (default) | Everything — the verdict, met and unmet criteria, and the reasoning |
| `criteria-only` | The `VERDICT:` line and the unmet `- [ ]` criteria, with the rationale stripped: what must still pass, not why it failed |
| `none` | A placeholder; the verdict is withheld |

Two things are never filtered, at any setting:

- **Human comments.** They amend the spec and outrank the frozen criteria in
  `state.md`. Withholding one is a spec regression, not a saving.
- **Bot notes that are not verdicts** (CI status notes). They carry loop
  context, not review reasoning.

The **worker** always receives full verdict reasoning — it has to act on a
FAIL, so it needs the why. Only the reviewer's own view is filtered.

**The default is `full` on purpose.** Withholding prior verdicts is not
obviously correct: a reviewer that forgets what it already rejected can
flip-flop across iterations, and the worker then chases a moving target and
burns the iteration cap. Turn on `criteria-only`, compare verdict stability
across iterations on real issues, and only then decide. An unknown value
falls back to `full` rather than filtering blind.

## Agent transcript

Every agent job uploads `agent-output.log` as a CI artifact (`when: always`
on GitLab, `if: always()` on GitHub, 7-day retention). A failed run is
exactly the one whose transcript matters, so it is uploaded on failure too.

Every escalation comment — "produced no code changes", "not mergeable",
"human intervention needed" — carries a link to the job that produced it.
Follow the link, open the artifacts, read the transcript.

The log is **scrubbed before it leaves the runner**: `bin/jc` redacts the
values of `BOUCLE_LLM_API_KEY`, `BOUCLE_FALLBACK_API_KEY`, `BOUCLE_TOKEN`,
`BOUCLE_BOT_TOKEN` and the Cloudflare token, plus generic token shapes
(`ghp_…`, `glpat-…`, `sk-…`, `Bearer …`). Redaction is literal, not
regex-based, so a key containing regex metacharacters is still caught. It
runs before every exit path, including the failure ones.

## Prompt budget

`BOUCLE_MAX_NOTE_CHARS` bounds the **worst note**; it does not bound the
**assembled prompt**. A note thread grows monotonically (triage analysis,
per-criterion reviewer verdicts, CI status notes, human comments), so forty
notes at 1500 chars is 60k chars that pass through untouched. Context rot
does not raise an error — the agent silently misses a file, which surfaces
one stage later as a reviewer FAIL and burns an iteration.

**Measure before you cap.** Every agent invocation logs an assembled size on
stderr:

```
[boucle:prompt] total role=worker iteration=2 total_chars=48213 est_tokens=12053 body_chars=1840 notes_chars_raw=51002 feedback_chars_raw=9310 ceiling=0
```

Set `BOUCLE_PROMPT_WARN_CHARS` first to see how close your repository runs,
then set `BOUCLE_MAX_PROMPT_CHARS` from observed values. Choosing a ceiling
blind truncates legitimate context.

When the ceiling is exceeded, boucle tightens **bot-authored notes only**,
along the ladder 750 → 300 → 120 chars, stopping at the first rung that
fits. Two invariants hold at every setting:

- **Human comments are never trimmed.** They amend the spec and take
  precedence over the frozen acceptance criteria in `state.md`; a truncated
  human amendment is a spec regression, not a saving.
- **No note is ever dropped.** Only tails are elided — the early
  preservation instructions must keep standing alongside later amendments.

If the floor is reached and the prompt still exceeds the ceiling, boucle
logs a warning and proceeds. It will not close the gap by dropping notes.

## Bug policy

See `.jcode/UPSTREAM-FIX-WORKFLOW.md` — fix upstream in boucle first, then
update the consumer, then remediate existing data. Never patch a consumer to
work around a boucle defect.
