#!/usr/bin/env bats
# shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
# test/setup-infra-profile.bats — the non-site/infra install preset (#182).
#
# bin/setup has no BASH_SOURCE guard: sourcing it runs the whole install
# (network calls, file writes). These tests therefore extract the PURE
# render_root_shim function with awk (same technique as test/setup.bats) and
# assert the generated root-shim YAML. The acceptance criterion is ground
# truth: a pre-existing consumer job must inherit neither the boucle-agents
# image nor `interruptible: true` — the shim ships the
# `inherit: default: false` contract, and the profile must not declare a
# leaking `image:`/`interruptible:` key.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  SETUP="$REPO/bin/setup"
}

# render <profile> <tags_block> <e2e_cmd> <update_disable>
# Extracts render_root_shim from bin/setup and calls it with a fixed engine
# include + host, so every assertion is hermetic (no env, no network).
render() {
  # shellcheck source=/dev/null
  source <(awk 'BEGIN{p=0} /^render_root_shim\(\) \{/{p=1; print; next} p==1 && /^\}/{print; p=0; next} p==1{print}' "$SETUP")
  render_root_shim \
    "https://raw.githubusercontent.com/ankaboot-source/boucle/abc123/.gitlab-ci.yml" \
    "gitlab.example.com" "$1" "$2" "$3" "$4"
}

# ── Infra profile: preset variables ───────────────────────────────────

@test "render_root_shim infra emits the non-site preset variables" {
  run render infra "" true true
  assert_success
  assert_output --partial "include:"
  assert_output --partial "remote: 'https://raw.githubusercontent.com/ankaboot-source/boucle/abc123/.gitlab-ci.yml'"
  assert_output --partial 'BOUCLE_DEPLOY_MODE: "external"'
  assert_output --partial 'BOUCLE_REVIEW_MODE: "diff"'
  assert_output --partial "BOUCLE_E2E_COMMAND: 'true'"
  assert_output --partial 'BOUCLE_BUILD_CMD: "true"'
  assert_output --partial 'BOUCLE_UPDATE_DISABLE: "true"'
}

@test "render_root_shim infra documents the inherit: default: false contract" {
  run render infra "" true true
  assert_success
  assert_output --partial "inherit:"
  assert_output --partial "default: false"
  assert_output --partial "non-site consumer (infra)"
}

@test "render_root_shim infra declares no leaking image or interruptible key" {
  run render infra "" true true
  assert_success
  # The contract text mentions them; the YAML must not declare them at all.
  refute_line --regexp '^[[:space:]]*image:'
  refute_line --regexp '^[[:space:]]*interruptible:'
}

@test "render_root_shim infra keeps runner-tag routing without leaking defaults" {
  run render infra $'default:\n  tags: [boucle]\n\n' true true
  assert_success
  assert_output --partial "tags: [boucle]"
  refute_line --regexp '^[[:space:]]*image:'
  refute_line --regexp '^[[:space:]]*interruptible:'
}

@test "render_root_shim infra escapes a single quote in the e2e command" {
  run render infra "" "bash -c 'echo hi'" true
  assert_success
  assert_output --partial "BOUCLE_E2E_COMMAND: 'bash -c ''echo hi'''"
}

# ── Site profile: unchanged ───────────────────────────────────────────

@test "render_root_shim site is unchanged (no preset variables, no inherit)" {
  run render site "" false false
  assert_success
  assert_output --partial "Add your own jobs below this block"
  refute_output --partial "BOUCLE_DEPLOY_MODE"
  refute_output --partial "BOUCLE_E2E_COMMAND"
  refute_output --partial "inherit:"
}

# ── CLI surface ───────────────────────────────────────────────────────

@test "bin/setup --help documents --profile and BOUCLE_PROFILE" {
  run env -i PATH="$PATH" HOME="$HOME" bash bin/setup --help
  assert_success
  assert_output --partial "--profile"
  assert_output --partial "BOUCLE_PROFILE"
}

@test "bin/setup rejects an unknown --profile at parse time" {
  run env -i PATH="$PATH" HOME="$HOME" bash bin/setup --profile bogus
  assert_failure
  assert_output --partial "--profile must be 'site' or 'infra'"
}

@test "bin/setup wires BOUCLE_PROFILE and the shim renderer" {
  run grep -q 'BOUCLE_PROFILE' bin/setup
  assert_success
  run grep -q 'render_root_shim' bin/setup
  assert_success
}
