#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2250
# lib/boucle.sh — shared helpers for the boucle CI loop.
#
# This is the single source of truth for all shell helpers that were
# previously copy-pasted into each .gitlab-ci.yml job's script block.
# Sourced by the default.before_script (one line: source lib/boucle.sh).
#
# All forge API calls go through the forge_* abstraction layer
# (bin/forge/common.sh + bin/forge/${BOUCLE_FORGE}.sh). This file
# contains NO glab/gh/curl calls — only forge_* calls and pure shell
# logic. To support a new forge, implement bin/forge/<forge>.sh.
#
# Conventions:
#   - All forge_* functions are best-effort (set +e, 2>/dev/null, || true)
#     so transient API errors never kill the loop.
#   - Functions are idempotent: set_boucle_label skips no-op writes
#     (delegated to forge_issue_labels_set).
#   - Project identity uses BOUCLE_* env vars (not CI_* or GITHUB_*).

# ── Ensure the forge backend is loaded ───────────────────────────────────
# The CI before_script sources bin/forge/common.sh before this file,
# but guard in case it didn't (e.g. local dev, tests).
type forge_init &> /dev/null && {
  type forge_issue_get &> /dev/null || forge_init
} || true

# ── Escalation context ──────────────────────────────────────────────────

# job_link — markdown pointer to the CI job behind the current run.
#
# Every escalation comment boucle posts ("agent likely exhausted its step
# budget", "produced no code changes", "not mergeable") states that the loop
# stopped without saying WHY. The agent transcript is uploaded as a job
# artifact (#33); this is the link that makes it reachable.
#
# Prints nothing when the forge exposes no job URL, so callers can append it
# unconditionally without emitting a dangling "(job: )".
job_link() {
  local url="${BOUCLE_JOB_URL:-}"
  [ -n "$url" ] || return 0
  printf '\n\n[🔍 Job log & agent transcript](%s) — the `agent-output.log` artifact shows what the agent actually did.' "$url"
}

# ── Scheduled maintenance issues (#39) ──────────────────────────────────

# Boucle has exactly one entry point: a human creates an issue. Its only
# scheduled job is inward-facing — the doctor heals state, it never produces
# work. So recurring product maintenance (dependency bumps, accessibility
# audits, dead-link sweeps) is work the loop is well suited for but can
# never start on its own.
#
# Opt-in (BOUCLE_SCHEDULES_ENABLED, default false): a repository that writes
# no template sees no behaviour change.

# boucle_cron_field_matches <field> <value>
# Supports "*", a number, a list "a,b,c", a range "a-b" and a step "*/n" —
# the subset a maintenance schedule actually needs.
boucle_cron_field_matches() {
  local field="$1" value="$2" part
  [ "$field" = "*" ] && return 0
  case "$field" in
    '*/'*)
      local step="${field#*/}"
      case "$step" in
        '' | *[!0-9]*) return 1 ;;
      esac
      [ "$step" -eq 0 ] && return 1
      [ $((value % step)) -eq 0 ] && return 0
      return 1
      ;;
  esac
  # Same globbing hazard as above when a field reaches the list branch.
  local restore_glob=0
  case "$-" in
    *f*) ;;
    *) restore_glob=1 ;;
  esac
  set -f
  local IFS=','
  for part in $field; do
    case "$part" in
      *-*)
        local lo="${part%%-*}" hi="${part##*-}"
        case "$lo$hi" in
          '' | *[!0-9]*) continue ;;
        esac
        if [ "$value" -ge "$lo" ] && [ "$value" -le "$hi" ]; then
          [ "$restore_glob" -eq 1 ] && set +f
          return 0
        fi
        ;;
      *)
        if [ "$part" = "$value" ]; then
          [ "$restore_glob" -eq 1 ] && set +f
          return 0
        fi
        ;;
    esac
  done
  [ "$restore_glob" -eq 1 ] && set +f
  return 1
}

# boucle_cron_due <cron> — does this 5-field expression match now?
#
# Granularity is HOURLY on purpose: the doctor sweeps every few minutes, so
# minute-level precision would fire a template several times inside its own
# minute. The minute field is parsed and ignored; the caller enforces the
# once-per-window rule with the last-fire check.
boucle_cron_due() {
  local cron="$1"
  # Globbing MUST be off while splitting: an unquoted "*" field expands to
  # the working directory's file list, and every expression silently stops
  # having five fields.
  local restore_glob=0
  case "$-" in
    *f*) ;;
    *) restore_glob=1 ;;
  esac
  set -f
  local -a fields
  # shellcheck disable=SC2206
  fields=($cron)
  [ "$restore_glob" -eq 1 ] && set +f
  [ "${#fields[@]}" -eq 5 ] || return 1
  local hour dom mon dow
  hour=$(date -u +%-H)
  dom=$(date -u +%-d)
  mon=$(date -u +%-m)
  dow=$(date -u +%w)
  boucle_cron_field_matches "${fields[1]}" "$hour" || return 1
  boucle_cron_field_matches "${fields[2]}" "$dom" || return 1
  boucle_cron_field_matches "${fields[3]}" "$mon" || return 1
  boucle_cron_field_matches "${fields[4]}" "$dow" || return 1
  return 0
}

# boucle_schedule_frontmatter <file> <key> — read one YAML frontmatter key.
boucle_schedule_frontmatter() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      idx = index($0, ":")
      if (idx == 0) next
      k = substr($0, 1, idx - 1)
      v = substr($0, idx + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^"|"$/, "", v)
      if (k == key) { print v; exit }
    }
  ' "$1" 2> /dev/null || true
}

# boucle_schedule_body <file> — everything after the frontmatter.
boucle_schedule_body() {
  awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { inside = 0; started = 1; next }
    started || (NR == 1 && $0 != "---") { print }
  ' "$1" 2> /dev/null || true
}

# boucle_schedules_run — create issues for every template whose cron is due.
#
# Deduplication is FORGE-persisted, not cache-persisted: the last firing is
# read from the most recent issue carrying the template's marker. A fresh
# runner therefore cannot re-fire a template it already fired.
boucle_schedules_run() {
  [ "${BOUCLE_SCHEDULES_ENABLED:-false}" = "true" ] || return 0
  local dir="${BOUCLE_WORKSPACE:-.}/.boucle-state/schedules"
  [ -d "$dir" ] || return 0

  # A cron must never starve human-created work.
  local max_parallel="${BOUCLE_MAX_PARALLEL_ISSUES:-0}"
  case "$max_parallel" in
    '' | *[!0-9]*) max_parallel=0 ;;
  esac
  if [ "$max_parallel" -gt 0 ]; then
    local in_flight
    in_flight=$(forge_issue_count_by_label "boucle:working" opened 2> /dev/null || echo 0)
    case "$in_flight" in
      '' | *[!0-9]*) in_flight=0 ;;
    esac
    if [ "$in_flight" -ge "$max_parallel" ]; then
      echo "  → schedules skipped: $in_flight issue(s) in flight, cap is $max_parallel"
      return 0
    fi
  fi

  local existing
  existing=$(forge_issue_list_by_label "boucle:scheduled" all 2> /dev/null || echo "[]")

  local file name cron title labels enabled body marker
  for file in "$dir"/*.md; do
    [ -f "$file" ] || continue
    name=$(basename "$file" .md)
    marker="<!-- boucle:schedule id=$name -->"

    enabled=$(boucle_schedule_frontmatter "$file" enabled)
    if [ "$enabled" = "false" ]; then
      continue
    fi
    cron=$(boucle_schedule_frontmatter "$file" cron)
    title=$(boucle_schedule_frontmatter "$file" title)
    labels=$(boucle_schedule_frontmatter "$file" labels)
    if [ -z "$cron" ] || [ -z "$title" ]; then
      # A malformed template is skipped, never fatal: one bad file must not
      # stop the others or fail the job (CONTEXT.md §7 fail-open).
      echo "  → schedule '$name' skipped: missing cron or title"
      continue
    fi

    boucle_cron_due "$cron" || continue

    # Never a second issue while a previous one is still open.
    local open_count
    open_count=$(echo "$existing" | jq -r --arg m "$marker" \
      '[.[] | select((.state // "opened") != "closed") | select((.description // .body // "") | contains($m))] | length' \
      2> /dev/null || echo 0)
    if [ "${open_count:-0}" -gt 0 ]; then
      echo "  → schedule '$name' due but a previous issue is still open — skipping"
      continue
    fi

    # A missed window fires once, not once per sweep.
    local last_created age
    last_created=$(echo "$existing" | jq -r --arg m "$marker" \
      '[.[] | select((.description // .body // "") | contains($m)) | .created_at] | sort | last // ""' \
      2> /dev/null || echo "")
    if [ -n "$last_created" ]; then
      age=$(($(date -u +%s) - $(date -u -d "$last_created" +%s 2> /dev/null || echo 0)))
      if [ "$age" -lt 3600 ]; then
        echo "  → schedule '$name' already fired ${age}s ago — skipping"
        continue
      fi
    fi

    body="$marker
$(boucle_schedule_body "$file")"
    local all_labels="boucle:triage,boucle:scheduled"
    [ -n "$labels" ] && all_labels="${all_labels},${labels}"
    local new_iid
    new_iid=$(forge_issue_create "$title" "$body" "$all_labels" 2> /dev/null || echo "")
    if [ -n "$new_iid" ]; then
      echo "  → schedule '$name' fired: created #$new_iid"
    else
      echo "  → WARN: schedule '$name' due but issue creation failed"
    fi
  done
}

# ── Status board (#36) ──────────────────────────────────────────────────

# boucle_board_render — the four sections of the board, as markdown.
#
# Boucle's state is fully legible: it lives in labels. But only if you know
# which labels to filter on and you go looking. With five issues in flight
# plus blocked and dependent ones, nothing answers "what is waiting on me?".
#
# The board is a forge ISSUE that boucle edits in place — the forge is the
# UI, which is the whole thesis (CONTEXT.md §7: no new frontend, no server).
boucle_board_render() {
  local section label iids body=""
  body="<!-- boucle:board v=1 -->
_Maintained by boucle. Edited in place — do not reply here; act on the linked issues._
"
  local -a groups=(
    "⏳ Waiting on you|boucle:spec-review boucle:approval"
    "🔄 In flight|boucle:working boucle:review boucle:merging"
    "🚧 Blocked|boucle:blocked boucle:human boucle:needs-info"
    "🔗 Waiting on a dependency|boucle:depends-on"
  )
  local group title labels rows
  for group in "${groups[@]}"; do
    title="${group%%|*}"
    labels="${group#*|}"
    rows=""
    for label in $labels; do
      iids=$(forge_issue_list_by_label "$label" opened 2> /dev/null \
        | jq -r --arg l "${label#boucle:}" \
          '.[] | "| #\(.iid // .number) | \(.title // "" | .[0:70]) | \($l) | \(.updated_at // "" | .[0:10]) |"' \
          2> /dev/null || true)
      [ -n "$iids" ] && rows="${rows}${iids}
"
    done
    body="${body}
## ${title}
"
    if [ -z "$(printf '%s' "$rows" | tr -d '[:space:]')" ]; then
      body="${body}
_Nothing._
"
    else
      body="${body}
| Issue | Title | State | Last moved |
|---|---|---|---|
${rows}"
    fi
  done
  printf '%s' "$body"
}

# boucle_board_upsert — create the board issue once, then edit it in place.
#
# NEVER posts a comment. CONTEXT.md §8 already warns that no-op label writes
# pollute the event history; a board that comments would be worse. And the
# write is skipped entirely when the rendered body is unchanged.
boucle_board_upsert() {
  [ "${BOUCLE_BOARD_ENABLED:-true}" = "true" ] || return 0
  command -v forge_issue_list_by_label > /dev/null 2>&1 || return 0

  local board_iid
  board_iid=$(forge_issue_list_by_label "boucle:board" opened 2> /dev/null \
    | jq -r 'sort_by(.iid // .number) | .[0] | .iid // .number // empty' 2> /dev/null || echo "")

  local body
  body=$(boucle_board_render) || return 0
  [ -n "$body" ] || return 0

  if [ -z "$board_iid" ]; then
    # Idempotent by find-then-create: deleting the board by hand simply
    # makes the next sweep recreate it.
    board_iid=$(forge_issue_create "➰ boucle — status board" "$body" "boucle:board" 2> /dev/null || echo "")
    if [ -n "$board_iid" ]; then
      echo "  → status board created as #$board_iid"
    else
      echo "  → WARN: could not create the status board"
    fi
    return 0
  fi

  local current
  current=$(forge_issue_get "$board_iid" 2> /dev/null | jq -r '.description // .body // ""' 2> /dev/null || echo "")
  if [ "$current" = "$body" ]; then
    echo "  → status board #$board_iid unchanged — no write"
    return 0
  fi
  forge_issue_update "$board_iid" "description" "$body" 2> /dev/null || true
  echo "  → status board #$board_iid refreshed"
}

# ── Cost accounting (#35) ───────────────────────────────────────────────

# boucle_cost_summary <issue> — markdown breakdown of what this issue cost.
#
# Reads the accumulator bin/jc appends to on every agent invocation. Prints
# nothing when there is no data, so callers can embed it unconditionally.
#
# Dollar figures appear ONLY when BOUCLE_PRICING_JSON supplied a price for
# the model that actually ran. Boucle is provider-agnostic and prices drift:
# a confident wrong number is worse than tokens alone.
boucle_cost_summary() {
  local iid="$1"
  local file="${BOUCLE_WORKSPACE:-.}/.boucle-state/${iid}/cost.json"
  [ -s "$file" ] || return 0
  command -v jq > /dev/null 2>&1 || return 0
  jq -r '
    if (.entries | length) == 0 then empty else
    ([.entries[] | .prompt_tokens // 0] | add) as $pt
    | ([.entries[] | .completion_tokens // 0] | add) as $ct
    | ([.entries[] | .cost_usd // 0] | add) as $cost
    | ([.entries[] | select(.cost_usd != null)] | length) as $priced
    | "### Cost\n\n| Role | Runs | Prompt | Completion |"
      + (if $priced > 0 then " Cost |" else "" end)
      + "\n|---|---:|---:|---:|"
      + (if $priced > 0 then "---:|" else "" end)
      + "\n"
      + ([.entries | group_by(.role)[]
          | "| \(.[0].role) | \(length) | \([.[] | .prompt_tokens // 0] | add) | \([.[] | .completion_tokens // 0] | add) |"
            + (if $priced > 0 then " $\([.[] | .cost_usd // 0] | add | .*10000 | round / 10000) |" else "" end)]
         | join("\n"))
      + "\n| **total** | \(.entries | length) | **\($pt)** | **\($ct)** |"
      + (if $priced > 0 then " **$\($cost * 10000 | round / 10000)** |" else "" end)
      + (if $priced > 0 and $priced < (.entries | length) then "\n\n_Some runs have no price for their model — the total is a lower bound._" else "" end)
    end
   ' "$file" 2> /dev/null || true
}

# ── Loop-health measurement (#52) ─────────────────────────────────────
# Append one JSONL line per agent run to .boucle-state/<issue>/health.jsonl.
# Derived from what bin/jc already emits ([boucle:metrics], [boucle:prompt],
# cost.json) plus the run exit code. Survives across iterations via the
# state cache (like cost.json). Read by bin/health and by the escalation
# diagnostic below.
boucle_health_record() {
  local iid="$1" role="$2" iteration="$3" exit_code="$4"
  local prompt_chars="${5:-0}" tokens="${6:-}" cost="${7:-}"
  local model="${8:-}" provider="${9:-}"
  local file="${BOUCLE_WORKSPACE:-.}/.boucle-state/${iid}/health.jsonl"
  mkdir -p "$(dirname "$file")" 2> /dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"timestamp":"%s","role":"%s","iteration":%s,"exit_code":%s,"prompt_chars":%s,"tokens":"%s","cost_usd":"%s","model":"%s","provider":"%s"}\n' \
    "$ts" "$role" "$iteration" "$exit_code" "$prompt_chars" "${tokens:-n/a}" "${cost:-n/a}" "$model" "$provider" \
    >> "$file" 2> /dev/null || true
}

# Append a verdict/outcome line to health.jsonl. Called by the jobs
# (worker: committed/no-changes/build-fail; reviewer/e2e: PASS/FAIL/UNCERTAIN;
# merger: merged/conflict). One line per stage outcome.
boucle_health_outcome() {
  local iid="$1" role="$2" outcome="$3" detail="${4:-}"
  local file="${BOUCLE_WORKSPACE:-.}/.boucle-state/${iid}/health.jsonl"
  mkdir -p "$(dirname "$file")" 2> /dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"timestamp":"%s","role":"%s","outcome":"%s","detail":"%s"}\n' \
    "$ts" "$role" "$outcome" "$detail" \
    >> "$file" 2> /dev/null || true
}

# Structured escalation diagnostic (#52). Reads health.jsonl + cost.json
# and returns a markdown diagnostic body on stdout: failure class, evidence,
# recommended next action. Consumer-facing only — never posts upstream (#54).
#
# Failure classes: provider/quota, build-fail, no-changes, rebase-conflict,
# not-mergeable, spec-ambiguity, engine-defect, infra, unknown.
boucle_escalation_diagnostic() {
  local iid="$1" trigger="$2"
  local health_file="${BOUCLE_WORKSPACE:-.}/.boucle-state/${iid}/health.jsonl"
  local cost_file="${BOUCLE_WORKSPACE:-.}/.boucle-state/${iid}/cost.json"
  local class="unknown" evidence="" action="Inspect the agent transcript (link below) and the health record."

  # Count outcomes by role from health.jsonl
  local worker_runs worker_no_changes worker_build_fails reviewer_fails
  worker_runs=$(grep -c '"role":"worker"' "$health_file" 2> /dev/null || echo 0)
  worker_no_changes=$(grep -c '"outcome":"no-changes"' "$health_file" 2> /dev/null || echo 0)
  worker_build_fails=$(grep -c '"outcome":"build-fail"' "$health_file" 2> /dev/null || echo 0)
  reviewer_fails=$(grep -c '"outcome":"FAIL"' "$health_file" 2> /dev/null || echo 0)

  # Classify based on the trigger + the health record
  case "$trigger" in
    no-changes)
      class="step-budget-exhaustion"
      evidence="$worker_no_changes worker iteration(s) produced no code changes."
      action="The agent exhausted its step budget before committing. Check the transcript for where it spent its steps. If the issue is too large for one iteration, consider splitting it (boucle supports parent-child splits). Re-queue with \`boucle:todo\` to retry."
      ;;
    build-fail)
      class="build-failure"
      evidence="$worker_build_fails worker iteration(s) failed the build."
      action="The worker shipped code that does not build. Check the build error in the MR discussion. If the build command is wrong, verify \`BOUCLE_BUILD_CMD\` in the consumer CI variables."
      ;;
    rebase-conflict)
      class="rebase-conflict"
      evidence="Worker could not rebase onto $BOUCLE_DEFAULT_BRANCH (master keeps advancing)."
      action="Master advanced faster than the worker could land the branch. Re-queue with \`boucle:todo\` to retry on a fresh base, or rebase the branch manually."
      ;;
    not-mergeable)
      class="not-mergeable"
      evidence="MR is not mergeable after rebase."
      action="Check the MR conflict status. The merger already attempted a rebase. Resolve the conflict manually on the branch, or re-queue with \`boucle:todo\` for a fresh worker run."
      ;;
    exit-4)
      class="provider/quota"
      evidence="Worker exited 4 (model/API failure — provider down or quota exhausted)."
      action="Check the model provider status and remaining credits/quota. If the provider is down, set \`BOUCLE_FALLBACK_PROVIDER\` to retry on a secondary. Once available, re-queue with \`boucle:todo\`."
      ;;
    *)
      class="unknown"
      evidence="Trigger: $trigger. $worker_runs worker run(s), $reviewer_fails reviewer FAIL(s)."
      action="Inspect the agent transcript (link below) and the health record. If this looks like an engine defect, report it per the upstream workflow."
      ;;
  esac

  # Cost summary if available
  local cost_summary=""
  if [ -f "$cost_file" ]; then
    cost_summary=$(boucle_cost_summary "$iid" 2> /dev/null || echo "")
  fi

  echo "<!-- boucle:diagnostic v=1 iid=$iid class=$class trigger=$trigger -->"
  echo "## 🔍 Diagnostic — issue #$iid"
  echo ""
  echo "**Failure class:** \`$class\`"
  echo ""
  echo "**Evidence:** $evidence"
  echo ""
  echo "**Recommended action:**"
  echo ""
  echo "$action"
  echo ""
  if [ -n "$cost_summary" ]; then
    echo "$cost_summary"
    echo ""
  fi
  echo "---"
  echo "*Diagnostic posted by boucle (doctor — #52).*"
}

# ── Outbound notification (send-only) ───────────────────────────────────

# boucle_notify <iid> <new_label>
#
# The loop is asynchronous by design: the human is not meant to watch it.
# But the forge's own email notifications are indistinguishable from any
# other repository activity, so the two moments that actually need a human —
# the spec gate and the MR gate — arrive with the same weight as a label
# tweak. This pushes those, and escalations, to one webhook.
#
# SEND-ONLY on purpose. CONTEXT.md §7 forbids a new frontend, a server, or a
# machine to keep running: boucle POSTs, nothing listens. The reply path
# stays the forge comment, which the loop already reads.
#
# Silent by default (BOUCLE_NOTIFY_URL unset) and fail-open always: a dead
# webhook logs a warning and returns 0. Same rule as auto-update — a
# notification failure must never block the loop.
boucle_notify() {
  local iid="$1" label="$2"
  local hook="${BOUCLE_NOTIFY_URL:-}"
  [ -n "$hook" ] || return 0

  # Only the transitions a human has to act on. Notifying every state change
  # would get the channel muted within a day, which is worse than silence.
  local event waiting
  case "$label" in
    boucle:spec-review)
      event="spec-review"
      waiting="Approve the spec (👍) or comment to amend it."
      ;;
    boucle:approval)
      event="approval"
      waiting="Review and approve the MR (👍) or comment on it."
      ;;
    boucle:human)
      event="human"
      waiting="The loop escalated — it needs you to unblock it."
      ;;
    boucle:blocked)
      event="blocked"
      waiting="Blocked on a dependency or a decision."
      ;;
    *) return 0 ;;
  esac

  local events="${BOUCLE_NOTIFY_EVENTS:-spec-review,approval,human,blocked}"
  echo "$events" | tr ',' '\n' | grep -qx "$event" || return 0

  # The whole point of a quiet window is not being contacted during it.
  # bin/dnd exits 0 inside the window and handles BOUCLE_DND_ENABLED itself.
  if [ -x "${BOUCLE_HOME:-}/bin/dnd" ] && "${BOUCLE_HOME}/bin/dnd" > /dev/null 2>&1; then
    echo "[boucle:notify] suppressed ($event, #$iid) — inside the DND window" >&2
    return 0
  fi

  # Title and URL are best-effort: a notification naming only the issue
  # number still beats no notification.
  local meta="" title="" issue_url=""
  if command -v forge_issue_get > /dev/null 2>&1; then
    meta=$(forge_issue_get "$iid" 2> /dev/null || echo "")
  fi
  if [ -n "$meta" ]; then
    title=$(echo "$meta" | jq -r '.title // ""' 2> /dev/null || echo "")
    issue_url=$(echo "$meta" | jq -r '.web_url // .html_url // ""' 2> /dev/null || echo "")
  fi

  local text="➰ boucle — ${event}
#${iid} ${title:-(title unavailable)}
${waiting}"
  [ -n "$issue_url" ] && text="${text}
${issue_url}"

  local body content_type="application/json"
  case "${BOUCLE_NOTIFY_FORMAT:-slack}" in
    # Slack incoming webhooks; Discord accepts the same shape on a /slack
    # endpoint. Telegram's sendMessage takes chat_id in the URL query.
    slack | telegram)
      body=$(jq -n --arg t "$text" '{text: $t}')
      ;;
    ntfy)
      body="$text"
      content_type="text/plain"
      ;;
    raw)
      body=$(jq -n \
        --arg e "$event" --arg i "$iid" --arg ti "$title" \
        --arg u "$issue_url" --arg w "$waiting" \
        '{event: $e, issue: $i, title: $ti, url: $u, waiting_for: $w}')
      ;;
    *)
      echo "WARN: unknown BOUCLE_NOTIFY_FORMAT='${BOUCLE_NOTIFY_FORMAT}' — using slack." >&2
      body=$(jq -n --arg t "$text" '{text: $t}')
      ;;
  esac

  if ! curl -fsS --max-time 10 -X POST \
    -H "Content-Type: $content_type" \
    --data-binary "$body" "$hook" > /dev/null 2>&1; then
    echo "WARN: [boucle:notify] webhook POST failed ($event, #$iid) — continuing. A dead webhook must never block the loop." >&2
  fi
  return 0
}

# ── Label management ────────────────────────────────────────────────────

# boucle_mono_user
#
# True when a single account owns both the issues and the loop, i.e. there
# is no separate bot identity. Set by bin/setup --mono-user.
#
# "false" is treated as unset so the variable can be pinned off explicitly
# without having to unset it — CI variable UIs make deletion awkward.
boucle_mono_user() {
  [ -n "${BOUCLE_MONO_USER:-}" ] && [ "${BOUCLE_MONO_USER}" != "false" ]
}

# boucle_branch_name <iid>
#
# Deterministic readable worker branch name: boucle/<iid>-<slug>. The slug is
# derived from the issue title (lowercase, kebab-case, max 40 chars, truncated
# at a word boundary when possible). The <iid> prefix keeps the protocol
# identifier stable for lookups — forge_mr_lookup_by_branch prefix-matches on
# boucle/<iid>, so a title edit that changes the slug does not break the
# lookup. Falls back to the legacy boucle/<iid> when the title is empty or the
# fetch fails. MUST be deterministic: same issue → same branch name across
# iterations.
boucle_branch_name() {
  local iid="$1"
  local title slug cut
  title=$(forge_issue_get "$iid" 2> /dev/null | jq -r '.title // empty' 2> /dev/null || echo "")
  if [ -z "$title" ]; then
    echo "boucle/$iid"
    return 0
  fi
  # Lowercase, replace non-alphanumeric runs with '-', trim leading/trailing '-'.
  slug=$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  # Truncate to 40 chars at a word boundary if possible.
  if [ "${#slug}" -gt 40 ]; then
    cut="${slug:0:40}"
    # Trim back to the last '-' (word boundary) if one exists within the cut.
    cut="${cut%-*}"
    [ -n "$cut" ] && slug="$cut"
  fi
  if [ -z "$slug" ]; then
    echo "boucle/$iid"
    return 0
  fi
  echo "boucle/$iid-$slug"
}

# set_boucle_label <iid> <new_detail_label> <gross_status_label>
#
# Preserve non-boucle: labels, strip old boucle: detail + boucle::status::*
# labels, then write <new> + <gross>. Idempotent: skips the PUT when every
# label in "$new,$gross" is already on the issue (delegated to
# forge_issue_labels_set which handles forge-specific no-op avoidance,
# e.g. GitLab records a Resource Label Event on every PUT).
#
# Side effect: reassigns the issue.
#   - boucle::status::bot  → assign to the bot (BOUCLE_BOT_ID, best-effort).
#   - boucle::status::human → assign to the human reporter (walks up the
#     parent chain via resolve_reporter_id to skip bot-authored sub-issues).
#
# In mono-user mode <gross> is not written at all and neither reassignment
# runs: "whose side is this on?" has no answer when there is one actor, and
# re-assigning the sole human to their own issue emits nothing anyway.
set_boucle_label() {
  local iid="$1" new="$2" gross="$3"
  local current_all current_non_boucle
  current_all=$(forge_issue_labels_get "$iid")
  # Preserve non-boucle: labels
  current_non_boucle=$(echo "$current_all" | tr ',' '\n' | grep -v '^boucle:' | tr '\n' ',' | sed 's/,$//')
  # The gross axis answers "whose side is this on?", which has no meaning
  # when there is only one actor. In mono-user mode we write the detail
  # axis alone; the idempotence checks that test the pair collapse to it.
  local merged
  if boucle_mono_user; then
    merged="${current_non_boucle:+$current_non_boucle,}$new"
  else
    merged="${current_non_boucle:+$current_non_boucle,}$new,$gross"
  fi
  forge_issue_labels_set "$iid" "$merged"
  # Notify on the TRANSITION, never on the state. The doctor sweep re-applies
  # labels that are already set (CONTEXT.md §8: the forge records an event on
  # every PUT), so notifying on presence would re-fire on every sweep and get
  # the channel muted. Hooked here rather than at the ~19 call sites so future
  # transitions are covered by construction. Fail-open: never blocks the loop.
  if ! echo "$current_all" | tr ',' '\n' | grep -qx "$new"; then
    boucle_notify "$iid" "$new" || true
  fi
  # Both reassignments are no-ops in mono-user mode: the issue already
  # belongs to the only human, and forges emit nothing when the assignee
  # set does not actually change. Skipping them avoids two pointless API
  # calls per transition, and avoids feeding the assignment-based trigger
  # in dispatch with self-assignment events.
  if boucle_mono_user; then
    return 0
  fi
  # When the issue moves to the bot side, assign it to the bot user so
  # the board reflects who owns the next action. Best-effort: skip
  # silently if BOUCLE_BOT_ID is unset (backward compat).
  if [ "$gross" = "boucle::status::bot" ] && [ -n "${BOUCLE_BOT_ID:-}" ]; then
    forge_issue_assign "$iid" "$BOUCLE_BOT_ID"
  elif [ "$gross" = "boucle::status::human" ]; then
    # Reassign the issue to the human reporter (walks up parent chain to
    # skip bot-authored sub-issues). Best-effort: skip silently if
    # resolve fails.
    local human_id
    human_id=$(resolve_reporter_id "$iid" 2> /dev/null)
    if [ -n "$human_id" ] && [ "$human_id" != "null" ] && [ "$human_id" != "${BOUCLE_BOT_ID:-}" ]; then
      forge_issue_assign "$iid" "$human_id"
    fi
  fi
}

# ── Issue / hierarchy helpers ───────────────────────────────────────────

# _resolve_reporter_walk <iid>
#
# Walk up the parent-issue chain until we find a non-bot author.
# Prints `reporter_id<TAB>author_username` for the resolved human reporter.
# Bot-authored sub-issues (created by up-bot) are skipped by matching
# BOUCLE_BOT_USERNAME (default "up-bot"). Max depth 10 to prevent loops.
# E2E-fail follow-ups (bot-authored, no parent section) are followed via
# their qualified origin marker (`<!-- boucle:e2e-origin v=1 iid=N -->`)
# so the original human reporter is found — otherwise the reviewer assigns
# the MR to the bot instead of the human.
# On a forge_issue_get failure, prints nothing (empty output).
_resolve_reporter_walk() {
  local iid="$1" data parent_iid parent_data reporter_id author_username
  local bot_user="${BOUCLE_BOT_USERNAME:-up-bot}"
  local depth=0 max_depth=10
  data=$(forge_issue_get "$iid") || {
    echo ""
    return
  }
  reporter_id=$(printf '%s' "$data" | jq -r '.author.id // empty')
  author_username=$(printf '%s' "$data" | jq -r '.author.username // empty')
  # Walk up the parent chain until we find a non-bot author.
  while [ "$author_username" = "$bot_user" ] && [ "$depth" -lt "$max_depth" ]; do
    parent_iid=$(printf '%s' "$data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
    # E2E-fail follow-ups are bot-authored with NO parent section; their
    # qualified origin marker carries the ORIGINAL issue's IID. Walk from
    # there so the MR is assigned to the human reporter, not the bot
    # (consumer regression: MR assigned to up-bot after reviewer PASS).
    if [ -z "$parent_iid" ]; then
      parent_iid=$(printf '%s' "$data" | jq -r '.description // empty' | sed -nE 's/.*<!-- boucle:e2e-origin v=1 iid=([0-9]+) -->.*/\1/p' | head -1)
    fi
    # Legacy E2E-fail follow-ups (created before the origin marker existed)
    # still carry the prose line "E2E verification failed for issue #N."
    # — parse it as a last-resort fallback so pre-marker issues also reach
    # their human reporter.
    if [ -z "$parent_iid" ]; then
      parent_iid=$(printf '%s' "$data" | jq -r '.description // empty' | sed -nE 's/.*issue #([0-9]+)\.$/\1/p' | head -1)
    fi
    [ -z "$parent_iid" ] && break
    parent_data=$(forge_issue_get "$parent_iid") || break
    reporter_id=$(printf '%s' "$parent_data" | jq -r '.author.id // empty')
    author_username=$(printf '%s' "$parent_data" | jq -r '.author.username // empty')
    data="$parent_data"
    depth=$((depth + 1))
  done
  printf '%s\t%s\n' "$reporter_id" "$author_username"
}

# resolve_reporter_id <iid>
#
# Walk up the parent-issue chain until we find a non-bot author.
# Returns the forge user ID of the original human reporter (empty on
# failure). Used by set_boucle_label to reassign issues to the human.
resolve_reporter_id() {
  _resolve_reporter_walk "$1" | cut -f1
}

# resolve_reporter_username <iid>
#
# Walk up the parent-issue chain until we find a non-bot author.
# Returns the forge username of the original human reporter (empty if
# unresolvable). Used by the allow-list gate (check_allow_list_gate) in
# the dispatch and doctor stages to decide whether an issue's author is
# in BOUCLE_ALLOWED_USERS.
resolve_reporter_username() {
  _resolve_reporter_walk "$1" | cut -f2
}

# check_allow_list_gate <iid>
#
# Safety net: only issues whose resolved human reporter is in
# BOUCLE_ALLOWED_USERS are accepted. Fail-open when the variable is
# unset/empty (legacy consumers — the net is seeded at install by
# bin/setup). The reporter is resolved through the parent chain
# (bot-authored sub-issues resolve to their parent's author), same
# semantics as resolve_reporter_id. On rejection: post an explanatory
# note; the caller must NOT trigger any role (the anti-accumulation
# EXIT trap turns the no-op exit into a visible pipeline failure).
# Returns 0 = allowed (or variable unset), 1 = rejected.
#
# Lives in lib/boucle.sh (not lib/boucle-ci/dispatch.sh) so it is
# available to BOTH the extracted lib path (bin/boucle-ci, which sources
# lib/boucle-ci.sh → all lib/boucle-ci/*.sh) AND the inline .gitlab-ci.yml
# jobs (which source only lib/boucle.sh). One definition, every caller.
check_allow_list_gate() {
  local iid="$1"
  local allowed_str needle username u
  allowed_str="$(printf '%s' "${BOUCLE_ALLOWED_USERS:-}" | tr -d '[:space:]')"
  [ -n "$allowed_str" ] || return 0
  username=$(resolve_reporter_username "$iid" 2> /dev/null || true)
  if [ -z "$username" ]; then
    echo "allow-list: cannot resolve the human reporter for #$iid — failing OPEN (transient/legacy)"
    return 0
  fi
  needle=$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')
  # Iterate over each comma-separated username. A `for` loop with IFS=','
  # (rather than `while read`) keeps `return` in the current shell so the
  # gate's exit code propagates to the caller.
  local IFS=','
  for u in $allowed_str; do
    [ -z "$u" ] && continue
    if [ "$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')" = "$needle" ]; then
      echo "allow-list: #$iid reporter @$username is allowed"
      return 0
    fi
  done
  echo "allow-list: #$iid reporter @$username is NOT in BOUCLE_ALLOWED_USERS — rejecting"
  forge_issue_note "$iid" ":lock: This issue was not accepted by the boucle loop: its author \`@$username\` is not in \`BOUCLE_ALLOWED_USERS\`. Ask a maintainer to add the username to the allow list if this is a mistake.\n\n<!-- boucle:allow-list v=1 user=$username -->"
  return 1
}

# get_work_item_global_id <iid>
#
# Fetch the global work-item ID for a project issue. Returns empty on
# failure (403, non-JSON, missing .id field). Used by triage to convert
# issue IIDs into work-item global IDs for the hierarchy API.
# Delegates to forge_work_item_global_id (GitLab: work-items API;
# GitHub: no equivalent — returns empty).
get_work_item_global_id() {
  local iid="$1"
  forge_work_item_global_id "$iid"
}

# get_work_item_children <parent_iid>
#
# List child work items of a parent via the hierarchy API.
# Returns a JSON array (empty array on failure). Each child has
# .iid, .state ("opened"|"closed"), .title.
# Delegates to forge_work_item_children (GitLab: hierarchy API with
# array-type validation; GitHub: sub-issues API or body-marker fallback).
get_work_item_children() {
  local parent_iid="$1"
  forge_work_item_children "$parent_iid"
}

# close_issue <iid>
#
# Close an issue. Best-effort (boucle:done is a board label, not
# a close state — closing is a separate lifecycle event).
close_issue() {
  local iid="$1"
  forge_issue_close "$iid"
}

# maybe_close_parent <child_iid>
#
# Parent-close cascade: if this issue is a sub-issue (has a "## Parent
# issue" section in its description), check whether ALL siblings are
# closed. If so, close the parent too.
#
# Sibling discovery order:
#   1. forge_work_item_children (hierarchy API — includes .state per child).
#   2. Legacy split-parent marker comment (older boucle versions).
maybe_close_parent() {
  local child_iid="$1" live_url="${2:-}"
  # Parse parent IID from the sub-issue body ("## Parent issue\n#N — <url>")
  local child_data parent_iid
  child_data=$(forge_issue_get "$child_iid") || {
    echo "maybe_close_parent: can't fetch issue #$child_iid — skipping."
    return 0
  }
  parent_iid=$(echo "$child_data" | jq -r '.description // empty' | awk '/^## Parent issue[[:space:]]*$/{f=1;next}/^## /{f=0}f' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
  if [ -z "$parent_iid" ]; then
    echo "maybe_close_parent: no parent issue link in #$child_iid — not a sub-issue."
    return 0
  fi

  # Fetch parent; skip if already closed
  local parent_data parent_state
  parent_data=$(forge_issue_get "$parent_iid") || {
    echo "maybe_close_parent: can't fetch parent #$parent_iid — skipping."
    return 0
  }
  parent_state=$(echo "$parent_data" | jq -r '.state')
  if [ "$parent_state" = "closed" ]; then
    echo "maybe_close_parent: parent #$parent_iid already closed."
    return 0
  fi

  # Check children via the forge hierarchy API (source of truth).
  # The children endpoint returns each child's .state directly, so we
  # can check all siblings in one call. Fall back to the legacy
  # split-parent marker comment for data produced by older boucle
  # versions that didn't use the hierarchy API.
  local children_data sibling_iids
  children_data=$(forge_work_item_children "$parent_iid")
  sibling_iids=$(echo "$children_data" | jq -r '[.[].iid] | join(",")' 2> /dev/null)
  if [ -z "$sibling_iids" ]; then
    # No children via hierarchy API — fall back to legacy marker comment
    local parent_notes
    parent_notes=$(forge_issue_notes "$parent_iid") || {
      echo "maybe_close_parent: can't fetch parent notes — skipping."
      return 0
    }
    sibling_iids=$(echo "$parent_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:split-parent"))] | first | .body // empty' | grep -oE 'iids=[0-9,]+' | cut -d= -f2)
    if [ -z "$sibling_iids" ]; then
      echo "maybe_close_parent: no children via hierarchy API and no split-parent marker on #$parent_iid — can't check siblings."
      return 0
    fi
    echo "maybe_close_parent: found $sibling_iids via legacy split-parent marker"
    # Legacy marker fallback: check each sibling state individually
    local all_closed=true iid
    for iid in $(echo "$sibling_iids" | tr ',' ' '); do
      local sib_data sib_state
      sib_data=$(forge_issue_get "$iid") || continue
      sib_state=$(echo "$sib_data" | jq -r '.state // "unknown"')
      if [ "$sib_state" != "closed" ]; then
        echo "maybe_close_parent: sibling #$iid is $sib_state — parent #$parent_iid stays open."
        all_closed=false
        break
      fi
    done
    if [ "$all_closed" = "true" ]; then
      echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
      # Post a note on the parent BEFORE closing it so the human sees the
      # production URL. Lesson #59: note FIRST, label/close SECOND. A parent
      # note failure is non-fatal (log + return 0) — the child is already
      # closed and the doctor retries the parent. forge_issue_note
      # auto-stamps the <!-- boucle:agent --> marker (lesson #55).
      local parent_note_body
      parent_note_body="✅ All sub-issues resolved and deployed. Closing parent issue.

## Production URL
${live_url:-$(boucle_resolve_live_url "" 2> /dev/null || echo "unavailable")}

## Sub-issues
$(echo "$sibling_iids" | tr ',' ' ' | sed 's/\([0-9]\+\)/#\1/g')"
      if ! forge_issue_note "$parent_iid" "$parent_note_body"; then
        echo "WARN: could not post parent-close note on #$parent_iid — not closing parent (doctor will retry)." >&2
        return 0
      fi
      close_issue "$parent_iid"
    fi
    return 0
  fi

  # Hierarchy API path: children response includes .state directly,
  # so we can check all siblings in one call (no per-sibling fetch).
  local open_count
  open_count=$(echo "$children_data" | jq '[.[] | select(.state != "closed")] | length' 2> /dev/null || echo 1)
  if [ "${open_count:-1}" -gt 0 ]; then
    local open_iids
    open_iids=$(echo "$children_data" | jq -r '[.[] | select(.state != "closed") | .iid] | join(",")')
    echo "maybe_close_parent: open sub-issue(s) #$open_iids — parent #$parent_iid stays open."
  else
    echo "maybe_close_parent: all sub-issues of #$parent_iid are closed — closing parent."
    # Post a note on the parent BEFORE closing it so the human sees the
    # production URL. Lesson #59: note FIRST, label/close SECOND. A parent
    # note failure is non-fatal (log + return 0) — the child is already
    # closed and the doctor retries the parent. forge_issue_note
    # auto-stamps the <!-- boucle:agent --> marker (lesson #55).
    # In the hierarchy path sibling_iids is set at line 899; if empty,
    # reconstruct from children_data.
    local parent_note_body hierarchy_siblings
    hierarchy_siblings="${sibling_iids:-$(echo "$children_data" | jq -r '[.[] | .iid] | join(",")' 2> /dev/null)}"
    parent_note_body="✅ All sub-issues resolved and deployed. Closing parent issue.

## Production URL
${live_url:-$(boucle_resolve_live_url "" 2> /dev/null || echo "unavailable")}

## Sub-issues
$(echo "$hierarchy_siblings" | tr ',' ' ' | sed 's/\([0-9]\+\)/#\1/g')"
    if ! forge_issue_note "$parent_iid" "$parent_note_body"; then
      echo "WARN: could not post parent-close note on #$parent_iid — not closing parent (doctor will retry)." >&2
      return 0
    fi
    close_issue "$parent_iid"
  fi
}

# ── Preview URL deep-linking ────────────────────────────────────────────

# preview_url_for_changed_files <base_url>
#
# Map the first changed src/pages/*.astro or src/content/*/*.md file to
# its route and append it to the base preview URL. Falls back to the
# base URL if no changed file maps to a route.
# Forge-agnostic (pure git + file logic).
preview_url_for_changed_files() {
  base_url="$1"
  [ -z "$base_url" ] && {
    echo ""
    return
  }
  changed=$(git diff --name-only "origin/${BOUCLE_DEFAULT_BRANCH:-main}...$BRANCH" 2> /dev/null)
  [ -z "$changed" ] && {
    echo "$base_url"
    return
  }
  path=""
  for f in $changed; do
    case "$f" in
      src/pages/*.astro)
        rel="${f#src/pages/}"
        rel="${rel%.astro}"
        if echo "$rel" | grep -qE '\[(\.\.\.)?slug\]'; then
          # Dynamic route component → fall back to parent static route
          dir=$(dirname "$rel")
          [ "$dir" = "." ] && dir=""
          path="/$dir"
        elif [ "$rel" = "index" ]; then
          path="/"
        else
          path="/$rel"
        fi
        break
        ;;
      src/content/*/*.md)
        # Content collection entry → map to listing page if a matching
        # dynamic route component exists under src/pages/<col>/.
        col=$(echo "$f" | sed -n 's|^src/content/\([^/]*\)/.*|\1|p')
        if [ -n "$col" ]; then
          if [ -f "src/pages/$col/[...slug].astro" ] || [ -f "src/pages/$col/[slug].astro" ]; then
            path="/$col"
            break
          fi
        fi
        ;;
    esac
  done
  # Normalize: collapse double slashes, strip trailing slash (except root)
  path=$(echo "$path" | sed 's|//\+|/|g; s|/\+$||')
  [ -z "$path" ] && path="/"
  echo "${base_url%/}${path}"
}

# ── Deploy / review mode helpers ─────────────────────────────────────────

# boucle_deploy_mode
#   Echo the current deploy mode ("self" or "external"). Default: "self".
boucle_deploy_mode() {
  echo "${BOUCLE_DEPLOY_MODE:-self}"
}

# boucle_review_mode
#   Echo the current review mode ("preview", "diff", or "screenshot").
#   Default: "preview".
boucle_review_mode() {
  echo "${BOUCLE_REVIEW_MODE:-preview}"
}

# boucle_is_self_deploy
#   Returns 0 (true) if BOUCLE_DEPLOY_MODE is "self", 1 (false) otherwise.
boucle_is_self_deploy() {
  [ "$(boucle_deploy_mode)" = "self" ]
}

# boucle_is_external_deploy
#   Returns 0 (true) if BOUCLE_DEPLOY_MODE is "external", 1 (false) otherwise.
boucle_is_external_deploy() {
  [ "$(boucle_deploy_mode)" = "external" ]
}

# boucle_is_preview_review
#   Returns 0 (true) if BOUCLE_REVIEW_MODE is "preview", 1 (false) otherwise.
boucle_is_preview_review() {
  [ "$(boucle_review_mode)" = "preview" ]
}

# boucle_is_diff_review
#   Returns 0 (true) if BOUCLE_REVIEW_MODE is "diff", 1 (false) otherwise.
boucle_is_diff_review() {
  [ "$(boucle_review_mode)" = "diff" ]
}

# boucle_is_screenshot_review
#   Returns 0 (true) if BOUCLE_REVIEW_MODE is "screenshot", 1 (false) otherwise.
#   Screenshot mode: the worker builds the site, serves it locally
#   (python3 -m http.server), captures screenshots of impacted pages via
#   puppeteer/chromium, uploads them to the MR. The reviewer receives the
#   screenshots as text descriptions (via describe-images with criteria)
#   instead of probing a deployed preview URL. No deploy command, no token,
#   no CDN propagation wait. Ideal for GitLab CE (no per-branch Pages) or
#   any token-less setup where visual review still matters.
boucle_is_screenshot_review() {
  [ "$(boucle_review_mode)" = "screenshot" ]
}

# boucle_resolve_live_url [deploy_log]
#   Resolve the production/live URL in priority order:
#     1. BOUCLE_LIVE_URL (explicit override)
#     2. BOUCLE_PRODUCTION_URL (fallback)
#     3. $CI_PAGES_URL when BOUCLE_DEPLOY_PROVIDER=gitlab-pages (declarative
#        GitLab Pages — the forge serves the site itself, no deploy command)
#     4. Regex-extract from deploy_log (self mode only)
#     5. Last-resort: https://${BOUCLE_DEPLOY_PROJECT}.pages.dev (self mode only)
#   Echoes the resolved URL on stdout.
boucle_resolve_live_url() {
  local deploy_log="$1"
  local url=""

  # Priority 1: explicit override
  if [ -n "${BOUCLE_LIVE_URL:-}" ]; then
    echo "$BOUCLE_LIVE_URL"
    return
  fi

  # Priority 2: production URL fallback
  if [ -n "${BOUCLE_PRODUCTION_URL:-}" ]; then
    echo "$BOUCLE_PRODUCTION_URL"
    return
  fi

  # Priority 3: declarative GitLab Pages — the forge serves the site at
  # $CI_PAGES_URL (only defined in CI jobs, never locally). The pages.dev
  # last-resort below would point at a nonexistent Cloudflare project.
  # NOTE: the inline GitLab post-merge job that `bin/boucle-ci post-merge`
  # replaced consulted $CI_PAGES_URL unconditionally. This gate is the
  # considered behaviour (see the test in test/boucle-lib.bats), so GitLab
  # Pages consumers must set BOUCLE_DEPLOY_PROVIDER=gitlab-pages — which is
  # what LOOP.md §"GitLab Pages declarative mode" already documents.
  if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "gitlab-pages" ] && [ -n "${CI_PAGES_URL:-}" ]; then
    echo "$CI_PAGES_URL"
    return
  fi

  # Priority 3b: declarative GitHub Pages — the site is served from the
  # gh-pages branch at https://<owner>.github.io/<repo>/. Like GitLab CE
  # there is no per-branch preview, so the reviewer falls back to diff
  # review; the e2e checks the canonical URL.
  if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "github-pages" ]; then
    echo "$(boucle_github_pages_url)"
    return
  fi

  # Priority 4-5: self mode only — extract from deploy log or fallback
  if boucle_is_self_deploy; then
    if [ -n "$deploy_log" ] && [ -f "$deploy_log" ]; then
      url=$(grep -oE "$BOUCLE_DEPLOY_URL_REGEX" "$deploy_log" | head -1)
    fi
    if [ -z "$url" ] && [ -n "${BOUCLE_DEPLOY_PROJECT:-}" ]; then
      url="https://${BOUCLE_DEPLOY_PROJECT}.pages.dev"
    fi
  fi

  echo "$url"
}

# boucle_worker_should_deploy
#   Returns 0 if the worker should run the preview deploy step,
#   1 if it should skip it (external mode, diff review mode, or no
#   deploy command — e.g. GitLab Pages declarative mode where
#   BOUCLE_DEPLOY_CMD is empty and the forge serves the site itself).
boucle_worker_should_deploy() {
  # GitHub Pages declarative mode: the worker itself pushes the build
  # output to the gh-pages branch (no BOUCLE_DEPLOY_CMD, no extra
  # credentials — the bot PAT already has contents:write). Deploy must
  # return 0 here so the SHA marker is stamped and the build output is
  # kept; boucle_worker_deploy handles the push branch.
  if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "github-pages" ]; then
    return 0
  fi
  # Skip deploy when no deploy command is configured (GitLab Pages
  # declarative / token-less mode, or a provider without a CLI). An empty
  # BOUCLE_DEPLOY_CMD must SKIP the preview deploy, never fail the worker:
  # the reviewer already falls back to diff review when no preview URL
  # could be extracted, so a skipped preview is a valid, complete loop.
  if [ -z "${BOUCLE_DEPLOY_CMD:-}" ]; then
    return 1
  fi
  # Skip deploy in external mode (consumer's own CI handles it)
  if boucle_is_external_deploy; then
    return 1
  fi
  # Skip deploy in diff review mode (no preview needed)
  if boucle_is_diff_review; then
    return 1
  fi
  # Skip deploy in screenshot review mode — the worker captures screenshots
  # locally (python3 -m http.server + puppeteer) instead of deploying a
  # preview. No BOUCLE_DEPLOY_CMD, no token, no CDN.
  if boucle_is_screenshot_review; then
    return 1
  fi
  return 0
}

# boucle_github_pages_url
#   Echo the canonical GitHub Pages URL for BOUCLE_PROJECT_ID
#   (https://<owner>.github.io/<repo>/). Handles user-site repos
#   (<owner>.github.io) which are served at the bare domain.
boucle_github_pages_url() {
  local owner repo
  owner="${BOUCLE_PROJECT_ID%%/*}"
  repo="${BOUCLE_PROJECT_ID#*/}"
  if [ "$repo" = "$owner.github.io" ]; then
    echo "https://$owner.github.io/"
  else
    echo "https://$owner.github.io/$repo/"
  fi
}

# boucle_worker_deploy
#   Run the preview deploy. Returns 0 on success. Sets preview_url if the
#   deploy emitted one, else leaves it empty (reviewer falls back to diff
#   review). Handles the github-pages provider by pushing the build output
#   to the gh-pages branch via the existing bot credentials — no token in
#   BOUCLE_DEPLOY_CMD, no CLOUDFLARE_* secrets required.
#   Arguments: deploy_log path (worker) — GitHub Pages mode ignores it.
boucle_worker_deploy() {
  local deploy_log="$1"
  if [ "${BOUCLE_DEPLOY_PROVIDER:-}" = "github-pages" ]; then
    local build_out="${BOUCLE_BUILD_OUTPUT:-public}"
    if [ ! -d "$build_out" ]; then
      echo "FAIL: github-pages: build output $build_out missing" >&2
      return 1
    fi
    echo "[boucle] GitHub Pages mode — pushing $build_out to gh-pages branch"
    # Push the build output to gh-pages. Strategy: create an orphan branch
    # commit containing only the build output, force-push it to gh-pages.
    # Using a temporary worktree keeps the working tree clean and avoids
    # touching the consumer's checked-out branch.
    local tmp_dir gh_sha
    tmp_dir=$(mktemp -d)
    gh_sha=$(git rev-parse --short HEAD)
    git -C "$tmp_dir" init -q -b gh-pages
    cp -a "$build_out"/. "$tmp_dir"/
    touch "$tmp_dir/.nojekyll"
    git -C "$tmp_dir" add -A
    git -C "$tmp_dir" -c user.email="${BOUCLE_BOT_EMAIL:-boucle-bot@boucle.local}" \
      -c user.name="${BOUCLE_BOT_USERNAME:-up-bot}" \
      commit -qm "deploy: $gh_sha [skip ci]"
    # Push with the bot PAT when available (same credential path the worker
    # uses — worker.sh configures origin with the token); fall back to the
    # checkout's origin URL (extraheader credentials) otherwise.
    if [ -n "${BOUCLE_TOKEN:-}" ]; then
      git -C "$tmp_dir" remote add origin "https://${BOUCLE_BOT_USERNAME:-up-bot}:${BOUCLE_TOKEN}@${BOUCLE_FORGE_HOST}/${BOUCLE_PROJECT_PATH}.git"
    else
      git -C "$tmp_dir" remote add origin "$(git remote get-url origin 2> /dev/null || echo "https://github.com/$BOUCLE_PROJECT_ID.git")"
    fi
    if ! git -C "$tmp_dir" push --force origin gh-pages > /dev/null 2>&1; then
      echo "FAIL: github-pages: push to gh-pages branch failed" >&2
      rm -rf "$tmp_dir"
      return 1
    fi
    rm -rf "$tmp_dir"
    echo "[boucle] GitHub Pages deployed: $(boucle_github_pages_url)"
    return 0
  fi
  # Fallback: run BOUCLE_DEPLOY_CMD and extract a preview URL.
  (eval "$BOUCLE_DEPLOY_CMD") > "$deploy_log" 2>&1
  local rc=$?
  local url
  url=$(grep -oE "$BOUCLE_DEPLOY_URL_REGEX" "$deploy_log" | head -1)
  if [ "$rc" -ne 0 ] && [ -z "$url" ]; then
    echo "FAIL: deploy exited $rc with no preview URL" >&2
    cat "$deploy_log" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ] && [ -n "$url" ]; then
    echo "WARN: deploy exited non-zero ($rc) but emitted a preview URL — proceeding" >&2
  fi
  echo "$url"
  return 0
}

# ── Cross-role variable forwarding ──────────────────────────────────────

# chain_to_role <issue_iid> <role> [var=value ...]
#
# Trigger the next role in the boucle loop via the forge trigger API.
# Always forwards BOUCLE_ISSUE=<issue_iid> and BOUCLE_ROLE=<role>.
# Extra variables are passed as var=value pairs (e.g.
#   chain_to_role "$BOUCLE_ISSUE" worker BOUCLE_ITERATION=2
# ).
#
# This is the single contract point for cross-role state forwarding.
# Previously each job hand-rolled its curl -F "variables[...]=..." calls,
# which led to missing variables (e.g. BOUCLE_ITERATION was not forwarded
# worker→reviewer, causing infinite loops at iteration 2).
#
# When <role> is empty, only BOUCLE_ISSUE is forwarded (used by triage
# re-triggers and bot-created issue launches where dispatch infers the role).
# Delegates to forge_trigger_role (GitLab: trigger/pipeline API with
# BOUCLE_TRIGGER_TOKEN; GitHub: workflow_dispatch API).
chain_to_role() {
  local issue_iid="$1" role="$2"
  shift 2
  forge_trigger_role "$issue_iid" "$role" "$@"
}
# ── S4: merge-conflict handling (worker retry first, human last) ──
# Parses rebase output, classifies the conflict. On conflict the merger
# FIRST re-triggers the worker (bounded by BOUCLE_MAX_ITERATIONS): the
# worker rebases onto the fresh default branch and re-implements the
# issue goal on top of whatever the sibling merged — it can conciliate
# semantic conflicts (it has the issue body + human amendments), where a
# blind rebase cannot. Only after the retry budget is exhausted does the
# loop escalate to the human with structured options.

# Pure parser: echo one line per conflicted path, format "- <path> (kind)".
boucle_parse_merge_conflicts() {
  local line kind file
  while IFS= read -r line; do
    case "$line" in
      *"CONFLICT (modify/delete):"*) kind="modify/delete" ;;
      *"CONFLICT (content):"*) kind="content (modify/modify)" ;;
      *"CONFLICT"*) kind="other" ;;
      *) continue ;;
    esac
    file=$(echo "$line" | sed 's/.*CONFLICT ([^)]*): //' | sed 's/^Merge conflict in //' | sed 's/ deleted in .*//' | sed 's/ modified in .*//')
    echo "- ${file} (${kind})"
  done <<< "$1"
}

boucle_escalate_merge_conflict() {
  local issue="$1" mr_iid="$2" default_branch="$3" rebase_out="$4"
  local conflicts parsed
  conflicts=$(boucle_parse_merge_conflicts "$rebase_out")
  [ -z "$conflicts" ] && conflicts="- (unclassified — see rebase output in the pipeline log)"

  # ── Conflict-retry budget ──────────────────────────────────────────
  # Count prior conflict-retries on this issue via the marker comment
  # `<!-- boucle:conflict-retry N -->` posted on each re-trigger. Bounded
  # by BOUCLE_CONFLICT_RETRIES (default 5): a semantic conflict is retried
  # by the WORKER (intelligent rebase + re-implementation on fresh master),
  # NOT escalated blindly — the worker can conciliate amendments that a
  # blind git rebase cannot (observed on a consumer 2026-08: sibling
  # issues #69/#71 diverged on the same component; the worker could have
  # re-implemented on top of the merged sibling instead of escalating).
  # Note: the worker ALSO has its own rebase-conflict retry loop
  # (iteration N/MAX), so the effective attempts are the product of both
  # loops — 5 merger retries is the observed sweet spot.
  local max_retries="${BOUCLE_CONFLICT_RETRIES:-5}"
  local retry_count=0 conflict_notes
  conflict_notes=$(forge_issue_notes "$issue" 2> /dev/null || echo "[]")
  retry_count=$(echo "$conflict_notes" | jq -r '[.[] | select(.body | contains("<!-- boucle:conflict-retry"))] | length' 2> /dev/null || echo 0)
  retry_count="${retry_count:-0}"

  if [ "$retry_count" -lt "$max_retries" ]; then
    local retry_n=$((retry_count + 1))
    local retry_body
    retry_body="🔄 **Merge conflict — re-triggering worker (retry ${retry_n}/${max_retries})**

The rebase onto \`$default_branch\` conflicted on:

$conflicts

The worker is being re-triggered to rebase onto the fresh \`$default_branch\` and re-implement the issue goal on top of the merged work (it can conciliate semantic conflicts with the issue body + human amendments). Escalation to a human happens only after ${max_retries} failed conflict-retries.

<!-- boucle:conflict-retry ${retry_n} -->"
    # Note BEFORE the re-trigger — never a silent transition.
    if ! forge_issue_note "$issue" "$retry_body"; then
      echo "FAIL: conflict-retry note could not be posted on issue #$issue — NOT re-triggering (retry instead of muting)." >&2
      return 1
    fi
    set_boucle_label "$issue" "boucle:todo" "boucle::status::bot"
    echo "→ #$issue: merge conflict — re-triggering worker (retry ${retry_n}/${max_retries}) with conflict feedback." >&2
    # Forward the conflicted paths so the worker knows what collided.
    chain_to_role "$issue" "worker" "BOUCLE_ITERATION=$retry_n" "BOUCLE_CONFLICT_FEEDBACK=$(echo "$conflicts" | tr '\n' ';')"
    return 0
  fi

  # ── Retry budget exhausted → human escalation ──────────────────────
  local body
  body="⚠️ **Merge conflict — human intervention required**

Issue #$issue (MR !$mr_iid, branch \`boucle/$issue\`) cannot be merged automatically: the rebase onto \`$default_branch\` hit a **semantic conflict** that ${max_retries} worker conflict-retries could not resolve. The loop is **paused** on this issue and it is assigned to you.

**Classification** : detected from the rebase output (modify/delete = this branch deletes a file the default branch has modified, or vice versa).

**Conflicted paths** :
$conflicts

**What I did** : rebased onto $default_branch → conflict → aborted (branch preserved, nothing lost). Re-triggered the worker ${max_retries} time(s) to re-implement on fresh $default_branch; the conflict persists.

**Manual options** :
1. **Resolve on the branch, then re-run the merger** :
   \`git checkout boucle/$issue && git fetch origin $default_branch && git rebase origin/$default_branch\`
   — take this branch's version of each conflicted file, or the default branch's (\`git checkout origin/$default_branch -- <file>\`), then
   \`git add -A && git rebase --continue && git push --force-with-lease origin boucle/$issue\`
   and restore \`boucle:approval\` (the merger will pick it up).
2. **Let the worker re-plan against fresh $default_branch** (if the issue's goal still stands): set \`boucle:todo\` + \`boucle::status::bot\` — the worker re-baselines and implements the goal on top of the current $default_branch.
3. **Close the issue** if obsolete or contradictory with changes already on $default_branch (MR !$mr_iid closes with it).

The loop is paused on #$issue until you decide."
  # Note BEFORE the terminal label — never a muted boucle:human. Observed on
  # a consumer 2026-08: the label flipped to boucle:human while the note POST
  # was silently swallowed; the human saw a state, no message. If the note
  # cannot be posted, abort WITHOUT escalating — the loop retries instead of
  # stranding a mute escalation.
  if ! forge_issue_note "$issue" "$body"; then
    echo "FAIL: merge-conflict escalation note could not be posted on issue #$issue — NOT escalating to boucle:human (retry instead of muting)." >&2
    return 1
  fi
  set_boucle_label "$issue" "boucle:human" "boucle::status::human"
}

# ── File-impact marker parsing (file gate, MR 1) ──────────────────────
# parse_files_marker <notes_json> — extract the paths from the newest
# `<!-- boucle:files v=1 paths=... -->` marker note.
#
# Pure parser (no forge calls). Input: a JSON array of notes as returned by
# forge_issue_notes (each note has .body and .created_at). Behavior:
#   - Find notes whose body contains the files marker.
#   - Among matching notes, pick the NEWEST by created_at (handles duplicate
#     markers from a failed update — F5).
#   - Extract the comma-separated `paths=` value and echo it.
#   - Malformed marker (no paths=, empty) → echo empty.
#   - No matching note → echo empty.
# Fail-open by construction: an unreadable/absent marker yields empty, which
# the caller treats as "no claim = no gate".
parse_files_marker() {
  local notes_json="$1"
  [ -n "$notes_json" ] || return 0
  local marker_body
  marker_body=$(printf '%s' "$notes_json" \
    | jq -r '[.[] | select(.body | contains("<!-- boucle:files v=1"))] | sort_by(.created_at) | last | .body // empty' \
      2> /dev/null || echo "")
  [ -n "$marker_body" ] || return 0
  local paths
  paths=$(printf '%s' "$marker_body" \
    | grep -oE 'paths=[^ >]+' | head -1 | cut -d= -f2)
  # Filter to safe path characters only (drops malformed junk). A trailing
  # comma from a malformed marker is harmless — the caller's for-loop skips
  # empty entries.
  paths=$(printf '%s' "$paths" | grep -oE '[A-Za-z0-9_./-]+' | paste -sd, -)
  printf '%s' "$paths"
}

# ── Worker rebase-conflict handling (agent-first) ─────────────────────
# Called when `git rebase origin/$CI_DEFAULT_BRANCH` fails inside the
# worker job (setup + pre-build stages). Two modes:
#
#  - Conflict-retry run (BOUCLE_CONFLICT_FEEDBACK set — the merger
#    re-triggered this run after a semantic conflict, see
#    boucle_escalate_merge_conflict): hand the CONFLICTED TREE to the
#    agent instead of aborting. bin/jc's worker prompt injects the
#    conflict context + the supersession rule ("take the default branch's
#    version as the base; if the goal is already covered by the default
#    branch, say so instead of duplicating"). The agent edits the files
#    and `git add`s the resolutions ONLY — the job completes the rebase
#    (continue/skip loop handles empty commits when a resolution makes a
#    commit a no-op). A blind abort+retry can NEVER resolve a semantic
#    conflict — the agent must see the tree (observed on a consumer:
#    MR !88, 5 mechanical retries, zero agent runs).
#
#  - Any other run: bounded abort → re-trigger → escalate (unchanged).
#
# $1: the re-trigger note text with a {ITER} placeholder for the
#     "iteration N/MAX" suffix. Uses the job env: BOUCLE_ISSUE,
#     BOUCLE_ITERATION, BOUCLE_MAX_ITERATIONS, CI_PROJECT_ID,
#     BOUCLE_DEFAULT_BRANCH, BOUCLE_HOME, BOUCLE_CONFLICT_FEEDBACK.
#     Exits the job on the retry/escalate paths.

# ── Dependency gate (lesson #49) ──────────────────────────────────────
# Called by dispatch AND triage (the "ready" path) before chaining the
# worker: an issue whose `## Depends on` deps are still open must park at
# boucle:blocked, never start. Returns 0 (ready) or 1 (blocked — note
# posted + boucle:blocked set). Fail-open: unreadable description or no
# deps → ready. Lives in lib/boucle.sh so EVERY job that calls it gets
# the definition — an inline def in the dispatch job left the triage job
# calling an undefined function: bash "command not found" (exit 127),
# `if ! cmd` → true → the "blocked" branch fired and the worker was
# NEVER chained (observed on a consumer 2026-08: the re-queued issue
# stayed at boucle:todo with no worker pipeline).
check_dependencies_and_gate() {
  local iid="$1"
  local desc deps_iids dep_iid dep_state open_deps
  desc=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$iid" 2> /dev/null \
    | jq -r '.description // empty' 2> /dev/null || echo "")
  [ -z "$desc" ] && return 0 # can't check → don't block (fail open)
  deps_iids=$(parse_depends_on "$desc" 2> /dev/null || echo "")
  [ -z "$deps_iids" ] && return 0 # no deps (or parser unavailable) → not blocked
  open_deps=""
  for dep_iid in $(echo "$deps_iids" | tr ',' ' '); do
    dep_state=$(glab api --hostname "$BOUCLE_FORGE_HOST" "/projects/$CI_PROJECT_ID/issues/$dep_iid" 2> /dev/null \
      | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
    if [ "$dep_state" != "closed" ]; then
      open_deps="${open_deps:+$open_deps,}#$dep_iid ($dep_state)"
    fi
  done
  if [ -n "$open_deps" ]; then
    echo "[boucle] #$iid blocked — waiting on deps: $open_deps"
    # Set boucle:blocked (replaces any boucle:todo). Preserve non-boucle labels.
    set_boucle_label "$iid" "boucle:blocked" "boucle::status::bot"
    # Post explanatory note (idempotent-ish: the unblock path will post a
    # follow-up when deps clear). Use a marker so the note is identifiable.
    local human_list
    human_list=$(echo "$deps_iids" | sed 's/,/, #/g; s/^/#/')
    local blocked_body
    blocked_body=$(printf '⏳ Blocked on sibling sub-issue(s): %s. The worker will start automatically once all of them are closed.\n\n<!-- boucle:blocked v=1 iids=%s -->' "$human_list" "$deps_iids")
    glab api --hostname "$BOUCLE_FORGE_HOST" -X POST "/projects/$CI_PROJECT_ID/issues/$iid/notes" \
      -f body="$blocked_body" > /dev/null 2>&1 || true
    return 1
  fi
  return 0
}

# ── Worker rebase-conflict handling (agent-first) ─────────────────────
# Called when `git rebase origin/$CI_DEFAULT_BRANCH` fails inside the
# worker job (setup + pre-build stages). Two modes:
#
#  - Conflict-retry run (BOUCLE_CONFLICT_FEEDBACK set — the merger
#    re-triggered this run after a semantic conflict, see
#    boucle_escalate_merge_conflict): hand the CONFLICTED TREE to the
#    agent instead of aborting. bin/jc's worker prompt injects the
#    conflict context + the supersession rule ("take the default branch's
#    version as the base; if the goal is already covered by the default
#    branch, say so instead of duplicating"). The agent edits the files
#    and `git add`s the resolutions — it may also complete the rebase
#    itself (cascading conflicts on later commits get the same judgment).
#    A blind abort+retry can NEVER resolve a semantic conflict — the
#    agent must see the tree (observed on a consumer: MR !88, 5
#    mechanical retries, zero agent runs).
#
#  - Any other run: bounded abort → re-trigger → escalate (unchanged).
#
# $1: the re-trigger note text with a {ITER} placeholder for the
#     "iteration N/MAX" suffix. Uses the job env: BOUCLE_ISSUE,
#     BOUCLE_ITERATION, BOUCLE_MAX_ITERATIONS, CI_PROJECT_ID,
#     BOUCLE_DEFAULT_BRANCH, BOUCLE_HOME, BOUCLE_CONFLICT_FEEDBACK.
#     Exits the job on the retry/escalate paths.
boucle_worker_rebase_conflict() {
  local retry_note="$1"
  local iteration="${BOUCLE_ITERATION:-1}"
  local max_iter="${BOUCLE_MAX_ITERATIONS:-5}"
  # Capture the conflicted paths BEFORE any abort clears them — the retry
  # below forwards them as BOUCLE_CONFLICT_FEEDBACK so the NEXT worker run
  # switches to agent-first resolution.
  local conflict_paths
  conflict_paths=$(git diff --name-only --diff-filter=U 2> /dev/null | tr '\n' ';')
  [ -z "$conflict_paths" ] && conflict_paths="unclassified"

  # ── Conflict-retry run: let the agent resolve the conflicted tree ──
  if [ -n "${BOUCLE_CONFLICT_FEEDBACK:-}" ]; then
    echo "[boucle] conflict-retry run — handing the conflicted tree to the agent (BOUCLE_CONFLICT_FEEDBACK)."
    # The agent's exit code is NOT the verdict — the tree state is (it may
    # exhaust its step budget right after resolving, or complete the rebase
    # itself). Loop: agent resolves → continue → if a LATER commit of the
    # rebase hits a NEW conflict, hand the tree back to the agent again
    # (cascading conflicts on subsequent commits need the same judgment).
    local attempt s resolved=false
    for attempt in 1 2 3; do
      if git status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
        if [ "$attempt" -gt 1 ]; then
          echo "[boucle] rebase --continue hit a new conflict — re-running the agent (attempt $attempt/3)."
        fi
        # Bounded per invocation: the resolve must be DECISIVE (inspect,
        # pick a side, continue), not open-ended — a slow agent eats the
        # whole 30m job timeout before the worker's build/push. A kill
        # (exit 124) is fine if the tree is already clean — the tree state
        # below is the verdict.
        timeout "${BOUCLE_CONFLICT_RESOLVE_TIMEOUT:-420}" $BOUCLE_HOME/bin/jc worker \
          || echo "WARN: conflict-resolution agent exited non-zero (or timed out) — checking the tree state..."
        if git status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
          echo "FAIL: conflict markers remain after the agent (attempt $attempt/3) — aborting" >&2
          break
        fi
      fi
      for s in $(seq 1 30); do
        if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
          resolved=true
          break 2
        fi
        if GIT_EDITOR=true git rebase --continue > /dev/null 2>&1; then
          continue
        fi
        if git status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
          break # new conflict → outer loop re-runs the agent
        fi
        if ! GIT_EDITOR=true git rebase --skip > /dev/null 2>&1; then
          echo "FAIL: rebase cannot continue or skip — aborting" >&2
          break 2
        fi
      done
      if [ "$resolved" = "true" ]; then
        break
      fi
    done
    if [ "$resolved" = "true" ]; then
      echo "[boucle] rebase completed after agent resolution."
      return 0
    fi
    git rebase --abort 2> /dev/null || true
  else
    echo "[boucle] Rebase conflicted — aborting, preserving prior worker commits." >&2
    git rebase --abort 2> /dev/null || true
  fi

  # ── Bounded fallback: re-trigger (iter < MAX) or escalate to human ──
  if [ "$iteration" -lt "$max_iter" ]; then
    local issue_state
    issue_state=$(forge_issue_get "$BOUCLE_ISSUE" 2> /dev/null | jq -r '.state // "unknown"' 2> /dev/null || echo "unknown")
    if [ "$issue_state" = "closed" ]; then
      echo "boucle: issue #$BOUCLE_ISSUE is closed — not re-triggering worker after rebase conflict (no-op on closed issue)"
      exit 1
    fi
    local note
    note=$(printf '%s' "$retry_note" | sed "s/{ITER}/$((iteration + 1))\/$max_iter/")
    echo "Re-triggering worker (iteration $((iteration + 1))/$max_iter) — the next run preserves prior worker commits and re-bases again." >&2
    set_boucle_label "$BOUCLE_ISSUE" "boucle:todo" "boucle::status::bot"
    forge_issue_note "$BOUCLE_ISSUE" "$note" > /dev/null 2>&1 || true
    chain_to_role "$BOUCLE_ISSUE" "worker" "BOUCLE_ITERATION=$((iteration + 1))" "BOUCLE_CONFLICT_FEEDBACK=$conflict_paths"
  else
    echo "Escalating to human (boucle:human) — iteration cap ($max_iter) reached after repeated rebase conflicts." >&2
    # Note BEFORE the terminal label — never a muted boucle:human.
    if ! forge_issue_note "$BOUCLE_ISSUE" "⚠️ Worker could not rebase onto $BOUCLE_DEFAULT_BRANCH (conflict) after $max_iter attempts. Master keeps advancing. Human intervention needed."; then
      echo "FAIL: escalation note could not be posted on issue #$BOUCLE_ISSUE — NOT escalating to boucle:human (retry instead of muting)." >&2
      exit 1
    fi
    set_boucle_label "$BOUCLE_ISSUE" "boucle:human" "boucle::status::human"
  fi
  exit 1
}

# ── Shallow-clone depth fix for rebases ─────────────────────────────────
# CI clones are shallow (GIT_DEPTH default 20; the merger CI comment says
# --depth=1). Once the default branch advances past the depth, the merge
# base between boucle/<iid> and origin/<default> sits BEYOND the shallow
# boundary and `git rebase origin/<default>` fails with CONFLICT (add/add)
# on EVERY file — "Rebasing (1/N)" then a wall of Auto-merging + add/add
# conflicts — even when the server-side merge is trivially mergeable
# (framagit 2026-08, MR !61: 3 worker rebase attempts + 1 merger attempt
# all failed this way and the issue escalated to boucle:human). Call this
# AFTER `git fetch origin <refs>` and BEFORE `git rebase`.
boucle_deepen_rebase_fetch() {
  if [ -f .git/shallow ]; then
    echo "[boucle] Shallow clone detected — deepening so rebase can find the merge base..."
    git fetch --unshallow origin 2> /dev/null \
      || git fetch --deepen=1000 origin 2> /dev/null \
      || echo "[boucle] WARN: could not deepen the clone — rebase may fail with add/add conflicts."
  fi
}

# ── Freeride mode helpers ────────────────────────────────────────────────
# has_llm_config: returns 0 if any LLM configuration is available
# (legacy endpoint or at least one freeride provider key). Used by triage
# to detect the no-key condition before launching the agent.
has_llm_config() {
  [ -n "${BOUCLE_LLM_BASE_URL:-}" ] && [ -n "${BOUCLE_LLM_API_KEY:-}" ] && return 0
  for _key_var in BOUCLE_GROQ_API_KEY BOUCLE_NVIDIA_API_KEY \
    BOUCLE_CEREBRAS_API_KEY BOUCLE_ZHIPU_API_KEY BOUCLE_CLOUDFLARE_API_KEY \
    BOUCLE_HUGGINGFACE_API_KEY BOUCLE_MISTRAL_API_KEY; do
    eval "_val=\${${_key_var}:-}"
    [ -n "$_val" ] && return 0
  done
  return 1
}
