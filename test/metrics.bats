#!/usr/bin/env bats
# Skill-effectiveness measurement (docs/skills-audit.md §03).
#
# The point of these tests is not that the numbers are produced, but that
# they are produced in a way that can be BELIEVED: the arm is stable per
# issue, censored iterations stay marked as censored, humans are told apart
# from the bot by the marker rather than by identity, and a failed metrics
# write never blocks the loop.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$BATS_TEST_DIRNAME/.."
  TMP=$(mktemp -d)
  export BOUCLE_WORKSPACE="$TMP"
  mkdir -p "$TMP/.boucle-state/7"
}

teardown() {
  # Leave the directory before deleting it. Several tests here cd into $TMP
  # to exercise git behaviour against a scratch remote, and teardown runs in
  # the same shell as the test — so without this, rm -rf removes the shell's
  # own working directory. Locally that is survivable and the suite exits 0;
  # on the CI runner the same TAP output exited 1 with no failing test named,
  # which is what a deleted CWD looks like from the outside.
  cd "$BATS_TEST_DIRNAME" 2> /dev/null || cd / || true
  rm -rf "$TMP"
}

lib() {
  # shellcheck source=/dev/null
  . "$REPO/lib/boucle.sh" 2> /dev/null || true
}

health_fixture() {
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'EOF'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":["astro"],"arm":"full","setup_fail":""}
{"timestamp":"2026-08-24T10:05:00Z","role":"worker","outcome":"build-fail","detail":"iteration 1"}
{"timestamp":"2026-08-24T10:10:00Z","role":"worker","iteration":2,"exit_code":0,"prompt_chars":100,"tokens":"20","cost_usd":"n/a","model":"m","provider":"p","skills":["astro","simplify"],"arm":"full","setup_fail":"dependency"}
EOF
}

stub_forge() {
  forge_issue_notes() { echo "[]"; }
  forge_mr_lookup_by_branch() { echo ""; }
  forge_mr_notes() { echo "[]"; }
}

# ── setup-fail classifier ─────────────────────────────────────────────

@test "classifier: a missing dependency is an environment block" {
  lib
  printf 'ModuleNotFoundError: No module named yaml\n' > "$TMP/a.log"
  run boucle_classify_setup_failure "$TMP/a.log"
  assert_success
  assert_output "dependency"
}

@test "classifier: a missing binary is an environment block" {
  lib
  printf 'bash: shfmt: command not found\n' > "$TMP/a.log"
  run boucle_classify_setup_failure "$TMP/a.log"
  assert_output "toolchain"
}

@test "classifier: a failing test is NOT an environment block" {
  # The whole value of this signal is that it separates "the environment
  # stopped the run" from "the work was wrong". A classifier that fires on
  # ordinary test failures measures nothing.
  lib
  printf 'FAIL test_header expected 1 got 2\n1 test failed\n' > "$TMP/a.log"
  run boucle_classify_setup_failure "$TMP/a.log"
  assert_success
  assert_output ""
}

@test "classifier: a port conflict is NOT counted here" {
  # The study measures service-lifecycle failures as a separate mode with a
  # much smaller skill effect (2.7% -> 0.8% vs 5.3% -> 0.2%). Folding them
  # in would dilute the indicator this exists to catch.
  lib
  printf 'Error: listen EADDRINUSE: address already in use :::3000\n' > "$TMP/a.log"
  run boucle_classify_setup_failure "$TMP/a.log"
  assert_output ""
}

@test "classifier: a missing log is not a finding of 'no failure'" {
  lib
  run boucle_classify_setup_failure "$TMP/nope.log"
  assert_success
  assert_output ""
}

# ── experiment arm ────────────────────────────────────────────────────

@test "arm: randomisation is OFF by default" {
  # Two arms out of three ship a deliberately degraded prompt. That costs a
  # consumer real iterations, so it must never be something they get without
  # having asked for it.
  lib
  unset BOUCLE_EXPERIMENT || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run boucle_experiment_arm "$i"
    assert_output "full"
  done
}

@test "arm: the same issue always lands in the same arm" {
  # The arm is a property of the ISSUE. If it varied per role or per
  # iteration, the comparison would be between prompt mixtures rather than
  # between arms, and the experiment would measure nothing.
  lib
  export BOUCLE_EXPERIMENT=on
  first=$(boucle_experiment_arm 4242)
  for _ in 1 2 3 4 5; do
    run boucle_experiment_arm 4242
    assert_output "$first"
  done
}

@test "arm: all three arms are reachable" {
  lib
  export BOUCLE_EXPERIMENT=on
  arms=""
  for i in $(seq 1 60); do arms="$arms$(boucle_experiment_arm "$i")\n"; done
  distinct=$(printf "$arms" | sort -u | grep -c .)
  [ "$distinct" -eq 3 ]
}

# ── human touches ─────────────────────────────────────────────────────

@test "touches: the bot is told from a human by the MARKER, not identity" {
  # SKILL.md invariant I7, and the only rule that survives mono-user mode
  # where the bot and the human are the same account.
  lib
  export BOUCLE_AGENT_MARKER="<!-- boucle:agent -->"
  forge_issue_notes() {
    echo '[{"body":"do the thing","system":false},{"body":"verdict <!-- boucle:agent -->","system":false},{"body":"label added","system":true}]'
  }
  forge_mr_lookup_by_branch() { echo ""; }
  forge_mr_notes() { echo "[]"; }
  run boucle_human_touches 7
  assert_success
  assert_output "1	0"
}

@test "touches: an amend-in-flight is delivery feedback, not spec feedback" {
  # A human comment arriving mid-work is the worker being corrected, not the
  # spec being corrected. Counting it on both sides would inflate the signal
  # that is supposed to separate triage quality from worker quality.
  lib
  export BOUCLE_AGENT_MARKER="<!-- boucle:agent -->"
  health_fixture
  echo '{"timestamp":"t","role":"worker","outcome":"amended-in-flight","detail":"x"}' \
    >> "$TMP/.boucle-state/7/health.jsonl"
  forge_issue_notes() {
    echo '[{"body":"spec fix","system":false},{"body":"amend now","system":false}]'
  }
  forge_mr_lookup_by_branch() { echo ""; }
  forge_mr_notes() { echo "[]"; }
  run boucle_human_touches 7
  assert_output "1	1"
}

# ── metrics row ───────────────────────────────────────────────────────

@test "row: a completed issue reports uncensored iterations" {
  lib
  stub_forge
  health_fixture
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -r '.iterations_censored'"
  assert_output "false"
}

@test "row: an escalated issue is marked CENSORED" {
  # It did not take N iterations, it took at least N. Averaging the two
  # together produces a number that is wrong in a direction the reader
  # cannot detect from the result.
  lib
  health_fixture
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 human | jq -r '.iterations_censored'"
  assert_output "true"
}

@test "row: skills are the union over the issue's runs" {
  lib
  health_fixture
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '.skills'"
  assert_output '["astro","simplify"]'
}

@test "row: environment blocks are counted with their family" {
  lib
  health_fixture
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.setup_failures, .setup_failure_families]'"
  assert_output '[1,["dependency"]]'
}

@test "row: no health data yields no row, not a row of zeroes" {
  # A fabricated all-zero row would enter the metrics log and be averaged
  # with real ones. Absent evidence has to stay absent.
  lib
  stub_forge
  run boucle_metrics_row 999 done
  assert_success
  assert_output ""
}

# ── publish ───────────────────────────────────────────────────────────

@test "publish: appends a row to an orphan metrics branch" {
  lib
  health_fixture
  REMOTE="$TMP/remote.git"
  git init -q --bare "$REMOTE"
  WORK="$TMP/work"
  git init -q "$WORK"
  git -C "$WORK" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" push -q origin HEAD:main
  mkdir -p "$WORK/.boucle-state/7"
  cp "$TMP/.boucle-state/7/health.jsonl" "$WORK/.boucle-state/7/"

  run bash -c "cd '$WORK' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$WORK' boucle_metrics_publish 7 done"
  assert_success

  run git --git-dir="$REMOTE" show "boucle/metrics:metrics.jsonl"
  assert_success
  assert_output --partial '"issue":"7"'

  # Orphan: the measurement log must not carry the consumer's history. Assert
  # the PROPERTY (main is not an ancestor), not a commit count: the publish
  # also syncs the raw health log so its outcome event is durable, which adds
  # a second commit to the same branch.
  run bash -c "git --git-dir='$REMOTE' merge-base --is-ancestor main boucle/metrics 2>/dev/null && echo ANCESTOR || echo ORPHAN"
  assert_output "ORPHAN"

  # The event that makes this publish diagnosable is on the branch with the
  # rest of the raw log.
  run git --git-dir="$REMOTE" show "boucle/metrics:raw/7.jsonl"
  assert_success
  assert_output --partial '"event":"metrics_publish"'
  assert_output --partial '"ok":true'
  assert_output --partial '"reason":"published"'
}

@test "publish: a failing write warns and returns 0 — never blocks the loop" {
  # An issue must be able to reach done when the metrics branch is
  # unreachable. This is the property that makes hooking the publish into
  # set_boucle_label safe.
  lib
  health_fixture
  WORK="$TMP/nowhere"
  mkdir -p "$WORK/.boucle-state/7"
  cp "$TMP/.boucle-state/7/health.jsonl" "$WORK/.boucle-state/7/"
  git init -q "$WORK"
  git -C "$WORK" remote add origin "file:///definitely/not/a/repo"

  run bash -c "cd '$WORK' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$WORK' boucle_metrics_publish 7 done; echo \"rc=\$?\""
  assert_output --partial "rc=0"

  # The failure is recorded as an event, not only as a lost row: absence of a
  # row cannot distinguish "never called" from "called and failed", and the
  # event is what the retro digest classifies.
  run grep '"event":"metrics_publish"' "$WORK/.boucle-state/7/health.jsonl"
  assert_success
  assert_output --partial '"ok":false'
  assert_output --partial '"reason":"git_append_failed"'
}

@test "toggle: publishing is ON by default" {
  lib
  unset BOUCLE_METRICS_ENABLED || true
  run boucle_metrics_enabled
  assert_success
}

@test "toggle: only an explicitly falsy value disables it" {
  # A default-on flag tested for equality against one spelling turns every
  # other spelling into a silent disable. Someone setting =1 to be helpful
  # must not get the opposite of what they asked for.
  lib
  for v in false FALSE 0 no off; do
    BOUCLE_METRICS_ENABLED="$v" run boucle_metrics_enabled
    assert_failure
  done
  for v in true TRUE 1 yes banana; do
    BOUCLE_METRICS_ENABLED="$v" run boucle_metrics_enabled
    assert_success
  done
}

@test "toggle: disabling skips the branch write and SAYS so" {
  # Silence is how a disabled metric becomes "why is the branch empty?".
  lib
  health_fixture
  REMOTE="$TMP/remote2.git"
  git init -q --bare "$REMOTE"
  WORK="$TMP/work2"
  git init -q "$WORK"
  git -C "$WORK" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" push -q origin HEAD:main
  mkdir -p "$WORK/.boucle-state/7"
  cp "$TMP/.boucle-state/7/health.jsonl" "$WORK/.boucle-state/7/"

  run bash -c "cd '$WORK' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    BOUCLE_METRICS_ENABLED=false BOUCLE_WORKSPACE='$WORK' boucle_metrics_publish 7 done 2>&1"
  assert_success
  assert_output --partial "disabled"

  run bash -c "git --git-dir='$REMOTE' rev-parse --verify boucle/metrics 2>&1 || echo ABSENT"
  assert_output --partial "ABSENT"
}

@test "toggle: disabling the branch write does NOT stop health.jsonl" {
  # health.jsonl predates the metrics branch and feeds bin/health and the
  # escalation diagnostic — decision support, not analytics. Opting out of
  # the analytics must not degrade the loop's own diagnostics.
  lib
  export BOUCLE_METRICS_ENABLED=false
  boucle_health_record 7 worker 1 0 100 10 n/a m p "astro" full ""
  run cat "$TMP/.boucle-state/7/health.jsonl"
  assert_success
  assert_output --partial '"skills":["astro"]'
}

@test "publish: the terminal transition is hooked once, not at each call site" {
  run grep -A4 'case "$new" in' "$REPO/lib/boucle.sh"
  assert_success
  assert_output --partial 'boucle:done) boucle_metrics_publish'
  assert_output --partial 'boucle:human) boucle_metrics_publish'
}

# ── bin/jc wiring ─────────────────────────────────────────────────────

@test "jc: sources the shared library so health records are actually written" {
  # bin/jc is executed, not sourced, and called boucle_health_record without
  # ever loading it: the call resolved to "command not found", its own
  # `|| true` swallowed it, and no consumer ever got a run record.
  run grep -q 'if ! type boucle_health_record > /dev/null 2>&1; then' "$REPO/bin/jc"
  assert_success
}

@test "jc: the health record carries skills, arm and setup_fail" {
  # These three fields are what make health.jsonl a join table between what a
  # run was given and how it went. Asserted on the call itself, wherever it
  # lives, so moving it into the EXIT trap cannot quietly drop one.
  run bash -c "grep -A5 'boucle_health_record \"\$ISSUE\"' '$REPO/bin/jc' | tr -d '\n'"
  assert_output --partial 'skills'
  assert_output --partial 'boucle_experiment_arm'
  assert_output --partial 'setup_fail'
}

@test "jc: withholding the catalogue is gated on the arm" {
  run bash -c "awk '/Append the generated skill catalogue/,/^  esac/' '$REPO/bin/jc' | grep -c 'arm'"
  assert_success
  [ "$output" -ge 1 ]
}

# ── reader ────────────────────────────────────────────────────────────

@test "stats: an empty log says so instead of reporting zeroes" {
  : > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl"
  assert_success
  assert_output --partial "No metrics yet"
}

@test "stats: the observed split states that it is confounded" {
  # The agent loads skills on the issues it judges hard. A reader that
  # presents that split without the caveat invites the exact wrong
  # conclusion, which is the failure this whole design exists to avoid.
  printf '%s\n' '{"schema":1,"issue":"1","terminal":"done","arm":"full","iterations":2,"skills":["astro"],"skills_n":1,"setup_failures":0,"human_spec":0,"human_delivery":0}' > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl"
  assert_success
  assert_output --partial "NOT evidence that skills hurt"
}

@test "stats: a single-arm experiment is called out as not an experiment" {
  printf '%s\n' '{"schema":1,"issue":"1","terminal":"done","arm":"full","iterations":2,"skills":[],"skills_n":0,"setup_failures":0,"human_spec":0,"human_delivery":0}' > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl" --experiment
  assert_success
  assert_output --partial "observational split wearing an experiment's label"
}

@test "stats: escalated issues are not averaged into the iteration figure" {
  printf '%s\n' \
    '{"schema":1,"issue":"1","terminal":"done","arm":"full","iterations":2,"skills":[],"skills_n":0,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    '{"schema":1,"issue":"2","terminal":"human","arm":"full","iterations":99,"skills":[],"skills_n":0,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    > "$TMP/m.jsonl"
  run bash -c "'$REPO/bin/skills-stats' --file '$TMP/m.jsonl' --json | jq -r '.[0].iterations_done'"
  assert_output "2"
}

# ── prompt size and verdicts on the published row (A3, A7) ────────────
# The raw log now reaches the branch as it is written, so these fields are
# durable per run either way. The summary row is what a dashboard reads
# without parsing every line, and a field missing from it is a field nobody
# will aggregate.

@test "row: carries the largest assembled prompt seen on the issue" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'EOF'
{"timestamp":"t","role":"worker","iteration":1,"exit_code":0,"prompt_chars":48213,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":0}
{"timestamp":"t","role":"worker","iteration":2,"exit_code":0,"prompt_chars":61002,"tokens":"20","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":2}
EOF
  run bash -c "cd '$REPO' && BOUCLE_WORKSPACE='$TMP' bash -c '. lib/boucle.sh 2>/dev/null; boucle_metrics_row 7 done' | jq -r '.prompt_chars_max | tostring'"
  assert_success
  assert_output "61002"
}

@test "row: sums the swarm spawns across the issue's runs" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'EOF'
{"timestamp":"t","role":"worker","iteration":1,"exit_code":0,"prompt_chars":10,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":3}
{"timestamp":"t","role":"worker","iteration":2,"exit_code":0,"prompt_chars":10,"tokens":"20","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":2}
EOF
  run bash -c "cd '$REPO' && BOUCLE_WORKSPACE='$TMP' bash -c '. lib/boucle.sh 2>/dev/null; boucle_metrics_row 7 done' | jq -r '.swarm_spawns | tostring'"
  assert_success
  assert_output "5"
}

@test "row: carries the reviewer and e2e verdicts, which tell a recovery from a first-pass success" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'EOF'
{"timestamp":"t","role":"worker","iteration":1,"exit_code":0,"prompt_chars":10,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":0}
{"timestamp":"t","role":"reviewer","outcome":"FAIL","detail":"iteration 1"}
{"timestamp":"t","role":"worker","iteration":2,"exit_code":0,"prompt_chars":10,"tokens":"20","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":"","swarm_spawns":0}
{"timestamp":"t","role":"reviewer","outcome":"PASS","detail":"iteration 2"}
{"timestamp":"t","role":"e2e","outcome":"PASS","detail":""}
EOF
  run bash -c "cd '$REPO' && BOUCLE_WORKSPACE='$TMP' bash -c '. lib/boucle.sh 2>/dev/null; boucle_metrics_row 7 done' | jq -c '.verdicts'"
  assert_success
  assert_output '["FAIL","PASS","PASS"]'
}

@test "row: a worker-only issue still produces a row (no verdicts, zero prompt size absent)" {
  lib
  health_fixture
  run bash -c "cd '$REPO' && BOUCLE_WORKSPACE='$TMP' bash -c '. lib/boucle.sh 2>/dev/null; boucle_metrics_row 7 done' | jq -c '{verdicts, prompt_chars_max, swarm_spawns}'"
  assert_success
  assert_output '{"verdicts":[],"prompt_chars_max":100,"swarm_spawns":0}'
}

# ── Durability of the raw health log ─────────────────────────────────────
#
# The defect these cover: health.jsonl is written into .boucle-state/ inside
# whichever ephemeral job produced it, but the TERMINAL label is usually
# applied by a different job with an empty workspace (a doctor sweep, a
# post-merge e2e). The publish then summarised a table that did not exist and
# reported "nothing to publish" for an issue that had just finished a full
# loop. These tests pin the two halves of the fix: the raw log leaves the job
# as it is written, and the reader finds it again when the local copy is gone.

metrics_remote() {
  # A bare repo standing in for origin, plus a working clone whose `origin`
  # points at it — boucle_metrics_git_append reads the remote off `origin`.
  git init -q --bare "$TMP/origin.git"
  git init -q "$TMP/work"
  git -C "$TMP/work" remote add origin "$TMP/origin.git"
  cd "$TMP/work" || return 1
}

remote_file() {
  git -C "$TMP/origin.git" show "$BOUCLE_METRICS_BRANCH:$1" 2> /dev/null
}

@test "metrics: health lines reach the branch as they are written" {
  lib
  metrics_remote
  health_fixture
  boucle_metrics_sync_health 7
  run remote_file "raw/7.jsonl"
  assert_success
  assert_output --partial '"role":"worker","iteration":1'
  assert_output --partial '"outcome":"build-fail"'
}

@test "metrics: re-syncing the same log does not duplicate lines" {
  lib
  metrics_remote
  health_fixture
  boucle_metrics_sync_health 7
  boucle_metrics_sync_health 7
  run bash -c "git -C '$TMP/origin.git' show '$BOUCLE_METRICS_BRANCH:raw/7.jsonl' | wc -l"
  assert_output "3"
}

@test "metrics: a later append adds only the new line" {
  lib
  metrics_remote
  health_fixture
  boucle_metrics_sync_health 7
  echo '{"timestamp":"2026-08-24T11:00:00Z","role":"e2e","outcome":"PASS","detail":""}' \
    >> "$TMP/.boucle-state/7/health.jsonl"
  boucle_metrics_sync_health 7
  run bash -c "git -C '$TMP/origin.git' show '$BOUCLE_METRICS_BRANCH:raw/7.jsonl' | wc -l"
  assert_output "4"
}

@test "metrics: BOUCLE_METRICS_SYNC=false keeps the local write and skips the push" {
  lib
  metrics_remote
  health_fixture
  BOUCLE_METRICS_SYNC=false boucle_metrics_sync_health 7
  run remote_file "raw/7.jsonl"
  assert_failure
  assert [ -s "$TMP/.boucle-state/7/health.jsonl" ]
}

@test "metrics: disabling metrics entirely also disables the raw sync" {
  lib
  metrics_remote
  health_fixture
  BOUCLE_METRICS_ENABLED=false boucle_metrics_sync_health 7
  run remote_file "raw/7.jsonl"
  assert_failure
}

@test "metrics: hydrate prefers the local health file" {
  lib
  metrics_remote
  health_fixture
  run boucle_metrics_hydrate_health 7
  assert_success
  assert_output "$TMP/.boucle-state/7/health.jsonl"
}

@test "metrics: hydrate falls back to the branch when the workspace is empty" {
  lib
  metrics_remote
  health_fixture
  boucle_metrics_sync_health 7
  rm -f "$TMP/.boucle-state/7/health.jsonl"
  run boucle_metrics_hydrate_health 7
  assert_success
  assert [ -s "$output" ]
  run bash -c "grep -c 'build-fail' '$(boucle_metrics_hydrate_health 7)'"
  assert_output "1"
}

@test "metrics: hydrate prints nothing when the issue never ran an agent" {
  lib
  metrics_remote
  run boucle_metrics_hydrate_health 7
  assert_success
  assert_output ""
}

@test "metrics: a terminal transition in a FRESH job still publishes a row" {
  # The regression that started this: the doctor recovered a closed issue,
  # the hook fired, and the row was empty because the doctor's workspace had
  # never seen health.jsonl. The raw log on the branch is what closes it.
  lib
  metrics_remote
  stub_forge
  health_fixture
  boucle_metrics_sync_health 7
  rm -rf "$TMP/.boucle-state/7"
  run boucle_metrics_row 7 done
  assert_success
  assert_output --partial '"issue":"7"'
  assert_output --partial '"terminal":"done"'
  assert_output --partial '"iterations":2'
}

@test "metrics: git_append reports failure when there is no origin to push to" {
  lib
  git init -q "$TMP/noremote"
  cd "$TMP/noremote" || return 1
  echo 'x' > "$TMP/line"
  run boucle_metrics_git_append "metrics.jsonl" "$TMP/line" "msg"
  assert_failure
}

# ── The credential bug, pinned ───────────────────────────────────────────
#
# The first implementation did the read-modify-append in a scratch `git init`
# under /tmp. That inherits none of the checkout's configuration — on a CI
# runner the token lives in the working repo's `http.<host>.extraheader`, so
# the scratch repo's push was unauthenticated and failed. The whole suite
# passed anyway, because a local file:// remote needs no credentials.
#
# `insteadOf` reproduces the class faithfully without a network: the remote
# URL is only resolvable through config that lives in THIS repo. Anything
# that shells out to a fresh clone cannot reach origin; anything that uses
# the working repo's own remote can.

metrics_remote_config_only() {
  git init -q --bare "$TMP/origin.git"
  git init -q "$TMP/work"
  git -C "$TMP/work" remote add origin "boucle-test://origin"
  git -C "$TMP/work" config \
    "url.$TMP/origin.git.insteadOf" "boucle-test://origin"
  cd "$TMP/work" || return 1
}

@test "metrics: the append reaches origin through the working repo's own config" {
  lib
  metrics_remote_config_only
  health_fixture
  boucle_metrics_sync_health 7
  run remote_file "raw/7.jsonl"
  assert_success
  assert_output --partial '"role":"worker","iteration":1'
}

@test "metrics: hydrate also reads through the working repo's own config" {
  lib
  metrics_remote_config_only
  health_fixture
  boucle_metrics_sync_health 7
  rm -f "$TMP/.boucle-state/7/health.jsonl"
  run boucle_metrics_hydrate_health 7
  assert_success
  assert [ -s "$output" ]
}

@test "metrics: the append never touches HEAD, the index or the working tree" {
  lib
  metrics_remote
  health_fixture
  echo 'code' > "$TMP/work/file.txt"
  git -C "$TMP/work" add file.txt
  git -C "$TMP/work" -c user.email=t@t -c user.name=t commit -q -m "work"
  echo 'uncommitted' > "$TMP/work/dirty.txt"
  local head_before status_before
  head_before=$(git -C "$TMP/work" rev-parse HEAD)
  status_before=$(git -C "$TMP/work" status --porcelain)

  boucle_metrics_sync_health 7

  assert_equal "$(git -C "$TMP/work" rev-parse HEAD)" "$head_before"
  assert_equal "$(git -C "$TMP/work" status --porcelain)" "$status_before"
  # The metrics branch must not appear as a local branch either.
  run git -C "$TMP/work" rev-parse --verify --quiet "$BOUCLE_METRICS_BRANCH"
  assert_failure
}

@test "metrics: a failed sync SAYS so instead of returning quietly" {
  # The bug behind the bug: the sync swallowed stderr, so an unauthenticated
  # push left no trace anywhere. The branch simply never appeared.
  lib
  git init -q "$TMP/noremote"
  cd "$TMP/noremote" || return 1
  mkdir -p "$TMP/.boucle-state/7"
  health_fixture
  # No origin at all — the append cannot succeed.
  run boucle_metrics_sync_health 7
  assert_success
  assert_output --partial "[boucle:metrics] WARN"
  assert_output --partial "issue #7"
}

# ── The health record must survive every exit path ───────────────────────
#
# The record used to sit at the very end of bin/jc, after six early `exit 3`
# / `exit 4` paths (silent failure, empty log, empty placeholder draft,
# provider down, quota exhausted) and after any `set -e` abort. So the runs
# that recorded nothing were exactly the runs worth measuring — the failures.
# The measurement had survivorship bias built into its own control flow.

@test "jc: the health record is emitted from an EXIT trap, not just at the end" {
  run grep -n 'trap emit_health_record EXIT' "$REPO/bin/jc"
  assert_success
}

@test "jc: no early exit can precede the trap" {
  # Every `exit N` in the file must come AFTER the trap is installed,
  # otherwise that path still drops the row.
  # Scoped to exits that can happen once there is a run to record. The
  # argument-validation exits above AGENT_LOG have no issue, role or
  # transcript yet — a row there would be an empty one, not a missing one.
  local trap_line agent_log_line first_exit
  trap_line=$(grep -n 'trap emit_health_record EXIT' "$REPO/bin/jc" | cut -d: -f1)
  agent_log_line=$(grep -n '^AGENT_LOG=' "$REPO/bin/jc" | head -1 | cut -d: -f1)
  assert [ -n "$trap_line" ]
  assert [ -n "$agent_log_line" ]
  # The trap is installed as soon as there is a transcript to describe.
  assert [ "$trap_line" -gt "$agent_log_line" ]
  first_exit=$(grep -nE '^[[:space:]]*exit [0-9$]' "$REPO/bin/jc" \
    | awk -F: -v a="$agent_log_line" '$1 > a {print $1; exit}')
  assert [ -n "$first_exit" ]
  assert [ "$trap_line" -lt "$first_exit" ]
}

@test "jc: the recorder is called once, through the trap function" {
  # A second direct call to boucle_health_record would write a duplicate row
  # on the happy path and reintroduce the drift the trap exists to prevent.
  run bash -c "grep -c '^boucle_health_record ' '$REPO/bin/jc' || true"
  assert_output "0"
  run grep -c 'boucle_health_record "\$ISSUE"' "$REPO/bin/jc"
  assert_output "1"
}

@test "jc: an early exit still reads the skills out of the transcript" {
  # SKILLS_USED is set in 7c, which an early exit never reaches. Recording
  # "no skills" for a run that loaded some before it died would be a wrong
  # answer, not a missing one.
  run grep -A3 'local skills="\${SKILLS_USED:-}"' "$REPO/bin/jc"
  assert_success
  assert_output --partial "extract_skills_used"
}

@test "jc: an early exit still reads the swarm count out of the transcript" {
  # Same rule as the skills above: SWARM_SPAWNS is set in 7d, which an early
  # exit never reaches. Recording 0 for a run that fanned out before it died
  # is a wrong answer, not a missing one — and 0 is exactly the value the
  # question "does swarm ever fire?" is trying to establish.
  run grep -A3 'local swarm="\${SWARM_SPAWNS:-}"' "$REPO/bin/jc"
  assert_success
  assert_output --partial "extract_swarm_spawns"
}

@test "jc: an all-empty health row raises a loud error" {
  # A row with every measured field empty is the signature of the trap having
  # run before its extractors existed. It must never pass quietly as a
  # healthy run — that is what hid the definition-order defect.
  run grep -A8 'local measured=""' "$REPO/bin/jc"
  assert_success
  assert_output --partial 'if [ -z "$measured" ]'
  run grep 'carries NO measurement' "$REPO/bin/jc"
  assert_success
}

@test "jc: the swarm count reaches the health record through the trap" {
  # The count is the 13th argument; a row written without it defaults to 0,
  # which is indistinguishable from a measured zero.
  run grep -A6 'boucle_health_record "\$ISSUE" "\$ROLE" "\$ITERATION"' "$REPO/bin/jc"
  assert_success
  assert_output --partial '"$setup_fail" "$swarm"'
}

# ── Telling a broken sensor from a real zero ─────────────────────────────
#
# a consumer produced 60+ runs with `skills: []` on every one.
# That is what an agent loading no skills looks like, and it is also exactly
# what an extractor that does not match the transcript format looks like.
# The name list alone cannot separate them; skills_evidence can.

@test "skills: an absent transcript is 'no-transcript', never a zero" {
  run bash -c "grep -A6 '^skills_evidence() {' '$REPO/bin/jc'"
  assert_success
  assert_output --partial "no-transcript"
}

@test "skills: extracted names classify as 'parsed'" {
  run bash -c "sed -n '/^skills_evidence() {/,/^}/p' '$REPO/bin/jc' > '$TMP/f.sh'; . '$TMP/f.sh'; echo 'x' > '$TMP/log'; skills_evidence '$TMP/log' 'astro,simplify'"
  assert_output "parsed"
}

@test "skills: a transcript with no skill_manage at all is a REAL zero" {
  run bash -c "sed -n '/^skills_evidence() {/,/^}/p' '$REPO/bin/jc' > '$TMP/f.sh'; . '$TMP/f.sh'; printf 'the agent read some files\n' > '$TMP/log'; skills_evidence '$TMP/log' ''"
  assert_output "not-invoked"
}

@test "skills: skill_manage in the log with nothing extracted is 'unparsed'" {
  # The whole point: the tool WAS called and we read nothing out of it.
  run bash -c "sed -n '/^skills_evidence() {/,/^}/p' '$REPO/bin/jc' > '$TMP/f.sh'; . '$TMP/f.sh'; printf 'calling skill_manage action=load name=astro\n' > '$TMP/log'; skills_evidence '$TMP/log' ''"
  assert_output "unparsed"
}

@test "skills: an empty transcript is not mistaken for 'not-invoked'" {
  run bash -c "sed -n '/^skills_evidence() {/,/^}/p' '$REPO/bin/jc' > '$TMP/f.sh'; . '$TMP/f.sh'; : > '$TMP/log'; skills_evidence '$TMP/log' ''"
  assert_output "no-transcript"
}

@test "jc: the unparsed state raises a WARN instead of passing quietly" {
  run bash -c "grep -A3 'SKILLS_EVIDENCE\" = \"unparsed\"' '$REPO/bin/jc'"
  assert_success
  assert_output --partial "WARN"
  assert_output --partial "does not match this transcript format"
}

@test "metrics: the row carries how many runs the sensor could not read" {
  lib
  metrics_remote
  mkdir -p "$TMP/.boucle-state/7"
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'EOF'
{"timestamp":"2026-08-27T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"1","cost_usd":"n/a","model":"m","provider":"p","skills":[],"skills_evidence":"unparsed","arm":"full","setup_fail":"","swarm_spawns":0}
{"timestamp":"2026-08-27T10:05:00Z","role":"reviewer","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"1","cost_usd":"n/a","model":"m","provider":"p","skills":[],"skills_evidence":"not-invoked","arm":"full","setup_fail":"","swarm_spawns":0}
EOF
  stub_forge
  run boucle_metrics_row 7 done
  assert_success
  assert_output --partial '"runs_skills_unparsed":1'
  assert_output --partial '"runs_skills_not_invoked":1'
}

# ── An empty verdict is not an UNCERTAIN verdict ─────────────────────────
#
# a consumer escalated to boucle:human twice showing ten UNCERTAIN rows.
# All ten were runs where the agent posted NOTHING — five of them on a
# byte-identical prompt. The two states take different paths through
# reviewer.sh (immediate escalation vs re-trigger), so recording them under
# one name points the diagnosis at the wrong bug.

@test "reviewer: an empty verdict records no-verdict, not UNCERTAIN" {
  run grep -n 'boucle_health_outcome "$BOUCLE_ISSUE" "reviewer"' "$REPO/lib/boucle-ci/reviewer.sh"
  assert_success
  assert_output --partial 'no-verdict'
  refute_output --partial 'VERDICT:-UNCERTAIN'
}

@test "e2e: an empty verdict records no-verdict, not UNCERTAIN" {
  run grep -n 'boucle_health_outcome "$BOUCLE_ISSUE" "e2e"' "$REPO/lib/boucle-ci/e2e.sh"
  assert_success
  assert_output --partial 'no-verdict'
  refute_output --partial 'VERDICT:-UNCERTAIN'
}

@test "reviewer: a genuinely posted UNCERTAIN still escalates to human" {
  # The fix must not touch the real UNCERTAIN path — that one is a judgement
  # by the agent and still needs a human.
  run bash -c "sed -n '/^    UNCERTAIN)/,/^      ;;/p' '$REPO/lib/boucle-ci/reviewer.sh'"
  assert_success
  assert_output --partial "boucle:human"
}

# ── Lesson injection (the other half of "what the run was given") ─────
#
# Boucle measured the SIZE of its prompt and never the effect of its
# contents. select_lessons is a keyword grep over a 158k file capped at 80
# lines, and nothing recorded what came back — so no lesson could be shown
# to be dead weight, and none to be paid for on every run.

lessons_fn() {
  awk '/^record_lessons_injected\(\) \{/,/^}/' "$REPO/bin/jc" > "$1"
}

@test "lessons: injected ids are recorded with their source file" {
  TMPF=$(mktemp); lessons_fn "$TMPF"
  run bash -c "STATE_DIR='$TMP/s'; . '$TMPF';
    record_lessons_injected matched '4:
  title: A
12:
  title: B
' '3:
  title: C
'; cat '$TMP/s/.lessons-injected'"
  assert_success
  assert_line --index 0 "matched"
  assert_line --index 1 "e4,e12,l3"
  rm -f "$TMPF"
}

@test "lessons: the two sources stay distinguishable" {
  # The same number in the engine file and in a repository file is two
  # unrelated entries. An unprefixed list would silently merge them.
  TMPF=$(mktemp); lessons_fn "$TMPF"
  run bash -c "STATE_DIR='$TMP/s'; . '$TMPF';
    record_lessons_injected matched '7:
  title: engine
' '7:
  title: local
'; sed -n 2p '$TMP/s/.lessons-injected'"
  assert_output "e7,l7"
  rm -f "$TMPF"
}

@test "lessons: no match records the source, not just an empty list" {
  # 'default' means nothing matched and the critical set was substituted.
  # Counting that as a selection would read the retrieval as working.
  TMPF=$(mktemp); lessons_fn "$TMPF"
  run bash -c "STATE_DIR='$TMP/s'; . '$TMPF';
    record_lessons_injected default '1:
  title: post early
' ''; cat '$TMP/s/.lessons-injected'"
  assert_line --index 0 "default"
  assert_line --index 1 "e1"
  rm -f "$TMPF"
}

@test "lessons: recording never fails the run" {
  # Measurement must not be what stops a loop. An unwritable state dir is a
  # missing row, not an exit code.
  TMPF=$(mktemp); lessons_fn "$TMPF"
  run bash -c "STATE_DIR='/proc/nonexistent/s'; . '$TMPF';
    record_lessons_injected matched '4:
  title: A
' ''; echo rc=\$?"
  assert_success
  assert_output --partial "rc=0"
  rm -f "$TMPF"
}

@test "lessons: the health row carries them as JSON" {
  lib
  run bash -c ". '$REPO/lib/boucle.sh' 2>/dev/null;
    boucle_metrics_sync_health() { :; };
    BOUCLE_WORKSPACE='$TMP' boucle_health_record 7 worker 1 0 100 10 n/a m p '' full '' 0 parsed 'e4,l3' matched;
    jq -c '[.lessons, .lessons_source]' < '$TMP/.boucle-state/7/health.jsonl'"
  assert_output '[["e4","l3"],"matched"]'
}

@test "row: lessons are the union over the issue's runs" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"skills":[],"arm":"full","setup_fail":"","lessons":["e4","e7"],"lessons_source":"matched"}
{"timestamp":"2026-08-24T10:10:00Z","role":"worker","iteration":2,"exit_code":0,"prompt_chars":100,"skills":[],"arm":"full","setup_fail":"","lessons":["e7","l3"],"lessons_source":"default"}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.lessons, .lessons_n, .runs_lessons_default]'"
  assert_output '[["e4","e7","l3"],3,1]'
}

@test "row: a withheld arm is not counted as a selection" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"skills":[],"arm":"none","setup_fail":"","lessons":[],"lessons_source":"withheld"}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.lessons_n, .runs_lessons_withheld]'"
  assert_output '[0,1]'
}

@test "stats: --per-lesson counts the issues each lesson reached" {
  printf '%s\n' \
    '{"schema":2,"issue":"1","terminal":"done","arm":"full","iterations":2,"skills":[],"skills_n":0,"lessons":["e4","e7"],"lessons_n":2,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    '{"schema":2,"issue":"2","terminal":"done","arm":"full","iterations":4,"skills":[],"skills_n":0,"lessons":["e7"],"lessons_n":1,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl" --per-lesson
  assert_success
  assert_output --partial "Per lesson"
  assert_line --regexp '^  e7 +2 +2'
  assert_line --regexp '^  e4 +1 +1'
}

@test "stats: --per-lesson names the lessons no prompt ever carried" {
  # The actionable half: an entry selected by nothing is dead weight in a
  # file every agent is told to treat as mandatory.
  printf '%s\n' \
    '{"schema":2,"issue":"1","terminal":"done","arm":"full","iterations":2,"skills":[],"skills_n":0,"lessons":["e1"],"lessons_n":1,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl" --per-lesson
  assert_success
  assert_output --partial "Never selected"
  refute_line --regexp '^  e1 e'
}

@test "stats: an empty group prints n/a, never a fabricated 0.00" {
  # A lesson or skill seen only on escalated issues has no uncensored
  # iteration count. printf rejected the 'n/a' the aggregation emits, which
  # printed an error next to a 0.00 that was not a measurement.
  printf '%s\n' \
    '{"schema":2,"issue":"1","terminal":"human","arm":"full","iterations":5,"skills":["zz"],"skills_n":1,"lessons":["e4"],"lessons_n":1,"setup_failures":0,"human_spec":0,"human_delivery":0}' \
    > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl" --per-lesson --per-skill
  assert_success
  refute_output --partial "invalid number"
  # The per-row figure, not the summary table above it (where 0.00 is a real
  # measurement).
  refute_line --regexp '^  (zz|e4) .*0\.00'
  assert_line --regexp '^  e4 +1 +0 +n/a'
  assert_line --regexp '^  zz +1 +0 +n/a' 
}

# ── A row that says what it could NOT measure (coverage) ───────────────
#
# The class of defect: a row was incomplete rather than explicitly empty.
# cost_usd was not written at all, the tokens sum filtered on
# `type == "number"` while the health log writes EVERY value as a string, and
# an empty verdicts array looked identical whether the gates ran and recorded
# an outcome or never ran at all. Every one of those is a field the retro
# agent has to read as "unknown", and none of them said so.

@test "row: carries the tokens and the dollars the runs reported" {
  # The regression: a consumer with millions of measured tokens published
  # tokens:null (the sum matched no value) and no cost_usd key whatsoever, so
  # every cost aggregate over the branch read null.
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"1500000","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":""}
{"timestamp":"2026-08-24T10:10:00Z","role":"worker","iteration":2,"exit_code":0,"prompt_chars":100,"tokens":"2270000","cost_usd":"0.42","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":""}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.tokens, .cost_usd]'"
  assert_success
  assert_output '[3770000,0.42]'
}

@test "row: an unknown value is an explicit null plus a reason, never an absent key" {
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"n/a","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":""}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '{has_cost: has(\"cost_usd\"), cost: .cost_usd, gap: .telemetry_gap, coverage}'"
  assert_success
  assert_output '{"has_cost":true,"cost":null,"gap":["tokens_unavailable","cost_unavailable","verdict_missing"],"coverage":"partial"}'
}

@test "row: an empty verdicts array after a completed run is itself a gap" {
  # "did review run?" has to be answerable from the row. An empty array with
  # runs > 0 means the gate either did not run or its outcome was lost — never
  # a pass, and never silence.
  lib
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":""}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.runs, (.telemetry_gap | index(\"verdict_missing\") != null)]'"
  assert_success
  assert_output '[1,true]'

  # The same issue WITH the gate outcomes recorded carries no such gap.
  cat > "$TMP/.boucle-state/7/health.jsonl" <<'FIX'
{"timestamp":"2026-08-24T10:00:00Z","role":"worker","iteration":1,"exit_code":0,"prompt_chars":100,"tokens":"10","cost_usd":"n/a","model":"m","provider":"p","skills":[],"arm":"full","setup_fail":""}
{"timestamp":"2026-08-24T10:05:00Z","role":"reviewer","outcome":"FAIL","detail":"iteration 1"}
{"timestamp":"2026-08-24T10:20:00Z","role":"e2e","outcome":"PASS","detail":""}
FIX
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    forge_issue_notes() { echo '[]'; }; forge_mr_lookup_by_branch() { echo ''; }; forge_mr_notes() { echo '[]'; };
    BOUCLE_WORKSPACE='$TMP' boucle_metrics_row 7 done | jq -c '[.verdicts, .coverage, .telemetry_gap]'"
  assert_success
  assert_output '[["FAIL","PASS"],"partial",["cost_unavailable"]]'
}

@test "row: a coverage row carries every documented key, all null, and says why" {
  # Emission is mandatory, so a terminal transition with no health log still
  # publishes a row. This pins that it is the SAME shape as a measured row
  # (a reader must not have to special-case a missing key) and that nothing
  # in it is a fabricated zero.
  lib
  run bash -c "cd '$REPO' && . lib/boucle.sh 2>/dev/null;
    boucle_metrics_gap_row 42 done no_health_data | jq -c '{issue, terminal, coverage, gap: .telemetry_gap, iterations, runs, tokens, cost_usd}'"
  assert_success
  assert_output '{"issue":"42","terminal":"done","coverage":"no-data","gap":["no_health_data"],"iterations":null,"runs":null,"tokens":null,"cost_usd":null}'
}

@test "publish: no health log publishes a coverage row instead of nothing" {
  # The window this comes from: 33 closed issues, 3 metrics rows, and nothing
  # anywhere saying which 30 were missing. A run that leaves no row is a blind
  # spot nobody downstream can even count.
  lib
  metrics_remote
  run bash -c "cd '$TMP/work' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    BOUCLE_WORKSPACE='$TMP/work' boucle_metrics_publish 99 done 2>&1"
  assert_success
  assert_output --partial "coverage row"
  run remote_file "metrics.jsonl"
  assert_success
  assert_output --partial '"issue":"99"'
  assert_output --partial '"coverage":"no-data"'
  assert_output --partial '"telemetry_gap":["no_health_data"]'
  assert_output --partial '"iterations":null'
  refute_output --partial '"iterations":0'
}

@test "stats: a coverage row is counted, never averaged as 0 iterations" {
  # The whole point of publishing it: the run is visible. The whole point of
  # excluding it: an issue nobody measured is not an issue that took no
  # iterations and needed no human help.
  printf '%s\n' \
    '{"schema":3,"issue":"1","terminal":"done","arm":"full","iterations":1,"skills":[],"skills_n":0,"setup_failures":0,"human_spec":0,"human_delivery":0,"telemetry_gap":[]}' \
    '{"schema":3,"issue":"2","terminal":"done","arm":"full","iterations":3,"skills":[],"skills_n":0,"setup_failures":0,"human_spec":0,"human_delivery":0,"telemetry_gap":["cost_unavailable"]}' \
    '{"schema":3,"issue":"3","terminal":"human","arm":"unknown","coverage":"no-data","iterations":null,"runs":null,"skills":[],"skills_n":0,"setup_failures":null,"human_spec":null,"human_delivery":null,"telemetry_gap":["no_health_data"]}' \
    > "$TMP/m.jsonl"
  run "$REPO/bin/skills-stats" --file "$TMP/m.jsonl"
  assert_success
  assert_output --partial "3 issue(s)"
  assert_output --partial "1 row(s) carry no measurement"
  # (1+3)/2, not (1+3+0)/3, and 0 escalated rather than 1.
  assert_line --regexp '^no-skills +2 +2 +0 +2\.00'
}

# ── Collector liveness: absence is diagnosed, not guessed ───────────────
#
# Zero metrics rows in a window with closed issues has three causes with
# different fixes: the terminal transition never called the collector
# (unwired), the collector ran and every append failed (wired-but-failing), or
# the row was written and lost (rows lost). A row cannot record its own
# absence, so the collector persists its outcome as a structured event and
# the digest classifies the blackout from it.

@test "publish: a failure emits a CI warning annotation, not only a stderr line" {
  # The fail-open contract makes the stderr WARN invisible: it lives in the
  # log of an ephemeral runner nobody aggregates. The annotation is attached
  # to the run summary, so "wired but failing" survives the job.
  lib
  health_fixture
  WORK="$TMP/annotate"
  mkdir -p "$WORK/.boucle-state/7"
  cp "$TMP/.boucle-state/7/health.jsonl" "$WORK/.boucle-state/7/"
  git init -q "$WORK"
  git -C "$WORK" remote add origin "file:///definitely/not/a/repo"

  run bash -c "cd '$WORK' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    GITHUB_ACTIONS=true BOUCLE_WORKSPACE='$WORK' boucle_metrics_publish 7 done 2>&1"
  assert_success
  assert_output --partial "::warning::"
  assert_output --partial "git_append_failed"
}

@test "publish: a disabled collector records the event locally, pushes nothing" {
  lib
  health_fixture
  metrics_remote
  run bash -c "cd '$TMP/work' && . '$REPO/lib/boucle.sh' 2>/dev/null;
    BOUCLE_METRICS_ENABLED=false BOUCLE_WORKSPACE='$TMP' boucle_metrics_publish 7 done 2>&1"
  assert_success
  run grep '"event":"metrics_publish"' "$TMP/.boucle-state/7/health.jsonl"
  assert_success
  assert_output --partial '"ok":false'
  assert_output --partial '"reason":"disabled"'
  run bash -c "git --git-dir='$TMP/origin.git' rev-parse --verify boucle/metrics 2>&1 || echo ABSENT"
  assert_output --partial "ABSENT"
}

# digest_liveness_setup <work-dir> <metrics-jsonl> <raw-event-line>
#
# Build an orphan metrics branch carrying the given summary row(s) and ONE
# raw/<iid>.jsonl line (the publish outcome event). A real digest run against
# it then has closed issues, zero rows and exactly the liveness signal under
# test.
digest_liveness_setup() {
  local work="$1" metrics="$2" event="$3"
  git init -q --bare "$work.origin.git"
  git init -q "$work"
  git -C "$work" remote add origin "$work.origin.git"
  git -C "$work" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
  git -C "$work" push -q origin HEAD:main
  git -C "$work" checkout -q --orphan boucle/metrics
  : > "$work/metrics.jsonl"
  [ -z "$metrics" ] || printf '%s\n' "$metrics" > "$work/metrics.jsonl"
  mkdir -p "$work/raw"
  [ -z "$event" ] || printf '%s\n' "$event" > "$work/raw/4242.jsonl"
  git -C "$work" add -A
  git -C "$work" -c user.email=a@b -c user.name=a commit -q -m metrics
  git -C "$work" push -q origin boucle/metrics
}

digest_liveness_run() {
  local work="$1" out="$2"
  bash -c "
    set -euo pipefail
    unset GITHUB_REPOSITORY BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH || true
    export BOUCLE_WORKSPACE='$work' BOUCLE_HOME='$REPO'
    source '$REPO/lib/boucle.sh' 2> /dev/null || true
    source '$REPO/lib/boucle-ci/retro.sh' 2> /dev/null || true
    cd '$work'
    forge_issue_list_all() { echo '[{\"iid\":4242,\"title\":\"Closed\",\"closed_at\":\"2026-10-03T00:00:00Z\"}]'; }
    retro_upstream_ready() { return 1; }
    _retro_build_digest '$out' '2026-09-15T00:00:00Z'
  "
}

@test "digest: zero rows with no publish event anywhere is UNWIRED" {
  lib
  WORK="$TMP/liveness-unwired"
  digest_liveness_setup "$WORK" "" ""
  run digest_liveness_run "$WORK" "$TMP/unwired.md"
  assert_success
  run cat "$TMP/unwired.md"
  assert_output --partial "WARNING: metrics blackout"
  assert_output --partial "unwired — no metrics_publish event anywhere for the window: the terminal transition never invoked the collector"
  refute_output --partial "wired-failing"
  refute_output --partial "wired-ok, rows lost"
}

@test "digest: failed publish events classify a blackout as WIRED-FAILING with the reason" {
  lib
  WORK="$TMP/liveness-failing"
  digest_liveness_setup "$WORK" "" \
    '{"timestamp":"2026-10-02T10:00:00Z","event":"metrics_publish","iid":"4242","ok":false,"reason":"git_append_failed"}'
  run digest_liveness_run "$WORK" "$TMP/failing.md"
  assert_success
  run cat "$TMP/failing.md"
  assert_output --partial "wired-failing — the collector ran and its last publish failed (reason: git_append_failed)"
  refute_output --partial "unwired"
}

@test "digest: successful publish events with no row classify as WIRED-OK, ROWS LOST" {
  lib
  WORK="$TMP/liveness-lost"
  digest_liveness_setup "$WORK" "" \
    '{"timestamp":"2026-10-02T10:00:00Z","event":"metrics_publish","iid":"4242","ok":true,"reason":"published"}'
  run digest_liveness_run "$WORK" "$TMP/lost.md"
  assert_success
  run cat "$TMP/lost.md"
  assert_output --partial "wired-ok, rows lost — the collector reported a successful publish, but no row is visible in the window"
  refute_output --partial "unwired"
}
