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
