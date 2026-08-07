# boucle

A portable dev-loop engine for GitLab: issues in, reviewed merge requests out.
Four jcode agents (triage, worker, reviewer, e2e) run as GitLab CI stages,
driven entirely by issue labels and comments — no humans required in the loop.

This repo is both the **engine** (everything under `bin/`, `lib/`, `.jcode/`,
`.gitlab-ci.yml`) and its own **dogfood** site (an Astro app deployed to
GitLab Pages via the same pipeline).

## How it works

- **Engine as a submodule** — consumers install boucle with one command. The
  engine lives at `.boucle/` in the consumer repo; nothing is copied into the
  repo root.
- **Thin CI shim** — the consumer's `.gitlab-ci.yml` is a ~10 line file that
  `include: remote`s the engine pipeline and overrides the runner tag and
  forge host. Existing consumer pipelines are never overwritten: `bin/setup`
  prints the include block to merge manually instead.
- **Per-issue state** — `.boucle-state/` (gitignored) holds per-issue work
  state, attachments, previews. It stays out of the engine submodule so
  `git submodule update` can never clobber in-flight work.
- **BYOK** — each consumer brings their own LLM credentials. Two CI/CD
  variables are enough: `BOUCLE_LLM_BASE_URL` (any OpenAI-compatible
  endpoint, default `https://ollama.com/v1`) and `BOUCLE_LLM_API_KEY`
  (masked). Models per role come from `.jcode/agents/*.md` frontmatter and
  can be overridden with `BOUCLE_MODEL_<ROLE>` variables.

## Requirements

- A GitLab project (self-hosted or gitlab.com).
- A GitLab runner available for the project (any tag; default tag is `data`).
- An OpenAI-compatible LLM endpoint + API key (BYOK).

## Installation

There are two paths. Pick whichever fits your setup.

### Path A — from a terminal (advanced)

```bash
git submodule add https://github.com/ankaboot-source/boucle .boucle
cd .boucle && bin/setup --project <your-project-id-or-path>
```

`bin/setup` is interactive: it asks for the bot token, Cloudflare token
(optional), and the LLM API key (masked input), then configures everything
on the GitLab side: CI variables, labels, board, branch protection, bot
member, trigger token, webhook, and writes the `.gitlab-ci.yml` shim + the
`.boucle-state/` entry in your `.gitignore`.

Everything can also be provided as environment variables for scripting:

```bash
BOUCLE_PROJECT=123456 BOUCLE_HOST=gitlab.example.com BOUCLE_RUNNER_TAG=data \
BOUCLE_LLM_API_KEY=sk-... .boucle/bin/setup --non-interactive
```

Then commit and push:

```bash
git add .gitmodules .boucle .gitlab-ci.yml
git commit -m "chore: install boucle engine"
git push
```

### Path B — copy/paste prompt (Claude Code, Cursor, …)

No terminal needed. Ask your coding agent to run the install for you by
pasting this prompt (fill the two placeholders first):

> Install boucle on this repository. Execute these steps and report back
> what you did:
>
> 1. `git submodule add https://github.com/ankaboot-source/boucle .boucle`
> 2. Run setup in non-interactive mode:
>    `BOUCLE_PROJECT=<your-project-id-or-path> BOUCLE_HOST=<your-gitlab-host> .boucle/bin/setup --non-interactive`
> 3. Do NOT include an API key anywhere. The API key must never appear in
>    this conversation. If setup tells you the key is missing, that's
>    expected — it is configured manually in the GitLab UI afterwards.
> 4. `git add .gitmodules .boucle .gitlab-ci.yml && git commit -m "chore: install boucle engine"`
> 5. Show me the URL `bin/setup` printed for configuring the masked API key,
>    and any next steps it listed.

**Why the key is added manually:** `bin/setup --non-interactive` configures
everything except `BOUCLE_LLM_API_KEY`. It prints the project's CI/CD
variables URL — open it, add the key as a **masked** variable, and you're
done. The key never crosses the agent conversation, logs, or shell history.

## After install

1. Add `BOUCLE_LLM_API_KEY` as a masked CI/CD variable (project → Settings →
   CI/CD → Variables), if setup didn't do it interactively.
2. Ensure a runner with the tag baked into `.gitlab-ci.yml` (default `data`)
   is available for the project.
3. Create your first issue. The webhook triggers triage automatically.
4. `bin/doctor` (run in CI) verifies all prerequisites.

## Updating

```bash
git submodule update --remote .boucle
git commit -am "chore: bump boucle engine"
```

The engine repo has no self-update mechanism; consumers pull updates through
the submodule.

## Uninstalling

```bash
git submodule deinit -f .boucle && git rm -f .boucle
git rm -f .gitlab-ci.yml
```

(Remove the `.boucle-state/` entry from `.gitignore` if you want.)

## Roles

Four jcode agents in `.jcode/agents/` (system prompts, BYOK models):

| Agent | Model (default) | Purpose |
|-------|-----------------|---------|
| `triage` | minimax-m3 | Analyzes issues, drafts acceptance criteria |
| `worker` | deepseek-v4-flash | Implements on a branch |
| `reviewer` | glm-5.2 | Adversarial review against deployed preview |
| `e2e` | kimi-k2.7-code | Verifies on live production URL |

## Docs

- `LOOP.md` — the loop contract (what agents must never do)
- `AGENTS.md` — guidance for agents working in this repo
- `.jcode/UPSTREAM-FIX-WORKFLOW.md` — bug resolution policy for consumers
- `docs/template-readme.md` — short install blurb for consumer repos
- Issue #1 — boucle MVP spec; Issue #7 — install design (submodule, no root
  pollution, BYOK at install time)
