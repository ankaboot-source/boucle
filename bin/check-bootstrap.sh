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
  # Unique per-job extract dir (lesson #58): a fixed /tmp path on a shared
  # executor collides when two jobs bootstrap the same version concurrently.
  SC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shellcheck.XXXXXX")"
  curl -sSL "https://github.com/koalaman/shellcheck/releases/download/${SC_VER}/shellcheck-${SC_VER}.linux.x86_64.tar.xz" \
    | tar -xJ -C "$SC_DIR"
  install -m 0755 "$SC_DIR/shellcheck-${SC_VER}/shellcheck" "$PREFIX/bin/shellcheck"
  rm -rf "$SC_DIR"
fi

if ! command -v shfmt > /dev/null 2>&1; then
  SHFMT_VER="v3.13.1"
  curl -sSL -o "$PREFIX/bin/shfmt" "https://github.com/mvdan/sh/releases/download/${SHFMT_VER}/shfmt_${SHFMT_VER}_linux_amd64"
  chmod +x "$PREFIX/bin/shfmt"
fi

if ! command -v bats > /dev/null 2>&1; then
  # Tarball install — no git required (the check job runs on ANY runner via
  # tags: [], and shared docker runners may lack git in the job PATH).
  # Unique per-job extract dir (lesson #58) — see shellcheck above.
  BATS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bats.XXXXXX")"
  curl -sSL "https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz" | tar -xz -C "$BATS_DIR"
  "$BATS_DIR/bats-core-1.14.0/install.sh" "$PREFIX"
  rm -rf "$BATS_DIR"
fi

# System prerequisites that cannot be user-installed. Try sudo (shared docker
# runners are often root-capable); otherwise fail with an actionable message.
ensure_tool() {
  local t="$1" pkg="$2"
  if command -v "$t" > /dev/null 2>&1; then
    return 0
  fi
  if command -v sudo > /dev/null 2>&1 && sudo -n true 2> /dev/null; then
    sudo apt-get update -qq > /dev/null 2>&1 || true
    sudo apt-get install -y -qq "$pkg" > /dev/null 2>&1 && return 0
  fi
  echo "check-bootstrap: missing system tool '$t' — no sudo to install it. Provide a runner that has '$t' (or install it on this runner), then re-run." >&2
  exit 1
}
ensure_tool curl curl
ensure_tool git git
ensure_tool make make
ensure_tool tar tar
ensure_tool xz xz-utils

shellcheck --version > /dev/null
shfmt --version > /dev/null
bats --version > /dev/null
echo "check-bootstrap: shellcheck/shfmt/bats ready (prefix=$PREFIX, PATH=$PATH)"
