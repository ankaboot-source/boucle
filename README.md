# ➰ boucle — zero-code autonomous product builder

> From a ticket in your forge to a feature in production — without running
> agents on your own machine. No laptop left half-open overnight. No Mac
> Mini purchase required.

boucle is zero-code **loop engineering**: you express a need in an issue,
and boucle handles the rest — analysis, implementation, review, merge,
deploy, verification. You stay in the forge you already use every day; you
never touch the engine itself.

## ✨ Why boucle?

**End to end, from idea to shipped.** A ticket becomes a feature deployed to
production — and you can **amend at any moment**: comment on the issue and
the loop picks your feedback up, re-plans, and adjusts. You validate the
result with **screenshots** of the live preview, not prose.

**Fast and cheap — BYOK.** Lightweight, purpose-built agents run on your
forge's existing CI, with your own LLM credentials. No Mac Mini, no VPS, no
always-on laptop.

**No new interface.** No web app, no TUI. Your forge stays the interface:
create an issue, label it, approve the spec and the MR — everything happens
where you already work.

**Ready to use, not a framework.** boucle ships as a working product, not a
loop-engineering framework you assemble. One command installs it; the
`doctor` job verifies every prerequisite; then it just runs.

**Built on fast, modern tools.** jcode, a standalone **Rust** binary (fast
startup, zero runtime dependencies), plus a **codebase knowledge graph**
that gives agents real structural understanding of your repository instead
of blind grep.

**Not a SaaS. No server.** The whole loop runs on your forge's CI
pipelines. Your code, your data, your tokens stay yours.

**By a product builder, for product builders.** Built by an indie Product
Builder who got tired of babysitting agents overnight.

### 🩹 What most loop tools get wrong

Boucle was designed against the common irritants, observed first-hand in a
seven-run POC of a representative loop tool (see
[docs/poc-looper-status.md](docs/poc-looper-status.md)):

- **A daemon to babysit.** Local daemons die silently, need restarts, and
  pollute your disk with worktrees and sessions. → boucle runs on your
  forge's CI: nothing to install, nothing to restart.
- **Deadlocks.** Single-identity loops stall because a bot can't review,
  approve, or merge its own PRs. → boucle's label-driven state machine has
  no self-approval path.
- **Reviews that ship broken code.** Diff-scoped review passes while
  deployment-dependent bugs reach production. → boucle verifies *behavior*:
  a preview URL, screenshots, and a post-deploy e2e gate anchored to the
  commit SHA.
- **Frozen specs.** Human comments after review never reach the worker. →
  boucle feeds every human note back into the loop — amend at any moment.
- **No budget control.** Token spend with no cap or visibility. → boucle
  ships step and iteration caps per role, and a concurrency cap on parallel
  issues.

## 🚀 Quick start

**Prerequisites:** a GitLab repository with Cloudflare Pages configured as the
deployment target, and a GitLab Personal Access Token for the bot.

Pick whichever path fits you.

### Option 1 — copy/paste prompt (easiest)

No terminal needed. Ask your coding agent (Claude Code, Cursor, …) to install
boucle by pasting this prompt. **Nothing to replace**: the agent detects your
GitLab host and project from the git remote, and it works even if you are not
already inside the target repository.

```text
Install boucle on this GitLab repository. Execute these steps and report
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

### Option 2 — command line

```bash
# 1. Add boucle as a submodule in your repo
git submodule add https://github.com/ankaboot-source/boucle .boucle

# 2. Configure everything (idempotent — safe to re-run)
.boucle/bin/setup --non-interactive
```

`bin/setup` configures GitLab (CI variables, labels, board, branch
protection, webhook), writes a thin `.gitlab-ci.yml` shim, and appends
`.boucle/` to your `.gitignore`. Your existing pipeline is never overwritten.
Project and host are read from the `origin` remote automatically — the only
values you may need to pass explicitly are the bot and Cloudflare tokens
(`--bot-token`, `--cf-token`), which otherwise come from the `BOUCLE_*`
environment variables.

### After install

1. Add `BOUCLE_LLM_API_KEY` as a **masked** CI/CD variable (project →
   Settings → CI/CD → Variables). It is never handled by setup so it never
   crosses a conversation, a log, or a shell history.
2. Make sure a runner with the tag from `.gitlab-ci.yml` (default `data`) is
   available for the project.
3. Create a GitLab issue with the `boucle:triage` label — or assign an
   existing issue to the boucle bot.
4. Run the `doctor` CI job: it checks every prerequisite and must print
   "OK" everywhere.

From there, the pipeline takes over. You only answer the human prompts:
spec validation and MR approval.

## ⚙️ How it works

```
issue in GitLab
      │  (create it, or assign one to the boucle bot)
      ▼
   triage          analyses the issue, posts a spec, asks for your approval
      │  (you validate the spec)
      ▼
   worker          implements on a branch and deploys a preview
      │
      ▼
   reviewer        adversarial review against the preview
      │
      ▼
   merge + deploy  (you approve the MR, then it merges)
      │
      ▼
   e2e             verifies the production URL
      │
      ▼
issue closed
```

Four specialized agents — **triage**, **worker**, **reviewer**, **e2e** —
orchestrate the whole flow. Humans only do what only humans can: validate the
spec and approve the MR.

## 🛠️ Configuration

Boucle reads its configuration from GitLab CI/CD variables. The only one you
**must** set to get started is `BOUCLE_LLM_API_KEY` (see
[After install](#after-install)). The basics below all have sane defaults —
override them only when you need to:

| Variable | Default | What it controls |
| --- | --- | --- |
| `BOUCLE_ENABLED` | `true` | Master switch. Set to `false` to pause boucle without touching the pipeline. |
| `BOUCLE_LLM_API_KEY` | *(unset)* | LLM provider key. Set as a **masked** variable. |
| `BOUCLE_LLM_BASE_URL` | `https://ollama.com/v1` | LLM provider endpoint (any OpenAI-compatible API). |
| `BOUCLE_RUNNER_TAG` | `data` | Runner tag that executes agent jobs. |
| `BOUCLE_SPEC_PROFILE` | `product` | Spec gate strictness: which issues require your spec approval. |
| `BOUCLE_DND_ENABLED` | `true` | Auto-validates the spec gate during quiet hours (Do-Not-Disturb). |
| `BOUCLE_DND_START` / `BOUCLE_DND_END` / `BOUCLE_DND_TZ` | `22:00` / `07:00` / `UTC` | Quiet-hours window for the spec gate. |
| `BOUCLE_UPDATE_MODE` | `release` | How boucle updates itself (release = pinned engine version). |
| `BOUCLE_MAX_PARALLEL_ISSUES` | `5` | Max issues worked on in parallel (`0` = unlimited). |
| `BOUCLE_MAX_ITERATIONS` | `3` | Max worker re-runs per issue before escalation. |

Variables are edited in GitLab under **Settings → CI/CD → Variables** — see
the [GitLab documentation on CI/CD variables](https://docs.gitlab.com/ci/variables/)
for how to add, mask, or protect them.

Every other option — models per agent, vision routing, provider fallback,
deploy overrides — is documented in [LOOP.md](LOOP.md).

## 🗺️ Roadmap

- [ ] **GitHub support** — run boucle on GitHub issues and Actions
- [ ] **servo rendering** — migrate preview rendering from Puppeteer to
      [servo](https://github.com/servo/servo) (Rust-native, no Chromium)

## ⚖️ License

boucle is free and open-source software licensed under the
[GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html).

## 📚 Docs

- [AGENTS.md](AGENTS.md) — agent guide, lessons learned, anti-patterns
- [CONTEXT.md](CONTEXT.md) — project context, tech stack, constraints
- [LOOP.md](LOOP.md) — per-consumer configuration
