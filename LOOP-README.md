# boucle template

Portable dev-loop engine. Install it in any GitLab repo without polluting
the repo root and without touching existing pipelines:

```bash
git submodule add https://github.com/ankaboot-source/boucle .boucle
cd .boucle && bin/setup --project <your-project-id-or-path>
```

Alternative (vendored install, when submodules are not an option):

```bash
cp -r boucle/boucle/bin <target-repo>/
cp -r boucle/boucle/.jcode <target-repo>/
cp boucle/boucle/.gitlab-ci.yml <target-repo>/
cp boucle/boucle/LOOP.md <target-repo>/
```

`bin/setup` configures GitLab (CI variables, labels, board, branch
protection, webhook), writes a thin `.gitlab-ci.yml` shim that includes the
engine pipeline, and appends `.boucle/` to your `.gitignore`. An existing
non-boucle `.gitlab-ci.yml` is never overwritten.

The consumer repo root only ever contains: `.boucle/` (engine submodule),
`.gitlab-ci.yml` (shim), and `.boucle/<issue>/` (gitignored per-issue state).

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Roles

Four jcode agents in `.boucle/.jcode/agents/`:

| Agent | Model (default) | Purpose |
|-------|-----------------|---------|
| `triage` | ollama-cloud/glm-5.2 | Analyzes issues, drafts acceptance criteria |
| `worker` | ollama-cloud/deepseek-v4-flash:0731 | Implements on a branch |
| `reviewer` | ollama-cloud/deepseek-v4-flash:0731 | Adversarial review against deployed preview |
| `e2e` | ollama-cloud/glm-5.2 | Verifies on live production URL |

Models are BYOK: override per role with `BOUCLE_MODEL_<ROLE>` CI variables,
or switch provider with `BOUCLE_LLM_BASE_URL` + `BOUCLE_LLM_API_KEY`.

Role-specific behavior lives in each agent's `.md` file (system prompt).
`bin/jc` passes only issue-specific context (issue number, target URL) as
the user prompt.

## Self-update

boucle updates itself automatically at the start of each pipeline. The self-update runs as the first step of the `dispatch` job, before any webhook processing.

### Update modes

Controlled by the `BOUCLE_UPDATE_MODE` CI/CD variable (GitLab → Settings → CI/CD → Variables):

| Mode | Behavior |
|------|----------|
| `release` (default) | Fetch the latest Git tag from `github.com/ankaboot-source/boucle` |
| `dev` | Fetch the latest commit on `main` from upstream |

If the variable is unset, `release` is used.

### How it works

1. `bin/update` reads the current version from the `BOUCLE_VERSION` forge Variable (falling back to the submodule pointer for submodule installs) and compares with upstream via the GitHub API.
2. If different, it downloads a tarball, extracts `bin/`, `.jcode/`, `.gitlab-ci.yml`, and commits the update to `main` via the bot.
3. The update takes effect on the **next** pipeline (not the current one — pipelines don't change their own config mid-run).

### Fail-open

Any error (network failure, permissions, corrupt tarball) logs a warning and continues. The pipeline runs with the current version. The update is retried on the next pipeline.

### Files synced

| Path | Synced | Why |
|------|--------|-----|
| `bin/` | Yes | boucle code |
| `.jcode/` | Yes | boucle agents + skills |
| `.gitlab-ci.yml` | Yes | boucle pipeline |
| `LOOP.md` | Yes | Product reference (config, modes, gates, caps) |

### Version tracking

The current engine version is tracked as the `BOUCLE_VERSION` forge Variable
(GitHub Actions Variable / GitLab CI/CD Variable), which persists across CI
runs. `bin/update` reads it to know the current version and writes it back
after a successful sync. For submodule installs, the submodule pointer
(`git submodule status .boucle`) is the fallback — it is always accurate.
There is no `.boucle-version` file; boucle only runs in forge CI, so the
forge Variable is always available when it matters.
