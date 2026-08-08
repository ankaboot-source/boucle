#!/usr/bin/env bats
# test/design-charter.bats — tests for bin/check-design-charter.
#
# Validates the structural charter checker (sections, color tokens,
# placeholders, contrast rules, non-empty sections) against fixture charters.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  CHARTER_DIR="${BATS_TMPDIR:-/tmp}/design-charter-${RANDOM}"
  mkdir -p "${CHARTER_DIR}"
}

teardown() {
  rm -rf "${CHARTER_DIR}"
}

# ── Helpers ────────────────────────────────────────────────────────────

# write a fully-valid charter fixture (sections 1-4, distinct tokens,
# contrast rules, non-empty Typography/Spacing/Motion)
write_valid_charter() {
  cat > "${CHARTER_DIR}/charter.md" <<'EOF'
## 1. Product context

- **What is being built:** a static blog
- **Who it's for:** readers

## 2. Design tokens

### Colors

| Token | HEX | Usage |
| ----- | --- | ----- |
| `--surface-base` | `#FFFFFF` | Page background |
| `--surface-raised` | `#F7F7F7` | Cards, modals |
| `--text-primary` | `#1A1A1A` | Headings, body |
| `--text-secondary` | `#555555` | Muted text |
| `--accent` | `#0055FF` | CTAs, links, focus |
| `--border` | `#DDDDDD` | Dividers, outlines |
| `--destructive` | `#CC0000` | Errors |

Contrast rules: primary text >= 4.5:1, secondary >= 3:1 in every mode.

### Typography

- **Font family:** Inter, system stack
- **Scale:** display 48/1.1, h1 32/1.2, body 16/1.5

### Spacing & layout

- **Grid unit:** 8px
- **Breakpoints:** mobile-first, 1440px base

## 3. Motion

- **Duration:** 150ms, eased out
- **Reduced motion:** respects prefers-reduced-motion

## 4. Components

| Component | Pattern / variant rules | Notes |
| --------- | ----------------------- | ----- |
| Buttons | primary filled | Usage notes |
EOF
}

# ── Syntax ─────────────────────────────────────────────────────────────

@test "bin/check-design-charter parses without syntax error" {
  run bash -n bin/check-design-charter
  assert_success
}

# ── Usage / file handling ──────────────────────────────────────────────

@test "unreadable charter exits 2" {
  run bash bin/check-design-charter "${CHARTER_DIR}/missing.md"
  assert_failure
  assert_output --partial "cannot read charter"
  [ "$status" -eq 2 ]
}

# ── PASS paths ─────────────────────────────────────────────────────────

@test "valid charter passes" {
  write_valid_charter
  run bash bin/check-design-charter "${CHARTER_DIR}/charter.md"
  assert_success
  assert_output --partial "DESIGN CHARTER: PASS"
}

@test "valid charter with recommended sections 5-7 passes with zero warnings" {
  write_valid_charter
  cat >> "${CHARTER_DIR}/charter.md" <<'EOF'

## 5. Content & tone

- **Voice:** clear, plain

## 6. Iconography

- **Icon system:** inline SVG

## 7. Visual foundations

- **Backgrounds:** solid white
EOF
  run bash bin/check-design-charter "${CHARTER_DIR}/charter.md"
  assert_success
  assert_output --partial "DESIGN CHARTER: PASS"
  assert_output --partial "0 warning(s)"
}

@test "missing recommended section 5-7 warns but still passes" {
  write_valid_charter
  run bash bin/check-design-charter "${CHARTER_DIR}/charter.md"
  assert_success
  assert_output --partial "recommended section missing: ## 5. Content & tone"
  assert_output --partial "DESIGN CHARTER: PASS"
}

# ── FAIL paths: sections ───────────────────────────────────────────────

@test "missing required section fails" {
  write_valid_charter
  grep -v '^## 3. Motion' "${CHARTER_DIR}/charter.md" > "${CHARTER_DIR}/no-motion.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/no-motion.md"
  assert_failure
  assert_output --partial "missing required section: ## 3. Motion"
}

@test "missing color token fails" {
  write_valid_charter
  grep -v '`--accent`' "${CHARTER_DIR}/charter.md" > "${CHARTER_DIR}/no-accent.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/no-accent.md"
  assert_failure
  assert_output --partial "missing color token: --accent"
}

# ── FAIL paths: placeholders / contrast / content ──────────────────────

@test "all-identical color tokens fail (unfilled template)" {
  write_valid_charter
  sed -E 's/`#[0-9A-Fa-f]{3,8}`/`#000000`/g' "${CHARTER_DIR}/charter.md" > "${CHARTER_DIR}/all-black.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/all-black.md"
  assert_failure
  assert_output --partial "all color tokens share one value"
}

@test "generic <...> placeholder fails" {
  write_valid_charter
  echo "- **Font family:** <e.g. Inter, system stack>" >> "${CHARTER_DIR}/charter.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/charter.md"
  assert_failure
  assert_output --partial "placeholder values remain"
}

@test "missing contrast rules fails" {
  write_valid_charter
  grep -v '4\.5:1' "${CHARTER_DIR}/charter.md" > "${CHARTER_DIR}/no-contrast.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/no-contrast.md"
  assert_failure
  assert_output --partial "contrast rule not cited (4.5:1)"
}

@test "empty Typography section fails" {
  write_valid_charter
  awk 'BEGIN{skip=0} /^### Typography/{print; skip=1; next} /^### /{skip=0} skip==0{print}' \
    "${CHARTER_DIR}/charter.md" > "${CHARTER_DIR}/empty-typo.md"
  run bash bin/check-design-charter "${CHARTER_DIR}/empty-typo.md"
  assert_failure
  assert_output --partial "Typography section is empty"
}
