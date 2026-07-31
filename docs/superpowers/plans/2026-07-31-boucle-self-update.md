# Boucle Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic self-update to boucle — `bin/update` runs first in the `dispatch` CI job, fetches the latest upstream version (tag or main commit), applies it via tarball download, and commits to main via the bot. Fail-open on any error.

**Architecture:** A new `bin/update` bash script with testable pure functions (sourced by tests) and a fail-open main entry point. It reads `BOUCLE_UPDATE_MODE` (release|dev), compares `.boucle-version` with upstream via GitHub API, downloads a tarball if different, extracts `bin/` `.opencode/` `.gitlab-ci.yml`, commits and pushes. `bin/setup` creates the initial `.boucle-version` and configures bot push permissions. `bin/doctor` verifies the new prerequisites.

**Tech Stack:** Bash (no framework), GitHub REST API (anonymous, public repo), GitLab API (via `glab`), GitLab CI/CD variables.

**Spec:** `docs/superpowers/specs/2026-07-31-boucle-self-update-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `bin/update` | Create | Self-update script: detect, download, extract, commit, push. Fail-open. |
| `tests/test-update.sh` | Create | Tests for `bin/update` pure functions (get_mode, get_current_version, needs_update). |
| `.gitlab-ci.yml` | Modify | Add `./bin/update` as first `script` item in `dispatch` job (line 143-144). |
| `bin/setup` | Modify | Add `BOUCLE_UPDATE_MODE` CI var, `.boucle-version` via GitLab API, `push_access_level=30` on branch protection. |
| `bin/doctor` | Modify | Add 4 checks: `.boucle-version` exists, `bin/update` executable, bot push permission, `BOUCLE_UPDATE_MODE` valid. |
| `LOOP-README.md` | Modify | Document self-update mechanism and `BOUCLE_UPDATE_MODE`. |

**Not touched:** `bin/oc`, `bin/fetch-issue-images`, `LOOP.md`, `.opencode/`.

---

## Task 1: Write `tests/test-update.sh` (failing tests)

**Files:**
- Create: `tests/test-update.sh`

- [ ] **Step 1: Create the test file**

```bash
#!/usr/bin/env bash
# tests/test-update.sh — tests for bin/update pure functions.
# Run: bash tests/test-update.sh

set -euo pipefail

# Source bin/update (functions only — main not executed due to BASH_SOURCE guard).
source "$(dirname "$0")/../bin/update"

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $desc"
    PASS=$((PASS+1))
  else
    echo "  ✗ $desc (expected '$expected', got '$actual')" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_return() {
  local desc="$1" expected="$2"; shift 2
  if "$@"; then
    [ "$expected" = "0" ] && { echo "  ✓ $desc"; PASS=$((PASS+1)); } || { echo "  ✗ $desc (expected failure, got success)" >&2; FAIL=$((FAIL+1)); }
  else
    [ "$expected" = "1" ] && { echo "  ✓ $desc"; PASS=$((PASS+1)); } || { echo "  ✗ $desc (expected success, got failure)" >&2; FAIL=$((FAIL+1)); }
  fi
}

# ── Test get_mode ─────────────────────────────────────────────────────
echo "=== get_mode ==="
unset BOUCLE_UPDATE_MODE
assert_eq "defaults to release when unset" "release" "$(get_mode)"
BOUCLE_UPDATE_MODE="dev"
assert_eq "reads dev" "dev" "$(get_mode)"
BOUCLE_UPDATE_MODE="release"
assert_eq "reads release" "release" "$(get_mode)"

# ── Test get_current_version ──────────────────────────────────────────
echo "=== get_current_version ==="
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
# Override VERSION_FILE to point into the temp dir.
VERSION_FILE="$TMPDIR/.boucle-version"
assert_eq "empty when no file" "" "$(get_current_version)"
echo "abc123def456" > "$VERSION_FILE"
assert_eq "reads file content" "abc123def456" "$(get_current_version)"
rm -f "$VERSION_FILE"

# ── Test needs_update ─────────────────────────────────────────────────
echo "=== needs_update ==="
assert_return "empty upstream → no update" "1" needs_update "abc" ""
assert_return "same versions → no update" "1" needs_update "abc" "abc"
assert_return "different versions → update" "0" needs_update "abc" "def"
assert_return "empty current, non-empty upstream → update" "0" needs_update "" "def"

echo ""
echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Make the test file executable**

Run: `chmod +x tests/test-update.sh`

- [ ] **Step 3: Run the test to verify it fails (bin/update does not exist yet)**

Run: `bash tests/test-update.sh`
Expected: FAIL with "No such file or directory" from `source` (bin/update doesn't exist yet).

- [ ] **Step 4: Commit**

```bash
git add tests/test-update.sh
git commit -m "test: add failing tests for bin/update pure functions"
```

---

## Task 2: Create `bin/update` script

**Files:**
- Create: `bin/update`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# bin/update — boucle self-update: fetch latest from upstream and apply.
# Runs as the first step of the dispatch job in .gitlab-ci.yml.
# Fail-open: any error → warning + exit 0, pipeline continues with current version.
# Usage: bin/update [--dry-run]

set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────
UPSTREAM_REPO="ankaboot-source/boucle"
UPSTREAM_API="https://api.github.com/repos/$UPSTREAM_REPO"
UPSTREAM_TARBALL="https://codeload.github.com/$UPSTREAM_REPO/tarball"
VERSION_FILE=".boucle-version"
SYNC_PATHS="bin .opencode .gitlab-ci.yml"

# ── Pure functions (testable, no network) ──────────────────────────────

# get_mode: echo the configured update mode (release|dev), default release.
get_mode() {
  echo "${BOUCLE_UPDATE_MODE:-release}"
}

# get_current_version: echo the content of .boucle-version, or empty if missing.
get_current_version() {
  if [ -f "$VERSION_FILE" ]; then
    cat "$VERSION_FILE"
  else
    echo ""
  fi
}

# needs_update: return 0 if update needed, 1 if not.
# Update is needed when upstream is non-empty and differs from current.
needs_update() {
  local current="$1" upstream="$2"
  [ -n "$upstream" ] || return 1
  [ "$current" != "$upstream" ] || return 1
  return 0
}

# ── Network functions ──────────────────────────────────────────────────

# get_upstream_version <mode>: echo the latest version identifier from upstream.
# release mode → latest tag name; dev mode → HEAD commit SHA on main.
# Echoes empty string on failure.
get_upstream_version() {
  local mode="$1"
  case "$mode" in
    release)
      curl -fsSL "$UPSTREAM_API/tags" 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null || echo ""
      ;;
    dev)
      curl -fsSL "$UPSTREAM_API/commits/main" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null || echo ""
      ;;
    *)
      echo ""
      ;;
  esac
}

# download_and_extract <mode> <version>: download tarball, extract SYNC_PATHS
# into the working tree. Returns 0 on success, 1 on failure.
download_and_extract() {
  local mode="$1" version="$2" tarball_url tmpdir topdir

  case "$mode" in
    release) tarball_url="$UPSTREAM_TARBALL/refs/tags/$version" ;;
    dev)     tarball_url="$UPSTREAM_TARBALL/refs/heads/main" ;;
    *)       return 1 ;;
  esac

  tmpdir=$(mktemp -d) || return 1

  # Download
  if ! curl -fsSL "$tarball_url" -o "$tmpdir/boucle.tar.gz" 2>/dev/null; then
    rm -rf "$tmpdir"; return 1
  fi

  # Validate tarball (integrity check: valid gzip archive that can be listed)
  if ! tar tzf "$tmpdir/boucle.tar.gz" >/dev/null 2>&1; then
    rm -rf "$tmpdir"; return 1
  fi

  # Extract
  tar xzf "$tmpdir/boucle.tar.gz" -C "$tmpdir" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }

  # Find top-level directory (GitHub tarballs have a single top-level dir
  # like ankaboot-source-boucle-<short-sha>/)
  topdir=$(find "$tmpdir" -maxdepth 1 -mindepth 1 -type d | head -1)
  if [ -z "$topdir" ]; then
    rm -rf "$tmpdir"; return 1
  fi

  # Replace sync paths in the working tree with upstream versions
  for path in $SYNC_PATHS; do
    if [ -e "$topdir/$path" ]; then
      rm -rf "$path"
      cp -r "$topdir/$path" "$path"
    fi
  done

  rm -rf "$tmpdir"
  return 0
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
  local dry_run=false mode current upstream

  [ "${1:-}" = "--dry-run" ] && dry_run=true

  mode=$(get_mode)
  # Validate mode
  case "$mode" in
    release|dev) ;;
    *)
      echo "[boucle] WARN: BOUCLE_UPDATE_MODE='$mode' invalid (expected release|dev), using release" >&2
      mode="release"
      ;;
  esac

  current=$(get_current_version)
  upstream=$(get_upstream_version "$mode")

  # No upstream version available
  if [ -z "$upstream" ]; then
    if [ "$mode" = "release" ]; then
      echo "[boucle] WARN: no releases found upstream, staying on current version" >&2
    else
      echo "[boucle] WARN: could not fetch upstream commit, staying on current version" >&2
    fi
    return 0
  fi

  # Already up to date
  if [ "$current" = "$upstream" ]; then
    echo "[boucle] up to date ($mode: $current)"
    return 0
  fi

  echo "[boucle] update available: ${current:-<none>} → $upstream ($mode)"

  if [ "$dry_run" = "true" ]; then
    echo "[boucle] DRY RUN — would download and apply $upstream"
    return 0
  fi

  # First run: no .boucle-version → just record current version and exit.
  # No file replacement happens on this run — we only record the baseline.
  if [ -z "$current" ]; then
    echo "$upstream" > "$VERSION_FILE"
    git config user.email >/dev/null 2>&1 || git config user.email "boucle-bot@boucle.local"
    git config user.name >/dev/null 2>&1 || git config user.name "boucle-bot"
    git add "$VERSION_FILE"
    git commit -m "chore(boucle): record initial version $upstream" >/dev/null 2>&1 || true
    git push 2>/dev/null || echo "[boucle] WARN: push failed, will retry next pipeline" >&2
    echo "[boucle] recorded initial version $upstream"
    return 0
  fi

  # Download and apply update
  if ! download_and_extract "$mode" "$upstream"; then
    echo "[boucle] WARN: download/extract failed, staying on current version" >&2
    return 0
  fi

  # Update version file
  echo "$upstream" > "$VERSION_FILE"

  # Commit and push
  git config user.email >/dev/null 2>&1 || git config user.email "boucle-bot@boucle.local"
  git config user.name >/dev/null 2>&1 || git config user.name "boucle-bot"
  git add $SYNC_PATHS "$VERSION_FILE"
  git commit -m "chore(boucle): auto-update to $upstream" >/dev/null 2>&1 || true
  git push 2>/dev/null || echo "[boucle] WARN: push failed, will retry next pipeline" >&2

  echo "[boucle] updated to $upstream"
  return 0
}

# ── Entry point (only when executed directly, not sourced by tests) ───
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@" || echo "[boucle] WARN: update failed, continuing with current version" >&2
  exit 0
fi
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x bin/update`

- [ ] **Step 3: Verify syntax**

Run: `bash -n bin/update`
Expected: no output (syntax OK).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test-update.sh`
Expected: all tests pass, output ends with "Passed: 8, Failed: 0".

- [ ] **Step 5: Verify dry-run mode works (no network needed for syntax check)**

Run: `BOUCLE_UPDATE_MODE=invalid bash bin/update --dry-run`
Expected: warning about invalid mode, then "DRY RUN" message, exit 0.

- [ ] **Step 6: Commit**

```bash
git add bin/update
git commit -m "feat: add bin/update self-update script"
```

---

## Task 3: Integrate `bin/update` into `.gitlab-ci.yml` dispatch job

**Files:**
- Modify: `.gitlab-ci.yml:143-144`

The `dispatch` job's `script:` key starts at line 143 with a single `- |` block (line 144). We insert `./bin/update` as a separate script item before the existing block. GitLab CI runs script items sequentially; `bin/update` always exits 0 (fail-open), so the existing block always runs.

**Why before the `- |` block and not inside it:** `bin/update` is a self-contained script. Keeping it as a separate script item makes it visible in the CI logs as its own step, and isolates its `set` options from the dispatch block's shell.

**Note on update timing:** If `bin/update` commits and pushes, the current pipeline continues running on the original checkout. The update takes effect on the **next** pipeline (the next webhook trigger). This is intentional — pipelines should not change their own config mid-run. The bot's push does not trigger a new pipeline (webhook has `push_events=false`).

- [ ] **Step 1: Read the current dispatch script section to confirm exact text**

Run: `sed -n '143,145p' .gitlab-ci.yml`
Expected output:
```
  script:
    - |
      # Anti-accumulation: if dispatch exits 0 without writing .boucle-issue,
```

- [ ] **Step 2: Insert `./bin/update` before the existing script block**

Edit `.gitlab-ci.yml`: replace the exact text:
```
  script:
    - |
      # Anti-accumulation: if dispatch exits 0 without writing .boucle-issue,
```
with:
```
  script:
    - ./bin/update
    - |
      # Anti-accumulation: if dispatch exits 0 without writing .boucle-issue,
```

- [ ] **Step 3: Verify the edit**

Run: `sed -n '143,147p' .gitlab-ci.yml`
Expected output:
```
  script:
    - ./bin/update
    - |
      # Anti-accumulation: if dispatch exits 0 without writing .boucle-issue,
```

- [ ] **Step 4: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml'))" && echo "YAML OK"`
Expected: "YAML OK" (no parse errors).

- [ ] **Step 5: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): run bin/update as first step of dispatch job"
```

---

## Task 4: Update `bin/setup`

**Files:**
- Modify: `bin/setup:113-130` (add `BOUCLE_UPDATE_MODE` CI variable)
- Modify: `bin/setup:205-232` (update branch protection with `push_access_level=30`)
- Modify: `bin/setup:346-371` (add `.boucle-version` creation + update "Next steps")

### Part A: Add `BOUCLE_UPDATE_MODE` CI variable

- [ ] **Step 1: Add the variable after `BOUCLE_SPEC_PROFILE` block (after line 130)**

Insert after the `BOUCLE_SPEC_PROFILE` block (which ends at line 130 with `fi`), before the `OPENCODE_AUTH` block (line 132):

```bash

# BOUCLE_UPDATE_MODE — controls self-update behavior.
# Values: release (default, fetch latest tag) | dev (fetch latest commit on main).
# If unset, bin/update defaults to release.
EXISTING=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/variables/BOUCLE_UPDATE_MODE" 2>/dev/null | jq -r '.key // empty' 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  log_skip "BOUCLE_UPDATE_MODE already exists"
else
  run "glab api --hostname $HOST -X POST /projects/$PROJECT_ID/variables -f key=BOUCLE_UPDATE_MODE -f value=release -f masked=false -f protected=false >/dev/null"
  log_pass "BOUCLE_UPDATE_MODE set to release"
fi
```

- [ ] **Step 2: Verify the insertion**

Run: `sed -n '130,142p' bin/setup`
Expected: the `BOUCLE_SPEC_PROFILE` `fi` followed by the new `BOUCLE_UPDATE_MODE` block.

### Part B: Update branch protection to allow bot push

- [ ] **Step 3: Replace the branch protection section (lines 205-232)**

Replace the entire section from `# ── 4. Branch Protection ───` through the `echo ""` after it with:

```bash
# ── 4. Branch Protection ─────────────────────────────────────────────
echo "=== Branch Protection ==="

# Get default branch
DEFAULT_BRANCH=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID" 2>/dev/null | jq -r '.default_branch')
if [ -z "$DEFAULT_BRANCH" ] || [ "$DEFAULT_BRANCH" = "null" ]; then
  log_fail "could not determine default branch"
  DEFAULT_BRANCH="master"
fi

# Check if branch is already protected
PROTECTION=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/protected_branches/$DEFAULT_BRANCH" 2>/dev/null)
if [ -n "$PROTECTION" ] && echo "$PROTECTION" | jq -e '.name' >/dev/null 2>&1; then
  # Already protected — verify both merge and push access levels
  MERGE_LEVEL=$(echo "$PROTECTION" | jq -r '.merge_access_levels[0].access_level // empty')
  PUSH_LEVEL=$(echo "$PROTECTION" | jq -r '.push_access_levels[0].access_level // empty')
  NEEDS_UPDATE=false
  if [ "$MERGE_LEVEL" != "40" ]; then
    echo "  ! $DEFAULT_BRANCH merge_access_level=$MERGE_LEVEL (expected 40)"
    NEEDS_UPDATE=true
  fi
  if [ "$PUSH_LEVEL" != "30" ]; then
    echo "  ! $DEFAULT_BRANCH push_access_level=$PUSH_LEVEL (expected 30 for bot self-update)"
    NEEDS_UPDATE=true
  fi
  if [ "$NEEDS_UPDATE" = "true" ]; then
    run "glab api --hostname $HOST -X PUT /projects/$PROJECT_ID/protected_branches/$DEFAULT_BRANCH -f merge_access_level=40 -f push_access_level=30 >/dev/null"
    log_pass "$DEFAULT_BRANCH access levels updated (merge=Maintainer, push=Developer)"
  else
    log_skip "$DEFAULT_BRANCH protected (merge=Maintainer, push=Developer)"
  fi
else
  run "glab api --hostname $HOST -X POST /projects/$PROJECT_ID/protected_branches -f name=$DEFAULT_BRANCH -f merge_access_level=40 -f push_access_level=30 >/dev/null"
  log_pass "$DEFAULT_BRANCH protected (merge=Maintainer, push=Developer)"
fi

echo ""
```

- [ ] **Step 4: Verify the replacement**

Run: `sed -n '205,250p' bin/setup`
Expected: the new branch protection section with `push_access_level=30`.

### Part C: Create `.boucle-version` via GitLab API + update "Next steps"

- [ ] **Step 5: Add a new section before the Summary (before line 348 `# ── Summary ───`)**

Insert this new section:

```bash
# ── 9. Initial .boucle-version ───────────────────────────────────────
echo "=== Initial .boucle-version ==="

# Fetch current upstream version (dev mode: main commit SHA — always works,
# even before the operator starts tagging releases).
UPSTREAM_VERSION=$(curl -fsSL "https://api.github.com/repos/ankaboot-source/boucle/commits/main" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null || echo "")

if [ -z "$UPSTREAM_VERSION" ]; then
  log_fail "could not fetch upstream version from GitHub API"
else
  # Check if .boucle-version already exists in the repo
  EXISTING_FILE=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/repository/files/.boucle-version?ref=$DEFAULT_BRANCH" 2>/dev/null | jq -r '.file_path // empty' 2>/dev/null || true)
  if [ -n "$EXISTING_FILE" ]; then
    log_skip ".boucle-version already exists in repo"
  else
    # Create .boucle-version via GitLab Repository Files API
    run "glab api --hostname $HOST -X POST /projects/$PROJECT_ID/repository/files/.boucle-version -f branch=$DEFAULT_BRANCH -f content=$UPSTREAM_VERSION -f 'commit_message=chore(boucle): record initial version' >/dev/null"
    if [ $? -eq 0 ]; then
      log_pass ".boucle-version created (version: ${UPSTREAM_VERSION:0:12}...)"
    else
      log_fail ".boucle-version creation failed (bin/update will create it on first run)"
    fi
  fi
fi

echo ""

```

- [ ] **Step 6: Update the "Next steps" section (lines 362-371)**

Replace the existing "Next steps" block:

```bash
echo "Next steps:"
echo "  1. Ensure a GitLab runner tagged 'tooling' is available for this project."
echo "     Register one on your build machine (docker executor) or enable a shared runner with the 'tooling' tag."
echo "  2. Apply the loop template to the target repo:"
echo "     cp -r boucle/boucle/bin <target-repo>/"
echo "     cp boucle/boucle/.gitlab-ci.yml <target-repo>/"
echo "     cp boucle/boucle/LOOP.md <target-repo>/"
echo "  3. Run bin/doctor in CI to verify all prerequisites are met."
echo "  4. Create your first issue — the webhook will trigger triage."
```

with:

```bash
echo "Next steps:"
echo "  1. Ensure a GitLab runner tagged 'tooling' is available for this project."
echo "     Register one on your build machine (docker executor) or enable a shared runner with the 'tooling' tag."
echo "  2. Apply the loop template to the target repo:"
echo "     cp -r boucle/boucle/bin <target-repo>/"
echo "     cp -r boucle/boucle/.opencode <target-repo>/"
echo "     cp boucle/boucle/.gitlab-ci.yml <target-repo>/"
echo "     cp boucle/boucle/LOOP.md <target-repo>/"
echo "  3. Run bin/doctor in CI to verify all prerequisites are met."
echo "  4. Create your first issue — the webhook will trigger triage."
echo ""
echo "Self-update: boucle updates itself automatically at the start of each pipeline."
echo "  Set BOUCLE_UPDATE_MODE=dev in CI/CD variables to track main instead of tags."
```

Note: the `cp` commands now include `.opencode/` (was missing in the original) and are consistent with LOOP-README.md.

- [ ] **Step 7: Verify syntax**

Run: `bash -n bin/setup`
Expected: no output (syntax OK).

- [ ] **Step 8: Commit**

```bash
git add bin/setup
git commit -m "feat(setup): add BOUCLE_UPDATE_MODE, .boucle-version, bot push permission"
```

---

## Task 5: Update `bin/doctor`

**Files:**
- Modify: `bin/doctor:49-55` (extend branch protection check with push access)
- Modify: `bin/doctor` (add new self-update checks section)

### Part A: Extend branch protection check

- [ ] **Step 1: Replace the branch protection check (lines 49-55)**

Replace:

```bash
# ── Branch protection ──────────────────────────────────────────────────
PROTECTION=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/protected_branches/master" 2>/dev/null || echo "")
if echo "$PROTECTION" | jq -e '.merge_access_levels[0].access_level == 40' >/dev/null 2>&1; then
  pass "master protected, merge=Maintainer only"
else
  fail "master not protected or merge access too broad"
fi
```

with:

```bash
# ── Branch protection ──────────────────────────────────────────────────
PROTECTION=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/protected_branches/master" 2>/dev/null || echo "")
if echo "$PROTECTION" | jq -e '.merge_access_levels[0].access_level == 40' >/dev/null 2>&1; then
  pass "master protected, merge=Maintainer only"
else
  fail "master not protected or merge access too broad"
fi

# Check bot push permission (required for self-update auto-commit)
PUSH_LEVEL=$(echo "$PROTECTION" | jq -r '.push_access_levels[0].access_level // empty' 2>/dev/null)
if [ "$PUSH_LEVEL" = "30" ] || [ "$PUSH_LEVEL" = "40" ]; then
  pass "bot can push to master (push_access_level=$PUSH_LEVEL)"
else
  fail "bot cannot push to master (push_access_level=${PUSH_LEVEL:-none}, need 30+ for self-update)"
fi
```

### Part B: Add self-update prerequisite checks

- [ ] **Step 2: Add new checks before the final summary (before line 103 `echo ""`)**

Insert before the `echo ""` that precedes the final summary:

```bash
# ── Self-update prerequisites ───────────────────────────────────────────
if [ -f ".boucle-version" ]; then
  pass ".boucle-version exists"
else
  fail ".boucle-version missing (will be created on first bin/update run)"
fi

if [ -x "bin/update" ]; then
  pass "bin/update exists and is executable"
elif [ -f "bin/update" ]; then
  fail "bin/update exists but is not executable (run: chmod +x bin/update)"
else
  fail "bin/update missing"
fi

# Check BOUCLE_UPDATE_MODE (optional — absent = release default, which is valid)
MODE=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/variables/BOUCLE_UPDATE_MODE" 2>/dev/null | jq -r '.value // empty' 2>/dev/null || echo "")
if [ -z "$MODE" ]; then
  pass "BOUCLE_UPDATE_MODE not set (defaults to release)"
elif [ "$MODE" = "release" ] || [ "$MODE" = "dev" ]; then
  pass "BOUCLE_UPDATE_MODE=$MODE"
else
  fail "BOUCLE_UPDATE_MODE='$MODE' invalid (expected release|dev or unset)"
fi

```

- [ ] **Step 3: Verify syntax**

Run: `bash -n bin/doctor`
Expected: no output (syntax OK).

- [ ] **Step 4: Commit**

```bash
git add bin/doctor
git commit -m "feat(doctor): add self-update prerequisite checks"
```

---

## Task 6: Update `LOOP-README.md`

**Files:**
- Modify: `LOOP-README.md`

- [ ] **Step 1: Add self-update documentation after the "Roles" section (after line 27)**

Append to the file:

```markdown

## Self-update

boucle updates itself automatically at the start of each pipeline. The self-update runs as the first step of the `dispatch` job, before any webhook processing.

### Update modes

Controlled by the `BOUCLE_UPDATE_MODE` CI/CD variable (GitLab → Settings → CI/CD → Variables):

| Mode | Behavior |
|------|----------|
| `release` (default) | Fetch the latest Git tag from `github.com/ankaboot-source/boucle` |
| `dev` | Fetch the latest commit on `main` from upstream |

If the variable is unset, `release` is used.

### How it works

1. `bin/update` reads `.boucle-version` (current version) and compares with upstream via the GitHub API.
2. If different, it downloads a tarball, extracts `bin/`, `.opencode/`, `.gitlab-ci.yml`, and commits the update to `main` via the bot.
3. The update takes effect on the **next** pipeline (not the current one — pipelines don't change their own config mid-run).

### Fail-open

Any error (network failure, permissions, corrupt tarball) logs a warning and continues. The pipeline runs with the current version. The update is retried on the next pipeline.

### Files synced

| Path | Synced | Why |
|------|--------|-----|
| `bin/` | Yes | boucle code |
| `.opencode/` | Yes | boucle agents + skills |
| `.gitlab-ci.yml` | Yes | boucle pipeline |
| `LOOP.md` | No | Per-consumer config |
| `.boucle-version` | No | Managed by `bin/update` |

### Version tracking

`.boucle-version` at the repo root records the current version (tag name in release mode, commit SHA in dev mode). It is created automatically on first run — no manual setup needed.
```

- [ ] **Step 2: Commit**

```bash
git add LOOP-README.md
git commit -m "docs: document self-update in LOOP-README.md"
```

---

## Self-Review

### Spec coverage

| Spec section | Task(s) |
|---|---|
| 4.2 `bin/update` script | Task 2 |
| 4.3 `.boucle-version` file | Task 2 (first-run creation), Task 4 (setup creates it) |
| 4.4 CI integration | Task 3 |
| 4.5 `bin/setup` changes | Task 4 |
| 4.6 `bin/doctor` changes | Task 5 |
| 4.7 `bin/oc` — no changes | (none needed) |
| 5.1-5.7 Security/edge cases | Task 2 (fail-open, first-run, tarball validation), Task 4 (push_access_level) |
| 6 Documentation | Task 6 |

All spec sections covered.

### Placeholder scan

No TBD, TODO, or vague references. All code blocks contain complete implementations.

### Type consistency

- `get_mode()` returns string in both test and implementation.
- `get_current_version()` returns string in both test and implementation.
- `needs_update()` returns 0/1 in both test and implementation.
- `BOUCLE_UPDATE_MODE` used consistently across `bin/update`, `bin/setup`, `bin/doctor`.
- `.boucle-version` used consistently as `VERSION_FILE` in `bin/update` and as literal in `bin/setup`, `bin/doctor`.
- `push_access_level=30` used consistently in `bin/setup` and checked in `bin/doctor`.

No inconsistencies found.