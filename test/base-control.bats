# test/base-control.bats — tests for the base-control CI feature (#2).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

@test "base-control: a check failing on both head and base is pre-existing" {
  run bash -c '
    check_data="[{\"name\":\"build\",\"conclusion\":\"failure\"},{\"name\":\"lint\",\"conclusion\":\"success\"}]"
    base_check_data="[{\"name\":\"build\",\"conclusion\":\"failure\"}]"
    BOUCLE_PREEXISTING_FAILURES=$(printf "%s\n%s" "$check_data" "$base_check_data" | jq -n --slurpfile head <(echo "$check_data") --slurpfile base <(echo "$base_check_data") "
      def fname: .name // .workflow_name // .app.slug // .id // tostring;
      def is_fail: .conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\" or .conclusion == \"action_required\";
      (\$head[0] | map(select(is_fail) | fname)) as \$hf
      | (\$base[0] | map(select(is_fail) | fname)) as \$bf
      | (\$hf - (\$hf - \$bf))
      | sort | unique
    ")
    echo "$BOUCLE_PREEXISTING_FAILURES"
  '
  assert_success
  assert_output --partial "build"
}

@test "base-control: a check failing only on head is NOT pre-existing" {
  run bash -c '
    check_data="[{\"name\":\"build\",\"conclusion\":\"failure\"},{\"name\":\"test\",\"conclusion\":\"failure\"}]"
    base_check_data="[{\"name\":\"build\",\"conclusion\":\"failure\"},{\"name\":\"test\",\"conclusion\":\"success\"}]"
    BOUCLE_PREEXISTING_FAILURES=$(printf "%s\n%s" "$check_data" "$base_check_data" | jq -n --slurpfile head <(echo "$check_data") --slurpfile base <(echo "$base_check_data") "
      def fname: .name // .workflow_name // .app.slug // .id // tostring;
      def is_fail: .conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\" or .conclusion == \"action_required\";
      (\$head[0] | map(select(is_fail) | fname)) as \$hf
      | (\$base[0] | map(select(is_fail) | fname)) as \$bf
      | (\$hf - (\$hf - \$bf))
      | sort | unique
    ")
    echo "$BOUCLE_PREEXISTING_FAILURES"
  '
  assert_success
  assert_output --partial "build"
  refute_output --partial "test"
}

@test "base-control: empty base yields empty pre-existing (fail-open)" {
  run bash -c '
    check_data="[{\"name\":\"build\",\"conclusion\":\"failure\"}]"
    base_check_data="[]"
    BOUCLE_PREEXISTING_FAILURES=$(printf "%s\n%s" "$check_data" "$base_check_data" | jq -n --slurpfile head <(echo "$check_data") --slurpfile base <(echo "$base_check_data") "
      def fname: .name // .workflow_name // .app.slug // .id // tostring;
      def is_fail: .conclusion == \"failure\" or .conclusion == \"cancelled\" or .conclusion == \"timed_out\" or .conclusion == \"action_required\";
      (\$head[0] | map(select(is_fail) | fname)) as \$hf
      | (\$base[0] | map(select(is_fail) | fname)) as \$bf
      | (\$hf - (\$hf - \$bf))
      | sort | unique
    ")
    echo "$BOUCLE_PREEXISTING_FAILURES"
  '
  assert_success
  assert_output "[]"
}

@test "base-control: reviewer.sh exports BOUCLE_PREEXISTING_FAILURES" {
  run grep -q "export BOUCLE_PREEXISTING_FAILURES" lib/boucle-ci/reviewer.sh
  assert_success
}

@test "base-control: bin/jc injects pre-existing failures into reviewer prompt" {
  run grep -q "Pre-existing CI failures" bin/jc
  assert_success
}
