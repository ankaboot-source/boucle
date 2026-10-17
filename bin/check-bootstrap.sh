#!/usr/bin/env bash
# bin/check-bootstrap.sh — toolchain bootstrap for the check quality-gate job.
#
# Installs shellcheck, shfmt and bats (pinned versions) when missing, then
# verifies the tools `make check` needs. Root-safe: when /usr/local/bin is
# not writable (shared shell executors running as a non-root user),
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

# fetch_checked URL DEST MAGIC [TRIES] — download URL to DEST with retries,
# and validate the first bytes against MAGIC (hex) before returning. Why the
# magic check: a flaky CDN (GitHub releases, gitlab packages) can serve an
# HTML error page with HTTP 200 — `curl -f` cannot catch it — and such a
# page used to be fed straight to `tar`, failing the check job with an
# opaque "gzip: stdin: not in gzip format" plus a retry storm in its wake
# (#144). Magic values: 1f8b = gzip, fd377a585a00 = xz, 7f454c46 = ELF.
fetch_checked() {
  local url="$1" dst="$2" magic="$3" tries="${4:-3}"
  local nb=$((${#magic} / 2)) n hex=""
  for ((n = 1; n <= tries; n++)); do
    hex=""
    if curl -fLsS --retry 2 --retry-delay 3 -o "${dst}" "${url}"; then
      hex="$(od -An -N "${nb}" -tx1 "${dst}" | tr -d ' \n')"
      if [ "${hex}" = "${magic}" ]; then
        return 0
      fi
    fi
    rm -f "${dst}"
    echo "fetch_checked: try ${n}/${tries} failed for ${url} (first bytes: ${hex:-none})"
    if [ "${n}" -lt "${tries}" ]; then
      sleep $((n * 3))
    fi
  done
  echo "fetch_checked: giving up on ${url} after ${tries} tries" >&2
  return 1
}

if ! command -v shellcheck > /dev/null 2>&1; then
  SC_VER="v0.11.0"
  # Unique per-job extract dir (lesson #58): a fixed /tmp path on a shared
  # executor collides when two jobs bootstrap the same version concurrently.
  SC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shellcheck.XXXXXX")"
  fetch_checked "https://github.com/koalaman/shellcheck/releases/download/${SC_VER}/shellcheck-${SC_VER}.linux.x86_64.tar.xz" "${SC_DIR}/shellcheck.tar.xz" "fd377a585a00"
  tar -xJf "${SC_DIR}/shellcheck.tar.xz" -C "${SC_DIR}"
  install -m 0755 "${SC_DIR}/shellcheck-${SC_VER}/shellcheck" "$PREFIX/bin/shellcheck"
  rm -rf "$SC_DIR"
fi

if ! command -v shfmt > /dev/null 2>&1; then
  SHFMT_VER="v3.14.1"
  SHFMT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shfmt.XXXXXX")"
  fetch_checked "https://github.com/mvdan/sh/releases/download/${SHFMT_VER}/shfmt_${SHFMT_VER}_linux_amd64" "${SHFMT_DIR}/shfmt" "7f454c46"
  install -m 0755 "${SHFMT_DIR}/shfmt" "$PREFIX/bin/shfmt"
  rm -rf "${SHFMT_DIR}"
fi

if ! command -v bats > /dev/null 2>&1; then
  # Tarball install — no git required (the check job runs on ANY runner via
  # tags: [], and shared docker runners may lack git in the job PATH).
  # Unique per-job extract dir (lesson #58) — see shellcheck above.
  BATS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bats.XXXXXX")"
  fetch_checked "https://github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz" "${BATS_DIR}/bats.tar.gz" "1f8b"
  tar -xzf "${BATS_DIR}/bats.tar.gz" -C "${BATS_DIR}"
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
