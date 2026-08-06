# boucle template

Portable dev-loop template. Apply to a target repo by copying these files to the repo root:

```bash
cp -r boucle/boucle/bin <target-repo>/
cp -r boucle/boucle/.jcode <target-repo>/
cp boucle/boucle/.gitlab-ci.yml <target-repo>/
cp boucle/boucle/LOOP.md <target-repo>/
```

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Roles

Four jcode agents in `.jcode/agents/`:

| Agent | Model | Purpose |
|-------|-------|---------|
| `triage` | ollama-cloud/glm-5.2 | Analyzes issues, drafts acceptance criteria |
| `worker` | ollama-cloud/deepseek-v4-flash | Implements on a branch |
| `reviewer` | ollama-cloud/glm-5.2 | Adversarial review against deployed preview |
| `e2e` | ollama-cloud/deepseek-v4-flash | Verifies on live production URL |

Role-specific behavior lives in each agent's `.md` file (system prompt). `bin/oc` passes only issue-specific context (issue number, target URL) as the user prompt.

See issue #1 (boucle MVP spec) for the full design.

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

1. `bin/update` reads `.boucle-version` (current version) and compares with upstream via the GitHub API.
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
| `LOOP.md` | No | Per-consumer config |
| `.boucle-version` | No | Managed by `bin/update` |

### Version tracking

`.boucle-version` at the repo root records the current version (tag name in release mode, commit SHA in dev mode). It is created automatically on first run — no manual setup needed.
