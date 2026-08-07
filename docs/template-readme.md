# boucle template

Portable dev-loop engine. Install it in any GitLab repo without polluting
the repo root and without touching existing pipelines:

```bash
git submodule add https://github.com/ankaboot-source/boucle .boucle
cd .boucle && bin/setup --project <your-project-id-or-path>
```

`bin/setup` configures GitLab (CI variables, labels, board, branch
protection, webhook), writes a thin `.gitlab-ci.yml` shim that includes the
engine pipeline, and appends `.boucle/` to your `.gitignore`. An
existing non-boucle `.gitlab-ci.yml` is never overwritten.

The consumer repo root only ever contains: `.boucle/` (engine submodule)
and `.gitlab-ci.yml` (shim). Per-issue state lives in `.boucle/<issue>/`
(gitignored) inside the submodule.

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Roles

Four jcode agents in `.boucle/.jcode/agents/`:

| Agent | Model (default) | Purpose |
|-------|-----------------|---------|
| `triage` | ollama-cloud/minimax-m3 | Analyzes issues, drafts acceptance criteria |
| `worker` | ollama-cloud/deepseek-v4-flash:0731 | Implements on a branch |
| `reviewer` | ollama-cloud/glm-5.2 | Adversarial review against deployed preview |
| `e2e` | ollama-cloud/kimi-k2.7-code | Verifies on live production URL |

Models are BYOK: override per role with `BOUCLE_MODEL_<ROLE>` CI variables,
or switch provider with `BOUCLE_LLM_BASE_URL` + `BOUCLE_LLM_API_KEY`.

Role-specific behavior lives in each agent's `.md` file (system prompt).
`bin/jc` passes only issue-specific context (issue number, target URL) as
the user prompt.

See issue #1 (boucle MVP spec) and issue #7 (install design) for details.
