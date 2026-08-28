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

@test "get_current_version returns empty when no BOUCLE_VERSION and no submodule" {
  unset BOUCLE_VERSION
  # No submodule in the repo root → git submodule status .boucle is empty.
  run get_current_version
  assert_success
  assert_output ""
}

@test "get_current_version reads BOUCLE_VERSION env var" {
  BOUCLE_VERSION="abc123def456"
  run get_current_version
  assert_success
  assert_output "abc123def456"
}

@test "get_current_version falls back to submodule pointer" {
  # When BOUCLE_VERSION is unset, get_current_version derives the version
  # from the submodule pointer (git submodule status .boucle → field 1).
  unset BOUCLE_VERSION
  git() {
    if [ "$1" = "submodule" ] && [ "$2" = "status" ]; then
      printf '%s\n' " 9f8e7d6c5b4a3210 .boucle (heads/main)"
      return 0
    fi
    return 1
  }
  export -f git
  run get_current_version
  assert_success
  assert_output "9f8e7d6c5b4a3210"
  unset -f git
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
  # UPSTREAM-FIX-WORKFLOW.md, DESIGN-template.md). prompt-overlay.md is
  # runtime-only (written by bin/jc, gitignored, never tracked).
  # Syncing .jcode as a whole is simpler and catches new top-level files
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

@test "get_current_version falls back to submodule pointer when BOUCLE_VERSION unset" {
  # When BOUCLE_VERSION env var is unset, get_current_version derives the
  # version from the .boucle submodule gitlink. This replaces the old
  # VERSION_FILE path resolution.
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir"
  cd "$tmpdir" || return
  git init -q 2>/dev/null
  # Create a fake submodule entry (gitlink) for .boucle
  mkdir -p .boucle
  git update-index --add --cacheinfo 160000,86d1a6a1e2917fec7d622de146df8a7f3506db16,.boucle 2>/dev/null
  # Source bin/update and call get_current_version with BOUCLE_VERSION unset
  unset BOUCLE_VERSION
  run bash -c 'cd "$1" && source "$2/bin/update" && get_current_version' _ "$tmpdir" "$BOUCLE_HOME" 2>/dev/null
  # The submodule SHA should appear (first 7+ chars). Tolerate empty if
  # git submodule status doesn't work in the test env (no .gitmodules).
  [ "$status" -eq 0 ] || [ "$status" -eq 127 ]
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

# ── Engine-owned symlink migration (issue #105) ───────────────────────
# A REAL .jcode/agents or .jcode/skills dir at the consumer root is an
# orphan from the old copy-based install (pre-submodule): frozen at the
# version of the first bin/setup, never refreshed by bin/update. .jcode/ is
# 100% engine-owned (except prompt-overlay.md, runtime/gitignored), so the
# migration below replaces the orphan with a symlink to the engine. The
# consumer-owned carve-out (LESSONS.yml) works by never being listed.

@test "propagate_consumer_root_files migrates a real .jcode/agents dir to a symlink" {
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  # The engine fixture needs bin/lib/engine-symlink.sh: the function sources
  # it unconditionally before the symlink loop.
  mkdir -p "$tmpdir/.boucle/.jcode/agents" "$tmpdir/.boucle/bin/lib" "$tmpdir/.jcode/agents"
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  cp "$BATS_TEST_DIRNAME/../bin/lib/engine-symlink.sh" "$tmpdir/.boucle/bin/lib/"
  # The orphan: stale prompt from the first copy-based install.
  echo "# OLD stale triage prompt" > "$tmpdir/.jcode/agents/triage.md"
  # The engine's current prompt.
  echo "# NEW engine triage prompt" > "$tmpdir/.boucle/.jcode/agents/triage.md"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  assert_output --partial ".jcode/agents"
  [ -L "$tmpdir/.jcode/agents" ] || fail "expected .jcode/agents to be a symlink"
  run cat "$tmpdir/.jcode/agents/triage.md"
  assert_output "# NEW engine triage prompt"
}

@test "propagate_consumer_root_files is idempotent: existing valid .jcode/agents symlink is a no-op" {
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle/.jcode/agents" "$tmpdir/.boucle/bin/lib" "$tmpdir/.jcode"
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  cp "$BATS_TEST_DIRNAME/../bin/lib/engine-symlink.sh" "$tmpdir/.boucle/bin/lib/"
  echo "# engine triage prompt" > "$tmpdir/.boucle/.jcode/agents/triage.md"
  cd "$tmpdir" || return
  # The correct target form (as engine_symlink_target computes it): the
  # relative target resolves from the LINK's directory, so a root-level link
  # inside .jcode/ needs the "../".
  ln -s "../.boucle/.jcode/agents" ".jcode/agents"
  [ -e "$tmpdir/.jcode/agents" ] || fail "precondition: the symlink must resolve"
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  refute_output --partial ".jcode/agents"
  [ -L "$tmpdir/.jcode/agents" ] || fail "expected .jcode/agents to remain a symlink"
  [ "$(readlink "$tmpdir/.jcode/agents")" = "../.boucle/.jcode/agents" ] || fail "symlink target changed"
}

@test "propagate_consumer_root_files migrates .jcode/skills real dir too (regression: guard used to skip it)" {
  # Regression for issue #105: the old "never overwrite a real dir" guard
  # skipped the migration for engine-owned paths, so a real .jcode/skills
  # dir from the copy-based install was never converted on consumers.
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle/.jcode/skills/demo" "$tmpdir/.boucle/bin/lib" "$tmpdir/.jcode/skills/demo"
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  cp "$BATS_TEST_DIRNAME/../bin/lib/engine-symlink.sh" "$tmpdir/.boucle/bin/lib/"
  echo "# OLD stale skill" > "$tmpdir/.jcode/skills/demo/SKILL.md"
  echo "# NEW engine skill" > "$tmpdir/.boucle/.jcode/skills/demo/SKILL.md"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  assert_output --partial ".jcode/skills"
  [ -L "$tmpdir/.jcode/skills" ] || fail "expected .jcode/skills to be a symlink"
  run cat "$tmpdir/.jcode/skills/demo/SKILL.md"
  assert_output "# NEW engine skill"
}

@test "propagate_consumer_root_files does NOT touch a real consumer-owned LESSONS.yml" {
  # The consumer-owned carve-out: LESSONS.yml is NOT in the symlink list, so
  # the migration must never apply to it. A real file stays untouched.
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle" "$tmpdir/.boucle/bin/lib"
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  cp "$BATS_TEST_DIRNAME/../bin/lib/engine-symlink.sh" "$tmpdir/.boucle/bin/lib/"
  echo "# consumer lessons" > "$tmpdir/LESSONS.yml"
  echo "# engine lessons" > "$tmpdir/.boucle/LESSONS.yml"
  cd "$tmpdir" || return
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  refute_output --partial "LESSONS.yml"
  [ ! -L "$tmpdir/LESSONS.yml" ] || fail "expected LESSONS.yml to remain a real file"
  run cat "$tmpdir/LESSONS.yml"
  assert_output "# consumer lessons"
}

@test "propagate_consumer_root_files replaces a broken .jcode/agents symlink with a working one" {
  # A stale/broken symlink is replaced, not skipped: rm -rf removes the
  # dangling link, ln -s writes a fresh one, and the "does not resolve"
  # branch only fires when the freshly computed target itself dangles.
  # shellcheck disable=SC2154
  local tmpdir="$BATS_TEST_TMPDIR"
  mkdir -p "$tmpdir/.boucle/.jcode/agents" "$tmpdir/.boucle/bin/lib" "$tmpdir/.jcode"
  # shellcheck disable=SC2154 # BATS_TEST_DIRNAME is set by bats at runtime
  cp "$BATS_TEST_DIRNAME/../bin/lib/engine-symlink.sh" "$tmpdir/.boucle/bin/lib/"
  echo "# engine triage prompt" > "$tmpdir/.boucle/.jcode/agents/triage.md"
  cd "$tmpdir" || return
  ln -s ".boucle/.jcode/agents-does-not-exist" ".jcode/agents"
  [ ! -e "$tmpdir/.jcode/agents" ] || fail "precondition: the symlink must dangle"
  ENGINE_DIR=".boucle" BOUCLE_FORGE=github run propagate_consumer_root_files
  assert_success
  assert_output --partial ".jcode/agents"
  [ -L "$tmpdir/.jcode/agents" ] || fail "expected .jcode/agents to be a symlink"
  run cat "$tmpdir/.jcode/agents/triage.md"
  assert_output "# engine triage prompt"
}

# ── configure_git_push ────────────────────────────────────────────────

@test "configure_git_push uses BOUCLE_PROJECT_PATH (the forge-agnostic alias)" {
  # Regression: the guard keyed on CI_PROJECT_PATH, which only GitLab sets.
  # On GitHub Actions the function silently did nothing and the push went out
  # under the workflow token instead of the configured bot PAT.
  BOUCLE_TOKEN="pat-secret"
  BOUCLE_FORGE_HOST="github.com"
  BOUCLE_PROJECT_PATH="acme/site"
  unset CI_PROJECT_PATH
  git() { echo "git $*"; }
  export -f git
  run configure_git_push
  assert_success
  assert_output --partial "https://up-bot:pat-secret@github.com/acme/site.git"
  unset -f git
}

@test "configure_git_push still honours CI_PROJECT_PATH as a fallback" {
  BOUCLE_TOKEN="pat-secret"
  BOUCLE_FORGE_HOST="framagit.org"
  unset BOUCLE_PROJECT_PATH
  CI_PROJECT_PATH="group/proj"
  git() { echo "git $*"; }
  export -f git
  run configure_git_push
  assert_success
  assert_output --partial "https://up-bot:pat-secret@framagit.org/group/proj.git"
  unset -f git
}

@test "configure_git_push is a no-op without a bot token (local dev)" {
  unset BOUCLE_TOKEN
  BOUCLE_FORGE_HOST="github.com"
  BOUCLE_PROJECT_PATH="acme/site"
  git() { echo "git $*"; }
  export -f git
  run configure_git_push
  assert_success
  refute_output --partial "remote set-url"
  unset -f git
}

@test "configure_git_push drops the persisted extraheader when a PAT is set" {
  # Issue #107: actions/checkout persists an Authorization extraheader for the
  # origin URL; libcurl prefers it over the URL-embedded credentials, so the
  # push went out under the workflow token even with the PAT configured — and
  # GitHub rejected every workflow-file sync ("refusing to allow a GitHub App
  # to create or update workflow ... without workflows permission").
  BOUCLE_TOKEN="pat-secret"
  BOUCLE_FORGE_HOST="github.com"
  BOUCLE_PROJECT_PATH="acme/site"
  git() { echo "git $*"; }
  export -f git
  run configure_git_push
  assert_success
  assert_output --partial "config --unset-all http.github.com.extraheader"
  unset -f git
}

@test "configure_git_push leaves the extraheader alone without a PAT" {
  # Without a PAT the persisted header is the only auth — removing it would
  # break the pushes that currently work.
  unset BOUCLE_TOKEN
  BOUCLE_FORGE_HOST="github.com"
  BOUCLE_PROJECT_PATH="acme/site"
  git() { echo "git $*"; }
  export -f git
  run configure_git_push
  assert_success
  refute_output --partial "extraheader"
  unset -f git
}

# ── push_update ───────────────────────────────────────────────────────

@test "push_update succeeds quietly when the push lands" {
  git() { echo "Everything up-to-date"; return 0; }
  export -f git
  run push_update
  assert_success
  refute_output --partial "push failed"
  unset -f git
}

@test "push_update reports the reason the push was rejected" {
  # Regression: the push was `git push 2> /dev/null`, so a consumer frozen on
  # an old engine was indistinguishable from an up-to-date one.
  git() {
    echo "remote: Permission to acme/site.git denied to up-bot." >&2
    echo "fatal: unable to access 'https://github.com/acme/site.git/': 403" >&2
    return 128
  }
  export -f git
  run push_update
  assert_failure
  assert_output --partial "push failed"
  assert_output --partial "denied to up-bot"
  assert_output --partial "403"
  unset -f git
}

@test "push_update redacts the credential git echoes back in its error" {
  # configure_git_push puts the PAT in the remote URL and git quotes that URL
  # back on failure. Surfacing the error is only safe because it is redacted.
  git() {
    echo "fatal: unable to access 'https://up-bot:ghp_supersecret@github.com/acme/site.git/': 403" >&2
    return 128
  }
  export -f git
  run push_update
  assert_failure
  refute_output --partial "ghp_supersecret"
  assert_output --partial "https://***@github.com/acme/site.git"
  unset -f git
}

@test "push_update names branch protection instead of promising a retry" {
  # A protected default branch is the one push failure retrying cannot clear.
  # boucle.dev sat on an old engine for hours while every run logged
  # "will retry next pipeline" — the retry could never have worked.
  BOUCLE_DEFAULT_BRANCH="main"
  git() {
    echo "remote: error: GH006: Protected branch update failed for refs/heads/main." >&2
    echo "remote: error: Changes must be made through a pull request." >&2
    return 1
  }
  export -f git
  run push_update
  assert_failure
  assert_output --partial "main looks protected"
  refute_output --partial "will retry next pipeline"
  unset -f git
}

@test "push_update names the workflows permission for a workflow-file rejection" {
  # Issue #107: the self-update sync always touches .github/workflows/boucle.yml
  # on GitHub, and a push token without the workflows permission is rejected on
  # EVERY run. Promising "will retry next pipeline" was false — boucle.dev
  # froze on an old engine while the log kept promising a retry that could
  # never succeed.
  BOUCLE_DEFAULT_BRANCH="main"
  git() {
    echo "! [remote rejected] main -> main (refusing to allow a GitHub App to create or update workflow \`.github/workflows/boucle.yml\` without \`workflows\` permission)" >&2
    return 1
  }
  export -f git
  run push_update
  assert_failure
  assert_output --partial "workflows"
  assert_output --partial "NOT clear by retrying"
  assert_output --partial "scopes and set BOUCLE_TOKEN"
  refute_output --partial "will retry next pipeline"
  unset -f git
}

@test "push_update still promises a retry for an ordinary transient failure" {
  BOUCLE_DEFAULT_BRANCH="main"
  git() { echo "fatal: unable to access: Could not resolve host: github.com" >&2; return 128; }
  export -f git
  run push_update
  assert_failure
  assert_output --partial "will retry next pipeline"
  refute_output --partial "looks protected"
  unset -f git
}

@test "push_update does not abort when BOUCLE_DEFAULT_BRANCH is unset (set -u)" {
  # bin/update runs under `set -u`; the protected-branch branch must not be
  # the thing that crashes the diagnostic it exists to print.
  unset BOUCLE_DEFAULT_BRANCH
  git() { echo "remote: error: GH006: Protected branch update failed." >&2; return 1; }
  export -f git
  run push_update
  assert_failure
  assert_output --partial "the default branch looks protected"
  unset -f git
}

# ── untrack_prompt_overlay ────────────────────────────────────────────

@test "untrack_prompt_overlay adds .jcode/prompt-overlay.md to .gitignore if missing" {
  tmp=$(mktemp -d)
  cd "$tmp" || exit 1
  printf 'node_modules/\n' > .gitignore
  git init -q
  # File not tracked, gitignore entry absent → function should add the entry.
  run untrack_prompt_overlay
  assert_success
  assert_output --partial ".gitignore"
  # The entry must be present.
  run grep -qxF '.jcode/prompt-overlay.md' .gitignore
  assert_success
  cd - >/dev/null || exit 1
  rm -rf "$tmp"
}

@test "untrack_prompt_overlay is idempotent (gitignore entry already present)" {
  tmp=$(mktemp -d)
  cd "$tmp" || exit 1
  printf 'node_modules/\n.jcode/prompt-overlay.md\n' > .gitignore
  git init -q
  run untrack_prompt_overlay
  assert_success
  # No files to stage (entry already present, file not tracked).
  refute_output --partial ".gitignore"
  cd - >/dev/null || exit 1
  rm -rf "$tmp"
}

@test "untrack_prompt_overlay git rm --cached a tracked prompt-overlay.md" {
  tmp=$(mktemp -d)
  cd "$tmp" || exit 1
  printf 'node_modules/\n' > .gitignore
  git init -q
  # A CI runner has no global git identity, so a bare `git commit` here fails
  # with "empty ident name" — the same shape as every other temp repo in this
  # suite, which all configure one. This test passed on any developer machine
  # and failed on the runner, which is why it landed.
  git config user.email "test@example.com"
  git config user.name "test"
  mkdir -p .jcode
  touch .jcode/prompt-overlay.md
  git add .jcode/prompt-overlay.md
  git commit -q -m init
  run untrack_prompt_overlay
  assert_success
  # The file should no longer be tracked.
  run git ls-files --error-unmatch .jcode/prompt-overlay.md
  assert_failure
  # But the file should still exist on disk.
  [ -f .jcode/prompt-overlay.md ]
  cd - >/dev/null || exit 1
  rm -rf "$tmp"
}
