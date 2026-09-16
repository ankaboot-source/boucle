#!/usr/bin/env bats
#
# test/runner-toolchain.bats — the image and the pipeline must agree on what
# is installed, and on which runners may pick a job up.
#
# Two failures this file exists to catch, both observed:
#
#   1. A job with NO `tags:` field is eligible for ANY runner, including a
#      TAGGED SHELL EXECUTOR. A shell executor ignores `image:` entirely, so
#      the agents image is simply not there — and the before_script installs
#      glab/jcode/node but never chromium, agent-browser, mermaid/jsdom or
#      python3. `triage` is the worst case: it calls bin/render-preview AND
#      bin/check-mermaid, and check-mermaid's "parser unavailable" exit (3)
#      is treated as a PASS, so the diagram gate silently stops gating.
#      LESSONS.yml #74 is the same failure, fixed on `worker` only at the time.
#
#   2. A version pinned in docker/Dockerfile.agents that no longer matches the
#      one the before_script installs. This never goes red: the guards compare
#      the installed version to the pin and reinstall on a mismatch. The image
#      just quietly stops being used — glab drifted 1.50.0 vs 1.111.0 and
#      jcode v0.73.0 vs v0.75.3, so both binaries were re-downloaded on every
#      single job while the image shipped them.
#
# These read the files, not the prose: a pin bumped in one place only is a
# red test, not a silent re-download.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  DOCKERFILE="docker/Dockerfile.agents"
}

# arg_of <name> — the default of `ARG <name>=...` in the Dockerfile.
arg_of() {
  sed -n "s/^ARG $1=\(.*\)$/\1/p" "$DOCKERFILE" | head -1
}

need_yaml() {
  command -v python3 > /dev/null 2>&1 || skip "python3 not installed"
  python3 -c 'import yaml' 2> /dev/null || skip "PyYAML not installed"
}

# ── 1. every job pins its runner class ────────────────────────────────

@test "gitlab: every job declares tags — none inherits 'any runner'" {
  need_yaml
  run python3 - <<'PY'
import sys, yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
reserved = {"stages", "variables", "default", "workflow", "include"}
missing = [
    name for name, job in d.items()
    if name not in reserved
    and not name.startswith(".")
    and isinstance(job, dict)
    and "tags" not in job
]
if missing:
    print("jobs with no tags: " + ", ".join(sorted(missing)))
    sys.exit(1)
PY
  assert_success
}

# ── 2. the pins agree across every file that carries them ─────────────

@test "jcode: Dockerfile pin matches the GitLab and GitHub before_scripts" {
  local docker_pin gitlab_pin github_pin
  docker_pin="$(arg_of JCODE_VERSION)"
  gitlab_pin="$(sed -n 's/.*JCODE_VERSION:-\([^}]*\)}.*/\1/p' .gitlab-ci.yml | sort -u)"
  github_pin="$(sed -n 's/.*JCODE_VERSION:-\([^}]*\)}.*/\1/p' .github/workflows/boucle.yml | sort -u)"

  [ -n "$docker_pin" ] || fail "no ARG JCODE_VERSION in $DOCKERFILE"
  # sort -u collapses the workflow's many copies: more than one line here
  # means the workflow itself disagrees with itself.
  assert_equal "$(printf '%s' "$gitlab_pin" | wc -l)" "0"
  assert_equal "$(printf '%s' "$github_pin" | wc -l)" "0"
  assert_equal "$docker_pin" "$gitlab_pin"
  assert_equal "$docker_pin" "$github_pin"
}

@test "glab: Dockerfile pin matches the GitLab before_script" {
  local docker_pin gitlab_pin
  docker_pin="$(arg_of GLAB_VERSION)"
  gitlab_pin="$(sed -n 's/^ *GLAB_VER="\([^"]*\)".*/\1/p' .gitlab-ci.yml | sort -u)"

  [ -n "$docker_pin" ] || fail "no ARG GLAB_VERSION in $DOCKERFILE"
  [ -n "$gitlab_pin" ] || fail "no GLAB_VER in .gitlab-ci.yml"
  assert_equal "$docker_pin" "$gitlab_pin"
}

@test "mermaid + jsdom: Dockerfile pins match bin/check-mermaid defaults" {
  local docker_mermaid docker_jsdom script_mermaid script_jsdom
  docker_mermaid="$(arg_of MERMAID_VERSION)"
  docker_jsdom="$(arg_of JSDOM_VERSION)"
  script_mermaid="$(sed -n 's/^MERMAID_VERSION="${BOUCLE_MERMAID_VERSION:-\([^}]*\)}".*/\1/p' bin/check-mermaid)"
  script_jsdom="$(sed -n 's/^JSDOM_VERSION="${BOUCLE_JSDOM_VERSION:-\([^}]*\)}".*/\1/p' bin/check-mermaid)"

  assert_equal "$docker_mermaid" "$script_mermaid"
  assert_equal "$docker_jsdom" "$script_jsdom"
}

# ── 3. the image carries what the scripts actually invoke ─────────────

@test "image: apt installs every non-slim binary the scripts call" {
  # debian:bookworm-slim carries 88 packages. None of these is among them,
  # and every one has a call site:
  #   make, g++  — npm ci (node-gyp), bin/check-bootstrap.sh
  #   procps     — pgrep, bin/jc RSS sampler
  #   time       — /usr/bin/time, bin/jc peak RSS
  #   unzip      — bin/forge/github.sh artifact unpack
  #   python3    — worker screenshot server, bin/check-lessons
  #   chromium   — bin/render-preview
  local installed
  # The package list is the indented, backslash-continued block under
  # `apt-get install`. Read it as tokens — a regex would have to escape both
  # the trailing backslash and the `+` in `g++`.
  installed="$(sed -n '/apt-get install/,/rm -rf \/var\/lib\/apt/p' "$DOCKERFILE" \
    | sed -n 's/^ \{4,\}\([a-z0-9+.-]*\) \\$/\1/p')"

  for pkg in make g++ procps time unzip python3 chromium jq git curl; do
    printf '%s\n' "$installed" | grep -qxF "$pkg" \
      || fail "$DOCKERFILE does not apt-install '$pkg' (installs: $(printf '%s ' $installed))"
  done
}

@test "image: the build asserts its own toolchain instead of deferring to a job" {
  run grep -q 'MISSING: ' "$DOCKERFILE"
  assert_success "$DOCKERFILE has no build-time toolchain assertion"
}

@test "gitlab: the environment probe names the image-only tools" {
  # A shell executor prints a clean Environment block and then dies hundreds
  # of lines later on a binary the probe never looked for. Each of these must
  # be probed by name.
  for tool in chromium agent-browser python3 make; do
    run grep -q "_probe ${tool} " .gitlab-ci.yml
    assert_success "before_script does not probe '$tool'"
  done
  run grep -q 'mermaid+jsdom' .gitlab-ci.yml
  assert_success "before_script does not probe the mermaid/jsdom pair"
}

# ── 4. build-site runs the consumer's build, so it needs the toolchain ─

@test "build-site: no image override — it needs the build toolchain" {
  need_yaml
  run python3 - <<'PY'
import sys, yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
img = d["build-site"].get("image")
if img is not None:
    print("build-site pins image=%r; it runs `npm ci && npm run build` and a "
          "bare node slim image has no make/g++ for node-gyp" % img)
    sys.exit(1)
PY
  assert_success
}
