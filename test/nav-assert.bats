#!/usr/bin/env bats
# test/nav-assert.bats — bin/nav-assert, the assertion layer over agent-browser.
#
# The test that matters is "nav_is FAILs on a hidden element". agent-browser's
# `is` commands are queries, not assertions: measured on 0.27.0, `is visible`
# prints "false" and exits 0 for a display:none element, and `batch --bail`
# does not stop on it either. A parcours that trusted exit codes would report
# PASS on a broken UI. Everything else here guards that property's edges.
#
# No browser is needed: BOUCLE_AGENT_BROWSER injects a stub that reproduces
# the measured contract, so the suite runs on any runner.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  export BOUCLE_HOME="$PWD"

  # Stub agent-browser: reproduces the MEASURED 0.27.0 contract.
  #   is visible <sel with "vis">    → "true",  exit 0
  #   is visible <sel with "hidden"> → "false", exit 0   ← the trap
  #   is visible <anything else>     → not-found, exit 1
  #   get text <sel with "vis">      → "Merci pour votre message"
  #   open/click/fill/set/close      → exit 0, except selectors with "ghost"
  # shellcheck disable=SC2154 # BATS_TEST_TMPDIR is provided by bats
  STUB="$BATS_TEST_TMPDIR/agent-browser-stub"
  cat > "$STUB" << 'STUB_EOF'
#!/usr/bin/env bash
# Consume the global --session flag the way the real CLI does.
while [ "${1:-}" = "--session" ]; do shift 2; done
cmd="${1:-}"; shift || true
case "$cmd" in
  is)
    sel="${2:-}"
    case "$sel" in
      *hidden*) echo "false"; exit 0 ;;
      *vis*)    echo "true";  exit 0 ;;
      *)        echo "✗ Element not found." >&2; exit 1 ;;
    esac
    ;;
  get)
    sel="${2:-}"
    case "$sel" in
      *vis*) echo "Merci pour votre message"; exit 0 ;;
      *)     echo "✗ Element not found." >&2; exit 1 ;;
    esac
    ;;
  open|click|fill)
    case "${1:-}" in
      *ghost*) echo "✗ Element not found." >&2; exit 1 ;;
      *)       exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod +x "$STUB"
  export BOUCLE_AGENT_BROWSER="$STUB"
  export BASE="http://preview.example.test"
}

# Run a parcours body with nav-assert sourced, in its own bash so the EXIT
# trap fires and sets the status the way a real parcours does.
run_parcours() {
  run bash -c "
    export BOUCLE_HOME='$BOUCLE_HOME' BOUCLE_AGENT_BROWSER='$BOUCLE_AGENT_BROWSER' BASE='$BASE'
    source '$BOUCLE_HOME/bin/nav-assert'
    $1
  "
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/nav-assert parses without syntax error" {
  run bash -n bin/nav-assert
  assert_success
}

@test "bin/lib/agent-browser.sh parses without syntax error" {
  run sh -n bin/lib/agent-browser.sh
  assert_success
}

# ── The trap: a false assertion must FAIL ─────────────────────────────

@test "nav_is FAILs on a hidden element (agent-browser prints false and exits 0)" {
  run_parcours 'nav_is visible "#hidden-box" "Le bandeau est affiché"'
  assert_failure
  assert_output --partial "NAV: FAIL — Le bandeau est affiché (expected visible, got false)"
  assert_output --partial "0 passed, 1 failed"
}

@test "nav_is PASSes on a visible element" {
  run_parcours 'nav_is visible "#vis-title" "Le titre est affiché"'
  assert_success
  assert_output --partial "NAV: PASS — Le titre est affiché"
  assert_output --partial "1 passed, 0 failed"
}

@test "nav_is FAILs on an absent element" {
  run_parcours 'nav_is visible "#nowhere" "Le formulaire est affiché"'
  assert_failure
  assert_output --partial "NAV: FAIL — Le formulaire est affiché (element not found)"
}

# ── Empty parcours must never read as PASS ────────────────────────────

@test "a parcours with zero assertions exits non-zero" {
  run_parcours 'true'
  assert_failure
  assert_output --partial "no assertion ran — treated as FAIL"
}

@test "nav_viewport alone is not an assertion" {
  run_parcours 'nav_viewport 390 844'
  assert_failure
  assert_output --partial "no assertion ran"
}

# ── Assertions accumulate instead of aborting ─────────────────────────

@test "a failing assertion does not stop the parcours" {
  run_parcours '
    nav_is visible "#hidden-box" "Critère A"
    nav_is visible "#vis-title"  "Critère B"
    nav_is visible "#nowhere"    "Critère C"
  '
  assert_failure
  assert_output --partial "NAV: FAIL — Critère A"
  assert_output --partial "NAV: PASS — Critère B"
  assert_output --partial "NAV: FAIL — Critère C"
  assert_output --partial "1 passed, 2 failed"
}

# ── Actions ───────────────────────────────────────────────────────────

@test "nav_open resolves a relative path against \$BASE" {
  run_parcours 'nav_open "/contact"'
  assert_success
  assert_output --partial "NAV: PASS — Ouvre http://preview.example.test/contact"
}

@test "nav_open passes an absolute URL through unchanged" {
  run_parcours 'nav_open "https://elsewhere.example.test/x"'
  assert_success
  assert_output --partial "https://elsewhere.example.test/x"
}

@test "nav_click FAILs when the element is missing" {
  run_parcours 'nav_click "#ghost-button" "Le bouton est cliquable"'
  assert_failure
  assert_output --partial "NAV: FAIL — Le bouton est cliquable"
}

@test "nav_fill PASSes on a present field" {
  run_parcours 'nav_fill "#email" "a@b.test" "Le champ email accepte une saisie"'
  assert_success
  assert_output --partial "NAV: PASS — Le champ email accepte une saisie"
}

# ── Content ───────────────────────────────────────────────────────────

@test "nav_text PASSes when the substring is present" {
  run_parcours 'nav_text "#vis-confirm" "Merci" "Une confirmation s'"'"'affiche"'
  assert_success
  assert_output --partial "NAV: PASS"
}

@test "nav_text FAILs when the substring is absent" {
  run_parcours 'nav_text "#vis-confirm" "Erreur" "Un message d'"'"'erreur s'"'"'affiche"'
  assert_failure
  assert_output --partial 'expected to contain "Erreur"'
}

# ── Degraded browser ──────────────────────────────────────────────────
# No CLI at all must produce a FAIL verdict, never a silent PASS and never
# an unbound-variable crash before any line is printed.

@test "an unresolvable browser FAILs every step instead of crashing" {
  run bash -c "
    export BOUCLE_HOME='$BOUCLE_HOME' BASE='$BASE'
    export BOUCLE_AGENT_BROWSER='' PATH=/nonexistent
    source '$BOUCLE_HOME/bin/nav-assert' 2>/dev/null
    nav_open '/contact'
    nav_is visible '#vis-title' 'Le titre est affiché'
  "
  assert_failure
  assert_output --partial "browser unavailable"
}
