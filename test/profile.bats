#!/usr/bin/env bats
# shellcheck=SC2154 # BATS_TEST_DIRNAME / BATS_TEST_TMPDIR are set by bats
# test/profile.bats — first-issue profile determination (#186).
#
# lib/profile.sh is pure: detect_project_profile scans a fixture tree (no
# network, no forge), profile_decision maps (effective, marker, reactions,
# replies) to an action, apply_profile_preset --dry-run lists the preset.
# Every case runs under `env -i` so an ambient BOUCLE_* cannot satisfy it.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  PROFILE_LIB="$REPO/lib/profile.sh"
  TMP="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TMP"
}

# profile_decision <effective> <marker> <reactions_json> <replies_text>
decision() {
  env -i PATH="$PATH" HOME="$HOME" bash -c \
    "source '$PROFILE_LIB'; profile_decision \"\$1\" \"\$2\" \"\$3\" \"\$4\"" \
    _ "$1" "$2" "$3" "$4"
}

# detect <root>
detect() {
  env -i PATH="$PATH" HOME="$HOME" bash -c \
    "source '$PROFILE_LIB'; detect_project_profile \"\$1\"" _ "$1"
}

# ── detect_project_profile: site ──────────────────────────────────────

@test "detect: astro.config.mjs is a site signal" {
  touch "$TMP/astro.config.mjs"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "site" ]
  assert_output --partial "evidence: astro.config.mjs"
}

@test "detect: a package.json with an astro dependency is a site signal" {
  printf '{"dependencies":{"astro":"^5.0.0"}}' > "$TMP/package.json"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "site" ]
  assert_output --partial "package.json (astro)"
}

@test "detect: a next.config.mjs is a site signal" {
  touch "$TMP/next.config.mjs"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "site" ]
}

@test "detect: a site signal in a script name does not match package.json" {
  # The grep fallback (no jq) names the dependency key, never a script.
  printf '{"scripts":{"astro":"astro build"}}' > "$TMP/package.json"
  run detect "$TMP"
  assert_success
  # No site config file and no framework dependency → unknown.
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "unknown" ]
}

# ── detect_project_profile: infra ─────────────────────────────────────

@test "detect: ansible.cfg is an infra signal" {
  touch "$TMP/ansible.cfg"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "infra" ]
  assert_output --partial "evidence: ansible.cfg"
}

@test "detect: a root *.tf file is an infra signal" {
  touch "$TMP/main.tf"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "infra" ]
  assert_output --partial "evidence: main.tf"
}

@test "detect: a terraform/ directory is an infra signal" {
  mkdir -p "$TMP/terraform"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "infra" ]
  assert_output --partial "evidence: terraform/"
}

@test "detect: a playbook-shaped YAML (hosts + tasks) is an infra signal" {
  cat > "$TMP/site.yml" << 'EOF'
- hosts: all
  tasks:
    - name: ping
      ansible.builtin.ping:
EOF
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "infra" ]
  assert_output --partial "evidence: site.yml (playbook)"
}

@test "detect: kustomization.yaml is an infra signal" {
  touch "$TMP/kustomization.yaml"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "infra" ]
}

# ── detect_project_profile: ambiguous / empty ─────────────────────────

@test "detect: both families present -> unknown with both evidences" {
  touch "$TMP/astro.config.mjs"
  touch "$TMP/ansible.cfg"
  run detect "$TMP"
  assert_success
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "unknown" ]
  assert_output --partial "evidence: astro.config.mjs"
  assert_output --partial "evidence: ansible.cfg"
}

@test "detect: an empty tree -> unknown with no evidence" {
  run detect "$TMP"
  assert_success
  assert_output "unknown"
  refute_output --partial "evidence:"
}

@test "detect: a missing directory -> unknown" {
  run detect "$TMP/does-not-exist"
  assert_success
  assert_output "unknown"
}

# ── profile_decision ──────────────────────────────────────────────────

@test "decision: an explicit site/infra profile never intervenes" {
  run decision site none '[]' ''
  assert_output "explicit"
  run decision infra none '[]' ''
  assert_output "explicit"
}

@test "decision: no determination comment -> no-marker" {
  run decision auto none '[]' ''
  assert_output "no-marker"
}

@test "decision: an applied marker is idempotent" {
  run decision auto profile-applied '[]' ''
  assert_output "applied"
}

@test "decision: thumbsup / heart / rocket / tada apply infra" {
  for emoji in thumbsup heart rocket tada; do
    run decision auto needs-info "[\"$emoji\"]" ''
    assert_output "apply-infra"
  done
}

@test "decision: thumbs_down applies site" {
  run decision auto needs-info '["thumbs_down"]' ''
  assert_output "apply-site"
}

@test "decision: a 'profile: infra' reply overrides to infra" {
  run decision auto needs-info '[]' 'profile: infra'
  assert_output "apply-infra"
}

@test "decision: a 'profile: site' reply applies site" {
  run decision auto needs-info '[]' 'profile: site'
  assert_output "apply-site"
}

@test "decision: a reply line overrides an emoji reaction" {
  run decision auto needs-info '["thumbsup"]' 'profile: site'
  assert_output "apply-site"
}

@test "decision: no decisive answer -> stay" {
  run decision auto needs-info '[]' 'just a question?'
  assert_output "stay"
}

@test "decision: a malformed reaction payload is tolerated (stay)" {
  run decision auto needs-info 'not-json' ''
  assert_output "stay"
}

@test "decision: an unset/auto effective profile with a marker is read" {
  run decision "" needs-info '["thumbsup"]' ''
  assert_output "apply-infra"
}

# ── apply_profile_preset --dry-run ────────────────────────────────────

@test "preset: infra --dry-run lists all six variables" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c \
    "source '$PROFILE_LIB'; apply_profile_preset infra --dry-run"
  assert_success
  assert_output --partial "would set BOUCLE_PROFILE=infra"
  assert_output --partial "would set BOUCLE_DEPLOY_MODE=external"
  assert_output --partial "would set BOUCLE_REVIEW_MODE=diff"
  assert_output --partial "would set BOUCLE_E2E_COMMAND=true"
  assert_output --partial "would set BOUCLE_BUILD_CMD=true"
  assert_output --partial "would set BOUCLE_UPDATE_DISABLE=true"
}

@test "preset: site --dry-run sets only BOUCLE_PROFILE" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c \
    "source '$PROFILE_LIB'; apply_profile_preset site --dry-run"
  assert_success
  assert_output "would set BOUCLE_PROFILE=site"
  refute_output --partial "BOUCLE_DEPLOY_MODE"
}

@test "preset: an unknown profile fails" {
  run env -i PATH="$PATH" HOME="$HOME" bash -c \
    "source '$PROFILE_LIB'; apply_profile_preset bogus --dry-run"
  assert_failure
}
