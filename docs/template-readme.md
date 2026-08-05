# boucle template

Portable dev-loop template. Apply to a target repo by copying these files from the boucle repo root to the target repo root:

```bash
cp -r bin <target-repo>/
cp -r .opencode <target-repo>/
cp .gitlab-ci.yml <target-repo>/
cp LOOP.md <target-repo>/
```

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Roles

Four opencode agents in `.opencode/agents/`:

| Agent | Model | Purpose |
|-------|-------|---------|
| `triage` | ollama-cloud/glm-5.2 | Analyzes issues, drafts acceptance criteria |
| `worker` | ollama-cloud/glm-5.2 | Implements on a branch |
| `reviewer` | ollama-cloud/glm-5.2 | Adversarial review against deployed preview |
| `e2e` | ollama-cloud/deepseek-v4-flash | Verifies on live production URL |

Role-specific behavior lives in each agent's `.md` file (system prompt). `bin/oc` passes only issue-specific context (issue number, target URL) as the user prompt.

See issue #1 (boucle MVP spec) for the full design.
