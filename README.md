<div align="center">
  <img src="https://boucle.dev/boucle-logo.gif" height="200" alt="boucle's logo"/>

  # boucle — zero-code autonomous product builder

> From a ticket in your forge to a feature in production — without running
> agents on your own machine. No laptop left half-open overnight. No Mac
> Mini purchase required.
</div>

boucle is zero-code **loop engineering**: you express a need in an issue,
and boucle handles the rest — analysis, implementation, review, merge,
deploy, verification. You stay in the forge you already use every day; you
never touch the engine itself.

## 📑 Table of contents

- [✨ Why boucle?](#-why-boucle)
- [How to install](#how-to-install)
  - [🚀 Quick start](#-quick-start)
  - [No terminal? Use a prompt](#no-terminal-use-a-prompt)
  - [Detailed install — CLI](#detailed-install--cli)
  - [Prerequisite](#prerequisite)
  - [After install](#after-install)
- [⚙️ How it works](#-how-it-works)
- [💰 Cost](#-cost)
- [🛠️ Configuration](#-configuration)
  - [The bot user](#the-bot-user)
  - [Running without a bot account (mono-user)](#running-without-a-bot-account-mono-user)
  - [Advanced — dedicated runners](#advanced--dedicated-runners)
- [🗺️ Roadmap](#-roadmap)
- [⚖️ License](#-license)
- [📚 Docs](#-docs)

## ✨ Why boucle?

A harness made for humans, by an indie product builder for product builders.

1. **End to end, amend anytime** — a ticket becomes a feature in production.
   Comment on the issue and the loop picks it up, re-plans, adjusts. No
   frozen specs.
2. **Lives in your forge** — GitHub or GitLab. No external tool, no dashboard.
   Everything happens where you already work.
3. **Spec on mockups, result on a live preview** — you validate the spec on
   mockups before code is written, and the result on a live preview with
   screenshots — not prose.
4. **Deterministic, therefore reliable** — a label-driven state machine with
   no self-approval path. You intervene at the decision points, not in a
   live chat.
5. **Works while you sleep** — runs on your forge's CI, not a daemon on your
   laptop. Nothing to install, nothing to restart, nothing to babysit.
6. **No UI, no CLI** — you interact through your forge: issues, comments,
   labels. Just a 👍 to approve.
7. **Verifies behavior, not diffs** — a preview URL, screenshots, and a
   SHA-anchored post-deploy e2e gate. Reviews that ship broken code are a
   thing of the past.
8. **Fast and cheap — BYOK** — purpose-built agents on your forge's CI, with
   your own LLM credentials. Step and iteration caps per role. 9.9× less
   per feature than Claude Code — see [Cost](#cost).
9. **Self-healing, self-learning** — the loop captures lessons from each run,
   self-updates, and adapts to your codebase as your project advances.
10. **Batteries included, yours to keep** — [jcode](https://github.com/1jehuang/jcode)
    (Rust binary), a [codebase knowledge graph](https://github.com/DeusData/codebase-memory-mcp),
    and a curated [skill library](.jcode/skills/) (UI/UX, design, frontend).
    No SaaS, no middleman — your code, your data, your tokens.

<details>
<summary><b>Other features</b> — the factual list, beyond the pitch above</summary>

- **Four specialized agents** — triage (spec), worker (implementation),
  reviewer (verification), e2e (production check), each with a focused prompt
  and step/iteration caps.
- **Mono-user mode** — no second account required: one account carries the
  issues, the MRs and the loop's own actions.
- **Deploy-agnostic** — Cloudflare Pages, GitHub Pages, GitLab Pages, or your
  own pipeline (`external` mode).
- **Three review modes** — `preview` (test the deployed preview), `diff`
  (review the MR diff + check suites), `screenshot` (grade screenshots via a
  vision model).
- **Do-Not-Disturb** — opt-in quiet window: the spec gate is auto-validated,
  the loop runs autonomously up to the MR.
- **Observability in the issue** — `/boucle status`, `/boucle log`,
  `/boucle help` as issue comments.
- **Interactive takeover** — `boucle takeover` resumes the worker's jcode
  session interactively when the loop escalates.
- **Status board** — a pinned issue answers "what is waiting on me?".
- **Scheduled maintenance issues** — cron-driven issue creation from
  `.boucle/schedules/*.md`.
- **Provider probe + fallback** — quota is probed before a run; a fallback
  provider takes over when the primary is down or exhausted.
- **Cost accounting** — per-issue token and cost tracking
  (`.boucle/<issue>/cost.json`).
- **Open-source, open-weight** — AGPL-3.0, open-weight models by default.
</details>

## How to install

### 🚀 Quick start

One command, and the loop takes over.

```sh
curl -fsSL https://raw.githubusercontent.com/ankaboot-source/boucle/main/install.sh | bash
```

The installer adds boucle as a git submodule (`.boucle/`) and runs
`bin/setup`, which auto-detects your forge from the `origin` remote. Then
create an issue in your forge and tag it `boucle:triage` — the loop starts.

### No terminal? Use a prompt

Ask your coding agent (Claude Code, Cursor, …) to install boucle by pasting
this prompt. **Nothing to replace**: the agent detects your GitLab/GitHub
host and project from the git remote, and it works even if you are not
already inside the target repository.

```text
Install boucle on this GitLab/GitHub repository. Execute these steps and report
back what you did:

1. If you are not already inside the target repository — the one whose
   origin remote points to your GitLab host — ask the user for its URL,
   clone it, and work from the clone.
2. git submodule add https://github.com/ankaboot-source/boucle .boucle
3. Run setup in non-interactive mode. It auto-detects the GitLab host and
   project from `git remote get-url origin`, so no value needs to be
   replaced: .boucle/bin/setup --non-interactive
4. Do NOT include an API key anywhere. The API key must never appear in
   this conversation. If setup tells you the key is missing, that's
   expected — it is configured manually in the GitLab UI afterwards.
5. git add .gitmodules .boucle .gitlab-ci.yml && git commit -m "chore: install boucle engine"
6. Show me the URL bin/setup printed for configuring the masked API key,
   and any next steps it listed.
```

### Detailed install — CLI

Run the steps by hand when you want control over each one — flags, bot
account, commit message. The one-liner above is a thin wrapper over these
steps:

```sh
git submodule add https://github.com/ankaboot-source/boucle .boucle
.boucle/bin/setup --non-interactive   # auto-detects the forge from origin
git add .gitmodules .boucle .gitlab-ci.yml
git commit -m "chore: install boucle engine"
```

Pass flags to setup when you need them — e.g. a GitHub bot account:

```sh
.boucle/bin/setup github --bot-token "<bot-PAT>" --bot-id <bot-user-id>
```

Prefer a one-liner with flags? Pipe them through the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/ankaboot-source/boucle/main/install.sh | bash -s -- github --bot-token "<bot-PAT>" --bot-id <bot-user-id>
```

`bin/setup` is idempotent — re-run it to change the bot, the runner tag
(`--runner-tag`), or the allow list (`--allowed-users`).

### Prerequisite

A Git repository hosted on **GitLab or GitHub**, with a
deployment target. The default target is Cloudflare Pages, but boucle is
deploy-agnostic: set `BOUCLE_DEPLOY_MODE=external` when your own CI/CD ships
the app (no deploy command needed, e2e still runs after merge), or bring any
hosting reachable by `BOUCLE_DEPLOY_CMD`/`BOUCLE_LIVE_URL` — see the
[Configuration](#configuration) table and [LOOP.md](LOOP.md). `bin/setup`
creates the bot (a project service account on GitLab, the PAT owner on
GitHub) as part of the install — see [The bot user](#the-bot-user) if you
prefer to wire in an existing account instead.

### After install

1. Add `BOUCLE_LLM_API_KEY` as a masked secret (GitLab: Settings → CI/CD →
   Variables; GitHub: Settings → Secrets and variables → Actions).
2. Create an issue. To dispatch the autonomous loop, add the `boucle:triage`
   label and assign the bot. To work interactively (a local harness drives
   the work), create the issue with **no** boucle labels — see
   [AGENTS.md](AGENTS.md) §"Interactive agents (harness)".

From there, the pipeline takes over. You only answer the human prompts:
spec validation and MR approval. The `doctor` job (a scheduled
self-healing sweep) runs automatically — there is nothing to run by hand.

## ⚙️ How it works

boucle lives in your forge. GitHub, GitLab. No external tool, no dashboard.

1. **Drop your idea in an issue** — I create an issue in my forge with a title and a description. It's just a normal ticket.
2. **Receive a proposal with a preview** — boucle analyzes, writes a spec, and posts a comment on the issue with a preview. I see exactly what it will look like.
3. **Validate with a thumb** — I react with a thumb up on the spec comment. No form, no CLI. Just an emoji.
4. **It works** — boucle implements, builds, deploys a preview. I have nothing to do meanwhile. The agent works.
5. **It's verified** — the reviewer checks the render, posts a verdict (PASS/FAIL) as a PR comment. If FAIL, it loops. If PASS, the PR is ready.
6. **Approve, it's live** — I approve the PR (or boucle merges per config). The feature ships to production. It's live.
7. **Lessons learned** — boucle captures what worked and what didn't from each loop, and applies those lessons to do better on the next feature.

> **Pipeline diagram** — the full 8-stage flowchart (triage → worker →
> reviewer → e2e, with the Self-improvement feedback node) lives in
> [ARCHITECTURE.md](ARCHITECTURE.md) §1. It is the single source of truth;
> this README keeps the prose summary below.

The loop runs asynchronously on CI. You intervene at two named gates —
spec approval and MR review — not in a live chat. A chat-based agent demands
your attention *now*; boucle inverts that: you take back control of the
timing.

**Do-Not-Disturb** (`BOUCLE_DND_*`, opt-in — disabled by default)
auto-validates the spec gate during your off-hours, so the loop never blocks
on you overnight. You approve the spec over morning coffee; by lunch the
worker has implemented, the reviewer has verified the preview, and the MR is
waiting — a calmer workflow, driven by your agenda, not the agent's.

**Peek without leaving the issue** — type `/boucle status` (or
`@<bot> status`) as an issue comment to see a `bin/health` projection of the
loop, `/boucle log` to read the tail of the agent's `agent-output.log`, or
`/boucle help` for the verb list. It is read-only: no label changes, no agent
invocation — just observability, in the same channel the loop posts in. See
[LOOP.md](LOOP.md) §"Interactive commands" for the full surface.

boucle is built on gates rather than on model choice. Anthropic's
["Building Effective Agents"](https://www.anthropic.com/research/building-effective-agents)
(Dec 2024) recommends "programmatic checks (gates) on any intermediate steps"
and notes that "code solutions are verifiable through automated tests." That
is the design boucle implements: four roles, each with a focused prompt, and
verdicts anchored to a commit SHA — an implementation is graded on the
behaviour of a real deployment, not on the agent's own account of it.

Whether this beats simply spending more on a stronger model is an **open
question**, not a settled one. boucle records tokens and cost per issue, per
role, per iteration (`.boucle/<issue>/cost.json`), so the trade-off is
measurable on your own repository rather than argued from benchmarks that
were not designed to answer it.

## 💰 Cost

The per-feature cost below serves two purposes: it tells you the **direct
cost** of shipping one feature, and — on a fixed-budget plan — it tells you
the **capacity**: how many features that budget sustains per month.

### Cost per feature

One feature flows through four roles: **triage** (analyze the issue, draft
the spec) → **worker** (implement, up to 3 iterations) → **reviewer** (verify
the preview, up to 3 iterations) → **e2e** (verify the live deployment). The
cost of one feature is the sum of all role invocations.

| | boucle | Claude Code |
| --- | ---: | ---: |
| **Cost per feature** | **$0.80** | **$15.00** |
| Intelligence (triage / worker) | 53 / 52 | 63 / 55 |
| **Cost per large feature** (intelligence-adjusted¹) | **$1.51** | **$15.00** |

The $/task figures are the **cost per Intelligence Index task** from
[Artificial Analysis](https://artificialanalysis.ai) (v4.1.1, max-effort
reasoning, retrieved 2026-08-09). ¹ Nominal Large feature: three failure
modes (feature KO, extra iterations, post-ship bugs) modeled per role and
weighted by feature size — boucle ships a large feature for **9.9× less**
than Claude Code. Full method, sensitivity, and break-even in
[docs/cost-benchmark.md](docs/cost-benchmark.md).

### Monthly capacity, multiplied

The plan is the base; the per-feature cost determines how many features it
sustains. boucle also runs issues **in parallel** (up to
`BOUCLE_MAX_PARALLEL_ISSUES`, default 5), so the monthly capacity is the plan
allowance divided by the per-feature cost — not serialized.

| Plan | Price | Config | $/feature | Features/month |
| --- | ---: | --- | ---: | ---: |
| Ollama Max | $100 | **default (GLM-5.2 + DeepSeek)** | $0.80 | **~125** |
| Ollama Max | $100 | full DeepSeek | $0.24 | ~416 |
| Ollama Max | $100 | Kimi K3 triage + DeepSeek | $1.22 | ~82 |
| Claude Code Max 20× | $200 | Opus 5 + Sonnet 5 | $15.00 | ~13 |

For **half the monthly fee**, boucle on Ollama Max ships **6–32× more
features** than Claude Code Max 20×. The capacity gap comes from the
per-feature cost gap (18.8×), not the plan price gap (2×) — and parallelism
multiplies it further.

### CI compute is the second meter

The figures above count **LLM tokens only**. boucle runs on your forge's CI,
so the runner is metered separately — and the two options bill in opposite
ways:

| Runner | CI cost | Trade-off |
| --- | --- | --- |
| **Shared** (default) | Metered. GitLab.com Free includes 400 compute-minutes/month, then $10 per 1 000; GitHub-hosted is free on public repos, metered on private ones. | Zero infrastructure, but a feature spends 30–60 min of runner wall-clock (LLM latency dominates) — so a free tier sustains roughly **7–13 features/month** before it bills. |
| **Dedicated** (opt-in) | Unmetered — you pay for the machine. | Requires a runner to register and keep alive; a shell executor also caches the toolchain between runs, so the loop is faster. See [Advanced — dedicated runners](#advanced--dedicated-runners). |

So the **token** capacity above (~125 features/month on the default config) is
only reachable end-to-end on an unmetered runner. On a free shared tier, CI
minutes bind first. Pick shared runners to start with nothing to maintain, and
move to a dedicated runner once the loop earns its keep.

## 🛠️ Configuration

Boucle reads its configuration from CI/CD variables (GitLab) or Actions
variables/secrets (GitHub). The only one you **must** set to get started is
`BOUCLE_LLM_API_KEY` (see [After install](#after-install)). The basics below
all have sane defaults — override them only when you need to:

| Variable | Default | What it controls |
| --- | --- | --- |
| `BOUCLE_ENABLED` | `true` | Master switch: `true` (default) or `false` to pause boucle. |
| `BOUCLE_LLM_API_KEY` | *(unset)* | LLM provider key. Set as a **masked** variable. |
| `BOUCLE_LLM_BASE_URL` | `https://ollama.com/v1` | LLM provider endpoint (any OpenAI-compatible API). |
| `BOUCLE_SPEC_PROFILE` | `strict` | Spec gate strictness: `strict` (default — gates all sizes), `product` (gates Size M only), `off` (never gates); unknown → `strict`. |
| `BOUCLE_DND_ENABLED` | `false` | Do-Not-Disturb master switch: `true` (opt-in) or `false` (default). |
| `BOUCLE_DND_START` / `BOUCLE_DND_END` / `BOUCLE_DND_TZ` | `22:00` / `07:00` / `UTC` | Quiet-hours window: HH:MM 24h start/end + IANA timezone (e.g. `Europe/Paris`). |
| `BOUCLE_DEPLOY_MODE` | `self` | Deploy handling: `self` (default — boucle runs `BOUCLE_DEPLOY_CMD`) or `external` (consumer's own CI/CD deploys; `BOUCLE_LIVE_URL` required). |
| `BOUCLE_REVIEW_MODE` | `preview` | Reviewer gate: `preview` (default — tests deployed preview) or `diff` (reviews PR diff + check suites). |
| `BOUCLE_LIVE_URL` | *(unset)* | Canonical e2e target URL — **required** in `external` mode; optional override in `self` mode. |
| `BOUCLE_NOTIFY_URL` | *(unset)* | Send-only webhook (Slack, Discord, ntfy, Telegram) pinged when the loop needs you — spec gate, MR gate, escalation. Silent during DND, fail-open. |

Deploy targets: Cloudflare Pages (default), GitHub Pages, GitLab Pages, or the
consumer's own pipeline (`external` mode). Per-provider
`BOUCLE_DEPLOY_CMD`/`BOUCLE_DEPLOY_URL_REGEX` recipes live in [LOOP.md](LOOP.md).
During install, `bin/setup` seeds the DND timezone (`BOUCLE_DND_TZ`) from the
machine's timezone, plus the fallback model variables (`BOUCLE_FALLBACK_*`) —
all overridable after install in the variables UI.

Variables are edited in GitLab under **Settings → CI/CD → Variables** (see the
[GitLab documentation on CI/CD variables](https://docs.gitlab.com/ci/variables/))
or in GitHub under **Settings → Secrets and variables → Actions** — see
[using variables in GitHub Actions](https://docs.github.com/en/actions/learn-github-actions/variables).

Every other option — `BOUCLE_RUNS_ON`, `BOUCLE_UPDATE_MODE`
(`release`|`dev`), iteration/concurrency caps (`BOUCLE_MAX_ITERATIONS`,
`BOUCLE_MAX_PARALLEL_ISSUES`), models per agent, vision routing, provider
fallback (`BOUCLE_FALLBACK_*`), deploy overrides, staleness, attachment caps —
is documented in [LOOP.md](LOOP.md).

### The bot user

boucle acts through a dedicated **bot account** — it comments on issues,
reassigns them, and merges approved MRs. **`bin/setup` creates it for you as
part of the install**: it is not a separate step.

- **GitLab** — setup provisions a **project service account** via the API
  (a project owner can do this without platform-admin rights, GitLab 16+)
  and requests a Personal Access Token (scope: `api`) for it. It then seeds
  the `BOUCLE_BOT_ID` / `BOUCLE_BOT_USERNAME` / `BOUCLE_TOKEN` CI/CD
  variables, and the loop reassigns issues to it automatically. Re-running
  setup reuses the existing account — it never creates a duplicate.
- **GitHub** — GitHub has no project service accounts: the bot is the account
  that owns the `--bot-token` PAT. setup resolves which account the PAT
  belongs to, seeds `BOUCLE_BOT_USERNAME` with that login (the loop detects
  the bot's own comments by it), and tells you if that account is not yet a
  collaborator of the repository so you can add it.
  Create the PAT at
  [github.com/settings/tokens/new](https://github.com/settings/tokens/new)
  with **`repo` + `workflow`** scopes (optionally `admin:org` for
  branch-protection checks) — see
  [Scopes for OAuth apps](https://docs.github.com/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps).
  An **invalid or expired PAT fails setup** with an explicit message pointing
  here; renew it and re-run `bin/setup` (idempotent).
  **The PAT is required on GitHub, in every mode** — setup refuses to run
  without it. The loop's self-update pushes `.github/workflows/boucle.yml`
  (the workflow must live at the repo root on GitHub Actions), and GitHub
  never lets a workflow token (a GitHub App token) create or update workflow
  files — only a PAT with the `workflow` scope can. An install without the
  PAT silently freezes on the engine version it shipped with.

If the GitLab service-account API is unavailable on your instance (feature
flag off, or the endpoint 403s), setup falls back to the manual flow: create
the bot from your project's **Service accounts** page (GitLab → Project →
Settings → Service accounts, e.g. on framagit:
`https://<your-gitlab-host>/<group>/<project>/-/settings/service_accounts`).
That page lets a project owner provision a bot without platform admin. Then:

1. Create a Personal Access Token for the bot account (scope: `api`) — this
   is the `--bot-token` value.
2. Get its numeric user ID — this is the `--bot-id` value.
3. Re-run `bin/setup --bot-id <id> --bot-token <pat>` (or set the
   `BOUCLE_BOT_ID` / `BOUCLE_BOT_TOKEN` environment variables).

`bin/setup` then adds the bot to the project as a Developer, seeds the
`BOUCLE_BOT_ID` / `BOUCLE_BOT_USERNAME` / `BOUCLE_TOKEN` CI/CD variables, and
the loop reassigns issues to it automatically.

### Running without a bot account (mono-user)

Mono-user is the **default** when no `--bot-id` is given — one account
carries the issues, the MRs, the approvals and boucle's own actions. This is
the common case on GitHub, where nothing provisions a bot account for you.

**Mono-user still needs a token carrying the `workflow` scope on GitHub**
(`--bot-token`, scopes `repo` + `workflow`). Mono-user changes *who* owns the
issues and approvals, not how the loop authenticates its pushes — the token is
the auth credential in both modes. If you omit `--bot-token`, setup adopts the
authenticated `gh` CLI token, provided it already carries the `workflow` scope
(`gh auth login` does **not** grant it by default — run
`gh auth refresh -s workflow` to add it). Without it, self-update cannot push
the workflow file it syncs and the install freezes on its initial engine
version (see [The bot user](#the-bot-user)).

**The cost: notifications degrade.** The forge signals "it's your turn" by
changing an issue's assignee — but the issue is already yours, so nothing is
emitted. And forges do not notify you about your own activity by default.

Enable own-activity notifications once, or you will hear nothing:

| Forge | Setting |
| --- | --- |
| GitHub | Settings → Notifications → **Include your own updates** |
| GitLab | Preferences → Notifications → **Receive notifications about your own activity** |

Both are account-wide, so expect noise. **Prefer a bot or service account
when you can** — see the [bot user](#the-bot-user) section for how to set one
up. Mono-user is the fallback.

### Advanced — dedicated runners

By default boucle needs no runner of its own: every job runs **untagged**, so
the shared runners of GitLab.com, GitHub, or your self-managed instance pick
them up. Install is therefore zero-infrastructure.

Bring your own runner when you want **unmetered compute** (shared runners bill
by the minute — see [Cost](#cost)), a **faster loop** (a shell executor keeps
node, glab and jcode installed between runs), **more memory or a bigger disk**
than the hosted tier gives you, or **network access** to something private.

**GitLab.** Register a runner carrying a tag, then pin boucle to it:

```bash
.boucle/bin/setup --runner-tag boucle    # idempotent — safe to re-run
```

That writes a `default:` override into your root `.gitlab-ci.yml`:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/ankaboot-source/boucle/<ref>/.gitlab-ci.yml'

default:
  tags: [boucle]

variables:
  BOUCLE_FORGE_HOST: "gitlab.example.com"
```

GitLab merges included configuration key-by-key, so this changes **routing
only** — the engine's `image:` and `before_script:` are preserved. To go back
to shared runners, delete the `default:` block.

The loop-critical control-plane jobs (`dispatch`, `merger`, `post-merge`,
`catchup`, `doctor`, `check`) keep an explicit `tags: []` and stay on any
available runner, on purpose: an approved MR must never sit in a queue behind
a long-running worker on your single dedicated runner.

**GitHub.** Set the `BOUCLE_RUNS_ON` repository variable (Settings → Secrets
and variables → Actions). It defaults to `ubuntu-latest`; for a self-hosted
runner use a JSON array of labels:

```
BOUCLE_RUNS_ON = ["self-hosted", "linux", "x64"]
```

**Either forge.** Agent jobs run on the pre-baked
`docker.io/ankabootops/boucle-agents` image (node 22, glab, jcode,
codebase-memory-mcp), so docker executors skip the toolchain download. Shell
executors ignore `image:` and fall back to a `before_script` that installs
only what is missing — both executor types work unchanged.

## 🗺️ Roadmap

- [ ] **servo rendering** — migrate preview rendering from Puppeteer to
      [servo](https://github.com/servo/servo) (Rust-native, no Chromium)
- [ ] **cost estimate** — per-issue token-cost estimate and tracking

## ⚖️ License

boucle is free and open-source software licensed under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).

## 📚 Docs

- [AGENTS.md](AGENTS.md) — agent guide, lessons learned, anti-patterns
- [CONTEXT.md](CONTEXT.md) — project context, tech stack, constraints
- [LOOP.md](LOOP.md) — per-consumer configuration
