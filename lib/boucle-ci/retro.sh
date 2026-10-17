#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC1091,SC2250
# lib/boucle-ci/retro.sh — rétro stage (#139).
#
# The rétro is boucle's return path to itself: a periodic, bounded analysis of
# the loops it already measured (health.jsonl rows on the metrics branch, the
# terminal state of every issue, the lessons) that proposes improvements
# UPSTREAM — anonymised, as a contributor, never as an automatic merge.
#
# This file carries three layers:
#
#   1. POST HELPERS (retro_post_*) — the ONLY way the retro agent is allowed
#      to touch a forge. Every body passes through retro_scrub, and every
#      write is a no-op under BOUCLE_RETRO_DRY_RUN. bin/retro-post is the thin
#      CLI the agent invokes; enforcing this in code (not in the prompt) is
#      the whole point (LESSONS.yml lesson #38).
#   2. THE STAGE (boucle_ci_retro) — guards, window, digest, agent, summary
#      parse, record, anti-accumulation, optional T2 contribution chain.
#   3. THE DOCTOR HOOK (boucle_retro_doctor_chain) — the periodic trigger.
#
# Exit semantics: a rétro failure must NEVER block the next loop run, so every
# step is fail-open (log + exit 0) — EXCEPT the agent invocation itself, whose
# exit 3 (silent failure) / 4 (provider down) is bin/jc's own contract and is
# propagated so the job is visibly red.

# First-ever retro window, in days. A CONSTANT, not a knob: a first run must
# be bounded, and a wider window is never more useful than the next run.
_RETRO_FIRST_WINDOW_DAYS=60
# Per-run bounds. The digest is fed to a 30-step model, not archived.
_RETRO_MAX_ISSUES=40
_RETRO_MAX_CLOSED=30
_RETRO_MAX_LESSONS=10

# ── Post helpers (agent-facing) ───────────────────────────────────────────

# _retro_upstream <fn> [args...]
#
# Call an upstream (= GitHub) forge helper with explicit repo+token. The
# upstream helpers live in bin/forge/github.sh even on a GitLab consumer (the
# upstream is always GitHub, BOUCLE_UPSTREAM_TOKEN is always a GitHub PAT), so
# when the active backend does not define them, load the GitHub backend in a
# SUBSHELL — sourcing it in-process would overwrite the consumer's own
# forge_* functions with GitHub implementations.
_retro_upstream() {
  local fn="$1"
  shift
  if type "$fn" > /dev/null 2>&1; then
    "$fn" "$@"
    return $?
  fi
  (
    # shellcheck source=/dev/null
    source "${BOUCLE_HOME:-.}/bin/forge/github.sh" 2> /dev/null || exit 1
    "$fn" "$@"
  )
}

# _retro_upstream_creds <what>
#
# Resolve repo+token once for a post helper; fail with a message (never
# silently post somewhere else) when no token is available.
_retro_upstream_creds() {
  local what="$1"
  RETRO_UPSTREAM_REPO="${BOUCLE_UPSTREAM_REPO:-ankaboot-source/boucle}"
  RETRO_UPSTREAM_TOKEN=$(retro_upstream_token 2> /dev/null || echo "")
  if [ -z "$RETRO_UPSTREAM_TOKEN" ]; then
    echo "ERROR: no upstream token for $what (set BOUCLE_UPSTREAM_TOKEN — a GitHub PAT with public_repo scope)" >&2
    return 1
  fi
  return 0
}

# retro_post_report <title> <body>
#
# Create the LOCAL rétro report issue (label boucle:retro — the dispatch guard
# skips it). Prints "report=<iid>". The body is scrubbed: even the local
# report may later be quoted upstream, and the agent must never handle an
# unsanitized string in the first place.
retro_post_report() {
  local title="$1" body="$2"
  if [ -z "$title" ]; then
    echo "ERROR: retro_post_report needs a title" >&2
    return 1
  fi
  local scrubbed
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip local report issue"
    return 0
  fi
  # The dispatch guard keys on the label; create it lazily (idempotent,
  # best-effort — bin/setup provisions it on fresh installs).
  forge_label_create "boucle:retro" "#5319E7" > /dev/null 2>&1 || true
  local iid
  iid=$(forge_issue_create "$title" "$scrubbed" "boucle:retro" 2> /dev/null) || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not create the local report issue" >&2
    return 1
  fi
  echo "report=$iid"
}

# retro_post_create <title> <body>
# Create an UPSTREAM proposal issue (label boucle:report — never dispatched
# there either). Prints "created=<iid>".
retro_post_create() {
  local title="$1" body="$2"
  if [ -z "$title" ]; then
    echo "ERROR: retro_post_create needs a title" >&2
    return 1
  fi
  local scrubbed
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip upstream proposal issue"
    return 0
  fi
  _retro_upstream_creds "the upstream proposal" || return 1
  # The upstream anti-loop guard keys on boucle:report EXISTING there. Create
  # it lazily (best-effort: if it already exists the create below still works,
  # if creation is denied the create fails loud instead of posting without
  # the guard).
  _retro_upstream forge_label_create_in "$RETRO_UPSTREAM_REPO" "$RETRO_UPSTREAM_TOKEN" \
    "boucle:report" "#1D76DB" > /dev/null 2>&1 || true
  local iid
  iid=$(_retro_upstream forge_issue_create_in "$RETRO_UPSTREAM_REPO" "$RETRO_UPSTREAM_TOKEN" \
    "$title" "$scrubbed" "boucle:report") || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not create the upstream proposal issue" >&2
    return 1
  fi
  echo "created=$iid"
}

# retro_post_enrich <upstream_iid> <body>
# Comment an anonymised case on an existing upstream proposal. Prints
# "enriched=<iid>". Enrichment is the default over creation (anti-noise).
retro_post_enrich() {
  local iid="$1" body="$2"
  if [ -z "$iid" ]; then
    echo "ERROR: retro_post_enrich needs an upstream issue number" >&2
    return 1
  fi
  local scrubbed
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip upstream enrichment comment on #$iid"
    return 0
  fi
  _retro_upstream_creds "the upstream comment" || return 1
  if ! _retro_upstream forge_issue_note_in "$RETRO_UPSTREAM_REPO" "$RETRO_UPSTREAM_TOKEN" \
    "$iid" "$scrubbed"; then
    echo "ERROR: could not comment on upstream issue #$iid" >&2
    return 1
  fi
  echo "enriched=$iid"
}

# retro_post_pr <title> <head> <base> <body>
# Open the T2 contributor PR upstream. Prints "pr=<iid>".
retro_post_pr() {
  local title="$1" head="$2" base="$3" body="$4"
  if [ -z "$title" ] || [ -z "$head" ] || [ -z "$base" ]; then
    echo "ERROR: retro_post_pr needs a title, a head branch and a base branch" >&2
    return 1
  fi
  local scrubbed
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip upstream pull request"
    return 0
  fi
  _retro_upstream_creds "the upstream pull request" || return 1
  local iid
  iid=$(_retro_upstream forge_pr_create_in "$RETRO_UPSTREAM_REPO" "$RETRO_UPSTREAM_TOKEN" \
    "$title" "$head" "$base" "$scrubbed") || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not open the upstream pull request" >&2
    return 1
  fi
  echo "pr=$iid"
}

# ── Digest (pre-anonymisation build) ──────────────────────────────────────

# _retro_build_digest <out-file> <since-iso>
#
# Assemble the window digest the retro agent reads: one JSON line per issue
# (bounded), window aggregates, closed-issue titles, recent lesson titles and
# the open upstream proposals (dedup/enrichment candidates). The file is
# scrubbed with retro_scrub as it is written — unsanitized consumer identity
# MUST NOT reach the disk, let alone the model.
#
# The data source is the metrics branch, fetched through the working repo's
# own remote (same credential reason as boucle_metrics_git_append): raw
# health rows carry runs/verdicts/setup_failures/models/tokens/cost, the
# metrics rows carry the terminal state.
#
# Returns non-zero only when nothing could be assembled at all.
_retro_build_digest() {
  local out="$1" since="$2"
  local tmp
  tmp=$(mktemp -d 2> /dev/null) || return 1
  local until
  until=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # ── Metrics snapshot ────────────────────────────────────────────────
  local have_metrics=no
  : > "$tmp/metrics.jsonl"
  : > "$tmp/raw-list"
  if git rev-parse --git-dir > /dev/null 2>&1 \
    && git remote get-url origin > /dev/null 2>&1 \
    && git fetch -q --depth 1 origin "$BOUCLE_METRICS_BRANCH" 2> /dev/null; then
    git cat-file -p "FETCH_HEAD:$BOUCLE_METRICS_FILE" > "$tmp/metrics.jsonl" 2> /dev/null || : > "$tmp/metrics.jsonl"
    git ls-tree -r --name-only FETCH_HEAD -- "$BOUCLE_METRICS_RAW_DIR" > "$tmp/raw-list" 2> /dev/null || : > "$tmp/raw-list"
    have_metrics=yes
  fi

  # Which issues are in the window? Newest 40 by terminal timestamp when the
  # metrics rows exist. Without them (an old consumer), fall back to the raw
  # file names — bounded, not ordered by recency, and the digest says so.
  local issue_list=""
  if [ -s "$tmp/metrics.jsonl" ]; then
    issue_list=$(jq -s -r --arg since "$since" --argjson max "$_RETRO_MAX_ISSUES" \
      '[.[] | select((.timestamp // "") >= $since)]
       | sort_by(.timestamp) | reverse | .[0:$max]
       | .[] | .issue // empty' \
      "$tmp/metrics.jsonl" 2> /dev/null || echo "")
  fi
  if [ -z "$issue_list" ]; then
    issue_list=$(sed -n 's|^.*/\([^/]*\)\.jsonl$|\1|p' "$tmp/raw-list" 2> /dev/null \
      | head -n "$_RETRO_MAX_ISSUES" || echo "")
  fi

  # Tag every raw line with its issue (the file name carries it, the lines do
  # not) and jq-assemble one row per issue.
  : > "$tmp/raw.jsonl"
  local iid
  while IFS= read -r iid; do
    [ -n "$iid" ] || continue
    git cat-file -p "FETCH_HEAD:${BOUCLE_METRICS_RAW_DIR}/${iid}.jsonl" 2> /dev/null \
      | jq -c --arg iid "$iid" 'select(type == "object") | . + {issue: $iid}' \
        >> "$tmp/raw.jsonl" 2> /dev/null || true
  done <<< "$issue_list"

  : > "$tmp/rows.jsonl"
  if [ -s "$tmp/raw.jsonl" ]; then
    jq -s -c --slurpfile m "$tmp/metrics.jsonl" '
      group_by(.issue)
      | map(
          (.[0].issue) as $iid
          | {
              issue: $iid,
              runs: ([.[] | select(.iteration != null)] | length),
              iterations: ([.[] | select(.iteration != null) | .iteration] | max // 0),
              terminal: (($m | map(select(.issue == $iid)) | last | .terminal) // "unknown"),
              models: ([.[] | select(.model != null and .model != "") | .model] | unique),
              verdicts: ([.[] | select(.role == "reviewer" or .role == "e2e")
                          | select(.outcome != null) | .outcome] | unique),
              outcomes: ([.[] | select(.outcome != null) | .outcome] | unique),
              setup_failures: ([.[] | select(.setup_fail != null and .setup_fail != "")] | length),
              tokens: ([.[] | select(.tokens != null) | (.tokens | tonumber? // empty)] | add),
              cost_usd: ([.[] | select(.cost_usd != null) | (.cost_usd | tonumber? // empty)] | add),
              first_ts: ([.[] | .timestamp // empty] | min),
              last_ts: ([.[] | .timestamp // empty] | max)
            }
        )
      | sort_by(.last_ts // "")
      | .[]' "$tmp/raw.jsonl" > "$tmp/rows.jsonl" 2> /dev/null \
      || : > "$tmp/rows.jsonl"
  fi

  : > "$tmp/aggregates.json"
  if [ -s "$tmp/rows.jsonl" ]; then
    jq -s -c '
      {
        issues: length,
        terminals: (group_by(.terminal)
          | map({key: (.[0].terminal // "unknown"), value: length}) | from_entries),
        verdicts: (map(.verdicts[]) | group_by(.)
          | map({key: .[0], value: length}) | from_entries),
        escalations: (map(.outcomes[]) | unique
          | map(select(. as $o
              | ["PASS", "FAIL", "UNCERTAIN", "committed", "amended-in-flight", "merged"]
              | index($o) | not))
          | group_by(.) | map({key: .[0], value: length}) | from_entries),
        setup_failures: (map(.setup_failures) | add // 0),
        tokens: (map(.tokens) | add),
        cost_usd: (map(.cost_usd) | add)
      }' "$tmp/rows.jsonl" > "$tmp/aggregates.json" 2> /dev/null \
      || : > "$tmp/aggregates.json"
  fi

  # ── Closed issues in the window (titles only) ────────────────────────
  local closed_block=""
  local closed_json
  closed_json=$(forge_issue_list_all closed 2> /dev/null || echo "[]")
  closed_block=$(printf '%s' "$closed_json" | jq -r --arg since "$since" --argjson max "$_RETRO_MAX_CLOSED" '
    [.[] | select((.pull_request // null) == null)
     | {iid: (.iid // .number), title: (.title // ""), closed: (.closed_at // "")}
     | select(.closed >= $since)]
    | sort_by(.closed) | reverse | .[0:$max]
    | .[] | "- #\(.iid) \(.title)"' 2> /dev/null || echo "")

  # ── Recent lesson titles ──────────────────────────────────────────────
  local lessons_block="" lessons_file=""
  local f
  for f in "${BOUCLE_WORKSPACE:-.}/LESSONS.yml" "${BOUCLE_HOME:-}/LESSONS.yml"; do
    if [ -f "$f" ]; then
      lessons_file="$f"
      break
    fi
  done
  if [ -n "$lessons_file" ]; then
    lessons_block=$(awk '
      /^[0-9]+:/ { num = $0; sub(/:.*/, "", num) }
      /^  title:/ { sub(/^  title:[[:space:]]*/, ""); print num ": " $0 }
    ' "$lessons_file" 2> /dev/null | tail -n "$_RETRO_MAX_LESSONS" || echo "")
  fi

  # ── Open upstream proposals (enrichment candidates) ──────────────────
  local upstream_block=""
  if retro_upstream_ready; then
    local upstream_token
    upstream_token=$(retro_upstream_token 2> /dev/null || echo "")
    upstream_block=$(forge_issue_list_in \
      "${BOUCLE_UPSTREAM_REPO:-ankaboot-source/boucle}" "$upstream_token" \
      "boucle:report" 2> /dev/null || echo "")
  fi

  # ── Assemble + scrub ──────────────────────────────────────────────────
  {
    echo "# Rétro window digest"
    echo
    echo "Window: $since → $until"
    echo "Data source: $BOUCLE_METRICS_BRANCH (fetched: $have_metrics; $(wc -l < "$tmp/rows.jsonl" 2> /dev/null | tr -d ' ') issue rows, bounded to $_RETRO_MAX_ISSUES)"
    echo "Anonymisation: every consumer identifier is ALREADY replaced by retro_scrub — [consumer], [host], [user], [email], boucle/N-. Do not try to de-anonymise; the generics are the data."
    echo
    echo "## Per-issue rows (oldest → newest)"
    if [ -s "$tmp/rows.jsonl" ]; then
      cat "$tmp/rows.jsonl"
    else
      echo "(none — no metrics data in this window)"
    fi
    echo
    echo "## Window aggregates"
    if [ -s "$tmp/aggregates.json" ]; then
      cat "$tmp/aggregates.json"
    else
      echo "{}"
    fi
    echo
    echo "## Closed issues in the window (titles only)"
    if [ -n "$closed_block" ]; then
      echo "$closed_block"
    else
      echo "(none)"
    fi
    echo
    echo "## Recent lesson titles (last $_RETRO_MAX_LESSONS)"
    if [ -n "$lessons_block" ]; then
      echo "$lessons_block"
    else
      echo "(none)"
    fi
    echo
    echo "## Open upstream proposals (boucle:report — enrich these instead of duplicating)"
    if [ -n "$upstream_block" ]; then
      echo "$upstream_block"
    else
      echo "(none)"
    fi
    echo
    echo "## Legend"
    echo "- terminal: done | human (from the metrics row); unknown when no metrics row exists."
    echo "- verdicts: reviewer/e2e outcomes. escalations: the non-verdict outcome signals (build-fail, no-changes, not-mergeable, ...)."
    echo "- tokens / cost_usd: null when no run reported a number — never a fake zero."
    echo "- issue numbers and branch prefixes are anonymised by the scrub; a 'N' in a branch is not an IID."
  } | retro_scrub > "$out" 2> /dev/null || return 1
  [ -s "$out" ] || return 1

  rm -rf "$tmp"
  return 0
}

# ── Summary parsing + bookkeeping ─────────────────────────────────────────

# _retro_summary_values <agent-log> <key>
#
# Read the pinned machine-readable tail the agent printed:
#   [boucle:retro] summary: created=<iid> enriched=<iid> report=<iid> implementable=<iid|none>
# `created=`/`enriched=` may repeat; values come back comma-separated. Uses
# the LAST summary line (a step-exhausted agent may have printed several).
_retro_summary_values() {
  local log="$1" key="$2"
  [ -f "$log" ] || return 0
  grep -E '^\[boucle:retro\] summary:' "$log" 2> /dev/null | tail -n 1 \
    | grep -oE "${key}=[^ ]+" 2> /dev/null | cut -d= -f2- \
    | sort -u | paste -sd, - 2> /dev/null || true
}

# _retro_count_values <csv>
# Count non-"none" values in a comma-separated list.
_retro_count_values() {
  case "${1:-}" in
    '' | none) echo 0 ;;
    *) printf '%s' "$1" | tr ',' '\n' | grep -c . 2> /dev/null || echo 0 ;;
  esac
}

# _retro_record <since> <report> <created> <enriched> <implementable>
# Append the run record to retros.jsonl on the metrics branch. This log is
# the trigger's only state; a failure is logged and swallowed.
_retro_record() {
  local since="$1" report="$2" created="$3" enriched="$4" implementable="$5"
  local created_n enriched_n
  created_n=$(_retro_count_values "$created")
  enriched_n=$(_retro_count_values "$enriched")
  local line
  line=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg window "$since" \
    --arg report "$report" \
    --arg implementable "$implementable" \
    --argjson created "$created_n" \
    --argjson enriched "$enriched_n" \
    '{schema: 1, timestamp: $ts, window: $window, created: $created,
      enriched: $enriched, report: $report, implementable: $implementable,
      dry_run: false}' 2> /dev/null) || return 1
  if retro_record_run "$line"; then
    echo "[retro] recorded the run on $BOUCLE_METRICS_BRANCH:$BOUCLE_RETRO_FILE"
  else
    echo "[retro] WARN: could not record the run — the next retro may repeat this window" >&2
  fi
  return 0
}

# _retro_close_previous_reports <keep-iid>
# Anti-accumulation: the local report issue is one per run, so the new run
# closes the previous ones. The report just created (from the summary) is
# kept; without one, the newest by created_at is.
_retro_close_previous_reports() {
  local keep="${1:-}"
  local list
  list=$(forge_issue_list_by_label "boucle:retro" all 2> /dev/null || echo "[]")
  [ -n "$list" ] || return 0
  local newest
  newest=$(printf '%s' "$list" | jq -r 'sort_by(.created_at // "") | reverse | .[0] | (.iid // .number // empty)' 2> /dev/null || echo "")
  case "$keep" in '' | none) ;; *) newest="$keep" ;; esac
  [ -n "$newest" ] || return 0

  local iid
  printf '%s' "$list" | jq -r --arg keep "$newest" '
    .[] | select((.state // "opened") != "closed")
    | (.iid // .number | tostring) | select(. != $keep) | .' 2> /dev/null \
    | while IFS= read -r iid; do
      [ -n "$iid" ] || continue
      if forge_issue_close "$iid" 2> /dev/null; then
        echo "[retro] closed previous report #$iid"
      fi
    done
  return 0
}

# ── T2: bounded contribution chain ────────────────────────────────────────

# _retro_slugify <text>
_retro_slugify() {
  local slug
  slug=$(printf '%s' "${1:-proposal}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' 2> /dev/null \
    | cut -c1-40)
  [ -n "$slug" ] || slug="proposal"
  printf '%s\n' "$slug"
}

# _retro_prepare_workspace <repo> <token> <slug>
#
# Clone the upstream shallowly into .boucle-state/retro-workspace/, wire the
# PUSH credential (extraheader in the clone's local config — the token never
# enters the remote URL, so it cannot leak through `git remote -v` or the
# agent transcript), create the retro/<slug> branch and print the path.
_retro_prepare_workspace() {
  local repo="$1" token="$2" slug="$3"
  local ws="${BOUCLE_WORKSPACE:-.}/.boucle-state/retro-workspace"
  rm -rf "$ws" 2> /dev/null || true
  mkdir -p "$(dirname "$ws")" 2> /dev/null || true
  if ! git clone -q --depth 1 "https://github.com/${repo}.git" "$ws" 2> /dev/null; then
    return 1
  fi
  local b64
  b64=$(printf 'x-access-token:%s' "$token" | base64 2> /dev/null | tr -d '\n')
  [ -n "$b64" ] && git -C "$ws" config --local "http.https://github.com/.extraheader" \
    "Authorization: Basic $b64" 2> /dev/null || true
  git -C "$ws" config user.name "${BOUCLE_BOT_NAME:-boucle}" 2> /dev/null || true
  git -C "$ws" config user.email "${BOUCLE_BOT_EMAIL:-boucle@localhost}" 2> /dev/null || true
  git -C "$ws" checkout -q -b "retro/${slug}" 2> /dev/null || return 1
  _RETRO_T2_WORKSPACE="$ws"
  printf '%s\n' "$ws"
}

# _retro_t2_cleanup — remove the T2 workspace on exit.
_retro_t2_cleanup() {
  [ -n "${_RETRO_T2_WORKSPACE:-}" ] && rm -rf "$_RETRO_T2_WORKSPACE" 2> /dev/null || true
}

# _retro_t2_chain <upstream-iid>
#
# T2: implement the proposal as a bounded contributor. Never fatal — an
# upstream push/PR failure degrades to "issue + plan remains", which is the
# documented outcome for a token without write access.
_retro_t2_chain() {
  local iid="${1:-}"
  retro_contribute_enabled || return 0
  case "$iid" in '' | none) return 0 ;; esac

  local repo="${BOUCLE_UPSTREAM_REPO:-ankaboot-source/boucle}"
  local token
  token=$(retro_upstream_token 2> /dev/null || echo "")
  [ -n "$token" ] || {
    echo "[retro] T2 skipped: no upstream token" >&2
    return 0
  }

  local issue_json title body slug
  issue_json=$(_retro_upstream forge_issue_get_in "$repo" "$token" "$iid" 2> /dev/null || echo "")
  if [ -z "$issue_json" ]; then
    echo "[retro] WARN: could not read upstream issue #$iid — T2 skipped (issue+plan remains)" >&2
    return 0
  fi
  title=$(printf '%s' "$issue_json" | jq -r '.title // empty' 2> /dev/null || echo "")
  body=$(printf '%s' "$issue_json" | jq -r '.description // .body // empty' 2> /dev/null || echo "")
  slug=$(_retro_slugify "$title")

  local ws
  if ! ws=$(_retro_prepare_workspace "$repo" "$token" "$slug" 2> /dev/null); then
    echo "[retro] WARN: could not prepare the upstream workspace — T2 skipped (issue+plan remains)" >&2
    return 0
  fi
  trap '_retro_t2_cleanup' EXIT

  local base
  base=$(git -C "$ws" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null | sed 's|^origin/||' || echo "")
  [ -n "$base" ] || base="${BOUCLE_DEFAULT_BRANCH:-main}"

  export BOUCLE_RETRO_WORKSPACE="$ws"
  export BOUCLE_RETRO_UPSTREAM_ISSUE="$iid"
  export BOUCLE_RETRO_BRANCH="retro/${slug}"
  local proposal
  proposal="Upstream issue: #$iid
Upstream clone: $ws
Branch: retro/$slug (already checked out)
PR base: $base

Proposal (already anonymised — keep it that way):
$(printf '%s' "$body" | retro_scrub)"
  export BOUCLE_RETRO_PROPOSAL="$proposal"

  echo "[retro] T2: implementing #$iid as retro/$slug (bounded contributor)"
  export BOUCLE_ROLE=retro-impl
  local rc=0
  "$BOUCLE_HOME/bin/jc" retro-impl || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[retro] WARN: retro-impl exited $rc — T2 fail-open (the upstream issue+plan remains)" >&2
  fi
  return 0
}

# ── Doctor hook ───────────────────────────────────────────────────────────

# boucle_retro_doctor_chain
#
# The periodic trigger, called by the doctor after boucle_schedules_run. The
# stage re-checks the threshold under its resource group, so a stale decision
# here can never double-fire. The pseudo-iid "retro" rides the trigger
# variables: the retro job needs no BOUCLE_ISSUE, and a non-numeric value
# cannot collide with a real issue.
boucle_retro_doctor_chain() {
  [ "${BOUCLE_ENABLED:-}" = "true" ] || return 0
  retro_enabled || return 0
  retro_upstream_ready || return 0
  retro_threshold_reached || return 0
  echo "  → rétro due — chaining the retro stage"
  chain_to_role "retro" "retro"
}

# ── Stage ──────────────────────────────────────────────────────────────────

boucle_ci_retro() {
  # ── Guards ─────────────────────────────────────────────────────────────
  if [ "${BOUCLE_ENABLED:-}" != "true" ]; then
    echo "[retro] BOUCLE_ENABLED is not 'true' — retro stage disabled" >&2
    exit 0
  fi
  if ! retro_enabled; then
    echo "[retro] BOUCLE_RETRO_ENABLED=${BOUCLE_RETRO_ENABLED:-} — retro disabled" >&2
    exit 0
  fi
  if ! retro_upstream_ready; then
    # Enabled but no usable upstream token. Normal on a consumer that has not
    # decided to participate: skip cleanly, no WARN per sweep — the operator
    # advisory lives in bin/doctor --audit.
    echo "[retro] no upstream token — retro skipped (bin/doctor --audit reports it)" >&2
    exit 0
  fi
  # Idempotence against the doctor's stale pre-check: the doctor may chain
  # this stage moments after a previous retro recorded its run. The
  # resource_group boucle-retro serializes the jobs; this re-check makes the
  # later one a no-op.
  if ! retro_threshold_reached; then
    echo "[retro] threshold not reached — nothing to do" >&2
    exit 0
  fi

  local dry=no
  if retro_dry_run; then
    dry=yes
    echo "[retro] dry-run: analysis only, no writes"
  fi

  # ── Window ─────────────────────────────────────────────────────────────
  local last since
  last=$(retro_last_run_read 2> /dev/null || echo "")
  if [ -n "$last" ]; then
    since="$last"
  else
    since=$(date -u -d "$_RETRO_FIRST_WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null \
      || echo "1970-01-01T00:00:00Z")
  fi
  echo "[retro] window since=$since"

  # ── Digest ─────────────────────────────────────────────────────────────
  local digest_dir="$BOUCLE_WORKSPACE/.boucle-state/retro"
  mkdir -p "$digest_dir" 2> /dev/null || true
  local digest="$digest_dir/digest.md"
  if ! _retro_build_digest "$digest" "$since"; then
    echo "[retro] WARN: could not build the window digest — retro skipped, the loop is unaffected" >&2
    exit 0
  fi
  export BOUCLE_RETRO_DIGEST="$digest"
  export BOUCLE_ROLE=retro
  # The retro job carries no issue: clear any pseudo-iid the CI shim passed,
  # so the agent log lands at a deterministic path (bin/jc keys it on it).
  export BOUCLE_ISSUE=""
  local digest_size
  digest_size=$(wc -c < "$digest" 2> /dev/null || echo 0)
  echo "[retro] digest=$digest (${digest_size} bytes)"

  # ── Agent ───────────────────────────────────────────────────────────────
  if [ ! -x "$BOUCLE_HOME/bin/jc" ]; then
    echo "[retro] WARN: $BOUCLE_HOME/bin/jc not executable — retro skipped (fail-open)" >&2
    exit 0
  fi
  local rc=0
  "$BOUCLE_HOME/bin/jc" retro || rc=$?
  if [ "$rc" -ne 0 ]; then
    # bin/jc's own contract: 3 = silent failure, 4 = provider down. The stage
    # has no issue to escalate on; propagate so the job is red.
    echo "[retro] agent exited $rc (bin/jc silent-failure/provider contract) — bookkeeping skipped" >&2
    exit "$rc"
  fi

  # ── Summary tail ────────────────────────────────────────────────────────
  local agent_log="$BOUCLE_WORKSPACE/.boucle-state/agent-output.log"
  local created enriched report implementable
  created=$(_retro_summary_values "$agent_log" created)
  enriched=$(_retro_summary_values "$agent_log" enriched)
  report=$(_retro_summary_values "$agent_log" report | head -1)
  implementable=$(_retro_summary_values "$agent_log" implementable | head -1)

  # ── Bookkeeping (all fail-open) ──────────────────────────────────────────
  if [ "$dry" = "yes" ]; then
    echo "[retro] dry-run: skip retros.jsonl record"
    echo "[retro] dry-run: skip closing the previous report"
    echo "[retro] dry-run: skip T2 contribution"
  else
    _retro_record "$since" "${report:-}" "$created" "$enriched" "${implementable:-}" || true
    _retro_close_previous_reports "${report:-}" || true
    case "$implementable" in
      '' | none)
        echo "[retro] no implementable proposal — T2 not applicable"
        ;;
      *)
        if retro_contribute_enabled; then
          _retro_t2_chain "$implementable" || true
        else
          echo "[retro] T2 disabled for this repo — issue+plan only"
        fi
        ;;
    esac
  fi

  echo "[retro] result: created=${created:-none} enriched=${enriched:-none} report=${report:-none} implementable=${implementable:-none}"
  exit 0
}
