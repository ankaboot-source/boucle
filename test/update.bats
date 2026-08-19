#!/usr/bin/env bats
# test/update.bats — unit tests for bin/update pure functions.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # Source bin/update (functions only — main guarded by BASH_SOURCE check).
  source bin/update
}

# ── get_mode ──────────────────────────────────────────────────────────

@test "get_mode defaults to release when BOUCLE_UPDATE_MODE unset" {
  unset BOUCLE_UPDATE_MODE
  run get_mode
  assert_success
  assert_output "release"
}

@test "get_mode reads dev" {
  BOUCLE_UPDATE_MODE="dev"
  run get_mode
  assert_success
  assert_output "dev"
}

@test "get_mode reads release" {
  BOUCLE_UPDATE_MODE="release"
  run get_mode
  assert_success
  assert_output "release"
}

# ── get_current_version ───────────────────────────────────────────────

@test "get_current_version returns empty when no version file" {
  VERSION_FILE="$(mktemp -u)"
  run get_current_version
  assert_success
  assert_output ""
  rm -f "$VERSION_FILE"
}

@test "get_current_version reads file content" {
  VERSION_FILE="$(mktemp)"
  echo "abc123def456" > "$VERSION_FILE"
  run get_current_version
  assert_success
  assert_output "abc123def456"
  rm -f "$VERSION_FILE"
}

# ── needs_update ──────────────────────────────────────────────────────

@test "needs_update: empty upstream → no update (returns 1)" {
  run needs_update "abc" ""
  assert_failure
}

@test "needs_update: same versions → no update (returns 1)" {
  run needs_update "abc" "abc"
  assert_failure
}

@test "needs_update: different versions → update (returns 0)" {
  run needs_update "abc" "def"
  assert_success
}

@test "needs_update: empty current, non-empty upstream → update (returns 0)" {
  run needs_update "" "def"
  assert_success
}

# ── SYNC_PATHS ────────────────────────────────────────────────────────

@test "SYNC_PATHS includes .jcode/agents (agent prompt propagation)" {
  # Agent prompts (triage.md, worker.md, reviewer.md, e2e.md) must propagate
  # to consumers on update, otherwise prompt fixes never reach CI.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial ".jcode"
}

@test "SYNC_PATHS includes .jcode/skills (skill propagation)" {
  # Skills must propagate to consumers on update, otherwise skill fixes
  # never reach CI.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial ".jcode"
}

@test "SYNC_PATHS includes lib (boucle-ci pipeline libraries)" {
  # lib/boucle-ci.sh + lib/boucle-ci/ must propagate to consumers on update,
  # otherwise bin/boucle-ci cannot source its stage functions and every
  # pipeline job fails on the consumer (comment in bin/update promises
  # "lib/ is always synced" — the variable list must honor it).
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  assert_output --partial "lib"
}

@test "SYNC_PATHS does NOT include .pi (migrated to .jcode in eba0013)" {
  # .pi was migrated to .jcode (commit eba0013, 2026-08-06). A stale .pi
  # entry in SYNC_PATHS is silently skipped by the [ -e ] guard in
  # download_and_extract, but it's dead cruft that confuses readers and
  # risks a false-positive if a .pi dir ever reappears upstream.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  refute_output --partial ".pi"
}

@test "SYNC_PATHS includes .jcode as a whole (not just subdirs)" {
  # .jcode/ is owned entirely by the engine (agents/, skills/,
  # UPSTREAM-FIX-WORKFLOW.md, DESIGN-template.md, prompt-overlay.md).
  # Syncing it as a whole is simpler and catches new top-level files
  # (e.g. a future .jcode/config.toml) without needing a SYNC_PATHS bump.
  run bash -c 'source bin/update && echo "$SYNC_PATHS"'
  assert_success
  # ".jcode" matches both ".jcode" and ".jcode/agents" — we want the
  # bare ".jcode" token (whole-dir sync), not just a subdir.
  assert_output --regexp '(^| )\.jcode( |$)'
}

# ── UPSTREAM_TARBALL (API endpoint, not codeload direct) ──────────────

@test "UPSTREAM_TARBALL uses the API endpoint (codeload direct 404s)" {
  # The direct codeload.github.com URL 404s for some repos/branches.
  # The API endpoint (api.github.com/repos/.../tarball/...) redirects
  # to codeload with a signed URL and works for both public and private
  # (with auth) repos.
  run bash -c 'source bin/update && echo "$UPSTREAM_TARBALL"'
  assert_success
  assert_output --partial "api.github.com/repos/ankaboot-source/boucle/tarball"
  refute_output --partial "codeload.github.com"
}

# ── curl_with_auth (token injection) ──────────────────────────────────

@test "curl_with_auth passes GITHUB_TOKEN as bearer header" {
  # When GITHUB_TOKEN is set, curl_with_auth injects it as a bearer
  # header — required for private repos and to raise the rate limit.
  # Stub curl to capture the args it was called with.
  GITHUB_TOKEN="test-token-abc123"
  unset GH_TOKEN
  curl() { echo "curl $*"; }
  export -f curl
  run curl_with_auth "https://example.com"
  assert_success
  assert_output --partial "Authorization: Bearer test-token-abc123"
  unset -f curl
}

@test "curl_with_auth falls back to GH_TOKEN when GITHUB_TOKEN unset" {
  unset GITHUB_TOKEN
  GH_TOKEN="test-token-xyz789"
  curl() { echo "curl $*"; }
  export -f curl
  run curl_with_auth "https://example.com"
  assert_success
  assert_output --partial "Authorization: Bearer test-token-xyz789"
  unset -f curl
}

@test "curl_with_auth works without any token (public repos)" {
  unset GITHUB_TOKEN
  unset GH_TOKEN
  curl() { echo "curl $*"; }
  export -f curl
  run curl_with_auth "https://example.com"
  assert_success
  refute_output --partial "Authorization"
  unset -f curl
}

# ── ENGINE_DIR detection ──────────────────────────────────────────────

@test "ENGINE_DIR defaults to . when bin/update is at repo root (dogfood/legacy)" {
  # When bin/update is at the repo root (dogfood or legacy full-copy install),
  # ENGINE_DIR should resolve to "." — the engine files live at the root.
  # We're already at the repo root when bats runs, so source directly.
  run bash -c 'source bin/update && echo "$ENGINE_DIR"'
  assert_success
  assert_output "."
}

@test "VERSION_FILE is relative to ENGINE_DIR" {
  # VERSION_FILE must be "$ENGINE_DIR/.boucle-version", not a fixed path,
  # so it resolves correctly in both legacy (./.boucle-version) and
  # .boucle/ install (.boucle/.boucle-version) models.
  run bash -c 'source bin/update && echo "$VERSION_FILE"'
  assert_success
  assert_output --partial ".boucle-version"
}

# ── Consumer root file propagation ─────────────────────────────────────

@test "propagate_consumer_root_files is a no-op when ENGINE_DIR is . (dogfood)" {
  ENGINE_DIR="." run propagate_consumer_root_files
  assert_success
  assert_output ""
}

@test "propagate_consumer_root_files copies charter docs to the consumer root" {
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle/.github/workflows"
  echo "# engine AGENTS" > "$tmpdir/.boucle/AGENTS.md"
  echo "# engine SKILL" > "$tmpdir/.boucle/SKILL.md"
  echo "# engine ARCH" > "$tmpdir/.boucle/ARCHITECTURE.md"
  echo "# workflow" > "$tmpdir/.boucle/.github/workflows/boucle.yml"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  # AGENTS.md is consumer-owned — NOT propagated. SKILL.md + ARCHITECTURE.md
  # are engine-owned and propagated.
  refute_output --partial "AGENTS.md"
  assert_output --partial "SKILL.md"
  assert_output --partial "ARCHITECTURE.md"
  [ ! -f "$tmpdir/AGENTS.md" ]
  [ -f "$tmpdir/SKILL.md" ]
  [ -f "$tmpdir/ARCHITECTURE.md" ]
  [ -f "$tmpdir/.github/workflows/boucle.yml" ]
}

@test "propagate_consumer_root_files does NOT overwrite consumer-owned AGENTS.md" {
  # AGENTS.md is consumer-owned (project-specific context). The engine has
  # its own AGENTS.md inside .boucle/, but it MUST NOT overwrite the consumer's.
  # Regression: bin/setup/bin/update used to copy AGENTS.md from the engine,
  # destroying the consumer's project context (observed during m3llm migration).
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle"
  echo "# consumer AGENTS — project context" > "$tmpdir/AGENTS.md"
  echo "# engine AGENTS — generic charter" > "$tmpdir/.boucle/AGENTS.md"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  run cat "$tmpdir/AGENTS.md"
  assert_output "# consumer AGENTS — project context"
}

@test "propagate_consumer_root_files does NOT overwrite consumer-owned docs" {
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle"
  echo "# consumer README" > "$tmpdir/README.md"
  echo "# engine README" > "$tmpdir/.boucle/README.md"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  run cat "$tmpdir/README.md"
  assert_output "# consumer README"
}
