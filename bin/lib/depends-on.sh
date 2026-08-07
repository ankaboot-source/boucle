# bin/lib/depends-on.sh — sub-issue dependency parsing and cycle detection
#
# Sourcable bash library (no shebang). Source this file to define:
#   parse_depends_on     — extract dep IIDs from a sub-issue description
#   detect_cycle         — DFS cycle detection on a dependency graph
#   resolve_dep_indices — map 1-based sibling indices to real GitLab IIDs
#
# Usage in CI:
#   source bin/lib/depends-on.sh
#   deps=$(parse_depends_on "$description")
#   if detect_cycle "0:1;1:0"; then echo "CYCLE"; fi
#   iid=$(resolve_dep_indices "2" "41,42,43")
#
# All functions are pure (no external calls, no file I/O). They use only
# bash builtins and POSIX-compatible constructs.

# ── parse_depends_on ────────────────────────────────────────────────────
# Extract dependency IIDs from a sub-issue description.
# Usage: parse_depends_on "<description>" → echoes "42,43" or empty.
#
# Two parse paths, same pattern as bin/fetch-issue-attachments:56-59:
#   1. Primary: grep the HTML comment marker
#      `<!-- boucle:depends-on iids=42,43 -->`
#   2. Fallback: awk the `## Depends on` section, grep #N, strip #, comma-join
#
# The marker is the primary path (robust against body edits). Both must
# always agree — the split job writes both atomically.
parse_depends_on() {
  local desc="$1"

  # Primary: HTML comment marker.
  # First match the full comment broadly, then extract the iids value.
  # For malformed markers like `iids=42,abc`, we extract `42,` (the numeric
  # prefix before the non-numeric junk). This is harmless — the trailing
  # comma produces an empty iteration in the for-loop.
  local marker iids=""
  marker=$(printf '%s' "$desc" \
    | grep -oE '<!-- boucle:depends-on iids=[^ ]+ -->' \
    | head -1)
  if [ -n "$marker" ]; then
    iids=$(printf '%s' "$marker" \
      | grep -oE 'iids=[^ ]+' \
      | cut -d= -f2)
    # Filter to only numeric and comma characters (drops non-numeric junk
    # like "abc" in "42,abc", leaving "42," — trailing comma is harmless).
    iids=$(printf '%s' "$iids" | grep -oE '[0-9,]+' | head -1)
    if [ -n "$iids" ]; then
      printf '%s' "$iids"
      return
    fi
  fi
  if [ -n "$iids" ]; then
    printf '%s' "$iids"
    return
  fi

  # Fallback: awk the ## Depends on section (mirrors ## Parent issue pattern).
  # Use a subshell to avoid pipefail issues: capture awk output, then
  # process it separately so grep's exit code doesn't kill the pipeline.
  local section
  section=$(printf '%s' "$desc" | awk '/^## Depends on[[:space:]]*$/{f=1;next}/^## /{f=0}f')
  if [ -z "$section" ]; then
    return 0
  fi
  # Extract #N references, strip #, comma-join. grep may exit 1 on no match
  # but we already checked section is non-empty, so this is defensive.
  local numbers
  numbers=$(printf '%s' "$section" | grep -oE '#[0-9]+' || true)
  if [ -z "$numbers" ]; then
    return 0
  fi
  printf '%s' "$numbers" | tr -d '#' | paste -sd, -
}

# ── detect_cycle ────────────────────────────────────────────────────────
# DFS cycle detection on a dependency graph.
# Usage: detect_cycle "<graph_string>"
#   Returns 0 if a cycle is found, 1 if the graph is acyclic.
#
# Graph string format: "node:deps;node:deps;..."
#   - node is a 0-based index
#   - deps is a space-separated list of 0-based dependency indices
#   - Nodes are ordered by index (0, 1, 2, ...)
#
# Examples:
#   detect_cycle "0:1;1:0"        → 0 (A→B, B→A = cycle)
#   detect_cycle "0:1;1:2;2:0"    → 0 (A→B→C, C→A = cycle)
#   detect_cycle "0:1;1:;2:"      → 1 (A→B, C isolated = no cycle)
#   detect_cycle "0:0"            → 0 (self-loop = cycle)
#   detect_cycle ""               → 1 (empty graph = no cycle)
#
# Algorithm: three-color DFS (white=unvisited, gray=in-progress, black=done).
# A back-edge to a gray node indicates a cycle. This is the standard
# algorithm for directed graph cycle detection and correctly handles
# DAGs with shared descendants (diamond patterns).
detect_cycle() {
  local graph="$1"

  # Parse graph into deps array
  local -a deps=()
  local count=0
  local old_ifs="$IFS"
  IFS=';'
  for entry in $graph; do
    deps[count]="${entry#*:}"
    count=$((count + 1))
  done
  IFS="$old_ifs"

  # Empty graph → no cycle
  [ "$count" -eq 0 ] && return 1

  # Color: 0=white (unvisited), 1=gray (in current DFS path), 2=black (done)
  local -a color=()
  for ((i = 0; i < count; i++)); do
    color[i]=0
  done

  # Iterative DFS with explicit backtrack markers
  for ((start = 0; start < count; start++)); do
    [ "${color[$start]}" -ne 0 ] && continue

    local -a stack=("$start")

    while [ ${#stack[@]} -gt 0 ]; do
      local top="${stack[-1]}"
      unset 'stack[-1]'

      if [[ "$top" == *:done ]]; then
        # Backtrack: mark node as fully processed (black)
        local node="${top%:done}"
        color[$node]=2
        continue
      fi

      # First visit: mark gray
      color[$top]=1

      # Push backtrack marker so we know when to mark black
      stack+=("${top}:done")

      # Push unvisited children; check for back-edges to gray nodes
      local dep_str="${deps[$top]:-}"
      if [ -n "$dep_str" ]; then
        local old_ifs2="$IFS"
        IFS=' '
        for dep in $dep_str; do
          if [ "${color[$dep]}" = "1" ]; then
            # Back-edge to a node currently on the recursion stack = cycle
            IFS="$old_ifs2"
            return 0
          fi
          if [ "${color[$dep]}" = "0" ]; then
            stack+=("$dep")
          fi
        done
        IFS="$old_ifs2"
      fi
    done
  done

  return 1
}

# ── resolve_dep_indices ─────────────────────────────────────────────────
# Map 1-based sibling indices to real GitLab IIDs.
# Usage: resolve_dep_indices "<raw_indices>" "<created_iids>"
#   raw_indices:  comma-separated 1-based indices (e.g. "2" or "1,3")
#   created_iids: comma-separated real IIDs in creation order (e.g. "41,42,43")
#   stdout:      comma-separated resolved IIDs (e.g. "42" or "41,43")
#   stderr:      warning for out-of-range indices
#
# The triage agent declares deps by 1-based sibling index (e.g. "Depends on: #2").
# After sub-issues are created, the split job knows the real IIDs and calls
# this function to resolve indices → IIDs for the ## Depends on section.
resolve_dep_indices() {
  local raw_indices="$1"
  local created_iids="$2"

  [ -z "$raw_indices" ] && return 0

  # Parse created_iids into array
  local -a iid_array=()
  local old_ifs="$IFS"
  IFS=','
  for iid in $created_iids; do
    iid_array+=("$iid")
  done
  IFS="$old_ifs"

  local -a result=()
  local old_ifs2="$IFS"
  IFS=','
  for idx in $raw_indices; do
    IFS="$old_ifs2"
    # Trim whitespace
    idx="${idx## }"
    idx="${idx%% }"
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#iid_array[@]}" ]; then
      result+=("${iid_array[$((idx - 1))]}")
    else
      echo "WARN: resolve_dep_indices: index '$idx' is out of range (1..${#iid_array[@]})" >&2
    fi
  done
  IFS="$old_ifs2"

  # Join with commas
  local first=true
  for r in "${result[@]}"; do
    if $first; then
      printf '%s' "$r"
      first=false
    else
      printf ',%s' "$r"
    fi
  done
  echo
}
