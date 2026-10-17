#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
# Rétro — dogfood self-improvement (#139): toggles, deterministic
# anonymisation, trigger state, upstream helpers and the dispatch guard.
#
# The point of these tests is the CONTRACT, not the happy path:
#   * an anonymiser that leaks one identifier leaks them all — assert NONE survive;
#   * the trigger must fail CLOSED when a forge API is flaky (no spam) and
#     still fire on the days backstop (no stall);
#   * a rétro report must never be dispatched, including via the
#     unlabeled-open route.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
  # Hermetic repository identity. This suite also runs in CI, where the forge
  # exports the REAL identity of the checkout (on the engine's own workflow:
  # GITHUB_REPOSITORY=ankaboot-source/boucle). `_retro_is_upstream_repo` reads
  # that before `origin`, so a consumer fixture would silently resolve to the
  # upstream and invert the assertion — green on a dev machine, red in CI.
  # Tests that need an identity export it explicitly.
  unset GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_API_URL \
    CI_PROJECT_ID CI_PROJECT_NAME CI_PROJECT_PATH CI_REPOSITORY_URL \
    BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH || true
}

teardown() {
  cd "$BATS_TEST_DIRNAME" 2> /dev/null || cd / || true
  rm -rf "$TMP"
}

lib() {
  # shellcheck source=/dev/null
  . "$REPO/lib/boucle.sh" 2> /dev/null || true
}

# run_in_scratch <dir> <function> [args...]
#
# Source the lib inside a scratch checkout and call the function. The tests
# that read the origin remote MUST NOT see the boucle repo's own origin, or a
# consumer scenario silently passes as the upstream.
run_in_scratch() {
  local dir="$1"
  shift
  bash -c 'cd "$1" && . "$2/lib/boucle.sh" 2> /dev/null && shift 2 && "$@"' \
    _ "$dir" "$REPO" "$@"
}

# ── retro_scrub ────────────────────────────────────────────────────────

@test "scrub: every consumer identifier is replaced, the upstream reference survives" {
  lib
  export CI_PROJECT_ID=424242
  export CI_PROJECT_NAME=site-urgence
  export CI_PROJECT_PATH=asso/site-urgence
  export BOUCLE_PROJECT_ID=424242
  export BOUCLE_BOT_USERNAME=loop-bot
  export GITLAB_USER_LOGIN=alice
  export BOUCLE_FORGE_HOST=gitlab.example.com
  SCRATCH="$TMP/consumer"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin https://gitlab.example.com/asso/site-urgence.git
  cat > "$TMP/input.txt" << 'EOF'
project asso/site-urgence (id 424242, name site-urgence) on gitlab.example.com
user alice asked loop-bot to fix branch boucle/139-fix-thing
mail: alice@example.org
upstream: https://github.com/ankaboot-source/boucle/issues/139
EOF

  run run_in_scratch "$SCRATCH" retro_scrub < "$TMP/input.txt"
  assert_success
  refute_output --partial "framagit"
  refute_output --partial "site-urgence"
  refute_output --partial "424242"
  refute_output --partial "loop-bot"
  refute_output --partial "alice"
  refute_output --partial "example.org"
  refute_output --partial "boucle/139-"
  assert_output --partial "boucle/N-"
  assert_output --partial "github.com/ankaboot-source/boucle/issues/139"
}

@test "scrub: the upstream forge host is exempt (github.com is a legitimate reference)" {
  # Blanket-replacing github.com would rewrite every upstream link the rétro
  # is supposed to file. The origin remote is absent here, so only the
  # host-exemption rule is under test.
  lib
  export BOUCLE_FORGE_HOST=github.com
  export CI_SERVER_URL=https://github.com
  SCRATCH="$TMP/plain"
  mkdir -p "$SCRATCH"

  run run_in_scratch "$SCRATCH" retro_scrub <<< "see https://github.com/ankaboot-source/boucle/issues/139"
  assert_success
  assert_output "see https://github.com/ankaboot-source/boucle/issues/139"
}

@test "scrub: deterministic — same input, same output" {
  lib
  export CI_PROJECT_NAME=acme
  SCRATCH="$TMP/det"
  mkdir -p "$SCRATCH"
  printf 'acme and acme again\n' > "$TMP/det.txt"

  first=$(run_in_scratch "$SCRATCH" retro_scrub < "$TMP/det.txt")
  second=$(run_in_scratch "$SCRATCH" retro_scrub < "$TMP/det.txt")
  [ "$first" = "$second" ]
  [ "$first" = "[consumer] and [consumer] again" ]
}

# ── toggles ─────────────────────────────────────────────────────────────

@test "retro: ON by default, and only an explicitly falsy value disables it" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  run retro_enabled
  assert_success
  for v in false FALSE 0 no off; do
    BOUCLE_RETRO_ENABLED="$v" run retro_enabled
    assert_failure
  done
  for v in true TRUE 1 yes banana; do
    BOUCLE_RETRO_ENABLED="$v" run retro_enabled
    assert_success
  done
}

@test "retro: contribution auto is OFF on a consumer; explicit false wins even upstream" {
  lib
  unset BOUCLE_RETRO_CONTRIBUTE || true
  export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
  # A scratch consumer checkout: the boucle repo's own origin IS the upstream,
  # so running this in-place would silently test the wrong branch.
  SCRATCH="$TMP/consumer-auto"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin https://gitlab.example.com/asso/site.git
  export GITHUB_REPOSITORY=someone/consumer
  run run_in_scratch "$SCRATCH" retro_contribute_enabled
  assert_failure

  export BOUCLE_RETRO_CONTRIBUTE=false
  export GITHUB_REPOSITORY=ankaboot-source/boucle
  run run_in_scratch "$SCRATCH" retro_contribute_enabled
  assert_failure
}

@test "retro: contribution auto is ON when the repo IS the upstream (slug or remote URL)" {
  lib
  unset BOUCLE_RETRO_CONTRIBUTE || true
  export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
  export GITHUB_REPOSITORY=ankaboot-source/boucle
  run retro_contribute_enabled
  assert_success

  # Remote-URL detection, isolated from the boucle checkout's own origin.
  unset GITHUB_REPOSITORY BOUCLE_PROJECT_PATH BOUCLE_PROJECT_ID
  SCRATCH="$TMP/upstream"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin git@github.com:ankaboot-source/boucle.git
  run run_in_scratch "$SCRATCH" retro_contribute_enabled
  assert_success
}

@test "retro: explicit true wins on a consumer, auto never matches a consumer origin" {
  lib
  unset BOUCLE_RETRO_CONTRIBUTE || true
  export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
  SCRATCH="$TMP/consumer2"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin https://gitlab.example.com/asso/site.git
  run run_in_scratch "$SCRATCH" retro_contribute_enabled
  assert_failure

  export BOUCLE_RETRO_CONTRIBUTE=true
  run run_in_scratch "$SCRATCH" retro_contribute_enabled
  assert_success
}

@test "retro: upstream readiness needs an enabled retro AND a resolvable token" {
  lib
  unset BOUCLE_RETRO_ENABLED BOUCLE_UPSTREAM_TOKEN BOUCLE_TOKEN BOUCLE_FORGE \
    BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH GITHUB_REPOSITORY || true
  # A scratch checkout (no upstream origin) so the self-targeting fallback
  # cannot accidentally apply from the engine repo's own origin.
  SCRATCH="$TMP/no-token"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  run run_in_scratch "$SCRATCH" retro_upstream_ready
  assert_failure

  export BOUCLE_UPSTREAM_TOKEN=ghp_fake
  run retro_upstream_ready
  assert_success

  export BOUCLE_RETRO_ENABLED=false
  run retro_upstream_ready
  assert_failure
}

@test "retro token: the explicit BOUCLE_UPSTREAM_TOKEN wins everywhere" {
  lib
  unset BOUCLE_FORGE BOUCLE_TOKEN || true
  export BOUCLE_UPSTREAM_TOKEN=ghp_explicit BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
  run retro_upstream_token
  assert_success
  assert_output "ghp_explicit"
}

@test "retro token: self-targeting fallback — BOUCLE_TOKEN when the repo IS the upstream, on GitHub" {
  lib
  unset BOUCLE_UPSTREAM_TOKEN || true
  export BOUCLE_FORGE=github BOUCLE_TOKEN=ghp_self
  export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle GITHUB_REPOSITORY=ankaboot-source/boucle
  run retro_upstream_token
  assert_success
  assert_output "ghp_self"
}

@test "retro token: no fallback for a consumer, whatever GitHub token it carries" {
  lib
  unset BOUCLE_UPSTREAM_TOKEN GITHUB_REPOSITORY BOUCLE_PROJECT_PATH BOUCLE_PROJECT_ID || true
  export BOUCLE_FORGE=github BOUCLE_TOKEN=ghp_consumer BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle
  SCRATCH="$TMP/consumer-token"
  mkdir -p "$SCRATCH"
  git init -q "$SCRATCH"
  git -C "$SCRATCH" remote add origin https://gitlab.example.com/asso/site.git
  run run_in_scratch "$SCRATCH" retro_upstream_token
  assert_failure
}

@test "retro token: NEVER the GitLab token — a GitLab credential is not a GitHub one" {
  lib
  unset BOUCLE_UPSTREAM_TOKEN || true
  export BOUCLE_FORGE=gitlab BOUCLE_TOKEN=glpat_gitlab
  export BOUCLE_UPSTREAM_REPO=ankaboot-source/boucle GITHUB_REPOSITORY=ankaboot-source/boucle
  run retro_upstream_token
  assert_failure
}

@test "retro: dry-run is OFF by default and only explicit true spellings enable it" {
  lib
  unset BOUCLE_RETRO_DRY_RUN || true
  run retro_dry_run
  assert_failure
  for v in true TRUE 1 yes on; do
    BOUCLE_RETRO_DRY_RUN="$v" run retro_dry_run
    assert_success
  done
  for v in false 0 no off banana; do
    BOUCLE_RETRO_DRY_RUN="$v" run retro_dry_run
    assert_failure
  done
}

# ── trigger ────────────────────────────────────────────────────────────

@test "retro threshold: a repo that never ran a retro is due" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  retro_last_run_read() { :; }
  run retro_threshold_reached
  assert_success
}

@test "retro threshold: under the merge count and inside the days window is NOT due" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  export BOUCLE_RETRO_EVERY_MERGES=10 BOUCLE_RETRO_EVERY_DAYS=3650
  retro_last_run_read() { date -u +%Y-%m-%dT%H:%M:%SZ; }
  forge_mr_count_merged_since() { echo 3; }
  run retro_threshold_reached
  assert_failure
}

@test "retro threshold: enough merged PRs since the last run is due" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  export BOUCLE_RETRO_EVERY_MERGES=2 BOUCLE_RETRO_EVERY_DAYS=3650
  retro_last_run_read() { date -u +%Y-%m-%dT%H:%M:%SZ; }
  forge_mr_count_merged_since() { echo 5; }
  run retro_threshold_reached
  assert_success
}

@test "retro threshold: the days backstop fires WITHOUT calling a flaky forge API" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  export BOUCLE_RETRO_EVERY_MERGES=1000 BOUCLE_RETRO_EVERY_DAYS=2
  retro_last_run_read() { echo "2000-01-01T00:00:00Z"; }
  forge_mr_count_merged_since() { : > "$TMP/api-called"; }
  run retro_threshold_reached
  assert_success
  [ ! -e "$TMP/api-called" ]
}

@test "retro threshold: a flaky forge API fails CLOSED (a flaky API must not spam retros)" {
  lib
  unset BOUCLE_RETRO_ENABLED || true
  export BOUCLE_RETRO_EVERY_MERGES=2 BOUCLE_RETRO_EVERY_DAYS=3650
  retro_last_run_read() { date -u +%Y-%m-%dT%H:%M:%SZ; }
  forge_mr_count_merged_since() { return 1; }
  run retro_threshold_reached
  assert_failure
}

@test "retro: a disabled retro never reports its threshold reached" {
  lib
  export BOUCLE_RETRO_ENABLED=false
  retro_last_run_read() { :; }
  run retro_threshold_reached
  assert_failure
}

@test "retro: record_run appends through the metrics git helper and refuses non-JSON" {
  lib
  boucle_metrics_git_append() { printf '%s|%s\n' "$1" "$(cat "$2")"; }
  run retro_record_run '{"timestamp":"2026-10-17T00:00:00Z","window":"x"}'
  assert_success
  assert_output --partial "retros.jsonl|"
  assert_output --partial '"timestamp":"2026-10-17T00:00:00Z"'

  run retro_record_run 'not json'
  assert_failure
}

# ── dispatch guard ─────────────────────────────────────────────────────

@test "dispatch: boucle:retro and boucle:report are recognised as rétro artefacts (#139)" {
  # shellcheck source=/dev/null
  . "$REPO/lib/boucle-ci/dispatch.sh"
  run dispatch_retro_artifact "boucle:todo,boucle:retro"
  assert_success
  run dispatch_retro_artifact "boucle:report"
  assert_success
  run dispatch_retro_artifact "boucle:triage"
  assert_failure
  run dispatch_retro_artifact ""
  assert_failure
}

@test "dispatch: the rétro guard sits before the unlabeled-open route (#139)" {
  guard_line=$(grep -n 'Rétro artefact guard' "$REPO/lib/boucle-ci/dispatch.sh" | head -1 | cut -d: -f1)
  triage_line=$(grep -n 'grep -q "boucle:triage"' "$REPO/lib/boucle-ci/dispatch.sh" | tail -1 | cut -d: -f1)
  [ -n "$guard_line" ] && [ -n "$triage_line" ]
  [ "$guard_line" -lt "$triage_line" ]
}

# ── upstream forge helpers ─────────────────────────────────────────────

@test "github: forge_issue_list_in prints number-tab-title lines and excludes PRs" {
  run bash -c '
    gh() {
      [ "$1" = "api" ] || return 0
      printf "[{\"number\":7,\"title\":\"First\",\"pull_request\":null},{\"number\":8,\"title\":\"A PR\",\"pull_request\":{}}]\n"
    }
    source "$1/bin/forge/github.sh"
    forge_issue_list_in "owner/repo" "tok" "boucle:report"
  ' _ "$REPO"
  assert_success
  assert_output $'7\tFirst'
}

@test "github: the upstream helpers return non-zero on API error (never a silent success)" {
  run bash -c '
    gh() { return 22; }
    source "$1/bin/forge/github.sh"
    forge_issue_create_in "owner/repo" "tok" "t" "b" "boucle:report" && echo UNEXPECTED-OK
  ' _ "$REPO"
  assert_failure
  refute_output --partial "UNEXPECTED-OK"

  run bash -c '
    gh() { return 22; }
    source "$1/bin/forge/github.sh"
    forge_pr_create_in "owner/repo" "tok" "t" "retro/slug" "main" "b" && echo UNEXPECTED-OK
  ' _ "$REPO"
  assert_failure
  refute_output --partial "UNEXPECTED-OK"
}

# ── wiring ─────────────────────────────────────────────────────────────

@test "wiring: both retro roles are registered in jc with fallbacks, timeouts and the post guard" {
  run grep -Fq 'retro-impl) FALLBACK_MODEL="${BOUCLE_FALLBACK_MODEL_RETRO_IMPL:-deepseek-v4.1-flash}"' "$REPO/bin/jc"
  assert_success
  run grep -Fq 'retro) FALLBACK_MODEL="${BOUCLE_FALLBACK_MODEL_RETRO:-glm-5.3-flash}"' "$REPO/bin/jc"
  assert_success
  run grep -Fq 'retro-impl) AGENT_TIMEOUT="12m"' "$REPO/bin/jc"
  assert_success
  run grep -Fq 'triage | reviewer | e2e | retro)' "$REPO/bin/jc"
  assert_success
  # A dash in a role would break ${!VAR} indirect expansion: the override
  # name must sanitise it to BOUCLE_MODEL_RETRO_IMPL.
  run grep -Fq "tr '[:lower:]-' '[:upper:]_'" "$REPO/bin/jc"
  assert_success
}

@test "wiring: doctor checks both agent files and advises on a token-less retro" {
  run grep -Fq 'for role in triage worker reviewer e2e retro retro-impl' "$REPO/bin/doctor"
  assert_success

  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k bash bin/doctor --audit
  assert_success
  assert_output --partial "BOUCLE_RETRO_ENABLED=true without BOUCLE_UPSTREAM_TOKEN"

  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_UPSTREAM_TOKEN=t bash bin/doctor --audit
  assert_success
  refute_output --partial "without BOUCLE_UPSTREAM_TOKEN"

  run env -i PATH="$PATH" HOME="$HOME" BOUCLE_LLM_API_KEY=k BOUCLE_RETRO_ENABLED=false bash bin/doctor --audit
  assert_success
  refute_output --partial "without BOUCLE_UPSTREAM_TOKEN"
}
