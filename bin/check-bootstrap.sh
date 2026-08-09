#!/usr/bin/env bash
# bin/check-bootstrap.sh — toolchain bootstrap for the check quality-gate job.
#
# Installs shellcheck, shfmt and bats (pinned versions) when missing, then
# verifies the tools `make check` needs. Root-safe: when /usr/local/bin is
# not writable (shared shell executors, e.g. framagit's non-root runner),
# tools land in $HOME/.local/bin instead. Idempotent.
#
# Usage: bin/check-bootstrap.sh   (call from the check job's before_script)
set -euo pipefail

# Prefer a user-local bin dir when /usr/local/bin is not writable.
export PATH="$HOME/.local/bin:$PATH"
if [ -w /usr/local/bin ]; then
  PREFIX="/usr/local"
else
  PREFIX="$HOME/.local"
fi
mkdir -p "$PREFIX/bin"

if ! command -v shellcheck > /dev/null 2>&1; then
  SC_VER="v0.11.0"
  curl -sSL "https://github.com/koalaman/shellcheck/releases/download/${SC_VER}/shellcheck-${SC_VER}.linux.x86_64.tar.xz" \
    | tar -xJ -C /tmp
  install -m 0755 "/tmp/shellcheck-${SC_VER}/shellcheck" "$PREFIX/bin/shellcheck"
fi

if ! command -v shfmt > /dev/null 2>&1; then
  SHFMT_VER="v3.13.1"
  curl -sSL -o "$PREFIX/bin/shfmt" "https://github.com/mvdan/sh/releases/download/${SHFMT_VER}/shfmt_${SHFMT_VER}_linux_amd64"
  chmod +x "$PREFIX/bin/shfmt"
fi

if ! command -v bats > /dev/null 2>&1; then
  git clone --depth 1 --branch v1.14.0 https://github.com/bats-core/bats-core.git /tmp/bats
  /tmp/bats/install.sh "$PREFIX"
fi

# Tools that cannot be user-installed — fail with an actionable message.
for t in curl git make tar xz; do
  command -v "$t" > /dev/null 2>&1 || {
    echo "check-bootstrap: missing system tool '$t' — install it (or provide a runner that has it), then re-run." >&2
    exit 1
  }
done

shellcheck --version > /dev/null
shfmt --version > /dev/null
bats --version > /dev/null
echo "check-bootstrap: shellcheck/shfmt/bats ready (prefix=$PREFIX, PATH=$PATH)"
