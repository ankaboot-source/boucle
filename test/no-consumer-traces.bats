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
# Scope is split, because the three checks below have different blast radii:
# the host allowlist applies to the engine's own surface, while the
# cross-project reference and compiled-artifact checks apply to everything.
#
# .jcode/ is in scope either way. That directory is NOT
# vendored from anywhere: bin/update's own comment says ".jcode/ is synced as
# a whole — the engine owns it entirely (agents/, skills/, ...)", and the
# sync runs FROM here TO consumers. So this repo is the origin, an edit here
# is the fix, and leaving it out only hid a leak — a skill's example command
# carried a consumer's project name verbatim, and shipped it to every
# consumer on the next engine bump. (The Makefile does exclude .jcode/ from
# shfmt, but that is about reformatting churn in vendored SCRIPTS, not a
# reason to leave content unreviewed.)
#
# What this guard CANNOT catch, stated plainly: an arbitrary proper noun. The
# leak that prompted widening the scope was a consumer's project name passed
# to a skill's example command, and no pattern distinguishes such a project
# name from any other capitalised phrase without the blocklist this file
# exists to avoid. What is checkable is the vector it travelled by — a
# tracked compiled artifact — and that is the fourth test.

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
# engine_files — the engine's executable + CI surface and its charter docs.
# .jcode/skills/ is out of scope for the HOST check specifically: those are
# design and review skills whose prose cites framework documentation, vendor
# design systems, accessibility and security references — some forty domains.
# A host there is a citation, not infrastructure, so the allowlist would be
# forty documentation domains long and would flag every new reference a skill
# adds: noise with no signal.
#
# NOTE for whoever edits this file: it is scanned by its own host check, so a
# literal hostname written anywhere in it outside ALLOWED_HOSTS fails the
# test. Name domains by description, not by spelling them.
engine_files() {
  git ls-files \
    '*.sh' '*.bats' '*.yml' '*.yaml' '*.md' 'bin/*' \
    ':!:.jcode/skills' ':!:test/test_helper' ':!:LICENSE'
}

# owned_files — everything this repo owns, .jcode/skills/ included. The
# patterns below it (a number qualified by a project, a compiled artifact)
# do not fire on citations, so they apply everywhere.
owned_files() {
  git ls-files ':!:test/test_helper' ':!:LICENSE'
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
  # A number qualified by a HOST — `<project>.<tld> #86`, `<host>#12` — and
  # a raw pipeline id. Those were the shapes every consumer leak took.
  #
  # Deliberately NOT matched: `<owner>/<project>#N`. It is indistinguishable
  # from citing a real upstream bug in a dependency, which is provenance a
  # comment SHOULD carry — the agents Dockerfile cites one in the base image
  # it builds on. Nor the bare forms: `#120` is this repo's own issue,
  # `MR !${MR_IID}` is runtime output, `"MR !123"` documents the
  # reference-token format. A guard that cries wolf gets deleted, not fixed.
  local hits
  hits=$(owned_files | xargs grep -nE \
    -I '[a-z0-9-]+\.[a-z]{2,} ?[#!][0-9]+|pipeline #[0-9]{5,}' \
    2> /dev/null | grep -vE 'boucle\.dev/|\.md#|\.sh#|\.yml#|\.csv:' || true)
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

@test "no compiled artifact is tracked" {
  # Four __pycache__ files were tracked in a vendored skill, and two carried
  # a consumer's project name in bytecode compiled from a source version
  # that had since been cleaned — a leak invisible to every text grep, and
  # shipped to every consumer by bin/update (SYNC_PATHS includes .jcode).
  # The skill's own .gitignore already listed __pycache__/ and *.pyc; a
  # tracked file ignores .gitignore, which is why it survived.
  #
  # Byte-compiled output is regenerable and must never be committed: it
  # cannot be reviewed, and it outlives the source it was built from.
  run bash -c "git ls-files | grep -E '__pycache__|\\.pyc$|\\.pyo$' || true"
  assert_success
  assert_output ""
}
