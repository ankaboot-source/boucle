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

  # Orphan: the measurement log must not carry the consumer's history.
  run bash -c "git --git-dir='$REMOTE' log --oneline boucle/metrics | wc -l | tr -d ' '"
  assert_output "1"
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
  run bash -c "grep -A3 'boucle_health_record \"\$ISSUE\"' '$REPO/bin/jc' | tr -d '\n'"
  assert_output --partial 'SKILLS_USED'
  assert_output --partial 'h_arm'
  assert_output --partial 'h_setup_fail'
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
