#!/usr/bin/env bats
#
# test/consumer-ci-noise.bats — what boucle is allowed to put in someone
# else's pipeline.
#
# A consumer includes .gitlab-ci.yml wholesale (bin/setup writes a one-line
# `include: remote` shim), so every job in this file lands in THEIR pipeline
# page, THEIR runner minutes and THEIR failure notifications. Two jobs were
# there without belonging to them:
#
#   - check      — `make check` lints the ENGINE's shell sources against the
#                  ENGINE's Makefile, LESSONS.yml and bats suite. A consumer
#                  has none of that, so the job failed on every push to their
#                  default branch, every MR and every worker branch. The
#                  GitHub workflow had guarded this from the start
#                  (github.repository == 'ankaboot-source/boucle'); the
#                  GitLab file never did.
#   - build-site — ran `npm ci && npm run build` on every push to the
#                  consumer's default branch even under
#                  BOUCLE_DEPLOY_MODE=external, where boucle deploys nothing
#                  and both consumers of the artifact (deploy, pages) skip.
#
# The GitHub workflow has the same problem from the other end: `deploy` ran
# unguarded in external mode, and BOUCLE_ENABLED — the master switch README.md
# and LOOP.md both document as "false to pause boucle" — was never wired in at
# all. 16 gates in .gitlab-ci.yml, zero in .github/workflows/boucle.yml, while
# bin/setup created the variable on every GitHub install.
#
# These tests read the YAML, not the prose: a rule deleted in a refactor is
# a red test, not a silent return of the noise.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  if ! command -v python3 > /dev/null 2>&1; then skip "python3 not installed"; fi
  python3 -c 'import yaml' 2> /dev/null || skip "PyYAML not installed"
}

# rules_of <job> — the job's `rules:` list as one JSON line.
rules_of() {
  python3 -c '
import json, sys, yaml
job = yaml.safe_load(open(".gitlab-ci.yml"))[sys.argv[1]]
print(json.dumps(job.get("rules", [])))
' "$1"
}

@test ".gitlab-ci.yml is valid YAML" {
  run python3 -c 'import yaml; yaml.safe_load(open(".gitlab-ci.yml"))'
  assert_success
}

@test ".github/workflows/boucle.yml is valid YAML" {
  run python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/boucle.yml"))'
  assert_success
}

# ── check: the engine's gate stays the engine's ───────────────────────

@test "check: a consumer install runs the sync guard and NOT make check" {
  # The split lives in the script, not in rules:. rules:exists is evaluated
  # against the parent project's file list, and the engine is installed as a
  # git SUBMODULE at .boucle/ — a gitlink, whose contents are not in that
  # list. The checked-out filesystem is the only reliable answer.
  block=$(sed -n '/^check:/,/^dispatch:/p' .gitlab-ci.yml)
  echo "$block" | grep -q 'BOUCLE_CONSUMER_INSTALL'
  echo "$block" | grep -q 'check-boucle-sync'
  # `make check` must be gated, never a bare step.
  run grep -cE '^    - make check$' <<< "$block"
  assert_output "0"
  echo "$block" | grep -q 'make check'
}

@test "check: a consumer install skips the lint toolchain bootstrap" {
  # Downloading three pinned binaries to run a five-line git guard is
  # minutes of runner time per push, spent on a lint that will not run.
  block=$(sed -n '/^check:/,/^dispatch:/p' .gitlab-ci.yml)
  run grep -cE '^    - check-bootstrap\.sh$' <<< "$block"
  assert_output "0"
  echo "$block" | grep -q 'check-bootstrap.sh'
}

@test "check: the shared stage function makes the same split" {
  # lib/boucle-ci/check.sh is the forge-agnostic twin of the job above.
  # Whoever wires `boucle-ci check` up must not get the unguarded version.
  grep -q '\.boucle/bin' lib/boucle-ci/check.sh
  grep -q 'check-boucle-sync' lib/boucle-ci/check.sh
}

@test "check: still matches on push, MR and worker branches" {
  # GitLab refuses to create a pipeline in which no job matches, and reports
  # the refusal on the push. Every loop job is gated on a trigger pipeline,
  # so on a consumer this job is what a push, an MR or a worker-branch
  # pipeline has to match. Scoping it out entirely trades one kind of noise
  # for another.
  rules=$(rules_of check)
  echo "$rules" | grep -q 'CI_DEFAULT_BRANCH'
  echo "$rules" | grep -q 'merge_request_event'
  echo "$rules" | grep -q 'boucle'
}

# ── build-site / deploy: nothing to build when boucle does not deploy ──

@test "build-site: never runs in external deploy mode" {
  rules=$(rules_of build-site)
  echo "$rules" | python3 -c '
import json, sys
rules = json.load(sys.stdin)
for r in rules:
    if r.get("if", "").strip() == "$BOUCLE_DEPLOY_MODE == \"external\"":
        assert r.get("when") == "never", r
        sys.exit(0)
sys.exit("no external-mode guard on build-site: " + json.dumps(rules))
'
}

@test "build-site: never runs when no publisher is configured" {
  rules=$(rules_of build-site)
  echo "$rules" | grep -q 'BOUCLE_DEPLOY_CMD'
  echo "$rules" | grep -q 'gitlab-pages'
}

@test "deploy: never runs in external deploy mode" {
  rules=$(rules_of deploy)
  echo "$rules" | python3 -c '
import json, sys
rules = json.load(sys.stdin)
for r in rules:
    if r.get("if", "").strip() == "$BOUCLE_DEPLOY_MODE == \"external\"":
        assert r.get("when") == "never", r
        sys.exit(0)
sys.exit("no external-mode guard on deploy: " + json.dumps(rules))
'
}

@test "the external-mode guards sit BEFORE the push rule" {
  # rules: is first-match-wins. A guard placed after the push rule never
  # fires.
  for job in build-site deploy; do
    rules=$(rules_of "$job")
    python3 -c '
import json, sys
rules = json.loads(sys.argv[1])
guard = push = None
for i, r in enumerate(rules):
    cond = r.get("if", "")
    if "BOUCLE_DEPLOY_MODE" in cond and r.get("when") == "never":
        guard = i if guard is None else guard
    if "CI_PIPELINE_SOURCE == \"push\"" in cond:
        push = i if push is None else push
assert guard is not None, "no guard in " + sys.argv[2]
assert push is not None, "no push rule in " + sys.argv[2]
assert guard < push, sys.argv[2] + ": guard at " + str(guard) + " after push rule at " + str(push)
' "$rules" "$job"
  done
}

@test "the loop jobs are untouched: still trigger-gated only" {
  # Guardrail on this change itself. Narrowing push-time jobs must not have
  # narrowed a loop job, which would break the loop rather than quiet it.
  for job in dispatch triage worker reviewer merger post-merge catchup e2e; do
    rules=$(rules_of "$job")
    echo "$rules" | grep -q 'trigger' || {
      echo "$job lost its trigger rule: $rules"
      false
    }
  done
}

# ── Entry policy is declared where consumers can see it ───────────────

@test "BOUCLE_ENTRY_MODE is declared in both CI files with the same default" {
  run python3 -c '
import yaml
gl = yaml.safe_load(open(".gitlab-ci.yml"))["variables"]["BOUCLE_ENTRY_MODE"]
gh = yaml.safe_load(open(".github/workflows/boucle.yml"))["env"]["BOUCLE_ENTRY_MODE"]
assert gl == "label", gl
assert "label" in gh, gh
print("ok")
'
  assert_success
  assert_output "ok"
}


# ── GitHub: the master switch, and the same deploy waste ──────────────
#
# These read the workflow through PyYAML in a quoted heredoc: the conditions
# under test are themselves full of single quotes ('false', 'external'), and
# nesting those inside a bats `run python3 -c '...'` ends the bash string at
# the first inner quote.

@test "github: BOUCLE_ENABLED gates EVERY job" {
  # The switch README.md and LOOP.md document ("false to pause boucle").
  # .gitlab-ci.yml had 16 of these gates; this workflow had none, so a
  # consumer who set it to false got every job running exactly as before.
  run python3 - <<'PY'
import yaml
w = yaml.safe_load(open(".github/workflows/boucle.yml"))
missing = [n for n, j in w["jobs"].items()
           if "vars.BOUCLE_ENABLED != 'false'" not in " ".join(str(j.get("if", "")).split())]
assert not missing, "ungated jobs: " + ", ".join(missing)
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "github: the gate is fail-OPEN, unlike GitLab's" {
  # GitLab: `$BOUCLE_ENABLED != "true" -> never` (a project missing the
  # variable runs nothing). Copying that polarity here would silence every
  # install whose variable predates or outlives bin/setup's `gh variable
  # set` line — an autonomous loop going quiet with no error. Unset must
  # read as enabled, which is also the documented default.
  run grep -c "BOUCLE_ENABLED == .true." .github/workflows/boucle.yml
  assert_output "0"
  run grep -c "vars.BOUCLE_ENABLED != .false." .github/workflows/boucle.yml
  refute_output "0"
}

@test "github: triage keeps always() first in its condition" {
  # triage runs after a dispatch marked continue-on-error, so `always()`
  # must survive having the gate prepended — without it the job is skipped
  # whenever dispatch exits non-zero, which is a normal dispatch outcome.
  run python3 - <<'PY'
import yaml
cond = " ".join(str(yaml.safe_load(open(".github/workflows/boucle.yml"))["jobs"]["triage"]["if"]).split())
assert cond.startswith("always()"), cond
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "github: deploy never runs in external deploy mode" {
  # Same waste as build-site on GitLab, one step earlier: boucle-ci deploy
  # returns immediately in external mode, but the checkout (fetch-depth: 0
  # + submodules), setup-node, dependency install and self-update step all
  # ran first, on every push to the consumer's default branch.
  #
  # It must read `vars`, not `env`: the env context is NOT available in a
  # job-level `if` (only in steps[*].if), so env.BOUCLE_DEPLOY_MODE would
  # evaluate to empty and the guard would never fire.
  run python3 - <<'PY'
import yaml
cond = " ".join(str(yaml.safe_load(open(".github/workflows/boucle.yml"))["jobs"]["deploy"]["if"]).split())
assert "vars.BOUCLE_DEPLOY_MODE != 'external'" in cond, cond
assert "env.BOUCLE_DEPLOY_MODE" not in cond, cond
print("ok")
PY
  assert_success
  assert_output "ok"
}
