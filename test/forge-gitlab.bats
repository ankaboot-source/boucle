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
    BOUCLE_FORGE_HOST="gitlab.example.com"
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

@test "gitlab forge_mr_count_merged_since compares epochs, not strings (S7)" {
  # GitLab can return an offset form (+02:00 / -05:00) and a fractional
  # second. A lexicographic compare turns "08:00-05:00" (13:00Z, AFTER the
  # 09:30Z window start) into an undercount; the epoch compare counts it.
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    glab() {
      printf "[{\"iid\":1,\"merged_at\":\"2026-10-17T08:00:00-05:00\"},{\"iid\":2,\"merged_at\":\"2026-10-17T09:00:00.500Z\"}]\n"
    }
    source bin/forge/common.sh
    source bin/forge/gitlab.sh
    forge_mr_count_merged_since "2026-10-17T09:30:00Z"
  '
  assert_success
  assert_output "1"
}

@test "gitlab forge_mr_count_merged_since: a fractional second still parses" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    glab() {
      printf "[{\"iid\":1,\"merged_at\":\"2026-10-17T09:30:00.500Z\"}]\n"
    }
    source bin/forge/common.sh
    source bin/forge/gitlab.sh
    forge_mr_count_merged_since "2026-10-17T09:30:00Z"
  '
  assert_success
  assert_output "1"
}

# ── forge_trigger_token_status (silent-dead-token incident) ───────────────

@test "gitlab forge_trigger_token_status: ok when the list contains our token" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-abcdefghijklmnopqrstuvwx"
    glab() { echo "[{\"id\":1,\"token\":\"glptt-abcdefghijklmnopqrstuvwx\",\"description\":\"boucle-loop\"}]"; }
    source bin/forge/gitlab.sh
    forge_trigger_token_status
  '
  assert_success
  assert_output "ok"
}

@test "gitlab forge_trigger_token_status: missing when an unredacted list lacks our token" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-abcdefghijklmnopqrstuvwx"
    glab() { echo "[{\"id\":9,\"token\":\"glptt-zzzzzzzzzzzzzzzzzzzzzz\",\"description\":\"other\"}]"; }
    source bin/forge/gitlab.sh
    forge_trigger_token_status
  '
  assert_success
  assert_output "missing"
}

@test "gitlab forge_trigger_token_status: unknown when the token is unset" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    unset BOUCLE_TRIGGER_TOKEN
    glab() { echo "[{\"id\":9,\"token\":\"glptt-zzzzzzzzzzzzzzzzzzzzzz\"}]"; }
    source bin/forge/gitlab.sh
    forge_trigger_token_status
  '
  assert_success
  assert_output "unknown"
}

@test "gitlab forge_trigger_token_status: unknown when every listed token is truncated" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-abcdefghijklmnopqrstuvwx"
    glab() { echo "[{\"id\":2,\"token\":\"QWe9\"},{\"id\":3,\"token\":\"Ab12\"}]"; }
    source bin/forge/gitlab.sh
    forge_trigger_token_status
  '
  assert_success
  assert_output "unknown"
}

@test "gitlab forge_trigger_token_status: unknown when the glab call fails" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-abcdefghijklmnopqrstuvwx"
    glab() { return 1; }
    source bin/forge/gitlab.sh
    forge_trigger_token_status
  '
  assert_success
  assert_output "unknown"
}

# ── forge_trigger_role WARN (silent-dead-token incident) ─────────────────

@test "gitlab forge_trigger_role: WARN to stderr on non-201, exit still 0 (fail-open)" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-deaddeaddeaddeaddead"
    BOUCLE_DEFAULT_BRANCH="master"
    curl() { printf "{\"message\":\"404\"}\n404\n"; }
    source bin/forge/gitlab.sh
    forge_trigger_role "359" "worker"
  '
  assert_success
  assert_output --partial "[boucle] WARN: forge_trigger_role issue=359 role=worker → HTTP 404"
}

@test "gitlab forge_trigger_role: silent on HTTP 201" {
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TRIGGER_TOKEN="glptt-alivealivealivealive"
    BOUCLE_DEFAULT_BRANCH="master"
    curl() { printf "{\"id\":1}\n201\n"; }
    source bin/forge/gitlab.sh
    forge_trigger_role "359" "worker"
  '
  assert_success
  refute_output --partial "WARN"
}

# ── forge_attachment_upload (curl multipart) ──────────────────────────────

@test "gitlab forge_attachment_upload: uploads via curl multipart and returns .url" {
  tmp=$(mktemp -d)
  : > "$tmp/slide.jpg"
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TOKEN="pat123"
    export BOUCLE_TOKEN
    curl() { echo "{\"id\":147675,\"url\":\"/uploads/abc/slide.jpg\",\"full_path\":\"/-/project/126561/uploads/abc/slide.jpg\"}"; }
    glab() { echo "glab must not be used for multipart uploads: $*" >&2; return 1; }
    source bin/forge/gitlab.sh
    forge_attachment_upload "359" "'"$tmp"'/slide.jpg" "slide.jpg"
  '
  assert_success
  assert_output "/uploads/abc/slide.jpg"
  rm -rf "$tmp"
}

@test "gitlab forge_attachment_upload: WARN + empty output when BOUCLE_TOKEN is unset" {
  tmp=$(mktemp -d)
  : > "$tmp/slide.jpg"
  run bash -c '
    unset BOUCLE_TOKEN
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    curl() { echo "curl must not run"; }
    source bin/forge/gitlab.sh
    forge_attachment_upload "359" "'"$tmp"'/slide.jpg" "slide.jpg"
  '
  assert_success
  assert_output --partial "BOUCLE_TOKEN not set"
  rm -rf "$tmp"
}

@test "gitlab forge_attachment_upload: WARN + empty output on HTTP failure (fail-open, loud)" {
  tmp=$(mktemp -d)
  : > "$tmp/slide.jpg"
  run bash -c '
    BOUCLE_PROJECT_ID="126561"
    BOUCLE_FORGE_HOST="gitlab.example.com"
    BOUCLE_TOKEN="pat123"
    curl() { return 1; }
    source bin/forge/gitlab.sh
    forge_attachment_upload "359" "'"$tmp"'/slide.jpg" "slide.jpg"
  '
  assert_success
  assert_output --partial "upload NOT attached"
  rm -rf "$tmp"
}
