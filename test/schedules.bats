#!/usr/bin/env bats
# Scheduled maintenance issues (#39)
#
# Boucle had exactly one entry point: a human creates an issue. Its only
# scheduled job healed state and never produced work, so recurring
# maintenance was work the loop suits but could not start on its own.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

sched_funcs() {
  for f in boucle_cron_field_matches boucle_cron_due boucle_schedule_frontmatter boucle_schedule_body boucle_schedules_run; do
    awk -v fn="$f" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' lib/boucle.sh
  done > "$1"
}

@test "cron: a wildcard field matches anything" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "source '$TMPF'; boucle_cron_field_matches '*' 17"
  assert_success
  rm -f "$TMPF"
}

@test "cron: exact, list and range fields" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "source '$TMPF'; boucle_cron_field_matches '6' 6"; assert_success
  run bash -c "source '$TMPF'; boucle_cron_field_matches '6' 7"; assert_failure
  run bash -c "source '$TMPF'; boucle_cron_field_matches '1,3,5' 3"; assert_success
  run bash -c "source '$TMPF'; boucle_cron_field_matches '1,3,5' 4"; assert_failure
  run bash -c "source '$TMPF'; boucle_cron_field_matches '1-5' 4"; assert_success
  run bash -c "source '$TMPF'; boucle_cron_field_matches '1-5' 6"; assert_failure
  rm -f "$TMPF"
}

@test "cron: step fields" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "source '$TMPF'; boucle_cron_field_matches '*/6' 12"; assert_success
  run bash -c "source '$TMPF'; boucle_cron_field_matches '*/6' 13"; assert_failure
  # A malformed step must not match everything.
  run bash -c "source '$TMPF'; boucle_cron_field_matches '*/x' 3"; assert_failure
  rm -f "$TMPF"
}

@test "cron: an expression without five fields is never due" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "source '$TMPF'; boucle_cron_due '0 6 *'"
  assert_failure
  rm -f "$TMPF"
}

@test "cron: an all-wildcard expression is always due" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "source '$TMPF'; boucle_cron_due '* * * * *'"
  assert_success
  rm -f "$TMPF"
}

@test "template: frontmatter keys and body are parsed" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; T=$(mktemp)
  cat > "$T" <<'TPL'
---
cron: "0 6 * * 1"
title: "chore: refresh dependencies"
labels: "chore"
enabled: false
---

Update the dependencies.

- criterion one
TPL
  run bash -c "source '$TMPF'; boucle_schedule_frontmatter '$T' cron"
  assert_output "0 6 * * 1"
  run bash -c "source '$TMPF'; boucle_schedule_frontmatter '$T' title"
  assert_output "chore: refresh dependencies"
  run bash -c "source '$TMPF'; boucle_schedule_frontmatter '$T' enabled"
  assert_output "false"
  run bash -c "source '$TMPF'; boucle_schedule_body '$T'"
  assert_output --partial "Update the dependencies."
  refute_output --partial "cron:"
  rm -f "$TMPF" "$T"
}

@test "schedules: disabled by default — no template directory is read" {
  TMPF=$(mktemp); sched_funcs "$TMPF"
  run bash -c "
    source '$TMPF'
    forge_issue_create() { echo 'UNEXPECTED'; }
    unset BOUCLE_SCHEDULES_ENABLED
    boucle_schedules_run
  "
  assert_success
  assert_output ""
  rm -f "$TMPF"
}

@test "schedules: a due template creates one issue carrying its marker" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf -- '---\ncron: "* * * * *"\ntitle: "audit: a11y"\n---\n\nAudit it.\n' > "$W/.boucle/schedules/a11y.md"
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=0
    source '$TMPF'
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_count_by_label() { echo 0; }
    forge_issue_create() { printf '%s\\n%s\\n%s\\n' \"\$1\" \"\$2\" \"\$3\" > '$W/created'; echo 51; }
    boucle_schedules_run 2>&1
  "
  assert_success
  assert_output --partial "created #51"
  # The create call's stderr is discarded by design, so assert on what it wrote.
  run cat "$W/created"
  assert_output --partial "audit: a11y"
  assert_output --partial "<!-- boucle:schedule id=a11y -->"
  assert_output --partial "boucle:triage,boucle:scheduled"
  rm -rf "$TMPF" "$W"
}

@test "schedules: enabled:false suppresses a template without deleting it" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf -- '---\ncron: "* * * * *"\ntitle: "t"\nenabled: false\n---\n\nBody.\n' > "$W/.boucle/schedules/off.md"
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=0
    source '$TMPF'
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_create() { echo 'UNEXPECTED'; }
    boucle_schedules_run
  "
  assert_success
  refute_output --partial "UNEXPECTED"
  rm -rf "$TMPF" "$W"
}

@test "schedules: no second issue while a previous one is still open" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf -- '---\ncron: "* * * * *"\ntitle: "t"\n---\n\nBody.\n' > "$W/.boucle/schedules/dep.md"
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=0
    source '$TMPF'
    forge_issue_list_by_label() { echo '[{\"iid\":9,\"state\":\"opened\",\"description\":\"<!-- boucle:schedule id=dep -->\",\"created_at\":\"2020-01-01T00:00:00Z\"}]'; }
    forge_issue_create() { echo 'UNEXPECTED'; }
    boucle_schedules_run
  "
  assert_success
  assert_output --partial "a previous issue is still open"
  refute_output --partial "UNEXPECTED"
  rm -rf "$TMPF" "$W"
}

@test "schedules: a missed window fires once, not once per sweep" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf -- '---\ncron: "* * * * *"\ntitle: "t"\n---\n\nBody.\n' > "$W/.boucle/schedules/dep.md"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=0
    source '$TMPF'
    forge_issue_list_by_label() { echo '[{\"iid\":9,\"state\":\"closed\",\"description\":\"<!-- boucle:schedule id=dep -->\",\"created_at\":\"$NOW\"}]'; }
    forge_issue_create() { echo 'UNEXPECTED'; }
    boucle_schedules_run
  "
  assert_success
  assert_output --partial "already fired"
  refute_output --partial "UNEXPECTED"
  rm -rf "$TMPF" "$W"
}

@test "schedules: a malformed template is skipped, not fatal" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf 'no frontmatter at all\n' > "$W/.boucle/schedules/broken.md"
  printf -- '---\ncron: "* * * * *"\ntitle: "good"\n---\n\nBody.\n' > "$W/.boucle/schedules/good.md"
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=0
    source '$TMPF'
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_create() { echo 60; }
    boucle_schedules_run 2>&1
  "
  assert_success
  assert_output --partial "skipped: missing cron or title"
  assert_output --partial "created #60"
  rm -rf "$TMPF" "$W"
}

@test "schedules: the parallelism cap is respected — a cron cannot starve human work" {
  TMPF=$(mktemp); sched_funcs "$TMPF"; W=$(mktemp -d)
  mkdir -p "$W/.boucle/schedules"
  printf -- '---\ncron: "* * * * *"\ntitle: "t"\n---\n\nBody.\n' > "$W/.boucle/schedules/dep.md"
  run bash -c "
    export BOUCLE_WORKSPACE='$W' BOUCLE_SCHEDULES_ENABLED=true BOUCLE_MAX_PARALLEL_ISSUES=2
    source '$TMPF'
    forge_issue_count_by_label() { echo 2; }
    forge_issue_list_by_label() { echo '[]'; }
    forge_issue_create() { echo 'UNEXPECTED'; }
    boucle_schedules_run
  "
  assert_success
  assert_output --partial "cap is 2"
  refute_output --partial "UNEXPECTED"
  rm -rf "$TMPF" "$W"
}

@test "schedules: the doctor runs them" {
  run grep -q 'boucle_schedules_run || true' lib/boucle-ci/doctor.sh
  assert_success
}
