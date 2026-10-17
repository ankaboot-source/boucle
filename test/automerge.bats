#!/usr/bin/env bats
# Bot-PR auto-merge (#138): forge_mr_list primitive + eligibility sweep tests.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

@test "forge_mr_list (github): extracts the unified shape from open pulls" {
  TMPF=$(mktemp)
  awk -v fn="forge_mr_list" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' bin/forge/github.sh > "$TMPF"
  run bash -c "
    _gh_api() { echo '[{\"number\":10,\"user\":{\"login\":\"dependabot[bot]\"},\"title\":\"Bump actions/checkout from 4.1.0 to 4.1.2\",\"labels\":[{\"name\":\"dependencies\"}],\"draft\":false,\"head\":{\"ref\":\"dependabot/github_actions/actions/checkout-4.1.2\",\"sha\":\"abc123\"},\"body\":\"Bump note\"}]'; }
    source '$TMPF'
    forge_mr_list | jq -r '[.[0].iid, .[0].author, .[0].labels, .[0].draft, .[0].head_sha] | @tsv'
  "
  assert_success
  assert_line '10	dependabot[bot]	dependencies	false	abc123'
  rm -f "$TMPF"
}

@test "forge_mr_list (github): echoes [] when the API call fails" {
  TMPF=$(mktemp)
  awk -v fn="forge_mr_list" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' bin/forge/github.sh > "$TMPF"
  run bash -c "
    _gh_api() { return 1; }
    source '$TMPF'
    forge_mr_list
  "
  assert_output '[]'
  rm -f "$TMPF"
}

@test "forge_mr_list (gitlab): extracts the unified shape from opened MRs" {
  TMPF=$(mktemp)
  awk -v fn="forge_mr_list" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' bin/forge/gitlab.sh > "$TMPF"
  run bash -c "
    glab() { echo '[{\"iid\":7,\"author\":{\"username\":\"dependabot[bot]\"},\"title\":\"Bump pillow (security advisories)\",\"labels\":[\"dependencies\"],\"draft\":false,\"source_branch\":\"dependabot/security/pillow\",\"sha\":\"def456\",\"description\":\"Security advisory update\"}]'; }
    source '$TMPF'
    forge_mr_list | jq -r '[.[0].iid, .[0].author, .[0].labels, .[0].head_sha] | @tsv'
  "
  assert_success
  assert_line '7	dependabot[bot]	dependencies	def456'
  rm -f "$TMPF"
}

lib_funcs() {
  local out="${!#}" f
  for f in "$@"; do
    [ "$f" = "$out" ] && continue
    awk -v fn="$f" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' lib/boucle.sh
  done > "$out"
}

@test "semver: version normalization handles bare ints, v-prefix, partial" {
  TMPF=$(mktemp); lib_funcs boucle_semver_version "$TMPF"
  run bash -c "source '$TMPF'; boucle_semver_version '4'; boucle_semver_version 'v4.1.0'; boucle_semver_version '4.1'; boucle_semver_version '4.1.2'"
  assert_output '4 0 0
4 1 0
4 1 0
4 1 2'
  run bash -c "source '$TMPF'; boucle_semver_version 'abc'"
  assert_failure
  rm -f "$TMPF"
}

@test "semver: gate classifies major, backward moves fail-closed" {
  TMPF=$(mktemp); lib_funcs boucle_semver_version boucle_semver_gate "$TMPF"
  run bash -c "source '$TMPF'; boucle_semver_gate '4.1.0' '4.1.2'"; assert_output "patch"
  run bash -c "source '$TMPF'; boucle_semver_gate '4.1.0' '4.2.0'"; assert_output "minor"
  run bash -c "source '$TMPF'; boucle_semver_gate '4' '5'"; assert_output "major"
  run bash -c "source '$TMPF'; boucle_semver_gate '4.2.0' '4.1.0'"; assert_failure
  run bash -c "source '$TMPF'; boucle_semver_gate 'x' '4.1.0'"; assert_failure
  rm -f "$TMPF"
}

@test "security: title, label or branch signals, any wins" {
  TMPF=$(mktemp); lib_funcs boucle_pr_is_security "$TMPF"
  run bash -c "source '$TMPF'; boucle_pr_is_security 'Bump pillow (security advisories)' '' ''"; assert_success
  run bash -c "source '$TMPF'; boucle_pr_is_security 'Bump x' 'dependencies,security' ''"; assert_success
  run bash -c "source '$TMPF'; boucle_pr_is_security 'Bump x' 'vulnerability' ''"; assert_success
  run bash -c "source '$TMPF'; boucle_pr_is_security 'Bump x' '' 'dependabot/security/pillow'"; assert_success
  run bash -c "source '$TMPF'; boucle_pr_is_security 'Bump x' 'dependencies' 'renovate/eslint-9.x'"; assert_failure
  rm -f "$TMPF"
}

@test "title gate: dependabot from-to versions; grouped PRs fail-closed" {
  TMPF=$(mktemp); lib_funcs boucle_semver_version boucle_semver_gate boucle_title_semver_gate "$TMPF"
  run bash -c "source '$TMPF'; boucle_title_semver_gate 'Bump actions/checkout from 4.1.0 to 4.1.2'"; assert_output "patch"
  run bash -c "source '$TMPF'; boucle_title_semver_gate 'Bump pillow from 7.2 to 9.0'"; assert_output "major"
  run bash -c "source '$TMPF'; boucle_title_semver_gate 'Bump the npm group with 2 updates'; "; assert_failure
  rm -f "$TMPF"
}

@test "bump gate: renovate body table + branch group fast-paths" {
  TMPF=$(mktemp)
  lib_funcs boucle_pr_is_security boucle_semver_version boucle_semver_gate boucle_title_semver_gate boucle_bump_gate "$TMPF"
  RENOVATE_BODY='This PR contains the following updates:

| Package | Type | Update | Change |
| --- | --- | --- | --- |
| eslint | devDependencies | major | [`8.57.0` → `9.14.0`] |'
  run bash -c "source '$TMPF'; boucle_bump_gate 'chore(deps): update eslint to v9.14.0' '' 'renovate/eslint-9.x' '$RENOVATE_BODY'"; assert_failure
  MINOR_BODY='This PR contains the following updates:

| Package | Type | Update | Change |
| --- | --- | --- | --- |
| eslint | devDependencies | minor | [`8.57.0` → `8.58.1`] |'
  run bash -c "source '$TMPF'; boucle_bump_gate 'chore(deps): update eslint to v8.58.1' '' 'renovate/eslint-8.x' '$MINOR_BODY'"; assert_output "minor"
  run bash -c "source '$TMPF'; boucle_bump_gate 'chore(deps): update digest' '' 'renovate/actions-checkout-digest' ''"; assert_output "patch"
  run bash -c "source '$TMPF'; boucle_bump_gate 'Bump the npm group with 2 updates' 'dependencies' 'dependabot/npm_and_yarn/group' ''"; assert_failure
  rm -f "$TMPF"
}

@test "checks green: fail-closed on empty, all-success only when settled" {
  TMPF=$(mktemp); lib_funcs boucle_checks_green "$TMPF"
  run bash -c "source '$TMPF'; boucle_checks_green ''"; assert_failure
  run bash -c "source '$TMPF'; boucle_checks_green '[]'"; assert_failure
  run bash -c "source '$TMPF'; boucle_checks_green '[{\"name\":\"check\",\"status\":\"completed\",\"conclusion\":\"success\"}]'"; assert_success
  run bash -c "source '$TMPF'; boucle_checks_green '[{\"name\":\"check\",\"status\":\"in_progress\",\"conclusion\":null}]'"; assert_failure
  run bash -c "source '$TMPF'; boucle_checks_green '[{\"name\":\"check\",\"status\":\"completed\",\"conclusion\":\"failure\"}]'"; assert_failure
  rm -f "$TMPF"
}

@test "eligible: sync titles bypass the bot list; boucle/* and drafts excluded" {
  TMPF=$(mktemp)
  lib_funcs boucle_pr_is_security boucle_semver_version boucle_semver_gate boucle_title_semver_gate boucle_bump_gate boucle_bot_pr_eligible "$TMPF"
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'chore(boucle): update engine to v1.2.3' 'bot' '' false 'boucle-update/main' ''"; assert_output "sync"
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'Bump actions/checkout from 4.1.0 to 4.1.2' 'dependabot[bot]' 'dependencies' false 'dependabot/github_actions/actions/checkout-4.1.2' ''"; assert_output "patch"
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'Bump x from 4 to 5' 'dependabot[bot]' '' false 'dependabot/github_actions/x-5' ''"; assert_failure
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'Bump x from 1.0 to 1.1' 'somehuman' '' false 'patch/human' ''"; assert_failure
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'Bump x from 1.0 to 1.1' 'dependabot[bot]' '' true 'dependabot/x' ''"; assert_failure
  run bash -c "source '$TMPF'; boucle_bot_pr_eligible 'feat: my feature' 'worker-bot' '' false 'boucle/123-slug' ''"; assert_failure
  run bash -c "source '$TMPF'; BOUCLE_AUTOMERGE_BOTS='renovate[bot]'; boucle_bot_pr_eligible 'Bump x from 1.0 to 1.1' 'dependabot[bot]' '' false 'dependabot/x-1.1' ''"; assert_failure
  rm -f "$TMPF"
}

@test "sweep: disabled by default costs nothing" {
  TMPF=$(mktemp)
  lib_funcs boucle_bot_pr_sweep boucle_bot_pr_eligible boucle_pr_is_security boucle_semver_version boucle_semver_gate boucle_title_semver_gate boucle_bump_gate "$TMPF"
  run bash -c "
    forge_mr_list() { echo 'MUST-NOT-CALL' >&2; exit 1; }
    chain_to_role() { echo 'MUST-NOT-CALL' >&2; exit 1; }
    unset BOUCLE_AUTOMERGE_ENABLED
    source '$TMPF'
    boucle_bot_pr_sweep
  "
  assert_success
  refute_output --partial 'MUST-NOT-CALL'
  rm -f "$TMPF"
}

@test "sweep: chains one automerge role with only eligible PR iids" {
  TMPF=$(mktemp)
  lib_funcs boucle_bot_pr_sweep boucle_bot_pr_eligible boucle_pr_is_security boucle_semver_version boucle_semver_gate boucle_title_semver_gate boucle_bump_gate "$TMPF"
  run bash -c "
    BOUCLE_AUTOMERGE_ENABLED=true
    LIST='[{\"iid\":10,\"author\":\"dependabot[bot]\",\"title\":\"Bump actions/checkout from 4.1.0 to 4.1.2\",\"labels\":\"dependencies\",\"draft\":false,\"source_branch\":\"dependabot/github_actions/actions/checkout-4.1.2\",\"head_sha\":\"a1\",\"body\":\"\"},
          {\"iid\":11,\"author\":\"dependabot[bot]\",\"title\":\"Bump x from 4 to 5\",\"labels\":\"\",\"draft\":false,\"source_branch\":\"dependabot/x-5\",\"head_sha\":\"a2\",\"body\":\"\"},
          {\"iid\":12,\"author\":\"dependabot[bot]\",\"title\":\"chore(boucle): update engine to v1.2.3\",\"labels\":\"chore\",\"draft\":false,\"source_branch\":\"boucle-update/x\",\"head_sha\":\"a3\",\"body\":\"\"},
          {\"iid\":13,\"author\":\"worker-bot\",\"title\":\"feat: my feature\",\"labels\":\"\",\"draft\":false,\"source_branch\":\"boucle/123-slug\",\"head_sha\":\"a4\",\"body\":\"\"}]
'
    forge_mr_list() { echo \"\$LIST\"; }
    chain_to_role() { echo \"CHAIN:\$1:\$2:\$3\"; }
    source '$TMPF'
    boucle_bot_pr_sweep
  "
  assert_success
  assert_line '  → automerge: PR #10 eligible (patch)'
  assert_line '  → automerge: PR #12 eligible (sync)'
  assert_line 'CHAIN:0:automerge:BOUCLE_AUTOMERGE_MR=10,12'
  rm -f "$TMPF"
}

@test "sweep: nothing eligible chains nothing" {
  TMPF=$(mktemp)
  lib_funcs boucle_bot_pr_sweep boucle_bot_pr_eligible boucle_pr_is_security boucle_semver_version boucle_semver_gate boucle_title_semver_gate boucle_bump_gate "$TMPF"
  run bash -c "
    BOUCLE_AUTOMERGE_ENABLED=true
    LIST='[{\"iid\":11,\"author\":\"dependabot[bot]\",\"title\":\"Bump x from 4 to 5\",\"labels\":\"\",\"draft\":false,\"source_branch\":\"dependabot/x-5\",\"head_sha\":\"a2\",\"body\":\"\"}]'
    forge_mr_list() { echo \"\$LIST\"; }
    chain_to_role() { echo 'MUST-NOT-CHAIN' >&2; exit 1; }
    source '$TMPF'
    boucle_bot_pr_sweep
  "
  assert_success
  refute_output --partial 'MUST-NOT-CHAIN'
  rm -f "$TMPF"
}
