#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154
# lib/boucle-ci.sh — Shared CI stage functions.
#
# This library extracts the job logic from .gitlab-ci.yml into forge-agnostic
# shell functions. Both .gitlab-ci.yml and .github/workflows/boucle.yml are
# thin wrappers that call `bin/boucle-ci <stage>`.
#
# Environment contract (set by the CI runner / forge shim):
#   BOUCLE_WORKSPACE      — checkout directory (CI_PROJECT_DIR / GITHUB_WORKSPACE)
#   BOUCLE_PROJECT_ID     — project identifier (numeric on GitLab, "owner/repo" on GitHub)
#   BOUCLE_PROJECT_PATH   — project path (e.g. group/subgroup/project or owner/repo)
#   BOUCLE_FORGE_HOST     — forge API host
#   BOUCLE_DEFAULT_BRANCH — default branch name (master / main)
#   BOUCLE_PIPELINE_SOURCE — what triggered this pipeline (trigger / push / schedule / workflow_dispatch)
#   BOUCLE_JOB_ID         — unique job identifier
#   BOUCLE_JOB_URL        — URL to this job (for diagnostics)
#   BOUCLE_TRIGGER_PAYLOAD — webhook JSON payload (GitLab) or github.event JSON (GitHub)
#   BOUCLE_TRIGGER_TOKEN   — GitLab trigger token (empty on GitHub)
#   BOUCLE_TOKEN          — bot PAT
#   BOUCLE_BOT_ID         — bot user ID (numeric on GitLab, login on GitHub)
#   BOUCLE_BOT_USERNAME   — bot username (default: up-bot)
#   BOUCLE_FORGE          — active forge (gitlab / github)
#   BOUCLE_HOME           — boucle installation root
#
# All forge API calls go through bin/forge/${BOUCLE_FORGE}.sh via forge_init().

set +o pipefail

# ── Bootstrap ──────────────────────────────────────────────────────────────────

# Source forge abstraction layer.
if [ -z "${BOUCLE_FORGE:-}" ]; then
  echo "BOUCLE_FORGE not set (expected: gitlab or github)" >&2
  exit 1
fi

# shellcheck source=forge/common.sh
. "$BOUCLE_HOME/bin/forge/common.sh"
forge_init

# Source shared helpers (set_boucle_label, resolve_reporter_id, etc.)
# shellcheck source=boucle.sh
. "$BOUCLE_HOME/lib/boucle.sh"

# ── Environment normalization ──────────────────────────────────────────────────
# Map forge-specific predefined vars to BOUCLE_* if not already set.
: "${BOUCLE_WORKSPACE:=${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-$(pwd)}}}"
: "${BOUCLE_PROJECT_ID:=${CI_PROJECT_ID:-}}"
: "${BOUCLE_PROJECT_PATH:=${CI_PROJECT_PATH:-}}"
: "${BOUCLE_FORGE_HOST:=${GITLAB_HOST:-github.com}}"
: "${BOUCLE_DEFAULT_BRANCH:=${CI_DEFAULT_BRANCH:-master}}"
: "${BOUCLE_DEFAULT_BRANCH:=${CI_DEFAULT_BRANCH:-main}}"
: "${BOUCLE_PIPELINE_SOURCE:=${CI_PIPELINE_SOURCE:-push}}"
: "${BOUCLE_JOB_ID:=${CI_JOB_ID:-${GITHUB_RUN_ID:-0}}}"
: "${BOUCLE_JOB_URL:=${CI_JOB_URL:-}}"
: "${BOUCLE_TRIGGER_PAYLOAD:=${TRIGGER_PAYLOAD:-}}"
: "${BOUCLE_BOT_USERNAME:=up-bot}"

export BOUCLE_WORKSPACE BOUCLE_PROJECT_ID BOUCLE_PROJECT_PATH BOUCLE_FORGE_HOST \
  BOUCLE_DEFAULT_BRANCH BOUCLE_PIPELINE_SOURCE BOUCLE_JOB_ID \
  BOUCLE_JOB_URL BOUCLE_TRIGGER_PAYLOAD BOUCLE_BOT_USERNAME

# ── Source per-stage functions ─────────────────────────────────────────────────
for _stage_file in "$BOUCLE_HOME"/lib/boucle-ci/*.sh; do
  # shellcheck source=/dev/null
  . "$_stage_file"
done
unset _stage_file
