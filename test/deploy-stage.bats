#!/usr/bin/env bats
# test/deploy-stage.bats — the shared deploy stage, and the GitLab jobs that
# now call it instead of carrying their own copy.
#
# Context: .gitlab-ci.yml used to inline its own deploy and post-merge logic
# alongside lib/boucle-ci/{deploy,post-merge}.sh, and the two had drifted:
#
#   - deploy      — the inline copy did NOT rebuild (build-site hands it
#                   public/ as an artifact; rebuilding OOMs WASM toolchains on
#                   shell executors, framagit 2026-08), while the shared one
#                   always ran $BOUCLE_BUILD_CMD.
#   - post-merge  — the inline copy had no BOUCLE_DEPLOY_MODE=external branch
#                   at all, so on GitLab external mode never waited for the
#                   consumer's check suites.
#
# The reconciliation makes the build conditional on the output tree already
# being populated, which is true on GitLab (artifact) and false on GitHub (no
# build-site job) — so one code path serves both.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# ── The build-skip reconciliation ──────────────────────────────────────────

@test "deploy skips the build when the output tree is already populated" {
  run bash -c '
    cd "$BATS_TEST_TMPDIR" || exit 1
    mkdir -p public && echo "<html></html>" > public/index.html
    BOUCLE_BUILD_OUTPUT=public
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    if [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] \
      && [ -n "$(ls -A "$BOUCLE_BUILD_OUTPUT" 2> /dev/null)" ]; then
      echo "deploy: $BOUCLE_BUILD_OUTPUT already populated (build artifact) — skipping build"
    else
      eval "$BOUCLE_BUILD_CMD"
    fi
  '
  assert_success
  assert_output --partial "skipping build"
  refute_output --partial "BUILD_RAN"
}

@test "deploy runs the build when the output tree is missing (GitHub has no build-site job)" {
  run bash -c '
    cd "$BATS_TEST_TMPDIR" || exit 1
    BOUCLE_BUILD_OUTPUT=public
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    if [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] \
      && [ -n "$(ls -A "$BOUCLE_BUILD_OUTPUT" 2> /dev/null)" ]; then
      echo "skipping build"
    else
      eval "$BOUCLE_BUILD_CMD"
    fi
  '
  assert_success
  assert_output --partial "BUILD_RAN"
}

@test "deploy runs the build when the output tree exists but is empty" {
  # An empty directory is not a usable artifact — a stale mkdir must not be
  # mistaken for a build that already happened.
  run bash -c '
    cd "$BATS_TEST_TMPDIR" || exit 1
    mkdir -p public
    BOUCLE_BUILD_OUTPUT=public
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    if [ -n "${BOUCLE_BUILD_OUTPUT:-}" ] && [ -d "$BOUCLE_BUILD_OUTPUT" ] \
      && [ -n "$(ls -A "$BOUCLE_BUILD_OUTPUT" 2> /dev/null)" ]; then
      echo "skipping build"
    else
      eval "$BOUCLE_BUILD_CMD"
    fi
  '
  assert_success
  assert_output --partial "BUILD_RAN"
}

@test "the shared deploy stage carries the conditional build, not an unconditional one" {
  run grep -q 'already populated (build artifact) — skipping build' lib/boucle.sh
  assert_success
  # The bare `eval "$BOUCLE_BUILD_CMD"` must be inside the else branch.
  run awk '/already populated \(build artifact\)/ {seen=1} seen && /eval "\$BOUCLE_BUILD_CMD"/ {print "GUARDED"; exit}' lib/boucle.sh
  assert_output "GUARDED"
}

# ── The GitLab jobs now delegate instead of duplicating ────────────────────

@test "the GitLab deploy job calls the shared stage" {
  run bash -c "sed -n '/^deploy:/,/^  timeout:/p' .gitlab-ci.yml | grep -c 'boucle-ci deploy'"
  assert_success
  assert_output "1"
}

@test "the GitLab post-merge job calls the shared stage" {
  run bash -c "sed -n '/^post-merge:/,/^  timeout:/p' .gitlab-ci.yml | grep -c 'boucle-ci post-merge'"
  assert_success
  assert_output "1"
}

@test "neither migrated job kept an inline copy of its logic" {
  # The signatures of the two inline implementations that were removed. If one
  # reappears in .gitlab-ci.yml, the duplication is back.
  run grep -c 'no deployment URL from wrangler' .gitlab-ci.yml
  assert_output "0"
  run grep -c 'Waiting for deploy pipeline to complete before triggering e2e' .gitlab-ci.yml
  assert_output "0"
}

@test "post-merge no longer overrides before_script with a drifted copy" {
  # The removed override pinned glab 1.50.0 while the global before_script
  # pins 1.111.0 — exactly the drift this migration exists to remove.
  run bash -c "sed -n '/^post-merge:/,/^  timeout:/p' .gitlab-ci.yml | grep -c 'before_script:'"
  assert_output "0"
}

@test "BOUCLE_FORGE is set, or bin/boucle-ci cannot bootstrap on GitLab" {
  # lib/boucle-ci.sh exits 1 when BOUCLE_FORGE is unset, so every migrated job
  # depends on this variable being defined in the engine pipeline.
  run grep -qE '^  BOUCLE_FORGE: "gitlab"' .gitlab-ci.yml
  assert_success
}

@test "deploy skips in external mode (consumer CI handles deploy)" {
  # BOUCLE_DEPLOY_MODE=external means the consumer's own CI deploys (SSH,
  # Docker, Ansible, etc.). The deploy stage must skip cleanly — not run
  # npm run build on a repo with no package.json (the engine repo regression:
  # every push to main failed with ENOENT package.json because the deploy
  # stage ran the default BOUCLE_BUILD_CMD on a shell project).
  run grep -q 'boucle_is_external_deploy' lib/boucle.sh
  assert_success
  run grep -q 'consumer CI handles deploy, skipping' lib/boucle.sh
  assert_success
}

# ── boucle_do_deploy: the extracted build+deploy core ─────────────────────

@test "boucle_do_deploy returns the URL and does not chain to e2e (cloudflare)" {
  run bash -c '
    # Pin the mode: a runner that exports BOUCLE_DEPLOY_MODE=external
    # (a consumer variable) would otherwise make this skip the deploy.
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_DEPLOY_CMD="echo DEPLOYED https://example.com"
    BOUCLE_DEPLOY_URL_REGEX="https://[a-zA-Z0-9./-]+"
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    BOUCLE_BUILD_OUTPUT=""
    BOUCLE_DEFAULT_BRANCH=main
    curl() { echo "200"; }
    source lib/boucle.sh
    chain_to_role() { echo "CHAINED:$1:$2"; }
    out=$(boucle_do_deploy)
    rc=$?
    echo "RC=$rc"
    echo "OUT=$out"
    [ "$rc" -eq 0 ]
    [ "$out" = "https://example.com" ]
  '
  assert_success
  assert_output --partial "RC=0"
  assert_output --partial "OUT=https://example.com"
  refute_output --partial "CHAINED"
}

@test "boucle_do_deploy returns empty URL for empty BOUCLE_DEPLOY_CMD (declarative Pages)" {
  run bash -c '
    BOUCLE_DEPLOY_CMD=""
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    BOUCLE_BUILD_OUTPUT=""
    source lib/boucle.sh
    out=$(boucle_do_deploy)
    rc=$?
    echo "RC=$rc"
    echo "OUT=[$out]"
    [ "$rc" -eq 0 ]
    [ -z "$out" ]
  '
  assert_success
  assert_output --partial "RC=0"
  assert_output --partial "OUT=[]"
}

@test "boucle_do_deploy returns empty URL in external mode" {
  run bash -c '
    BOUCLE_DEPLOY_CMD="echo DEPLOYED https://example.com"
    BOUCLE_DEPLOY_MODE=external
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    BOUCLE_BUILD_OUTPUT=""
    source lib/boucle.sh
    out=$(boucle_do_deploy)
    rc=$?
    echo "RC=$rc"
    echo "OUT=[$out]"
    [ "$rc" -eq 0 ]
    [ -z "$out" ]
  '
  assert_success
  assert_output --partial "RC=0"
  assert_output --partial "OUT=[]"
}

@test "boucle_do_deploy exits non-zero when deploy fails with no URL" {
  run bash -c '
    BOUCLE_DEPLOY_MODE=self
    BOUCLE_DEPLOY_CMD="echo FAILED; exit 1"
    BOUCLE_DEPLOY_URL_REGEX="https://[a-zA-Z0-9./-]+"
    BOUCLE_BUILD_CMD="echo BUILD_RAN"
    BOUCLE_BUILD_OUTPUT=""
    BOUCLE_DEFAULT_BRANCH=main
    source lib/boucle.sh
    boucle_do_deploy
    rc=$?
    echo "RC=$rc"
    [ "$rc" -ne 0 ]
  '
  assert_success
  assert_output --partial "RC=1"
}
