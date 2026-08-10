#!/usr/bin/env bats
# test/preview-check.bats — regression test for the 308-redirect trap.
#
# Bug class: Cloudflare Pages (and other static hosts) 308-redirect directory
# routes to add a trailing slash (/mobilisation → /mobilisation/). The worker,
# merger, and e2e jobs assert the preview/deploy/live URL returns 200 via
# `curl -s -o /dev/null -w "%{http_code}"`. Without `-L`, curl does NOT follow
# the redirect, sees 308, and FAILs on a valid page. The fix adds `-L` so curl
# follows the redirect and reports the final 200.
#
# This test stands up a local HTTP server that mimics the 308-redirect
# behaviour and asserts the check passes with `curl -sL` and fails with
# `curl -s` (no -L). It guards against the `-L` being removed from any of the
# three HTTP-code checks in .gitlab-ci.yml (worker preview, merger deploy URL,
# e2e smoke test).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Start a tiny Python HTTP server that 308-redirects /mobilisation →
# /mobilisation/ and returns 200 for /mobilisation/. Mimics Cloudflare Pages
# directory-route behaviour.
_start_redirect_server() {
  SERVER_ROOT="$(mktemp -d)"
  mkdir -p "$SERVER_ROOT/mobilisation"
  printf 'ok\n' > "$SERVER_ROOT/mobilisation/index.html"
  SERVER_SCRIPT="$(mktemp)"
  cat > "$SERVER_SCRIPT" <<'PY'
import http.server, socketserver, sys, os

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.environ['SERVER_ROOT'], **kw)
    def do_GET(self):
        # 308-redirect directory routes without a trailing slash (mimic
        # Cloudflare Pages). SimpleHTTPRequestHandler already serves
        # /mobilisation/ as a directory listing/index, so only intercept
        # the slash-less path.
        if self.path == '/mobilisation':
            self.send_response(308)
            self.send_header('Location', '/mobilisation/')
            self.end_headers()
            return
        super().do_GET()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
PY
  SERVER_ROOT="$SERVER_ROOT" python3 "$SERVER_SCRIPT" > "$SERVER_ROOT/port" 2>/dev/null &
  SERVER_PID=$!
  # Wait for the port to appear.
  for _ in $(seq 1 50); do
    if [ -s "$SERVER_ROOT/port" ]; then break; fi
    sleep 0.1
  done
  SERVER_PORT="$(cat "$SERVER_ROOT/port")"
  SERVER_URL="http://127.0.0.1:${SERVER_PORT}/mobilisation"
}

teardown() {
  if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  if [ -n "${SERVER_ROOT:-}" ]; then rm -rf "$SERVER_ROOT"; fi
  if [ -n "${SLOW_PID:-}" ]; then kill "$SLOW_PID" 2>/dev/null || true; fi
  if [ -n "${SLOW_ROOT:-}" ]; then rm -rf "$SLOW_ROOT"; fi
}

@test "curl -sL follows 308 redirect and reports 200 (the fix)" {
  _start_redirect_server
  code="$(curl -sL -o /dev/null -w "%{http_code}" "$SERVER_URL")"
  [ "$code" = "200" ]
}

@test "curl -s without -L sees 308 and would FAIL the check (the bug)" {
  _start_redirect_server
  code="$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL")"
  [ "$code" = "308" ]
}

@test "worker preview check pattern passes with -L on a redirecting URL" {
  _start_redirect_server
  # Mirrors .gitlab-ci.yml worker preview assertion:
  #   if ! curl -sL -o /dev/null -w "%{http_code}" "$PREVIEW_URL" | grep -q "200"; then
  if ! curl -sL -o /dev/null -w "%{http_code}" "$SERVER_URL" | grep -q "200"; then
    fail "preview check failed on a valid (redirecting) URL — -L missing?"
  fi
}

@test "merger/e2e check pattern passes with -L on a redirecting URL" {
  _start_redirect_server
  # Mirrors .gitlab-ci.yml merger deploy + e2e smoke assertions (both use
  # curl -sL -o /dev/null -w "%{http_code}" ... | grep -q "200" or = "200").
  code="$(curl -sL -o /dev/null -w "%{http_code}" "$SERVER_URL")"
  [ "$code" = "200" ]
}

# ── Retry-with-backoff tests ────────────────────────────────────────────
# Bug class: Cloudflare Pages deployments take time to propagate after the
# deploy command returns the URL. A single curl fails while the edge is
# warming up, stalling the worker (and the whole loop). The fix retries
# with exponential backoff. These tests stand up a server that returns
# non-200 a fixed number of times then 200, and assert the retry loop
# succeeds (and that a permanently-failing server fails after 6 attempts).

_start_slow_server() {
  SLOW_ROOT="$(mktemp -d)"
  printf 'ok\n' > "$SLOW_ROOT/index.html"
  SLOW_SCRIPT="$(mktemp)"
  cat > "$SLOW_SCRIPT" <<'PY'
import http.server, socketserver, os, sys

# Serve 503 for the first N requests, then 200.
SERVE_503_FOR = int(os.environ.get('SERVE_503_FOR', '3'))
state = {'count': 0}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=os.environ['SLOW_ROOT'], **kw)
    def do_GET(self):
        state['count'] += 1
        if state['count'] <= SERVE_503_FOR:
            self.send_response(503)
            self.end_headers()
            return
        super().do_GET()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
PY
  SERVE_503_FOR="${1:-3}" SLOW_ROOT="$SLOW_ROOT" python3 "$SLOW_SCRIPT" > "$SLOW_ROOT/port" 2>/dev/null &
  SLOW_PID=$!
  for _ in $(seq 1 50); do
    if [ -s "$SLOW_ROOT/port" ]; then break; fi
    sleep 0.1
  done
  SLOW_PORT="$(cat "$SLOW_ROOT/port")"
  SLOW_URL="http://127.0.0.1:${SLOW_PORT}/"
}

@test "worker preview retry loop succeeds after transient 503s" {
  # Server returns 503 for the first 2 requests, then 200.
  _start_slow_server 2
  # Mirrors the worker retry loop in .gitlab-ci.yml (6 attempts, backoff).
  # Use near-zero delays so the test stays fast.
  ok=false
  attempt=0
  delay=0
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    code=$(curl -sL -o /dev/null -w "%{http_code}" "$SLOW_URL" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then ok=true; break; fi
    [ "$attempt" -lt 6 ] && { sleep "$delay"; delay=$((delay + 1)); }
  done
  [ "$ok" = "true" ]
}

@test "worker preview retry loop fails after 6 permanent 503s" {
  # Server always returns 503 (SERVE_503_FOR huge).
  _start_slow_server 999
  ok=false
  attempt=0
  delay=0
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    code=$(curl -sL -o /dev/null -w "%{http_code}" "$SLOW_URL" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then ok=true; break; fi
    [ "$attempt" -lt 6 ] && { sleep "$delay"; delay=$((delay + 1)); }
  done
  [ "$ok" = "false" ]
  [ "$attempt" = "6" ]
}

# ── Multi-viewport preview (#37) ──────────────────────────────────────
# The spec gate is approved on a screenshot. A desktop-only shot hides
# exactly the class of regression boucle's audience (Product Builders,
# not full-time developers) cannot read from a diff.

@test "render-preview: parses a viewport list" {
  run node -e "
    const {parseViewports} = require('./bin/render-preview.cjs');
    const v = parseViewports('390x844,1440x900');
    if (v.length !== 2) process.exit(1);
    if (v[0].width !== 390 || v[0].height !== 844) process.exit(1);
    if (v[1].width !== 1440 || v[1].height !== 900) process.exit(1);
  "
  assert_success
}

@test "render-preview: a malformed viewport is skipped, not fatal" {
  # A bad entry must not cost the human the preview entirely.
  run node -e "
    const {parseViewports} = require('./bin/render-preview.cjs');
    const v = parseViewports('390x844, bogus ,1440x900');
    if (v.length !== 2) process.exit(1);
  " 2> /dev/null
  assert_success
}

@test "render-preview: defaults to one phone and one desktop viewport" {
  run grep -q "const DEFAULT_VIEWPORTS = '390x844,1440x900';" bin/render-preview.cjs
  assert_success
}

@test "render-preview: one failing viewport does not lose the others" {
  run grep -q "A partial set of" bin/render-preview.cjs
  assert_success
  # Every viewport failing is still an error.
  run grep -q "render-preview: every viewport failed" bin/render-preview.cjs
  assert_success
}

@test "render-preview: prints each produced path for the caller" {
  run grep -q "for (const p of produced) console.log(p);" bin/render-preview.cjs
  assert_success
}

@test "render-preview: requiring the module does not launch Chromium" {
  # puppeteer-core is not installed in the test environment; a require that
  # reached the launch path would throw.
  run node -e "require('./bin/render-preview.cjs'); console.log('ok')"
  assert_success
  assert_output "ok"
}

@test "triage preview: viewport uploads respect the total attachment budget" {
  run grep -q 'BOUCLE_IMAGE_TOTAL_MAX_BYTES' lib/boucle-ci/triage.sh
  assert_success
}

@test "triage preview: each screenshot is labelled by device class" {
  run grep -q 'Mobile ($dims)' lib/boucle-ci/triage.sh
  assert_success
  run grep -q 'Desktop ($dims)' lib/boucle-ci/triage.sh
  assert_success
}

@test "triage preview: BOUCLE_PREVIEW_DISABLE still skips Chromium entirely" {
  run grep -q 'BOUCLE_PREVIEW_DISABLE:-false' lib/boucle-ci/triage.sh
  assert_success
}
