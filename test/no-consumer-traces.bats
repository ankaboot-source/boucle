#!/usr/bin/env bats
#
# test/no-consumer-traces.bats — the engine names no consumer.
#
# boucle ships to other people's repositories. Every incident note it keeps
# ("observed on X", "MR !N", "<project>#86", "X's non-root runner") was written
# while debugging a REAL consumer, and each one carries that consumer's
# identity into a public engine: which host they use, which tracker, which
# issue numbers, which source files, which service stack. None of it helps a
# reader — the failure mode and the date do; the name does not.
#
# This guard is a host allowlist rather than a blocklist of names, on purpose:
# a blocklist would have to spell out the very identities the cleanup removed,
# re-introducing them in the test that forbids them. An allowlist stays
# accurate as consumers come and go, and it fails on the NEXT third-party host
# to appear in engine code, whoever it belongs to.
#
# Scope: the engine's own executable + CI surface, plus its charter docs.
# .jcode/skills/ is excluded — it is vendored upstream and re-synced by
# bin/update, so an edit there is churn the next sync reverts (the Makefile
# excludes it from lint for the same reason).

# shellcheck disable=SC2154 # BATS_TEST_FILENAME is set by bats at runtime
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  cd "$REPO_ROOT" || return 1
}

# Hosts the engine may legitimately name: forges it supports, placeholder
# domains, its own site, deploy targets and LLM providers it ships defaults
# for. Anything else in engine code is somebody's infrastructure.
ALLOWED_HOSTS='^(github\.com|githubusercontent\.com|gitlab\.com|gitlab\.io|docs\.gitlab\.com|about\.gitlab\.com|example\.com|example\.org|boucle\.dev|pages\.dev|github\.io|cloudflare\.com|ollama\.com|openrouter\.ai|groq\.com|nvidia\.com|mistral\.ai|huggingface\.co|cerebras\.ai|z\.ai|npmjs\.org|npmjs\.com|nodejs\.org|docker\.io|docker\.com|w3\.org|gnu\.org|shadcn\.com|config\.com|schema\.org|json\.org|claude\.ai|claude\.com|anthropic\.com|telegram\.org|youtube\.com|artificialanalysis\.ai)$'

# engine_files — the engine's own surface, excluding vendored skills.
engine_files() {
  git ls-files \
    '*.sh' '*.bats' '*.yml' '*.yaml' '*.md' 'bin/*' \
    ':!:.jcode/skills' ':!:test/test_helper' ':!:LICENSE'
}

@test "no third-party host is named in engine code" {
  local offenders=""
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local h
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      if ! printf '%s' "$h" | grep -qE "$ALLOWED_HOSTS"; then
        offenders="$offenders$f: $h"$'\n'
      fi
    done < <(grep -ohE '\b[a-z0-9][a-z0-9-]*\.(org|com|fr|dev|io|net|ai|co)\b' "$f" 2> /dev/null | sort -u)
  done < <(engine_files)
  if [ -n "$offenders" ]; then
    echo "Hosts not on the allowlist — a consumer's infrastructure, or a new"
    echo "legitimate host that belongs in ALLOWED_HOSTS in this file:"
    printf '%s' "$offenders" | sort -u
    false
  fi
}

@test "no cross-project issue or MR reference" {
  # A number QUALIFIED BY A PROJECT — `<project>.<tld> #86`, `<host>#12`,
  # `<owner>/<project> #71` — points into a tracker that is not this
  # repository's. A bare `#120` or `!105` is this repo's own and stays; so
  # does `MR !${MR_IID}` in runtime output and `"MR !123"` documenting the
  # reference-token format. Matching the bare forms would fire on all of
  # those, and a guard that cries wolf gets deleted, not fixed.
  local hits
  hits=$(engine_files | xargs grep -nE \
    '[a-z0-9-]+\.[a-z]{2,} ?[#!][0-9]+|[a-z0-9-]+/[a-z0-9._-]+ ?[#!][0-9]+|pipeline #[0-9]{5,}' \
    2> /dev/null | grep -vE 'boucle\.dev/|\.md#|\.sh#|\.yml#' || true)
  if [ -n "$hits" ]; then
    echo "Cross-project tracker references:"
    echo "$hits"
    false
  fi
}

@test "the forge-host placeholder is the documented one" {
  # A real instance hostname as a default or test fixture tells every reader
  # which instance the author runs. gitlab.example.com is the placeholder the
  # engine documents; tests only need *a* host.
  run bash -c "grep -E '^\s+BOUCLE_FORGE_HOST:' .gitlab-ci.yml | head -1"
  assert_success
  assert_output --partial "gitlab.example.com"
}
