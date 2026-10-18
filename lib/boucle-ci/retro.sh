#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC1091,SC2250
# lib/boucle-ci/retro.sh — retro stage (#139).
#
# The retro is boucle's return path to itself: a periodic, bounded analysis of
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
# Exit semantics: a retro failure must NEVER block the next loop run, so every
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
# How many of the issues the window could not measure are NAMED in the
# metrics_coverage line. The count is always exact; the names are bounded so
# the line stays one line.
_RETRO_MAX_MISSING_IDS=8

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
# Create the LOCAL retro report issue (label boucle:retro — the dispatch guard
# skips it). Prints "report=<iid>". The body is scrubbed: even the local
# report may later be quoted upstream, and the agent must never handle an
# unsanitized string in the first place.
retro_post_report() {
  local title="$1" body="$2"
  if [ -z "$title" ]; then
    echo "ERROR: retro_post_report needs a title" >&2
    return 1
  fi
  # The TITLE is agent free-text too — scrub it like the body (B3). The
  # digest carries consumer issue titles, so a title is a real leak surface.
  local scrubbed scrubbed_title
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  scrubbed_title=$(printf '%s' "$title" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip local report issue"
    return 0
  fi
  # The dispatch guard keys on the label; create it lazily (idempotent,
  # best-effort — bin/setup provisions it on fresh installs).
  forge_label_create "boucle:retro" "#5319E7" > /dev/null 2>&1 || true
  local iid
  iid=$(forge_issue_create "$scrubbed_title" "$scrubbed" "boucle:retro" 2> /dev/null) || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not create the local report issue" >&2
    return 1
  fi
  echo "[retro-post] report=$iid"
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
  local scrubbed scrubbed_title
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  scrubbed_title=$(printf '%s' "$title" | retro_scrub)
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
    "$scrubbed_title" "$scrubbed" "boucle:report") || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not create the upstream proposal issue" >&2
    return 1
  fi
  echo "[retro-post] created=$iid"
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
  echo "[retro-post] enriched=$iid"
}

# retro_post_pr <title> <head> <base> <body>
# Open the T2 contributor PR upstream. Prints "pr=<iid>".
retro_post_pr() {
  local title="$1" head="$2" base="$3" body="$4"
  if [ -z "$title" ] || [ -z "$head" ] || [ -z "$base" ]; then
    echo "ERROR: retro_post_pr needs a title, a head branch and a base branch" >&2
    return 1
  fi
  # head/base are not free text — validate the branch charset instead of
  # scrubbing them (a branch name is structural; a scrub would corrupt it).
  case "$head" in
    *[!A-Za-z0-9._/-]*)
      echo "ERROR: invalid head branch name '$head'" >&2
      return 1
      ;;
  esac
  case "$base" in
    *[!A-Za-z0-9._/-]*)
      echo "ERROR: invalid base branch name '$base'" >&2
      return 1
      ;;
  esac
  local scrubbed scrubbed_title
  scrubbed=$(printf '%s' "$body" | retro_scrub)
  scrubbed_title=$(printf '%s' "$title" | retro_scrub)
  if retro_dry_run; then
    echo "[retro] dry-run: skip upstream pull request"
    return 0
  fi
  _retro_upstream_creds "the upstream pull request" || return 1
  local iid
  iid=$(_retro_upstream forge_pr_create_in "$RETRO_UPSTREAM_REPO" "$RETRO_UPSTREAM_TOKEN" \
    "$scrubbed_title" "$head" "$base" "$scrubbed") || iid=""
  if [ -z "$iid" ]; then
    echo "ERROR: could not open the upstream pull request" >&2
    return 1
  fi
  echo "[retro-post] pr=$iid"
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
# The digest cross-checks its own completeness: a window with closed issues but
# ZERO metrics rows is a HOLLOW retro (the primary evidence layer is missing and
# the digest would otherwise render clean), so it carries an explicit, greppable
# `WARNING: metrics blackout` banner. A failed fetch and a fetch that returned no
# rows are reported with distinct wording — different root causes.
#
# Returns non-zero only when nothing could be assembled at all.
# _retro_renumber_map — stdin: one consumer IID per line, in order of first
# appearance; stdout: "<old>\t#<new>" lines. Deterministic per window. The
# digest must never carry a raw consumer issue number (S3): the renumbering
# is the code-enforced part, retro_scrub cannot know which integers are IIDs.
_retro_renumber_map() {
  awk 'NF && !seen[$0]++ { printf "%s\t#%d\n", $0, ++n }'
}

_retro_build_digest() {
  local out="$1" since="$2"
  local tmp
  tmp=$(mktemp -d 2> /dev/null) || return 1
  local until
  until=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # ── Metrics snapshot ────────────────────────────────────────────────
  # THREE states, not two, because "the collector wrote nothing" and "the fetch
  # failed" have different root causes and the digest MUST say which one. A
  # hollow window renders clean otherwise (the blackout banner below is what
  # makes it loud):
  #   metrics_fetch=no            → branch / credential / remote missing
  #   metrics_fetch=yes, 0 rows   → collector unwired or never ran
  #   metrics_fetch=yes, N rows   → normal
  local metrics_fetch=no metrics_rows=0 metrics_window_rows=0 metrics_last_ts=""
  : > "$tmp/metrics.jsonl"
  : > "$tmp/raw-list"
  if git rev-parse --git-dir > /dev/null 2>&1 \
    && git remote get-url origin > /dev/null 2>&1 \
    && git fetch -q --depth 1 origin "$BOUCLE_METRICS_BRANCH" 2> /dev/null; then
    git cat-file -p "FETCH_HEAD:$BOUCLE_METRICS_FILE" > "$tmp/metrics.jsonl" 2> /dev/null || : > "$tmp/metrics.jsonl"
    git ls-tree -r --name-only FETCH_HEAD -- "$BOUCLE_METRICS_RAW_DIR" > "$tmp/raw-list" 2> /dev/null || : > "$tmp/raw-list"
    metrics_fetch=yes
  fi
  if [ -s "$tmp/metrics.jsonl" ]; then
    metrics_rows=$(jq -s 'length' "$tmp/metrics.jsonl" 2> /dev/null || echo 0)
    metrics_window_rows=$(jq -s --arg since "$since" \
      '[.[] | select((.timestamp // "") >= $since)] | length' \
      "$tmp/metrics.jsonl" 2> /dev/null || echo 0)
    # Last-seen row, NOT last window row: it tells "collector stopped at X"
    # apart from "collector never ran" in a window where the slice is empty.
    metrics_last_ts=$(jq -s -r '[.[] | .timestamp // empty] | max // ""' \
      "$tmp/metrics.jsonl" 2> /dev/null || echo "")
    # A jq parse error can still emit partial output, so coerce the counts back
    # to integers: a count is compared with -eq, never trusted as text (the
    # `grep -c` "0\n0" class of bug).
    case "$metrics_rows" in '' | *[!0-9]*) metrics_rows=0 ;; esac
    case "$metrics_window_rows" in '' | *[!0-9]*) metrics_window_rows=0 ;; esac
  fi

  # Which issues are in the window? Newest 40 by terminal timestamp when the
  # metrics rows exist. Without them (an old consumer), fall back to the raw
  # file names — bounded, not ordered by recency, and the digest says so.
  local issue_list="" issue_list_source=metrics
  if [ -s "$tmp/metrics.jsonl" ]; then
    issue_list=$(jq -s -r --arg since "$since" --argjson max "$_RETRO_MAX_ISSUES" \
      '[.[] | select((.timestamp // "") >= $since)]
       | sort_by(.timestamp) | reverse | .[0:$max]
       | .[] | .issue // empty' \
      "$tmp/metrics.jsonl" 2> /dev/null || echo "")
  fi
  if [ -z "$issue_list" ]; then
    issue_list_source=raw
    issue_list=$(sed -n 's|^.*/\([^/]*\)\.jsonl$|\1|p' "$tmp/raw-list" 2> /dev/null \
      | head -n "$_RETRO_MAX_ISSUES" || echo "")
  fi

  # Tag every raw line with its issue (the file name carries it, the lines do
  # not) and jq-assemble one row per issue. Each row also carries `gaps`: what
  # it could NOT measure, in the same vocabulary as the row's telemetry_gap on
  # the metrics branch. Without it the reader cannot tell an empty `verdicts`
  # array (no gate outcome recorded — the gates are invisible) from a `cost_usd`
  # null (no pricing configured — the money is unknown), and both read as
  # findings about the loop when neither is one.
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
          | ([.[] | select(.iteration != null)] | length) as $runs
          | ([.[] | select(.model != null and .model != "") | .model] | unique) as $models
          | ([.[] | select(.role == "reviewer" or .role == "e2e")
              | select(.outcome != null) | .outcome] | unique) as $verdicts
          # `tonumber?` takes a number or a numeric string and drops the
          # "n/a" the health writer records for a value nobody reported.
          | ([.[] | select(has("tokens")) | (.tokens | tonumber? // empty)] | add) as $tokens
          | ([.[] | select(has("cost_usd")) | (.cost_usd | tonumber? // empty)] | add) as $cost
          | (($m | map(select(.issue == $iid)) | last | .terminal) // "unknown") as $terminal
          | [
              (if $runs == 0 then "no_runs" else empty end),
              (if ($models | length) == 0 then "model_unavailable" else empty end),
              (if $tokens == null then "tokens_unavailable" else empty end),
              (if $cost == null then "cost_unavailable" else empty end),
              (if ($verdicts | length) == 0 and $runs > 0 then "verdict_missing" else empty end),
              (if $terminal == "unknown" then "terminal_unknown" else empty end)
            ] as $gaps
          | {
              issue: $iid,
              runs: $runs,
              iterations: ([.[] | select(.iteration != null) | .iteration] | max // 0),
              terminal: $terminal,
              models: $models,
              verdicts: $verdicts,
              outcomes: ([.[] | select(.outcome != null) | .outcome] | unique),
              setup_failures: ([.[] | select(.setup_fail != null and .setup_fail != "")] | length),
              tokens: $tokens,
              cost_usd: $cost,
              gaps: $gaps,
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
        cost_usd: (map(.cost_usd) | add),
        # The window-level version of what the per-row gaps say, because an
        # aggregate hides exactly this: `verdicts: {}` alone cannot tell "no
        # gate ever ran" from "no gate outcome was ever recorded".
        issues_with_verdicts: (map(select((.verdicts // []) | length > 0)) | length),
        rows_with_gaps: (map(select((.gaps // []) | length > 0)) | length),
        gap_counts: (map(.gaps // []) | add // [] | group_by(.)
                     | map({key: .[0], value: length}) | from_entries)
      }' "$tmp/rows.jsonl" > "$tmp/aggregates.json" 2> /dev/null \
      || : > "$tmp/aggregates.json"
  fi

  # ── Closed issues in the window (titles only) ────────────────────────
  # closed_window keeps the WHOLE window; closed_items is the bounded slice
  # the digest prints (#156): the coverage reconciliation needs the full
  # denominator — a ratio computed against a truncated one would report a gap
  # that is an artefact of the bound. closed_count is the UNBOUNDED in-window
  # count (#153): the blackout banner needs the true size of the window, not
  # the bounded slice.
  local closed_block="" closed_items="[]" closed_window="[]" closed_count=0
  local closed_json
  closed_json=$(forge_issue_list_all closed 2> /dev/null || echo "[]")
  closed_window=$(printf '%s' "$closed_json" | jq -c --arg since "$since" '
    [.[] | select((.pull_request // null) == null)
     | {iid: ((.iid // .number) | tostring), title: (.title // ""), closed: (.closed_at // "")}
     | select(.closed >= $since)]
    | sort_by(.closed) | reverse' 2> /dev/null || echo "[]")
  closed_items=$(printf '%s' "$closed_window" | jq -c --argjson max "$_RETRO_MAX_CLOSED" '.[0:$max]' 2> /dev/null || echo "[]")
  closed_count=$(printf '%s' "$closed_json" | jq -r --arg since "$since" '
    [.[] | select((.pull_request // null) == null) | select((.closed_at // "") >= $since)] | length' \
    2> /dev/null || echo 0)
  case "$closed_count" in '' | *[!0-9]*) closed_count=0 ;; esac

  # ── Anonymise consumer IIDs (S3) ─────────────────────────────────────
  # Renumber #1..#N in order of first appearance (per-issue rows
  # oldest→newest, then closed issues newest→oldest). Deterministic, and the
  # digest can no longer claim an anonymisation it does not perform.
  local map_tsv map_json
  map_tsv=$(
    {
      jq -r '.issue // empty' "$tmp/rows.jsonl" 2> /dev/null || true
      printf '%s' "$closed_window" | jq -r '.[].iid // empty' 2> /dev/null || true
    } | _retro_renumber_map
  )
  map_json=$(printf '%s' "$map_tsv" | jq -Rn '[inputs | split("\t")] | map({key: .[0], value: .[1]}) | from_entries' 2> /dev/null || echo "{}")
  # ── Metrics coverage reconciliation ──────────────────────────────────
  # Coverage is the digest's own blind spot, quantified instead of inferred.
  # A window holding 3 rows for 33 closed issues reads as "the gates never
  # ran" when the honest reading is "30 runs emitted no measurement at all":
  # the question the retro must answer ("did review run?") was unanswerable
  # for lack of ROWS, not for lack of verdicts. `usable` excludes the coverage
  # rows a terminal transition writes when it has no health log (coverage:
  # no-data) — those ARE the gap, counting them as rows would report full
  # coverage of a window that measured nothing.
  local coverage_line="" closed_ids="[]"
  closed_ids=$(printf '%s' "$closed_window" | jq -c '[.[].iid]' 2> /dev/null || echo "[]")
  coverage_line=$(jq -n -r \
    --arg since "$since" \
    --arg fetched "$metrics_fetch" \
    --argjson map "$map_json" \
    --argjson named_max "$_RETRO_MAX_MISSING_IDS" \
    --argjson closed "$closed_ids" \
    --slurpfile m "$tmp/metrics.jsonl" '
    ($m | map(select((.timestamp // "") >= $since))) as $window
    | ($window | map(select(((.telemetry_gap // []) | index("no_health_data")) == null)
                     | (.issue | tostring))) as $usable
    | ($window | map(select(((.telemetry_gap // []) | index("no_health_data")) != null))
       | length) as $nodata
    # Dedupe WITHOUT `unique`, which sorts: the closed list is newest-first and
    # the named gaps must keep that order, or the reader has to re-sort them to
    # find the recent ones.
    | (reduce $closed[] as $i ([]; if index($i) then . else . + [$i] end)) as $c
    | ($c | map(select(. as $i | ($usable | index($i)) != null))) as $covered
    | ($c | map(select(. as $i | ($usable | index($i)) == null))) as $missing
    # Only RENUMBERED ids are ever printed: an unmapped integer is a consumer
    # IID and the digest must never carry one (S3).
    | ($missing | map($map[.]) | map(select(. != null))) as $named
    | "metrics_coverage: \($covered | length)/\($c | length)"
      + " (usable metrics rows / closed issues in the window; without a row: "
      + (if ($missing | length) == 0 then "none"
         elif ($named | length) == 0 then "\($missing | length) (unmapped, omitted)"
         else (($named[0:$named_max] | join(" "))
               + (if ($missing | length) > $named_max
                  then " (+\(($missing | length) - $named_max) more)" else "" end))
         end)
      + (if $nodata > 0 then "; coverage rows: \($nodata)" else "" end)
      + (if $fetched == "yes" then ")" else "; metrics branch NOT fetched)" end)' \
    2> /dev/null || echo "")
  if [ -z "$coverage_line" ]; then
    coverage_line="metrics_coverage: unavailable (the reconciliation could not be computed — treat EVERY number below as an undercount)"
  fi

  : > "$tmp/rows.out.jsonl"
  if [ -s "$tmp/rows.jsonl" ]; then
    jq -c --argjson map "$map_json" '.issue = ($map[.issue] // .issue)' \
      "$tmp/rows.jsonl" > "$tmp/rows.out.jsonl" 2> /dev/null \
      || cp "$tmp/rows.jsonl" "$tmp/rows.out.jsonl" 2> /dev/null || true
  fi
  closed_block=$(printf '%s' "$closed_items" | jq -r --argjson map "$map_json" \
    '.[] | "- \($map[.iid] // "#\(.iid)") \(.title)"' 2> /dev/null || echo "")

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
  # A blackout is `closed issues in the window` with `0 metrics rows in the same
  # window`. Genuinely inactive consumers stay silent: both sides zero is not a
  # blackout, it is a quiet window.
  local blackout=no
  if [ "$closed_count" -gt 0 ] && [ "$metrics_window_rows" -eq 0 ]; then
    blackout=yes
  fi
  local digest_rows fetch_label last_label list_label
  digest_rows=$(wc -l < "$tmp/rows.out.jsonl" 2> /dev/null | tr -d ' ')
  case "$digest_rows" in '' | *[!0-9]*) digest_rows=0 ;; esac
  case "$metrics_fetch" in
    yes)
      if [ "$metrics_rows" -gt 0 ]; then
        # Distinguish "fetched with rows" from "fetched, 0 rows": the first is
        # normal, the second means the collector is unwired (or never ran).
        fetch_label="fetched: yes"
      else
        fetch_label="fetched: yes, 0 rows on the branch — collector unwired or never ran"
      fi
      ;;
    *)
      fetch_label="fetch failed — $BOUCLE_METRICS_BRANCH unavailable (branch, credential or remote missing)"
      ;;
  esac
  last_label="${metrics_last_ts:-never}"
  if [ "$issue_list_source" = raw ]; then
    list_label="raw file names (metrics-window list empty)"
  else
    list_label="metrics window"
  fi
  {
    echo "# Retro window digest"
    echo
    echo "Window: $since → $until"
    echo "Data source: $BOUCLE_METRICS_BRANCH ($fetch_label; metrics rows: $metrics_window_rows in window, $metrics_rows on branch; issue rows: $digest_rows, bounded to $_RETRO_MAX_ISSUES; list: $list_label; last metrics row: $last_label)"
    echo "$coverage_line"
    if [ "$blackout" = yes ]; then
      echo "WARNING: metrics blackout — 0 metrics rows for $closed_count closed issue(s) in window; the retro evidence layer is missing (collector unwired, or its rows dropped before the window query)."
    fi
    echo "Anonymisation: every consumer identifier is ALREADY replaced by retro_scrub — [consumer], [host], [user], [email], boucle/N-. Do not try to de-anonymise; the generics are the data."
    echo
    echo "## Per-issue rows (oldest → newest)"
    if [ -s "$tmp/rows.jsonl" ]; then
      cat "$tmp/rows.out.jsonl"
    elif [ "$blackout" = yes ]; then
      echo "(none — metrics blackout: no metrics rows for this window; the WARNING above is the finding)"
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
    echo "- gaps (per row): what that row could NOT measure — no_runs, model_unavailable, tokens_unavailable, cost_unavailable, verdict_missing, terminal_unknown. An empty verdicts array with runs > 0 IS a gap: the gates either did not run or their outcome was lost, and neither is a pass."
    echo "- metrics_coverage: usable metrics rows / closed issues in the window. A closed issue with no row is delivery this digest cannot see at all — report the gap, never read the absence as a zero."
    echo "- tokens / cost_usd: null when no run reported a number — never a fake zero; gaps names which fields are missing and why."
    echo "- issue numbers are renumbered per window (#1..#N in order of first appearance); branch prefixes are anonymized by the scrub."
    echo "- data source: metrics rows are the collector's rows in the window; on branch = all of them. The last metrics row distinguishes 'collector stopped at date X' from 'never ran'. A line beginning 'WARNING: metrics' means the window has closed issues but no metrics evidence — cite it verbatim; never read the empty aggregates as 'no activity'."
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
# Count non-"none" values in a comma-separated list. `grep -c` prints 0 AND
# exits 1 when nothing matches, so `|| echo 0` would append a SECOND zero and
# the captured value becomes "0\n0" — which jq --argjson then refuses.
_retro_count_values() {
  case "${1:-}" in
    '' | none) echo 0 ;;
    *)
      local n
      n=$(printf '%s' "$1" | tr ',' '\n' | grep -c . 2> /dev/null || true)
      case "$n" in '' | *[!0-9]*) n=0 ;; esac
      echo "$n"
      ;;
  esac
}

# _retro_record <since> <report> <created> <enriched> <implementable>
# Append the run record to retros.jsonl on the metrics branch. This log is
# the trigger's only state; a failure is logged and swallowed.
_retro_record() {
  local since="$1" report="$2" created="$3" enriched="$4" implementable="$5" dry="${6:-no}"
  local created_n enriched_n
  created_n=$(_retro_count_values "$created")
  enriched_n=$(_retro_count_values "$enriched")
  local line
  line=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg window "$since" \
    --arg report "$report" \
    --arg implementable "$implementable" \
    --arg dry "$dry" \
    --argjson created "$created_n" \
    --argjson enriched "$enriched_n" \
    '{schema: 1, timestamp: $ts, window: $window, created: $created,
      enriched: $enriched, report: $report, implementable: $implementable,
      dry_run: ($dry == "yes")}' 2> /dev/null) || return 1
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
  # NOTE: _RETRO_T2_WORKSPACE is set by the CALLER from the captured output —
  # an assignment here dies in the command substitution's subshell.
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
  # Set the cleanup target in the PARENT shell: the value printed by
  # _retro_prepare_workspace came through a command substitution, so an
  # assignment made inside that subshell never reaches the trap below.
  _RETRO_T2_WORKSPACE="$ws"
  trap '_retro_t2_cleanup' EXIT
  # A job timeout kills with TERM (45m); the trap must cover it so the
  # extraheader-bearing .git/config never outlives the run.
  trap '_retro_t2_cleanup; exit 143' TERM
  trap '_retro_t2_cleanup; exit 130' INT

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
  # bin/jc TRUNCATES the per-run agent log. Preserve the retro transcript
  # before the contributor run overwrites it — both must reach the artifacts.
  cp "$BOUCLE_WORKSPACE/.boucle-state/agent-output.log" \
    "$BOUCLE_WORKSPACE/.boucle-state/retro-agent-output.log" 2> /dev/null || true
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
  # Absent or empty BOUCLE_ENABLED must NOT disable here: on GitHub the
  # workflow's env block does not export it (repo Variables only reach job
  # `if:` gates), so this hook runs with the engine's default-on state —
  # explicit non-true values are the operator's opt-out.
  case "${BOUCLE_ENABLED:-}" in true | "") ;; *) return 0 ;; esac
  retro_enabled || return 0
  retro_upstream_ready || return 0
  # #157: without a resolvable jcode LLM config the agent cannot start, the
  # run records nothing, and the next sweep would chain it again — a red job
  # every 10 minutes. One log line here; bin/doctor --audit carries the
  # operator-facing advisory.
  retro_llm_ready || {
    echo "  → retro LLM config missing — not chaining (bin/doctor --audit reports it)"
    return 0
  }
  retro_threshold_reached || return 0
  echo "  → retro due — chaining the retro stage"
  chain_to_role "retro" "retro"
}

# ── Stage ──────────────────────────────────────────────────────────────────

boucle_ci_retro() {
  # ── Guards ─────────────────────────────────────────────────────────────
  # BOUCLE_ENABLED absent/empty does NOT disable: on GitHub the env block
  # does not export it (repo Variables reach only the job `if:` gates), and
  # the CI-level gating already handles the disabled case. An explicit
  # non-true value is the operator's opt-out.
  case "${BOUCLE_ENABLED:-}" in
    true | "") ;;
    *)
      echo "[retro] BOUCLE_ENABLED='${BOUCLE_ENABLED}' — retro stage disabled" >&2
      exit 0
      ;;
  esac
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
  if ! retro_llm_ready; then
    # #157: the agent cannot start without a jcode-resolvable LLM config.
    # Exit 0 (green job) BEFORE the window/digest work; the one operator
    # signal is the bin/doctor --audit advisory. A red exit here would repeat
    # every sweep because no run record is written to advance the cadence.
    echo "[retro] no jcode LLM config — retro skipped (bin/doctor --audit reports it)" >&2
    exit 0
  fi
  # Idempotence against the doctor's stale pre-check: the doctor may chain
  # this stage moments after a previous retro recorded its run. The
  # resource_group boucle-retro serializes the jobs; this re-check makes the
  # later one a no-op. BOUCLE_RETRO_FORCE is the operator escape hatch: a
  # manually dispatched job proceeds even before the window elapses. The
  # doctor NEVER reads FORCE, so it cannot make the periodic trigger fire.
  if retro_force; then
    echo "[retro] BOUCLE_RETRO_FORCE=true — threshold re-check skipped (operator-triggered run)" >&2
  elif ! retro_threshold_reached; then
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
  # The trigger state is recorded in BOTH modes. A dry run advances the
  # cadence deliberately (dry_run:true): its posts are no-ops, and without a
  # record the empty retros.jsonl would read as "first run" on every sweep,
  # so the doctor would chain a 30-step retro after each one. Only the
  # anti-accumulation close and T2 are skipped in dry-run.
  _retro_record "$since" "${report:-}" "$created" "$enriched" "${implementable:-}" "$dry" || true
  if [ "$dry" = "yes" ]; then
    echo "[retro] dry-run: recorded the run (dry_run=true — the cadence advances; no post was made)"
    echo "[retro] dry-run: skip closing the previous report"
    echo "[retro] dry-run: skip T2 contribution"
  else
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
