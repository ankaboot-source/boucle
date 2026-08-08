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

    # Install shellcheck (static binary, pinned)
    if ! command -v shellcheck &>/dev/null; then
        SC_VER="v0.11.0"
        curl -sSL "https://github.com/koalaman/shellcheck/releases/download/${SC_VER}/shellcheck-${SC_VER}.linux.x86_64.tar.xz" \
            | tar -xJ -C /tmp
        install -m 0755 "/tmp/shellcheck-${SC_VER}/shellcheck" /usr/local/bin/shellcheck
    fi

    # shfmt (static binary, pinned)
    if ! command -v shfmt &>/dev/null; then
        SHFMT_VER="v3.13.1"
        curl -sSL -o /usr/local/bin/shfmt "https://github.com/mvdan/sh/releases/download/${SHFMT_VER}/shfmt_${SHFMT_VER}_linux_amd64"
        chmod +x /usr/local/bin/shfmt
    fi

    # bats-core (from source, pinned tag)
    if ! command -v bats &>/dev/null; then
        git clone --depth 1 --branch v1.14.0 https://github.com/bats-core/bats-core.git /tmp/bats
        /tmp/bats/install.sh /usr/local
    fi

    shellcheck --version
    shfmt --version
    bats --version

    # Run the quality gate
    make check
}
