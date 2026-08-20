#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/command.sh — /boucle interactive command parser + router (#61).
#
# A forge-native observability surface: a human posts `/boucle <verb>` (or
# `@<bot> <verb>`) as an ISSUE comment; dispatch parses it, authorizes the
# actor, and triggers a separate fast CI job (cmd-log / cmd-status / cmd-help)
# that fetches data and posts a stamped reply comment.
#
# Design contract (issue #61):
#   - Forge-native: no agent invocation, no label writes, no security surface.
#   - Non-redundancy: labels = control/state; /boucle = observability. A
#     command NEVER writes a label (idempotence lesson #4 trivially satisfied).
#   - Every reply is stamped `<!-- boucle:agent -->` (lesson #55) so the
#     anti-loop marker filter in dispatch skips boucle's own replies — no
#     self-trigger loop.
#   - Issue comments only at MVP. MR comments are handled separately below.
#
# Functions:
#   boucle_command_parse   <body>   → "VERB ARGS" or empty
#   boucle_command_authorize <iid> <actor> <verb> → 0 allowed / 1 denied
#   boucle_command_run     <iid> <verb> <args> → route to the right cmd job

# boucle_command_parse <body>
#
# Echo "VERB ARGS" (space-separated) when the first non-empty line of the
# comment body is a /boucle or @<bot> command; empty otherwise.
#
# Regex: `^(/boucle|@${BOUCLE_BOT_USERNAME})[[:space:]]` case-insensitive,
# anchored at the first non-empty line. An empty capture (just `/boucle` with
# no verb) echoes empty — the router treats it as an unknown verb → help reply.
# An unknown first token echoes the token so the router can reply "unknown
# verb, try `/boucle help`".
boucle_command_parse() {
  local body="$1"
  local bot="${BOUCLE_BOT_USERNAME:-up-bot}"
  local line rest
  # First non-empty line, leading whitespace trimmed.
  line=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -n 1 | sed 's/^[[:space:]]*//')
  [ -n "$line" ] || return 0
  # Word boundary: `/boucle` or `@<bot>` followed by whitespace or end-of-line.
  # Rejects `/bouclefoobar` and `@<bot>suffix`.
  if ! printf '%s' "$line" | grep -qiE "^(/boucle|@${bot})([[:space:]]|$)"; then
    return 0
  fi
  rest=$(printf '%s' "$line" | sed -nE "s#^(\/boucle|@${bot})[[:space:]]*(.*)#\2#Ip")
  printf '%s' "$rest"
}

# boucle_command_authorize <iid> <actor> <verb>
#
# Return 0 (allowed) / 1 (denied). For log/status/help the actor must be the
# issue author OR the parent-issue human author (one generation, via
# resolve_reporter_username — the same parent-chain walk resolve_reporter_id
# uses). Reuses dispatch_human_actor semantics for mono-user mode (the human
# IS the bot account).
#
# Bot actors are already filtered upstream by the has_agent_marker check in
# dispatch, so no extra bot guard is needed here.
#
# Fail-open on API error: if resolve_reporter_username returns empty (API
# hiccup), ALLOW — the data is observable in the CI UI anyway, so no new trust
# boundary is crossed. This matches the existing spec-approval fallback
# (dispatch.sh:915-918).
boucle_command_authorize() {
  local iid="$1" actor="$2" verb="$3"
  # Mono-user mode: the human IS the bot account, so any event that reaches
  # routing is human by construction (dispatch_human_actor semantics).
  if boucle_mono_user; then
    return 0
  fi
  # help is pure text — allow any human actor (still filtered by the
  # agent-marker skip upstream, so boucle's own replies never self-trigger).
  if [ "$verb" = "help" ]; then
    return 0
  fi
  local reporter
  reporter=$(resolve_reporter_username "$iid" 2> /dev/null || true)
  # Fail-open on API error (empty reporter): the data is observable in the CI
  # UI anyway — no new trust boundary crossed.
  if [ -z "$reporter" ]; then
    echo "command: cannot resolve the human reporter for #$iid — failing OPEN (transient/legacy)"
    return 0
  fi
  if [ "$(printf '%s' "$reporter" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$actor" | tr '[:upper:]' '[:lower:]')" ]; then
    return 0
  fi
  return 1
}

# boucle_command_run <iid> <verb> <args>
#
# Route to the right cmd job via chain_to_role. Stamps every reply with the
# agent marker (stamp_agent_marker is applied by forge_issue_note). No label
# writes. Closed-issue guard (lesson #44): do not run log/status on a closed
# issue (the forge API may 404 or return stale data); help is pure text and
# allowed on closed issues.
#
# For an unknown verb, post the one-line reply directly from dispatch — no
# separate job needed.
boucle_command_run() {
  local iid="$1" verb="$2" args="$3"
  case "$verb" in
    log)
      # Closed-issue guard: log/status on a closed issue may 404 or return
      # stale data. help is pure text and allowed.
      if [ "$(forge_issue_get "$iid" | jq -r '.state // empty' 2> /dev/null || true)" = "closed" ]; then
        forge_issue_note "$iid" "🔒 Issue #$iid is closed — \`/boucle log\` is not available on a closed issue. Use \`/boucle help\` to see what's available." 2> /dev/null || true
        return 0
      fi
      chain_to_role "$iid" "cmd-log" "BOUCLE_CMD_ARGS=$args"
      ;;
    status)
      if [ "$(forge_issue_get "$iid" | jq -r '.state // empty' 2> /dev/null || true)" = "closed" ]; then
        forge_issue_note "$iid" "🔒 Issue #$iid is closed — \`/boucle status\` is not available on a closed issue. Use \`/boucle help\` to see what's available." 2> /dev/null || true
        return 0
      fi
      chain_to_role "$iid" "cmd-status"
      ;;
    help)
      chain_to_role "$iid" "cmd-help"
      ;;
    *)
      # Unknown verb — one-line reply, no separate job.
      forge_issue_note "$iid" "🤔 Unknown verb \`/boucle $verb\` — try \`/boucle help\` to see what's available." 2> /dev/null || true
      ;;
  esac
}
