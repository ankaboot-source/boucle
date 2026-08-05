#!/usr/bin/env bash
# boucle POC — looper agent health check (layer 2)
# Runs every 15 min via cron. Spawns an opencode headless session that
# detects novel edge cases the bash script can't catch:
# - never-ending fixer↔reviewer cycles (same PR >3 rounds)
# - zombie processes (running but no CPU/log for 10+ min)
# - semantic issues (PR with 0 changes, review with 0 comments)
# - any new failure mode
# Documents lessons to docs/poc-looper-drawbacks.md.
# Can stop stuck loops and file bugs on nexu-io/looper.

set -euo pipefail

POC_DIR="$HOME/Projects/ankaboot-source/boucle"
LOG="$HOME/.looper/logs/agent-health-check.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$LOG")"

PROMPT='You are the boucle POC health-check agent. Your job: detect anomalies in the looper dev-loop orchestrator that the bash health-check script (scripts/looper-health-check.sh) cannot catch, and document them as POC lessons.

## Context
- looper is an autonomous dev-loop orchestrator running as a daemon (looperd)
- It runs loops: planner (issue→spec PR), reviewer (review PR), worker (spec→impl PR), fixer (address review comments)
- Known bugs already handled by the bash script: #595 (EBADF), #598 (worker PR review gap), #599 (marker mismatch), #600 (outbound guard false positive)
- Config: ~/.looper/config.toml, DB: ~/.looper/looper.sqlite, logs: ~/.looper/logs/
- Daemon runs as bot (ankaboot-bot) via ~/.looper/start-looperd-as-bot.sh

## Your tasks (do ALL of these every run)

### 1. Gather state
Run these commands and analyze the output:
- `/tmp/looper-dev/looper loop list --json` — all loops and their status
- `sqlite3 ~/.looper/looper.sqlite "SELECT seq, type, status, repo, pr_number, attempts, last_run_at FROM loops WHERE status IN ('"'"'running'"'"','"'"'backing_off'"'"','"'"'paused'"'"','"'"'queued'"'"') ORDER BY seq;"` — active/stuck loops
- `sqlite3 ~/.looper/looper.sqlite "SELECT l.seq, l.type, l.pr_number, l.repo, COUNT(*) as rounds FROM loops l WHERE l.type IN ('"'"'fixer'"'"','"'"'reviewer'"'"') AND l.pr_number IS NOT NULL GROUP BY l.pr_number, l.type HAVING rounds > 3;"` — potential never-ending cycles
- `pgrep -af opencode` — running agent processes (check for zombies: running but no CPU)
- `tail -50 ~/.looper/logs/looperd.log` — recent daemon log (look for errors, panics, stuck ticks)
- `tail -30 ~/.looper/logs/health-check.log` — what the bash script already handled

### 2. Detect anomalies
Look for these patterns the bash script CANNOT catch:
- **Never-ending cycles:** same PR has >3 fixer OR >3 reviewer loops (ping-pong: fixer fixes → reviewer finds new issue → fixer fixes again)
- **Zombie processes:** loop status "running" but the opencode child process has 0% CPU for 10+ min (stuck on infinite reasoning)
- **Semantic garbage:** worker PR with 0 file changes, review with 0 inline comments, fixer that "fixed" something but the diff is empty
- **Novel errors:** any error in daemon log not matching known bugs (#595/#598/#599/#600)
- **Stuck planner:** planner running >30 min (should take <1h but if stuck at 45min with no spec PR, likely stuck)

### 3. Take action (quick-win fixes)
- If a never-ending cycle is detected: stop the loop with `/tmp/looper-dev/looper stop <seq>`, document why
- If a zombie process is detected: kill the opencode child PID, mark the loop as stopped in DB
- If a novel error looks like a new bug: check if it is already filed at https://github.com/nexu-io/looper/issues, if not, file a minimalist bug report using `gh issue create --repo nexu-io/looper`

### 4. Document lessons
Append findings to docs/poc-looper-drawbacks.md in this format:
```
## <timestamp> — <short description>
- **Symptom:** <what you observed>
- **Quick-win:** <what you did to fix it>
- **Root cause:** <why it happened, or "unknown — needs investigation">
- **Bug filed:** <link if filed, or "none">
```

### 5. Report
Print a concise summary at the end:
- How many loops are healthy vs stuck
- What anomalies you found and fixed
- What new lessons you documented
- What (if anything) needs human attention

## Constraints
- Do NOT modify looper source code
- Do NOT merge any PRs
- Do NOT change ~/.looper/config.toml (the bash script handles config)
- Be minimalist — only act on clear anomalies, do not over-engineer
- If unsure whether something is a bug, document it but do not file an issue'

echo "[$TS] agent health check starting..." >> "$LOG"

# Run the agent headless with auto-approve (needs shell/sqlite3/gh access)
OPENCODE_PERMISSION='{"bash":"allow","edit":"allow","write":"allow","read":"allow","glob":"allow","grep":"allow","list":"allow","external_directory":"allow","task":"allow","skill":"allow","todowrite":"allow","question":"allow","webfetch":"allow","websearch":"allow","lsp":"allow","doom_loop":"allow"}' \
  opencode run --auto --dir "$POC_DIR" --format json --title "looper-health-check-$TS" "$PROMPT" >> "$LOG" 2>&1 || true

echo "[$TS] agent health check done" >> "$LOG"
