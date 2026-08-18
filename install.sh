#!/usr/bin/env bash
# install.sh — one-line installer for boucle.
#
#   curl -fsSL https://raw.githubusercontent.com/ankaboot-source/boucle/main/install.sh | bash
#
# Adds the boucle engine as a git submodule (.boucle/) and runs bin/setup,
# which auto-detects your forge (GitHub/GitLab) from the origin git remote.
# Exits non-zero on failure with a clear error message.
set -euo pipefail

ENGINE_URL="${BOUCLE_ENGINE_URL:-https://github.com/ankaboot-source/boucle}"
ENGINE_DIR=".boucle"

# ── 1. Ensure we are inside a git repository ─────────────────────────
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "Error: boucle must be installed inside a git repository." >&2
  echo "       Run this installer from the root of your project." >&2
  exit 1
fi

# ── 2. Add the engine as a git submodule ─────────────────────────────
# Fails with a clear git error if .boucle/ already exists — by design.
echo "Adding boucle engine as a git submodule at ${ENGINE_DIR}/ ..."
git submodule add "${ENGINE_URL}" "${ENGINE_DIR}"

# ── 3. Run setup (auto-detects forge from the origin remote) ─────────
echo ""
echo "Running boucle setup ..."
"${ENGINE_DIR}/bin/setup" "$@"
