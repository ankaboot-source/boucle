# boucle loop template

Portable dev-loop template. Apply to a target repo by copying these files to the repo root:

```bash
cp -r boucle/loop/bin <target-repo>/
cp boucle/loop/.gitlab-ci.yml <target-repo>/
cp boucle/loop/LOOP.md <target-repo>/
```

Then run `bin/doctor` in CI to verify all prerequisites are met.

## Role mapping (oh-my-opencode-slim)

`bin/oc` maps boucle roles to existing oh-my-opencode-slim agents — no agent .md files needed:

| boucle role | oh-my-opencode-slim agent |
|-------------|---------------------------|
| `triage`    | `explorer` (cheap, codebase-aware) |
| `worker`    | `fixer` (mechanical implementation) |
| `reviewer`  | `oracle` (adversarial review) |
| `e2e`       | `observer` (visual verification) |

Role-specific task instructions are passed as the prompt to `opencode run` by `bin/oc`.

See issue #1 (boucle MVP spec) for the full design.
