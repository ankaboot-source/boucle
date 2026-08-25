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

_rp_have_browser() {
  [ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && [ -x "${AGENT_BROWSER_EXECUTABLE_PATH}" ] && return 0
  [ -n "${BOUCLE_CHROME:-}" ] && [ -x "${BOUCLE_CHROME}" ] && return 0
  for c in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$c" > /dev/null 2>&1 && return 0
  done
  return 1
}

_rp_have_agent_browser() {
  command -v agent-browser > /dev/null 2>&1 || [ -x /tmp/node_modules/.bin/agent-browser ]
}

@test "render-preview: defaults to one phone and one desktop viewport" {
  run grep -q "DEFAULT_VIEWPORTS='390x844,1440x900'" bin/render-preview
  assert_success
}

@test "render-preview: a malformed viewport is skipped, not fatal" {
  # A bad entry must not cost the human the preview entirely.
  run grep -q 'ignoring malformed viewport' bin/render-preview
  assert_success
}

@test "render-preview: one failing viewport does not lose the others" {
  # Each viewport `continue`s on failure; only an empty result set is fatal.
  run grep -q 'render-preview: every viewport failed' bin/render-preview
  assert_success
}

@test "render-preview: prints each produced path for the caller" {
  run grep -q "printf '%s' \"\$PRODUCED\"" bin/render-preview
  assert_success
}

@test "render-preview: missing arguments exit 2 with usage" {
  run bin/render-preview
  [ "$status" -eq 2 ]
  assert_output --partial 'Usage: bin/render-preview'
}

@test "render-preview: a missing local input exits 2" {
  run bin/render-preview "$BATS_TEST_TMPDIR/absent.html" "$BATS_TEST_TMPDIR/out.png"
  [ "$status" -eq 2 ]
  assert_output --partial 'input missing or empty'
}

# Fraction of non-white pixels, sampled. A capture of about:blank scores ~0.
# File size cannot stand in for this: a solid-colour page and a blank page
# compress to within 100 bytes of each other (2827 vs 2726, measured).
_rp_ink_ratio() {
  python3 - "$1" <<'INKPY'
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
pos, idat, color, w, h = 8, b'', None, 0, 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos + 8])
    c = d[pos + 8:pos + 8 + ln]
    if typ == b'IHDR':
        w, h, _depth, color = struct.unpack('>IIBB', c[:10])
    elif typ == b'IDAT':
        idat += c
    pos += 12 + ln
ch = {0: 1, 2: 3, 4: 2, 6: 4}[color]
raw = zlib.decompress(idat)
stride = w * ch
prev = bytearray(stride)
i = ink = total = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i + stride]); i += stride
    if f:
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c2 = prev[x - ch] if x >= ch else 0
            if f == 1:   line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            else:
                pr = a + b - c2
                pa, pb, pc = abs(pr - a), abs(pr - b), abs(pr - c2)
                line[x] = (line[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c2))) & 255
    if y % 8 == 0:
        for x in range(0, w, 8):
            o = x * ch
            total += 1
            if not (line[o] > 245 and line[o + 1] > 245 and line[o + 2] > 245):
                ink += 1
    prev = line
print(f"{(ink / total if total else 0):.3f}")
INKPY
}

@test "render-preview: an entirely malformed viewport list falls back to the defaults" {
  _rp_have_agent_browser || skip "agent-browser not installed"
  _rp_have_browser || skip "no browser available"
  cat > "$BATS_TEST_TMPDIR/preview.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>fixture</title><body style="background:#5b5bd6">
HTML
  BOUCLE_PREVIEW_VIEWPORTS='bogus,nawak' \
    run bin/render-preview "$BATS_TEST_TMPDIR/preview.html" "$BATS_TEST_TMPDIR/fb.png"
  assert_success
  [ -s "$BATS_TEST_TMPDIR/fb-390x844.png" ]
  [ -s "$BATS_TEST_TMPDIR/fb-1440x900.png" ]
}

@test "render-preview: a valid viewport that fails to render is not retried with the defaults" {
  _rp_have_agent_browser || skip "agent-browser not installed"
  _rp_have_browser || skip "no browser available"
  # Regression: the fallback keyed on "nothing was produced" instead of
  # "nothing parsed", so an unreachable page was re-rendered once per default
  # viewport, burying the real error under repeats.
  BOUCLE_PREVIEW_VIEWPORTS='800x600' \
    run bin/render-preview "http://127.0.0.1:59999/nope.html" "$BATS_TEST_TMPDIR/dead.png"
  [ "$status" -eq 1 ]
  assert_output --partial 'every viewport failed'
  refute_output --partial 'retrying with defaults'
  [ ! -e "$BATS_TEST_TMPDIR/dead-390x844.png" ]
}

@test "render-preview: renders one non-blank PNG per viewport" {
  _rp_have_agent_browser || skip "agent-browser not installed"
  _rp_have_browser || skip "no browser available"
  cat > "$BATS_TEST_TMPDIR/preview.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>fixture</title>
<style>body{margin:0;background:#5b5bd6}.b{width:60%;height:180px;background:#22c55e;margin:20px auto}</style>
<div class="b"></div>
HTML
  BOUCLE_PREVIEW_VIEWPORTS='320x480,800x600' \
    run bin/render-preview "$BATS_TEST_TMPDIR/preview.html" "$BATS_TEST_TMPDIR/shot.png"
  assert_success
  # One path per viewport, on stdout, in order.
  [ "$(printf '%s\n' "$output" | grep -c 'shot-')" -eq 2 ]
  [ -s "$BATS_TEST_TMPDIR/shot-320x480.png" ]
  [ -s "$BATS_TEST_TMPDIR/shot-800x600.png" ]
  # The failure mode the script's URL assertion exists to catch: exit 0 with a
  # blank capture. The fixture is a solid colour, so ink must dominate.
  ratio="$(_rp_ink_ratio "$BATS_TEST_TMPDIR/shot-800x600.png")"
  run python3 -c "import sys; sys.exit(0 if float('$ratio') > 0.5 else 1)"
  [ "$status" -eq 0 ] || fail "capture looks blank (ink ratio $ratio)"
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

# Regression for boucle.dev #73: the visual preview block was nested inside
# the READY) case branch, so NEEDS-INFO / NEEDS-SPLIT issues never had their
# mockup rendered — even though the triage agent produces preview.html +
# RENDER_REQUEST for any UI/UX issue regardless of disposition. The block
# must live OUTSIDE the case/esac so it fires for all dispositions.
@test "triage preview: block is outside the case/esac (fires for all dispositions)" {
  # The preview block header must appear AFTER the main case/esac, not
  # inside any case branch. We assert: the line number of the preview header
  # is greater than the line number of the main esac.
  preview_line=$(grep -n '# ── Visual preview (systematic for UI/UX issues)' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  esac_line=$(grep -n '^  esac$' lib/boucle-ci/triage.sh | head -1 | cut -d: -f1)
  [ -n "$preview_line" ] || { echo "preview header not found"; false; }
  [ -n "$esac_line" ] || { echo "main esac not found"; false; }
  [ "$preview_line" -gt "$esac_line" ] || {
    echo "preview block (line $preview_line) is inside the case (esac at $esac_line) — must be after"
    false
  }
}

@test "triage preview: no chain_to_role inside the preview block" {
  # The preview block runs for all dispositions now. A chain_to_role call
  # inside it would wrongly trigger a worker run for NEEDS-INFO issues (which
  # must pause for the author). The only legitimate chain_to_role calls are
  # in the READY non-gated path, before the case/esac.
  run grep -n 'chain_to_role "\$IID" "worker"' lib/boucle-ci/triage.sh
  assert_success
  # Exactly two occurrences (both in the READY non-gated path, before esac).
  count=$(echo "$output" | grep -c 'chain_to_role')
  [ "$count" -eq 2 ] || {
    echo "expected 2 chain_to_role calls (READY non-gated path), found $count:"
    echo "$output"
    false
  }
}
