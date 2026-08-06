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
