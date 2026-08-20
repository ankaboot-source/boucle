#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci/cmd-help.sh — /boucle help (#61).
#
# Posts static text: the verb table + the non-redundancy rationale
# ("labels = control/state; /boucle = observability; never duplicate label
# control"). Pure text — allowed on closed issues.

boucle_ci_cmd_help() {
  local iid="${BOUCLE_ISSUE:-}"
  if [ -z "$iid" ]; then
    echo "cmd-help: BOUCLE_ISSUE is unset — nothing to do" >&2
    exit 0
  fi

  local body
  body="### ❓ /boucle — available verbs

\`/boucle\` is a forge-native observability command. It reads data the loop
already produces and posts it back in this issue — it NEVER changes state.

| Verb | Action |
|---|---|
| \`/boucle log [role]\` | Post the tail of the most recent \`agent-output.log\` for \`<role>\` (default: the role in flight, else the last completed) on this issue. |
| \`/boucle status\` | Post a projection of loop health (iterations, outcomes by role, cost, last verdict, role in flight). |
| \`/boucle help\` | Post this list. |

You can also trigger with \`@<bot> <verb>\` (e.g. \`@up-bot log\`).

**Non-redundancy**: labels are the single plan of control/state. \`/boucle\`
is observability — it never duplicates label control. Use labels to change
state; use \`/boucle\` to see what the loop did.

**Authorization**: \`log\`/\`status\`/\`help\` are limited to the issue author
(or the parent-issue author). The data they return is already visible in the
CI UI — no new trust boundary is crossed.

**Forge asymmetries**: on GitHub, \`/boucle log\` is post-completion only
(GitHub Actions has no streaming log API)."
  forge_issue_note "$iid" "$body" 2> /dev/null || true
  exit 0
}
