#!/usr/bin/env bats
# test/command.bats — the /boucle interactive command (#61).
#
# Exercises the pure pieces of the command surface:
#   - boucle_command_parse: trigger forms, unknown verb, empty verb, leading
#     whitespace, multi-line comments.
#   - boucle_command_authorize: issue author allowed, non-author denied,
#     empty resolve_reporter_username (API error) → fail-open allowed,
#     mono-user mode allowed.
#   - boucle_command_run: unknown verb → one-line reply (no separate job),
#     closed-issue guard (log/status denied, help allowed).
#
# The functions are sourced from lib/boucle-ci/command.sh with mocked
# forge_* helpers (same pattern as test/boucle-lib.bats).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"
  export BOUCLE_FORGE=gitlab
  # shellcheck disable=SC1091
  source bin/forge/common.sh
  # shellcheck disable=SC1091
  source lib/boucle.sh
  # shellcheck disable=SC1091
  source lib/boucle-ci/command.sh
}

# ── Syntax / formatting ───────────────────────────────────────────────

@test "lib/boucle-ci/command.sh parses without syntax error" {
  run bash -n lib/boucle-ci/command.sh
  assert_success
}

@test "lib/boucle-ci/command.sh passes shfmt -d" {
  if ! command -v shfmt > /dev/null 2>&1; then skip "shfmt not installed"; fi
  run shfmt -d -i 2 -bn -ci -sr lib/boucle-ci/command.sh
  assert_success
}

# ── Parser: trigger forms ─────────────────────────────────────────────

@test "parse: /boucle log" {
  run boucle_command_parse '/boucle log'
  assert_success
  assert_output "log"
}

@test "parse: /boucle status" {
  run boucle_command_parse '/boucle status'
  assert_success
  assert_output "status"
}

@test "parse: /boucle help" {
  run boucle_command_parse '/boucle help'
  assert_success
  assert_output "help"
}

@test "parse: @up-bot log (mention form)" {
  run boucle_command_parse '@up-bot log'
  assert_success
  assert_output "log"
}

@test "parse: case-insensitive (/BOUCLE LOG)" {
  run boucle_command_parse '/BOUCLE LOG'
  assert_success
  assert_output "LOG"
}

@test "parse: /boucle with no verb → empty (unknown verb → help reply)" {
  run boucle_command_parse '/boucle'
  assert_success
  assert_output ""
}

@test "parse: /boucle foobar → unknown verb token" {
  run boucle_command_parse '/boucle foobar'
  assert_success
  assert_output "foobar"
}

@test "parse: leading whitespace is trimmed" {
  run boucle_command_parse '  /boucle status'
  assert_success
  assert_output "status"
}

@test "parse: multi-line comment — only first non-empty line matters" {
  run boucle_command_parse 'first line
/boucle log'
  assert_success
  assert_output ""
}

@test "parse: /boucle on a later non-empty line is ignored" {
  run boucle_command_parse 'some preamble

/boucle status'
  assert_success
  assert_output ""
}

@test "parse: a normal comment is not a command" {
  run boucle_command_parse 'just a normal comment'
  assert_success
  assert_output ""
}

@test "parse: /bouclefoobar is not a command (word boundary)" {
  run boucle_command_parse '/bouclefoobar'
  assert_success
  assert_output ""
}

@test "parse: empty body is not a command" {
  run boucle_command_parse ''
  assert_success
  assert_output ""
}

@test "parse: custom BOUCLE_BOT_USERNAME" {
  BOUCLE_BOT_USERNAME=mybot run boucle_command_parse '@mybot status'
  assert_success
  assert_output "status"
}

# ── Authorization ─────────────────────────────────────────────────────

@test "authorize: issue author allowed" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    resolve_reporter_username() { echo "human"; }
    boucle_command_authorize 42 human log
  '
  assert_success
}

@test "authorize: non-author denied" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    resolve_reporter_username() { echo "human"; }
    boucle_command_authorize 42 other log
  '
  assert_failure
}

@test "authorize: empty resolve_reporter_username (API error) → fail-open allowed" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    resolve_reporter_username() { echo ""; }
    boucle_command_authorize 42 anyone log
  '
  assert_success
}

@test "authorize: mono-user mode → allowed" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot BOUCLE_MONO_USER=true
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    resolve_reporter_username() { echo "human"; }
    boucle_command_authorize 42 anyone log
  '
  assert_success
}

@test "authorize: help allowed for any human actor" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    resolve_reporter_username() { echo "human"; }
    boucle_command_authorize 42 other help
  '
  assert_success
}

# ── Run: routing / unknown verb / closed-issue guard ─────────────────

@test "run: unknown verb posts one-line reply, no separate job" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { echo "NOTE:$2"; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"open\"}"; }
    boucle_command_run 42 foobar ""
  '
  assert_success
  assert_output --partial "Unknown verb"
  assert_output --partial "try \`/boucle help\`"
  refute_output --partial "CHAIN:"
}

@test "run: log routes to cmd-log job" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { echo "NOTE:$2"; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"open\"}"; }
    boucle_command_run 42 log ""
  '
  assert_success
  assert_output --partial "CHAIN:42:cmd-log"
}

@test "run: status routes to cmd-status" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { :; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"open\"}"; }
    boucle_command_run 42 status ""
  '
  assert_success
  assert_output --partial "CHAIN:42:cmd-status"
}

@test "run: help routes to cmd-help" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { :; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"open\"}"; }
    boucle_command_run 42 help ""
  '
  assert_success
  assert_output --partial "CHAIN:42:cmd-help"
}

@test "run: log denied on a closed issue (no chain)" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { echo "NOTE:$2"; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"closed\"}"; }
    boucle_command_run 42 log ""
  '
  assert_success
  assert_output --partial "closed"
  refute_output --partial "CHAIN:"
}

@test "run: status denied on a closed issue (no chain)" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { echo "NOTE:$2"; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"closed\"}"; }
    boucle_command_run 42 status ""
  '
  assert_success
  assert_output --partial "closed"
  refute_output --partial "CHAIN:"
}

@test "run: help allowed on a closed issue" {
  run bash -c '
    BOUCLE_FORGE=gitlab BOUCLE_BOT_USERNAME=up-bot
    source bin/forge/common.sh
    source lib/boucle.sh
    source lib/boucle-ci/command.sh
    forge_issue_note() { :; }
    chain_to_role() { echo "CHAIN:$1:$2"; }
    forge_issue_get() { echo "{\"state\":\"closed\"}"; }
    boucle_command_run 42 help ""
  '
  assert_success
  assert_output --partial "CHAIN:42:cmd-help"
}
