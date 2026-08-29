#!/usr/bin/env bats
# test/forge-gitlab.bats — tests for the GitLab forge backend's CI-variable
# contract. No dedicated suite existed because most gitlab.sh functions need
# a live forge; forge_ci_var_* are unit-testable with a glab stub.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

@test "gitlab forge_ci_var_set is unbound-safe when BOUCLE_PROJECT_ID is unset (set -u)" {
  # Issue #120: bin/update runs under `set -u` BEFORE the before_script
  # exports the forge context. The expansion in the args array killed the
  # script (exit 127) before the self-update commit+push — the consumer
  # stayed frozen on an old engine with only the generic "self-update
  # failed" fallback in the trace. The variable write is best-effort:
  # unset context ⇒ skip with a message, never die.
  run bash -c '
    set -u
    unset BOUCLE_PROJECT_ID
    glab() { echo "glab must not run: $*"; return 1; }
    source bin/forge/gitlab.sh
    forge_ci_var_set "BOUCLE_VERSION" "abc123"
  '
  assert_success
  assert_output --partial "skipping"
  refute_output --partial "glab must not run"
}

@test "gitlab forge_ci_var_set falls back to PUT when the POST is rejected (upsert)" {
  # Issue #120: GitLab rejects a POST on an existing key ("key has already
  # been taken") and the plain || true swallowed it, so BOUCLE_VERSION never
  # advanced past its first write and every pipeline re-extracted the
  # engine tarball. The write MUST degrade to a PUT (update). The function
  # silences the glab calls (> /dev/null 2>&1), so the stub records its
  # invocations to a side-effect file for observation.
  tmp=$(mktemp -d)
  LOG="$tmp/calls.log"
  run env TEST_LOG="$LOG" bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="framagit.org"
    glab() {
      local method="" prev="" a
      for a in "$@"; do
        [ "$prev" = "-X" ] && method="$a"
        prev="$a"
      done
      printf "%s %s\n" "$method" "$*" >> "$TEST_LOG"
      [ "$method" = "POST" ] && return 1 # "key has already been taken"
      return 0
    }
    source bin/forge/gitlab.sh
    forge_ci_var_set "BOUCLE_VERSION" "57378c3"
  '
  assert_success
  run grep -q "^POST .*-X POST /projects/126561/variables " "$LOG"
  assert_success
  run grep -q "^PUT .*-X PUT /projects/126561/variables/BOUCLE_VERSION" "$LOG"
  assert_success
  rm -rf "$tmp"
}

@test "gitlab forge_ci_var_get/list are no-ops without a project id (set -u)" {
  run bash -c '
    set -u
    unset BOUCLE_PROJECT_ID
    glab() { echo "glab must not run: $*"; }
    source bin/forge/gitlab.sh
    forge_ci_var_get "BOUCLE_VERSION"
    forge_ci_var_list
  '
  assert_success
  refute_output --partial "glab must not run"
}
