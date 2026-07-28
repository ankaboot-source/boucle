# boucle template

Portable dev-loop template. Apply to a target repo by copying these files to the repo root:

```bash
cp -r boucle/boucle/bin <target-repo>/
cp -r boucle/boucle/.opencode <target-repo>/
cp boucle/boucle/.gitlab-ci.yml <target-repo>/
cp boucle/boucle/LOOP.md <target-repo>/
```

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Roles

Four opencode agents in `.opencode/agents/`:

| Agent | Model | Purpose |
|-------|-------|---------|
| `triage` | ollama-cloud/minimax-m3 | Analyzes issues, drafts acceptance criteria |
| `worker` | ollama-cloud/minimax-m3 | Implements on a branch |
| `reviewer` | ollama-cloud/glm-5.2 | Adversarial review against deployed preview |
| `e2e` | ollama-cloud/kimi-k2.7-code | Verifies on live production URL |

Role-specific behavior lives in each agent's `.md` file (system prompt). `bin/oc` passes only issue-specific context (issue number, target URL) as the user prompt.

See issue #1 (boucle MVP spec) for the full design.
