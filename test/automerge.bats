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
