#!/usr/bin/env bats
#
# test/doctor-on-dispatch.bats — the doctor, driven by events.
#
# Why this exists: measured on the engine's own GitHub workflow over 20 days
# (187 scheduled runs), `*/10 * * * *` asks for 144 firings a day and GitHub
# delivers 9.3 — 6.5%, median gap 54 min, p90 4.5 h, worst 5.7 days. The
# delivered minutes are flat across all six /10 buckets, so the firings are
# not late, they are dropped. Recovery therefore rides dispatch, which a
# webhook actually reaches.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"
  # shellcheck disable=SC1091
  source lib/boucle-ci/doctor.sh
  unset BOUCLE_DOCTOR_ON_DISPATCH BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL
}

@test "lib/boucle-ci/doctor.sh parses without syntax error" {
  run bash -n lib/boucle-ci/doctor.sh
  assert_success
}

# ── The mode gate ─────────────────────────────────────────────────────

@test "mode auto: on for GitHub" {
  BOUCLE_FORGE=github run boucle_doctor_on_dispatch_enabled
  assert_success
}

@test "mode auto: off for GitLab — the measurement is GitHub's, not GitLab's" {
  BOUCLE_FORGE=gitlab run boucle_doctor_on_dispatch_enabled
  assert_failure
}

@test "mode auto is the default when the variable is unset" {
  unset BOUCLE_DOCTOR_ON_DISPATCH
  BOUCLE_FORGE=github run boucle_doctor_on_dispatch_enabled
  assert_success
  BOUCLE_FORGE=gitlab run boucle_doctor_on_dispatch_enabled
  assert_failure
}

@test "mode true/false force, on either forge" {
  BOUCLE_DOCTOR_ON_DISPATCH=true BOUCLE_FORGE=gitlab run boucle_doctor_on_dispatch_enabled
  assert_success
  BOUCLE_DOCTOR_ON_DISPATCH=false BOUCLE_FORGE=github run boucle_doctor_on_dispatch_enabled
  assert_failure
  BOUCLE_DOCTOR_ON_DISPATCH=TRUE BOUCLE_FORGE=gitlab run boucle_doctor_on_dispatch_enabled
  assert_success
}

@test "an unrecognised mode falls back to auto, never to on" {
  BOUCLE_DOCTOR_ON_DISPATCH=yes BOUCLE_FORGE=gitlab run boucle_doctor_on_dispatch_enabled
  assert_failure
  BOUCLE_DOCTOR_ON_DISPATCH=yes BOUCLE_FORGE=github run boucle_doctor_on_dispatch_enabled
  assert_success
}

# ── The interval ──────────────────────────────────────────────────────

@test "interval defaults to the cadence the cron asks for" {
  run boucle_doctor_sweep_interval
  assert_output "600"
}

@test "interval honours a numeric override" {
  BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL=120 run boucle_doctor_sweep_interval
  assert_output "120"
}

@test "a non-numeric interval falls back instead of disabling the rate limit" {
  # "" would make every dispatch sweep; a typo must not do that.
  BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL=abc run boucle_doctor_sweep_interval
  assert_output "600"
  BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL="" run boucle_doctor_sweep_interval
  assert_output "600"
  BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL="10m" run boucle_doctor_sweep_interval
  assert_output "600"
}

# ── The stage ─────────────────────────────────────────────────────────
#
# boucle_ci_doctor is stubbed: this asserts the rate limit and the stamp
# ordering, not the sweep itself (doctor.bats covers that).

# stage_with <last-stamp> [interval] [persist]
#
# The forge-variable stubs behave like a real store by default: the
# read-back after the write sees what was written. Pass persist=no to
# simulate a token that cannot write forge variables.
stage_with() {
  local last="$1" interval="${2:-600}" persist="${3:-yes}"
  BOUCLE_FORGE=github \
    BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL="$interval" \
    bash -c "
      BOUCLE_HOME='$PWD'
      source lib/boucle-ci/doctor.sh
      STORE='$last'
      forge_ci_var_get() { printf '%s' \"\$STORE\"; }
      forge_ci_var_set() {
        echo \"STAMP:\$1=\$2\"
        [ '$persist' = yes ] && STORE=\"\$2\"
        return 0
      }
      boucle_ci_doctor() { echo 'SWEPT'; }
      boucle_ci_doctor_opportunistic
    "
}

@test "stage: sweeps when the interval has elapsed" {
  run stage_with "$(($(date +%s) - 1200))"
  assert_success
  assert_output --partial "SWEPT"
}

@test "stage: skips inside the interval" {
  run stage_with "$(($(date +%s) - 60))"
  assert_success
  refute_output --partial "SWEPT"
  assert_output --partial "skipping"
}

@test "stage: an absent stamp sweeps (first run)" {
  run stage_with ""
  assert_success
  assert_output --partial "SWEPT"
  # And says so, rather than reporting the epoch as an elapsed time — the
  # first real run logged "last sweep 1789377418s ago".
  assert_output --partial "no sweep recorded yet"
  refute_output --partial "WARN"
}

@test "stage: stamps BEFORE sweeping, so a storm cannot multi-sweep" {
  run stage_with "$(($(date +%s) - 1200))"
  assert_success
  # STAMP must appear before SWEPT in the output.
  local stamp_line swept_line
  stamp_line=$(echo "$output" | grep -n "STAMP:" | head -1 | cut -d: -f1)
  swept_line=$(echo "$output" | grep -n "SWEPT" | head -1 | cut -d: -f1)
  [ -n "$stamp_line" ] || { echo "no stamp written"; false; }
  [ "$stamp_line" -lt "$swept_line" ] || {
    echo "stamp written after the sweep:"; echo "$output"; false
  }
}

@test "stage: the stamp is written unmasked" {
  # A masked forge variable is hidden in job logs; masking a timestamp buys
  # nothing and makes the rate limit unreadable when it misbehaves.
  run stage_with "$(($(date +%s) - 1200))"
  assert_output --partial "STAMP:BOUCLE_DOCTOR_LAST_SWEEP="
  grep -q 'forge_ci_var_set BOUCLE_DOCTOR_LAST_SWEEP "$now" false false' lib/boucle-ci/doctor.sh
}

@test "stage: a stamp from the future does not park the sweep" {
  # Clock skew or a hand-edited variable must not disable recovery until
  # the future catches up.
  run stage_with "$(($(date +%s) + 99999))"
  assert_success
  assert_output --partial "SWEPT"
}

@test "stage: disabled mode never reads or writes the forge variable" {
  run bash -c "
    BOUCLE_HOME='$PWD'
    source lib/boucle-ci/doctor.sh
    forge_ci_var_get() { echo 'READ'; }
    forge_ci_var_set() { echo 'WROTE'; }
    boucle_ci_doctor() { echo 'SWEPT'; }
    BOUCLE_DOCTOR_ON_DISPATCH=false boucle_ci_doctor_opportunistic
  "
  assert_success
  refute_output --partial "READ"
  refute_output --partial "WROTE"
  refute_output --partial "SWEPT"
}

# ── The wiring ────────────────────────────────────────────────────────

@test "the stage is reachable through bin/boucle-ci" {
  # bin/boucle-ci resolves a stage by `boucle_ci_${STAGE//-/_}` and refuses
  # a name it cannot resolve, so the hyphenated stage must map onto a
  # function that lib/boucle-ci.sh actually defines.
  local stage="doctor-opportunistic"
  declare -F "boucle_ci_${stage//-/_}" > /dev/null
  # And it must be offered in the usage line, or the only way to discover it
  # is to read the source.
  run grep -c "doctor-opportunistic" bin/boucle-ci
  refute_output "0"
}

@test "GitHub: the sweep step runs even when dispatch exits non-zero" {
  # A dispatch no-op exits non-zero by design (anti-accumulation), and that
  # is exactly a run whose sweep is worth having. Without if: always() the
  # step is skipped on every no-op — i.e. on most webhooks.
  run python3 - <<'PY'
import yaml
steps = yaml.safe_load(open(".github/workflows/boucle.yml"))["jobs"]["dispatch"]["steps"]
sweep = [s for s in steps if "doctor-opportunistic" in str(s.get("run", ""))]
assert len(sweep) == 1, f"expected one sweep step, got {len(sweep)}"
assert str(sweep[0].get("if", "")).strip() == "always()", sweep[0].get("if")
assert steps.index(sweep[0]) > next(i for i, s in enumerate(steps) if s.get("id") == "dispatch")
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "GitLab: the sweep preserves dispatch's exit code" {
  # triage declares `needs: [dispatch]` WITHOUT optional, so dispatch's hard
  # failure is the signal that skips triage. Swallowing it would make every
  # no-op webhook run triage.
  block=$(python3 -c "
import yaml
print(''.join(yaml.safe_load(open('.gitlab-ci.yml'))['dispatch']['script']))
")
  echo "$block" | grep -q 'DISPATCH_RC=\$?'
  echo "$block" | grep -q 'boucle-ci doctor-opportunistic'
  echo "$block" | grep -q 'exit "\$DISPATCH_RC"'
  # The sweep must not be able to change the code dispatch returned.
  echo "$block" | grep -q 'doctor-opportunistic || true'
}

@test "both CI files declare the new variables with the same defaults" {
  run python3 - <<'PY'
import yaml
gl = yaml.safe_load(open(".gitlab-ci.yml"))["variables"]
gh = yaml.safe_load(open(".github/workflows/boucle.yml"))["env"]
assert gl["BOUCLE_DOCTOR_ON_DISPATCH"] == "auto", gl["BOUCLE_DOCTOR_ON_DISPATCH"]
assert gl["BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL"] == "600", gl["BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL"]
assert "auto" in gh["BOUCLE_DOCTOR_ON_DISPATCH"], gh["BOUCLE_DOCTOR_ON_DISPATCH"]
assert "600" in gh["BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL"], gh["BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL"]
print("ok")
PY
  assert_success
  assert_output "ok"
}

# ── The rate limit must fail loudly, not silently ─────────────────────

@test "stage: a stamp that does not persist SKIPS the sweep, loudly" {
  # The lease is the rate limit. Without it, sweeping on every dispatch is
  # unbounded runner time — worse than both alternatives. Refusing falls
  # back to the schedule, i.e. the behaviour that existed before this
  # feature. Verified against the real failure: the first production run
  # read back nothing.
  # Empty store, and the write does not land — exactly what the first
  # production run saw: no variable before, nothing readable after.
  run stage_with "" 600 no
  assert_success
  refute_output --partial "SWEPT"
  assert_output --partial "WARN"
  assert_output --partial "did not persist"
  assert_output --partial "SKIPPED"
}

@test "stage: stands down when another dispatch holds the lease" {
  # A concurrent dispatch stamped after us: it is sweeping, and two sweeps
  # of the same board is waste.
  run bash -c "
    BOUCLE_HOME='$PWD'
    source lib/boucle-ci/doctor.sh
    forge_ci_var_get() { printf '%s' '9999999999'; }
    forge_ci_var_set() { return 0; }
    boucle_ci_doctor() { echo 'SWEPT'; }
    BOUCLE_FORGE=github BOUCLE_DOCTOR_ON_DISPATCH_INTERVAL=600 \
      boucle_ci_doctor_opportunistic
  "
  assert_success
  refute_output --partial "SWEPT"
  assert_output --partial "another dispatch holds the lease"
}

@test "stage: sweeps when it holds the lease" {
  run stage_with "$(($(date +%s) - 1200))" 600 yes
  assert_success
  assert_output --partial "SWEPT"
  refute_output --partial "WARN"
}

@test "stage: the read-back is on the sweep path only" {
  # It must not cost an extra call on the common path, which is the skip.
  run stage_with "$(($(date +%s) - 60))"
  assert_success
  refute_output --partial "STAMP:"
  refute_output --partial "WARN"
}
