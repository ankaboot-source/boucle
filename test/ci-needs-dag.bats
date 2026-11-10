#!/usr/bin/env bats
# test/ci-needs-dag.bats — every non-optional `needs:` edge must reference a job
# that CANNOT be excluded while the dependent job is included.
#
# Context: on a consumer with no publisher (BOUCLE_DEPLOY_CMD empty, no
# gitlab-pages provider) `build-site` is excluded but `deploy` — which needs it
# WITHOUT `optional: true` — was still included. GitLab then creates the push
# pipeline and fails it immediately: 0 job, `created_at == finished_at`,
# `started_at: null`. The two jobs' `rules:` had drifted: `build-site` carried a
# third `when: never` guard that `deploy` lacked.
#
# The general test below is the contract, not the instance: for every job D with
# a non-optional need on U, D's inclusion set must be a subset of U's. GitLab
# `rules:` are first-match-wins and, when present with no match, exclude the
# job — the test simulates exactly that over a finite domain of the variables
# the two jobs actually mention. A future guard added to one side of ANY needs
# edge is a red test.
#
# `deploy`'s need on `build-site` is `optional: true` (BOUCLE_DEPLOY_INLINE
# excludes build-site while deploy runs), so that edge is outside the general
# test by construction. It is pinned explicitly instead: build-site's rules MUST
# equal deploy's plus exactly one inline-only `when: never` guard, and deploy's
# need MUST stay optional.
#
# These tests read the YAML, not the prose: a rule deleted in a refactor is a
# red test, not a silently broken consumer pipeline.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  if ! command -v python3 > /dev/null 2>&1; then skip "python3 not installed"; fi
  python3 -c 'import yaml' 2> /dev/null || skip "PyYAML not installed"
}

# ── The general DAG contract ───────────────────────────────────────────────

@test "no non-optional needs references a job that can be excluded while it runs" {
  run python3 - <<'PY'
import itertools
import re
import sys

import yaml

doc = yaml.safe_load(open(".gitlab-ci.yml"))


def if_conditions(job):
    return [r["if"] for r in (job.get("rules") or []) if r.get("if")]


def uses(cond):
    return set(re.findall(r"\$(\w+)", cond))


def eval_cond(cond, values):
    # Rewrite the restricted GitLab rules:if grammar into Python.

    def _v(name):
        return values.get(name)

    def _t(name):
        value = _v(name)
        return value is not None and value != ""

    expr = re.sub(
        r'\$(\w+)\s*(==|!=)\s*"([^"]*)"',
        lambda m: "_v(%r) %s %r" % (m.group(1), m.group(2), m.group(3)),
        cond,
    )
    expr = re.sub(
        r"\$(\w+)\s*(==|!=)\s*\$(\w+)",
        lambda m: "_v(%r) %s _v(%r)" % (m.group(1), m.group(2), m.group(3)),
        expr,
    )
    expr = re.sub(r"\$(\w+)", lambda m: "_t(%r)" % m.group(1), expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    return bool(eval(expr, {"__builtins__": {}}, {"_v": _v, "_t": _t}))


def included(job, values):
    rules = job.get("rules")
    if rules is None:
        return True
    for rule in rules:
        cond = rule.get("if")
        if cond is None or eval_cond(cond, values):
            return rule.get("when", "on_success") != "never"
    return False  # rules: present, no match -> excluded


def failing_assignment(down, up):
    conds = if_conditions(down) + if_conditions(up)
    # The evaluator models the subset of rules:if this file uses. A new
    # construct (=~, a quoted $VAR) MUST fail loudly instead of being
    # mis-evaluated into a false "safe" — extend eval_cond, do not silence.
    for cond in conds:
        if "=~" in cond or re.search(r'"\s*\$', cond):
            sys.exit("unsupported rules:if syntax in a needs edge, extend eval_cond: " + cond)
    names = sorted(set().union(*[uses(c) for c in conds]) if conds else set())
    literals = {n: set() for n in names}
    for cond in conds:
        for m in re.finditer(r'\$(\w+)\s*(?:==|!=)\s*"([^"]*)"', cond):
            literals.setdefault(m.group(1), set()).add(m.group(2))
    domains = []
    for name in names:
        vals = literals.get(name, set()) | {"", "__other__", None}
        domains.append(sorted(vals, key=lambda v: (v is None, str(v))))
    for combo in itertools.product(*domains):
        values = dict(zip(names, combo))
        if included(down, values) and not included(up, values):
            return values
    return None


pairs = []
for name, job in doc.items():
    if not isinstance(job, dict):
        continue
    for need in job.get("needs") or []:
        if isinstance(need, str):
            pairs.append((name, need))
        elif isinstance(need, dict) and not need.get("optional"):
            pairs.append((name, need["job"]))

problems = []
for down, up in pairs:
    if up not in doc:
        problems.append("%s needs unknown job %s" % (down, up))
        continue
    counter = failing_assignment(doc[down], doc[up])
    if counter is not None:
        problems.append(
            "%s can be included while its non-optional need %s is excluded: %s"
            % (down, up, counter)
        )

if problems:
    sys.exit("\n".join(problems))
print("ok: %d non-optional needs edge(s) are DAG-safe" % len(pairs))
PY
  assert_success
  assert_output --partial "DAG-safe"
}

# ── The targeted regression: deploy must co-exclude with build-site ─────────

@test "deploy carries the same publisher guard as build-site" {
  # The instance that broke a consumer: build-site excludes "no deploy command
  # and no gitlab-pages provider" but deploy did not, so deploy survived with a
  # non-optional needs on an absent build-site.
  run python3 - <<'PY'
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
want = '$BOUCLE_DEPLOY_CMD == "" && $BOUCLE_DEPLOY_PROVIDER != "gitlab-pages"'
rules = ci["deploy"]["rules"]
guards = [i for i, r in enumerate(rules)
          if r.get("if", "").strip() == want and r.get("when") == "never"]
assert guards, "deploy lacks the publisher guard: " + str(rules)
push = [i for i, r in enumerate(rules)
        if 'CI_PIPELINE_SOURCE == "push"' in r.get("if", "")]
assert push, "deploy has no push rule"
assert guards[0] < push[0], "the guard must sit BEFORE the push rule (first-match-wins)"
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "build-site rules equal deploy rules plus exactly the inline guard" {
  # Equal rules was the strongest "no drift" form while deploy needed build-site
  # non-optionally. The need is now optional (inline deploy runs alone), so the
  # contract is equality up to build-site's single inline-only guard: every
  # other rule must match deploy's, in the same order.
  run python3 - <<'PY'
import json

import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
inline = '$BOUCLE_DEPLOY_INLINE == "true" && $BOUCLE_DEPLOY_PROVIDER != "gitlab-pages"'
deploy = [(r.get("if"), r.get("when", "on_success")) for r in ci["deploy"]["rules"]]
build = [(r.get("if"), r.get("when", "on_success")) for r in ci["build-site"]["rules"]]
guards = [i for i, rule in enumerate(build) if rule == (inline, "never")]
assert len(guards) == 1, "build-site must carry exactly one inline guard:\n%s" % json.dumps(build)
without = build[: guards[0]] + build[guards[0] + 1 :]
assert without == deploy, (
    "build-site/deploy rules drifted outside the inline guard:\ndeploy=%s\nbuild-without-inline=%s"
    % (json.dumps(deploy), json.dumps(without))
)
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "deploy's need on build-site is optional (inline deploy runs alone)" {
  # BOUCLE_DEPLOY_INLINE=true excludes build-site. A non-optional need would
  # reference an absent job and GitLab would fail the push pipeline at once.
  run python3 - <<'PY'
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
assert ci["deploy"]["needs"] == [{"job": "build-site", "optional": True}], ci["deploy"]["needs"]
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "BOUCLE_DEPLOY_INLINE defaults to false" {
  run python3 - <<'PY'
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
assert ci["variables"]["BOUCLE_DEPLOY_INLINE"] == "false", ci["variables"].get("BOUCLE_DEPLOY_INLINE")
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "inline deploy excludes build-site and pages but keeps deploy" {
  # The optimisation's happy path: self mode, deploy command set, no Pages
  # provider, push to the default branch. `deploy` builds in-job; the artifact
  # producer and the Pages publisher are out of the pipeline.
  run python3 - <<'PY'
import re
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))


def included(job, vals):
    def _v(name):
        return vals.get(name, "")

    def _t(name):
        return _v(name) != ""

    def cond_is_true(cond):
        expr = re.sub(
            r'\$(\w+)\s*(==|!=)\s*"([^"]*)"',
            lambda m: "_v(%r) %s %r" % (m.group(1), m.group(2), m.group(3)),
            cond,
        )
        expr = re.sub(
            r"\$(\w+)\s*(==|!=)\s*\$(\w+)",
            lambda m: "_v(%r) %s _v(%r)" % (m.group(1), m.group(2), m.group(3)),
            expr,
        )
        expr = re.sub(r"\$(\w+)", lambda m: "_t(%r)" % m.group(1), expr)
        return bool(eval(expr.replace("&&", " and ").replace("||", " or "),
                         {"__builtins__": {}}, {"_v": _v, "_t": _t}))

    for rule in job.get("rules") or []:
        cond = rule.get("if")
        if cond is None or cond_is_true(cond):
            return rule.get("when", "on_success") != "never"
    return False


vals = {
    "BOUCLE_ENABLED": "true",
    "BOUCLE_DEPLOY_MODE": "self",
    "BOUCLE_DEPLOY_INLINE": "true",
    "BOUCLE_DEPLOY_CMD": "npx wrangler pages deploy public",
    "BOUCLE_DEPLOY_PROVIDER": "",
    "CI_COMMIT_BRANCH": "main",
    "CI_DEFAULT_BRANCH": "main",
    "CI_PIPELINE_SOURCE": "push",
}
got = {job: included(ci[job], vals) for job in ("build-site", "deploy", "pages")}
assert got == {"build-site": False, "deploy": True, "pages": False}, got
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "inline deploy keeps build-site when BOUCLE_DEPLOY_PROVIDER=gitlab-pages" {
  # `pages` needs build-site's artifact non-optionally. The inline guard MUST
  # carve gitlab-pages out or the Pages pipeline references an absent job.
  run python3 - <<'PY'
import re
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))


def included(job, vals):
    def _v(name):
        return vals.get(name, "")

    def _t(name):
        return _v(name) != ""

    def cond_is_true(cond):
        expr = re.sub(
            r'\$(\w+)\s*(==|!=)\s*"([^"]*)"',
            lambda m: "_v(%r) %s %r" % (m.group(1), m.group(2), m.group(3)),
            cond,
        )
        expr = re.sub(
            r"\$(\w+)\s*(==|!=)\s*\$(\w+)",
            lambda m: "_v(%r) %s _v(%r)" % (m.group(1), m.group(2), m.group(3)),
            expr,
        )
        expr = re.sub(r"\$(\w+)", lambda m: "_t(%r)" % m.group(1), expr)
        return bool(eval(expr.replace("&&", " and ").replace("||", " or "),
                         {"__builtins__": {}}, {"_v": _v, "_t": _t}))

    for rule in job.get("rules") or []:
        cond = rule.get("if")
        if cond is None or cond_is_true(cond):
            return rule.get("when", "on_success") != "never"
    return False


vals = {
    "BOUCLE_ENABLED": "true",
    "BOUCLE_DEPLOY_MODE": "self",
    "BOUCLE_DEPLOY_INLINE": "true",
    "BOUCLE_DEPLOY_CMD": "",  # Pages mode: the command stays empty
    "BOUCLE_DEPLOY_PROVIDER": "gitlab-pages",
    "CI_COMMIT_BRANCH": "main",
    "CI_DEFAULT_BRANCH": "main",
    "CI_PIPELINE_SOURCE": "push",
}
got = {job: included(ci[job], vals) for job in ("build-site", "deploy", "pages")}
assert got == {"build-site": True, "deploy": True, "pages": True}, got
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "regression: a consumer with no publisher gets a valid, empty push pipeline" {
  # The reported incident, exactly: BOUCLE_ENABLED=true, BOUCLE_DEPLOY_CMD="",
  # BOUCLE_DEPLOY_MODE unset (so the YAML default `self` applies),
  # BOUCLE_DEPLOY_PROVIDER unset, push to the default branch. build-site was
  # excluded but deploy was not, so deploy's non-optional needs: build-site
  # referenced an absent job: GitLab created the pipeline and failed it at once
  # — 0 job, created_at == finished_at, started_at: null.
  run python3 - <<'PY'
import re
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
vals = {
    "BOUCLE_ENABLED": "true",
    "BOUCLE_DEPLOY_CMD": "",
    "BOUCLE_DEPLOY_MODE": "",  # unset -> the YAML default `self` is used
    "BOUCLE_DEPLOY_PROVIDER": "",
    "CI_COMMIT_BRANCH": "main",
    "CI_DEFAULT_BRANCH": "main",
    "CI_PIPELINE_SOURCE": "push",
}


def _v(name):
    return vals.get(name)


def _t(name):
    value = _v(name)
    return value is not None and value != ""


def cond_is_true(cond):
    expr = re.sub(
        r'\$(\w+)\s*(==|!=)\s*"([^"]*)"',
        lambda m: "_v(%r) %s %r" % (m.group(1), m.group(2), m.group(3)),
        cond,
    )
    expr = re.sub(
        r"\$(\w+)\s*(==|!=)\s*\$(\w+)",
        lambda m: "_v(%r) %s _v(%r)" % (m.group(1), m.group(2), m.group(3)),
        expr,
    )
    expr = re.sub(r"\$(\w+)", lambda m: "_t(%r)" % m.group(1), expr)
    return bool(eval(expr.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}},
                     {"_v": _v, "_t": _t}))


def included(job):
    rules = job.get("rules")
    if rules is None:
        return True
    for rule in rules:
        cond = rule.get("if")
        if cond is None or cond_is_true(cond):
            return rule.get("when", "on_success") != "never"
    return False


for job in ("build-site", "deploy", "pages"):
    assert not included(ci[job]), "%s is included on a publisher-less consumer" % job
print("ok")
PY
  assert_success
  assert_output "ok"
}

@test "pages co-excludes with build-site in external mode" {
  # pages also needs build-site without optional. In external mode build-site
  # is excluded; pages must not survive alone (the same invalid-DAG class).
  run python3 - <<'PY'
import yaml

ci = yaml.safe_load(open(".gitlab-ci.yml"))
rules = ci["pages"]["rules"]
assert any(r.get("if", "").strip() == '$BOUCLE_DEPLOY_MODE == "external"'
           and r.get("when") == "never" for r in rules), \
    "pages lacks the external-mode guard: " + str(rules)
print("ok")
PY
  assert_success
  assert_output "ok"
}
