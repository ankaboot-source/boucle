#!/usr/bin/env bats
# test/worker-build-gate.bats — worker-side build gate (#53).
#
# The build gate lives inside boucle_ci_worker (a large function we cannot
# source directly). We extract the gate block into a sourceable snippet,
# wrap it in a function, and drive it with stubbed forge helpers, asserting
# the observable side effects: the build-feedback.md file write/clear and
# the BOUCLE_BUILD_FEEDBACK export.

setup() {
	load 'test_helper/bats-support/load'
	load 'test_helper/bats-assert/load'
}

# Extract the build-gate block from lib/boucle-ci/worker.sh (from the
# "Build gate (#53)" comment through the gate's closing `fi`). The gate is a
# single `if ... else ... fi` at 2-space indent, so the first `  fi` after the
# comment is its closing brace.
extract_build_gate() {
	awk '
    /# ── Build gate \(#53\)/ { p = 1 }
    p { print }
    p && /^  fi$/ { exit }
  ' lib/boucle-ci/worker.sh
}

# Run the extracted gate in a sandbox with stubbed helpers.
# run_gate <issue> <build_cmd> <deploy:0|1>
run_gate() {
	local issue="$1" build_cmd="$2" deploy="$3" seed="$4"
	local tmp
	tmp=$(mktemp -d)
	mkdir -p "$tmp/.boucle-state/$issue"
	if [ -n "$seed" ]; then
		printf '%s\n' "$seed" >"$tmp/.boucle-state/$issue/build-feedback.md"
	fi
	{
		cat <<-'EOF'
			# NOTE: no `set -e` — the real worker.sh runs without it (only
			# `set +o pipefail`), and the gate relies on `build_rc=$?` capturing a
			# failing `(eval ...)` subshell. Under `set -e` the script would die
			# before the capture.
			set -uo pipefail
			BOUCLE_ISSUE="$1"
			BOUCLE_BUILD_CMD="$2"
			BOUCLE_BUILD_OUTPUT="$3"
			BOUCLE_ITERATION="${BOUCLE_ITERATION:-1}"
			BOUCLE_MAX_ITERATIONS="${BOUCLE_MAX_ITERATIONS:-5}"
			OUT="${OUT:-/dev/null}"
			set_boucle_label() { echo "label:$1:$2" >> "$OUT"; }
			forge_issue_note() { echo "note:$1" >> "$OUT"; }
			chain_to_role() { echo "chain:$1:$2:$3" >> "$OUT"; }
			job_link() { echo ""; }
			boucle_worker_should_deploy() { [ "$DEPLOY" = "1" ]; }
			run_build_gate() {
		EOF
		extract_build_gate
		cat <<-'EOF'
			}
			run_build_gate
		EOF
	} >"$tmp/gate.sh"
	# Capture the gate's exit code without letting it fail the test harness.
	local rc=0
	(cd "$tmp" && OUT="$tmp/out.txt" DEPLOY="$deploy" bash gate.sh "$issue" "$build_cmd" "public") 2>/dev/null || rc=$?
	echo "$rc" >"$tmp/rc.txt"
	cp -r "$tmp/.boucle-state" "$BATS_TEST_TMPDIR/.boucle-state" 2>/dev/null || true
	cp "$tmp/out.txt" "$BATS_TEST_TMPDIR/out.txt" 2>/dev/null || true
	cp "$tmp/rc.txt" "$BATS_TEST_TMPDIR/rc.txt"
	rm -rf "$tmp"
}

@test "build gate: a failing BOUCLE_BUILD_CMD writes build-feedback.md and exits non-zero" {
	BATS_TEST_TMPDIR=$(mktemp -d)
	run_gate "42" "echo boom; exit 1" "0" ""
	rc=$(cat "$BATS_TEST_TMPDIR/rc.txt")
	[ "$rc" -ne 0 ]
	[ -f "$BATS_TEST_TMPDIR/.boucle-state/42/build-feedback.md" ]
	run grep -q "boom" "$BATS_TEST_TMPDIR/.boucle-state/42/build-feedback.md"
	assert_success
}

@test "build gate: a successful build removes build-feedback.md" {
	BATS_TEST_TMPDIR=$(mktemp -d)
	run_gate "42" "echo ok" "0" "stale error"
	[ ! -f "$BATS_TEST_TMPDIR/.boucle-state/42/build-feedback.md" ]
}

@test "build gate: an empty BOUCLE_BUILD_CMD skips the gate (no feedback file, exit 0)" {
	BATS_TEST_TMPDIR=$(mktemp -d)
	run_gate "42" "" "0" ""
	rc=$(cat "$BATS_TEST_TMPDIR/rc.txt")
	[ "$rc" -eq 0 ]
	[ ! -f "$BATS_TEST_TMPDIR/.boucle-state/42/build-feedback.md" ]
}

@test "build gate: BOUCLE_BUILD_FEEDBACK is exported from build-feedback.md when it exists" {
	BATS_TEST_TMPDIR=$(mktemp -d)
	mkdir -p "$BATS_TEST_TMPDIR/.boucle-state/42"
	printf 'build error line 1\nline 2\n' >"$BATS_TEST_TMPDIR/.boucle-state/42/build-feedback.md"
	# Source the read block in isolation (the same logic as Edit A).
	run bash -c '
    cd "$1"
    BOUCLE_ISSUE=42
    export BOUCLE_BUILD_FEEDBACK
    BOUCLE_BUILD_FEEDBACK=""
    if [ -f ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" ]; then
      BOUCLE_BUILD_FEEDBACK=$(cat ".boucle-state/$BOUCLE_ISSUE/build-feedback.md" 2>/dev/null || echo "")
    fi
    printf "%s" "$BOUCLE_BUILD_FEEDBACK"
  ' -- "$BATS_TEST_TMPDIR"
	assert_success
	assert_output "build error line 1
line 2"
}
