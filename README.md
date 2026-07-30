# boucle

A label-driven autonomous dev loop on GitLab CI. boucle takes an issue from triage to deployed-and-verified, with **human merge as the only gate**.

An issue tagged for boucle flows through a state machine — triage → worker → reviewer → deploy → e2e — driven by GitLab labels and chained via trigger tokens. Each step is an opencode agent run headless inside a CI job; the job (shell + `glab`) manages state, the agent produces content. No daemon, no server — just a pipeline and a webhook.

```
issue opened ──▶ dispatch ──▶ triage ──▶ worker ──▶ reviewer ──▶ (human merge) ──▶ deploy ──▶ e2e ──▶ done
                   │            │          │           │                            │
                   │            │          │           └─ FAIL ──▶ worker (retry, ≤3) │
                   │            │          └─ NEEDS-INFO ──▶ pause (author replies)  │
                   │            └─ NEEDS-SPLIT ──▶ sub-issues auto-created            │
                   └─ bot events ignored                                                  └─ FAIL ──▶ new triage issue (loop closes)
```

## Why

The loop shape works — label-driven state machine, worktree isolation, harness-agnostic agents, HITL via MR comments, genuine deep review. boucle is the self-hostable, GitLab-native, verification-gated version of that pattern: merge is gated on **verified behavior in production**, not reviewed diff. See [`docs/poc-looper-status.md`](./docs/poc-looper-status.md) for the POC that proved the shape and exposed the verification gap boucle closes.

## How it works

### The state machine

Eight labels drive the loop, each a column on the boucle issue board:

| Label | Meaning | Next |
|-------|---------|------|
| `boucle:triage` | awaiting analysis | → `todo` / `needs-info` / `needs-split` / `human` |
| `boucle:needs-info` | paused, author must answer blocking questions | → `triage` (on author reply) |
| `boucle:todo` | ready to implement | → `working` |
| `boucle:working` | worker is implementing | → `review` |
| `boucle:review` | reviewer is testing the deployed preview | → `human` (PASS) / `todo` (FAIL, retry) / `blocked` (cap hit) |
| `boucle:human` | awaiting human merge | → `done` (on merge) |
| `boucle:blocked` | iteration cap hit or unparsable | human picks up |
| `boucle:done` | merged and e2e-verified | terminal |

Plus `size:s` / `size:m` / `size:l` for complexity routing.

### The four agents

Each role is an opencode agent in [`.opencode/agents/`](./.opencode/agents/). The agent's system prompt provides role behavior; `bin/oc` passes only issue-specific context (issue number, preview/live URL) as the user prompt.

| Agent | Model | Purpose |
|-------|-------|---------|
| [`triage`](./.opencode/agents/triage.md) | ollama-cloud/minimax-m3 | Analyzes the issue, drafts verifiable acceptance criteria, classifies size, deduces sub-issues |
| [`worker`](./.opencode/agents/worker.md) | ollama-cloud/minimax-m3 | Implements on a branch, updates `state.md` |
| [`reviewer`](./.opencode/agents/reviewer.md) | ollama-cloud/glm-5.2 | Adversarial review against the **deployed preview URL** (not a local build) |
| [`e2e`](./.opencode/agents/e2e.md) | ollama-cloud/kimi-k2.7-code | Verifies acceptance criteria on the **live production URL** after merge |

### The pipeline

[`.gitlab-ci.yml`](./.gitlab-ci.yml) defines six jobs across six stages:

1. **dispatch** — parses the webhook payload, routes new/reopened/edited issues to triage or worker
2. **triage** — runs the triage agent, parses disposition, routes to `todo` / `needs-info` / `needs-split` (auto-creates sub-issues)
3. **worker** — runs the worker agent on a branch, builds, deploys a preview, opens an MR, chains to reviewer
4. **reviewer** — runs the reviewer agent against the preview URL, routes PASS→human / FAIL→worker (retry, ≤3) / UNCERTAIN→human
5. **deploy** — on merge to master, builds and deploys to production, chains to e2e
6. **e2e** — runs the e2e agent against the live URL, routes PASS→done / FAIL→new triage issue (loop closes)

Jobs chain to the next role via the project's pipeline trigger token — no daemon, no scheduler.

### The harness entrypoint

[`bin/oc`](./bin/oc) is the single seam between the pipeline and the agent harness. It wraps `opencode run`:

- scrubs deploy secrets (`CLOUDFLARE_API_TOKEN`) before invoking the agent
- isolates the opencode DB per job
- maps boucle roles → project-local agents
- builds the issue-specific user prompt
- appends to `iterations.md` after each run

Swapping to Claude Code or Codex = editing this one file.

## Repo structure

```
boucle/
├── .gitlab-ci.yml              # dispatcher + 6 jobs (the state machine)
├── .opencode/
│   ├── agents/                 # triage, worker, reviewer, e2e (system prompts)
│   └── skill/                  # skills the agents can load (astro, frontend-design, …)
├── bin/
│   ├── oc                      # harness entrypoint — wraps opencode run
│   ├── setup                   # Day 0 infrastructure setup (idempotent, via glab API)
│   └── doctor                  # Day 0 verification (~20 checks)
├── LOOP.md                     # repo-level loop config (cadence, caps, escalation rules)
├── README.md                   # this file
└── docs/                        # POC research and results (see below)
```

## Apply boucle to a target repo

boucle is a portable template. To apply it to a GitLab repo:

```bash
# from the boucle repo root
cp -r bin <target-repo>/
cp -r .opencode <target-repo>/
cp .gitlab-ci.yml <target-repo>/
cp LOOP.md <target-repo>/
```

Then run Day 0 setup (creates labels, CI variables, board, branch protection, trigger token, webhook, Cloudflare Pages project):

```bash
cd <target-repo>
./bin/setup --project <id-or-path> --host <forge-host> \
  --bot-id <id> --bot-token <pat> --cf-token <token>
```

And verify everything is in place:

```bash
./bin/doctor   # run in CI, not locally (needs CI variables in env)
```

See [`docs/template-readme.md`](./docs/template-readme.md) for the template apply steps.

## Configuration

[`LOOP.md`](./LOOP.md) holds the per-repo loop config: cadence (webhook), human gates (MR approval only), iteration cap (3 worker runs), escalation rules, and out-of-bounds constraints.

Pipeline-level config lives in the `variables:` block of [`.gitlab-ci.yml`](./.gitlab-ci.yml):

- `BOUCLE_FORGE_HOST` — GitLab host (default: `framagit.org`)
- `BOUCLE_BUILD_CMD` — build command (default: `npm ci && npm run build`)
- `BOUCLE_DEPLOY_CMD` — deploy command (swap to Netlify / Vercel / GitLab Pages)
- `BOUCLE_DEPLOY_PROJECT` — Cloudflare Pages project name
- `BOUCLE_DEPLOY_URL_REGEX` — extracts the deployed URL from deploy stdout
- `BOUCLE_PRODUCTION_URL` — live URL for e2e fallback

## Constraints (by design)

- **Harness-agnostic** — start with opencode, extensible via `bin/oc`
- **Forge-agnostic** — GitLab via `glab` (GitHub adapter is a future seam)
- **Models configurable** — per-agent in `.opencode/agents/*.md` frontmatter
- **Human merge is the only gate** — boucle never merges; the reviewer routes PASS→`boucle:human` and a human clicks merge
- **Verified behavior, not reviewed diff** — the reviewer tests the deployed preview; e2e tests the live URL. `UNVERIFIABLE` does not block merge, but FAIL does.

## POC research

The `docs/` directory holds the research and POC results that led to boucle:

- [`docs/poc-charter.md`](./docs/poc-charter.md) — POC charter: goal, methodology, decision framework
- [`docs/poc-looper-status.md`](./docs/poc-looper-status.md) — looper POC state: runs, config, bugs, findings, decision (Option B)
- [`docs/poc-looper-drawbacks.md`](./docs/poc-looper-drawbacks.md) — looper drawbacks analysis
- [`docs/poc-autonomous-dev-team-status.md`](./docs/poc-autonomous-dev-team-status.md) — autonomous-dev-team POC state
- [`docs/superpowers/plans/`](./docs/superpowers/plans/) — implementation plans (historical)
- [`docs/scripts/`](./docs/scripts/) — looper health-check scripts (POC artifacts)

## License

MIT