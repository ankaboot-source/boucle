#!/usr/bin/env sh
# shellcheck shell=sh
# bin/lib/agent-browser.sh — resolve the agent-browser CLI and a browser for it.
#
# Sourced by bin/render-preview (screenshots) and bin/nav-assert (functional
# navigation checks). Single source of truth on purpose: the ladder below
# lived inline in render-preview until nav-assert needed the same one, and
# two copies of a browser-resolution ladder drift the day a CI image changes
# its Chromium path.
#
# POSIX sh — render-preview is `#!/usr/bin/env sh`, so this file must stay
# sourceable by both sh and bash. No arrays, no `local`.
#
# Contract: boucle_agent_browser_setup [tag]
#   - sets $AB to the CLI to invoke
#   - exports the AGENT_BROWSER_* environment the CLI reads
#   - returns 0 on success, 1 when no CLI or no browser could be resolved
#     (the caller decides whether that is fatal — render-preview exits,
#     nav-assert reports a FAIL verdict instead of dying silently)
#
# CLI resolution order (first hit wins):
#   1. $BOUCLE_AGENT_BROWSER  — explicit override (also how the bats suite
#      injects a stub, so the assertion layer is testable without a browser)
#   2. agent-browser on PATH  — baked into the agents image
#   3. /tmp/node_modules/.bin/agent-browser
#   4. npm install --prefix /tmp agent-browser
#
# Browser resolution order (first hit wins):
#   1. $AGENT_BROWSER_EXECUTABLE_PATH — set by the agents image
#   2. $BOUCLE_CHROME                 — per-consumer override
#   3. chromium / chromium-browser / google-chrome / google-chrome-stable
#   4. `agent-browser install` (needs network; last resort)

boucle_agent_browser_setup() {
  _ab_tag="${1:-agent-browser}"

  # ── CLI ──────────────────────────────────────────────────────────────
  if [ -n "${BOUCLE_AGENT_BROWSER:-}" ]; then
    AB="$BOUCLE_AGENT_BROWSER"
  elif command -v agent-browser > /dev/null 2>&1; then
    AB="agent-browser"
  elif [ -x /tmp/node_modules/.bin/agent-browser ]; then
    AB="/tmp/node_modules/.bin/agent-browser"
  elif npm install --prefix /tmp agent-browser > /dev/null 2>&1; then
    AB="/tmp/node_modules/.bin/agent-browser"
  else
    echo "$_ab_tag: agent-browser unavailable (not installed, npm install failed)" >&2
    return 1
  fi

  # ── browser executable ───────────────────────────────────────────────
  if [ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]; then
    : # already exported, agent-browser picks it up
  elif [ -n "${BOUCLE_CHROME:-}" ]; then
    AGENT_BROWSER_EXECUTABLE_PATH="$BOUCLE_CHROME"
    export AGENT_BROWSER_EXECUTABLE_PATH
  else
    for _ab_candidate in chromium chromium-browser google-chrome google-chrome-stable; do
      if command -v "$_ab_candidate" > /dev/null 2>&1; then
        AGENT_BROWSER_EXECUTABLE_PATH="$(command -v "$_ab_candidate")"
        export AGENT_BROWSER_EXECUTABLE_PATH
        break
      fi
    done
  fi

  # The install fallback is skipped under an explicit CLI override: the stub
  # the bats suite injects is not a browser driver, and asking it to install
  # one would either hang or invent a success. Everything ABOVE this point
  # still runs for a stub — the AGENT_BROWSER_* exports below are what make a
  # real browser usable in CI (no sandbox as root), so an early return here
  # would leave a real run without them.
  if [ -z "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && [ -z "${BOUCLE_AGENT_BROWSER:-}" ]; then
    echo "$_ab_tag: no system browser found — falling back to 'agent-browser install'" >&2
    if ! "$AB" install > /dev/null 2>&1; then
      echo "$_ab_tag: agent-browser install failed and no browser is present" >&2
      return 1
    fi
  fi

  # CI containers run as root without a usable sandbox, and /dev/shm is small.
  AGENT_BROWSER_ARGS="${AGENT_BROWSER_ARGS:---no-sandbox,--disable-dev-shm-usage}"
  export AGENT_BROWSER_ARGS

  # file:// navigation needs this. Note it must be the environment variable, not
  # the documented `--allow-file-access` CLI flag: passing the flag leaves the
  # page on about:blank and yields a blank PNG with a zero exit code (verified on
  # 0.27.0 and 0.34.0, and against agent-browser main at 021d925 where the flag
  # does reach Chrome's argv only through this variable).
  AGENT_BROWSER_ALLOW_FILE_ACCESS=1
  export AGENT_BROWSER_ALLOW_FILE_ACCESS

  return 0
}
