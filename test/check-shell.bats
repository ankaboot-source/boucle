#!/usr/bin/env bats
# test/check-shell.bats — the shell safety gate's own regression suite.
#
# The gate exists because five unset-variable / inherited-environment defects
# reached a consumer in one window. These tests pin the detection classes:
# unquoted expansion, unbound variables, syntax errors, and an EXIT trap armed
# before its handler is defined.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

write_fixture() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir"
  printf '%s\n' "$body" > "$dir/$name"
  chmod +x "$dir/$name"
  printf '%s\n' "$dir/$name"
}

@test "check-shell accepts a clean script" {
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" clean.sh '#!/usr/bin/env bash
set -euo pipefail
value="a b"
printf "%s\n" "$value"')
  run bin/check-shell "$file"
  assert_success
  assert_output --partial "OK: shell safety gate"
  rm -rf "$tmp"
}

@test "check-shell rejects an unquoted expansion (SC2086)" {
  # The info-level quoting class `make lint` used to skip at
  # --severity=warning. This is the class that produced unbound/empty command
  # arguments on failure paths.
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" unquoted.sh '#!/usr/bin/env bash
set -euo pipefail
items="a b"
printf "%s\n" $items')
  run bin/check-shell "$file"
  assert_failure
  assert_output --partial "SC2086"
  assert_output --partial "FAIL: shell safety gate"
  rm -rf "$tmp"
}

@test "check-shell rejects an unbound variable (SC2154)" {
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" unbound.sh '#!/usr/bin/env bash
set -euo pipefail
echo "$UNDECLARED"')
  run bin/check-shell "$file"
  assert_failure
  assert_output --partial "SC2154"
  rm -rf "$tmp"
}

@test "check-shell rejects a syntax error via bash -n" {
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" broken.sh '#!/usr/bin/env bash
if then
  echo broken
fi')
  run bin/check-shell "$file"
  assert_failure
  assert_output --partial "FAIL: shell safety gate"
  rm -rf "$tmp"
}

@test "check-shell rejects an EXIT trap armed before its handler is defined" {
  # The consumer window's health-record defect: the trap ran before the
  # extractor functions existed, so every measured field was silently empty.
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" trap-late.sh '#!/usr/bin/env bash
set -euo pipefail
trap extract EXIT
extract() { echo "extracted"; }')
  run bin/check-shell "$file"
  assert_failure
  assert_output --partial "trap handler 'extract' is defined later"
  rm -rf "$tmp"
}

@test "check-shell accepts a trap handler defined before it is armed" {
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" trap-early.sh '#!/usr/bin/env bash
set -euo pipefail
extract() { echo "extracted"; }
trap extract EXIT')
  run bin/check-shell "$file"
  assert_success
  rm -rf "$tmp"
}

@test "check-shell rejects a quoted EXIT trap handler defined later" {
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" trap-quoted.sh '#!/usr/bin/env bash
set -euo pipefail
trap '"'"'extract'"'"' EXIT
extract() { echo "extracted"; }')
  run bin/check-shell "$file"
  assert_failure
  assert_output --partial "trap handler 'extract' is defined later"
  rm -rf "$tmp"
}

@test "check-shell ignores an inline EXIT trap body" {
  # An inline body is not a named handler; it must not be mistaken for a
  # function that is missing or defined late.
  tmp=$(mktemp -d)
  file=$(write_fixture "$tmp" trap-inline.sh '#!/usr/bin/env bash
set -euo pipefail
tmpfile=""
trap '"'"'rm -f "$tmpfile"'"'"' EXIT')
  run bin/check-shell "$file"
  assert_success
  rm -rf "$tmp"
}
