#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# check stage — quality gate (shellcheck + shfmt + bats)
# Extracted from .gitlab-ci.yml check job
# Runs on push/MR to the default branch, NOT on trigger (autonomous loop) or schedule.

boucle_ci_check() {
  set +o pipefail

  # Engine repo or consumer install? `make check` lints the ENGINE's shell
  # sources against the ENGINE's Makefile, LESSONS.yml and bats suite. A
  # consumer has none of those, so there it either fails outright ("No rule
  # to make target 'check'") or runs the consumer's own unrelated target —
  # on every push to their default branch, every MR and every worker branch.
  # Their half of this gate is check-boucle-sync, which needs git and
  # nothing else. Mirrors the `check:` job in .gitlab-ci.yml and the
  # `github.repository == 'ankaboot-source/boucle'` guard in the GitHub
  # workflow; the filesystem is the only place the question has a reliable
  # answer (the engine is a git submodule, so rules:exists cannot see it).
  if [ -d "${BOUCLE_WORKSPACE:-.}/.boucle/bin" ]; then
    echo "check: consumer install — running the .boucle/ sync guard only"
    "${BOUCLE_WORKSPACE:-.}/.boucle/bin/check-boucle-sync"
    return $?
  fi

  # Initialize bats test helper submodules (guarded: jobs may run on
  # runners without git; GitLab's get_sources initializes them anyway).
  if command -v git > /dev/null 2>&1; then
    git submodule update --init --recursive
  fi

  # Install the toolchain (shellcheck/shfmt/bats, pinned) via the shared
  # root-safe bootstrap — falls back to $HOME/.local/bin when /usr/local/bin
  # is not writable (shared shell executors, e.g. framagit's non-root runner).
  "${BOUCLE_HOME:-.}/bin/check-bootstrap.sh"

  # Run the quality gate
  make check
}
