#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# check stage — quality gate (shellcheck + shfmt + bats)
# Extracted from .gitlab-ci.yml check job
# Runs on push/MR to the default branch, NOT on trigger (autonomous loop) or schedule.

boucle_ci_check() {
  set +o pipefail

  # Initialize bats test helper submodules
  git submodule update --init --recursive

  # Install the toolchain (shellcheck/shfmt/bats, pinned) via the shared
  # root-safe bootstrap — falls back to $HOME/.local/bin when /usr/local/bin
  # is not writable (shared shell executors, e.g. framagit's non-root runner).
  "${BOUCLE_HOME:-.}/bin/check-bootstrap.sh"

  # Run the quality gate
  make check
}
