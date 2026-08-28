#!/usr/bin/env bats
# test/describe-images.bats — tests for bin/describe-images, focused on the
# repo-images source added for PR-changed raster images (#98).
#
# bin/describe-images runs the vision model via `jcode` per image. These
# tests stub `jcode` on PATH (a script that echoes a fake description) so no
# network or model is needed. The stub must be a real executable on PATH
# because describe-images calls `jcode ... run --quiet "$PROMPT"` directly.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  # Temp project dir: CI_PROJECT_DIR points here, state lives under
  # .boucle-state/$BOUCLE_ISSUE (same formula as the fetchers and bin/jc).
  TEST_DIR="$(mktemp -d)"
  export BOUCLE_ISSUE="42"
  export CI_PROJECT_DIR="$TEST_DIR"
  STATE_DIR="$TEST_DIR/.boucle-state/$BOUCLE_ISSUE"

  # Stub jcode: echoes a deterministic fake description. The vision model
  # invocation is `jcode --provider-profile ... --model ... --tools '*' run
  # --quiet "<prompt>"` — the stub ignores args and prints the description.
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/jcode" <<'STUB'
#!/usr/bin/env bash
echo "FAKE-DESCRIPTION: a 1x1 red pixel image"
STUB
  chmod +x "$STUB_DIR/jcode"
  export PATH="$STUB_DIR:$PATH"

  # ensure_jcode_config writes a config when BOUCLE_LLM_BASE_URL +
  # BOUCLE_LLM_API_KEY are set; point JCODE_HOME at a temp dir so the test
  # never touches the real ~/.jcode.
  JCODE_HOME="$(mktemp -d)"
  export JCODE_HOME
  export BOUCLE_LLM_BASE_URL="https://example.invalid/v1"
  export BOUCLE_LLM_API_KEY="test-key"
}

teardown() {
  rm -rf "$TEST_DIR" "$STUB_DIR" "$JCODE_HOME"
}

# Write a minimal real 1x1 red PNG (base64 of a 67-byte PNG) at the given
# path (dirs created as needed).
write_png() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
    | base64 -d > "$path"
}

@test "describe-images: repo-images nested path is discovered and headed by repo-relative path" {
  write_png "$STATE_DIR/repo-images/public/foo.png"

  run bash bin/describe-images reviewer
  assert_success
  assert [ -f "$STATE_DIR/.image-descriptions.md" ]
  # Heading is the repo-relative path, not the bare filename.
  run grep -q "^## public/foo.png" "$STATE_DIR/.image-descriptions.md"
  assert_success
  # The stub description made it into the file.
  run grep -q "FAKE-DESCRIPTION: a 1x1 red pixel image" "$STATE_DIR/.image-descriptions.md"
  assert_success
  # The absolute path is kept on the File: metadata line.
  run grep -q "File: \`$STATE_DIR/repo-images/public/foo.png\`" "$STATE_DIR/.image-descriptions.md"
  assert_success
}

@test "describe-images: svg in repo-images is NOT described" {
  mkdir -p "$STATE_DIR/repo-images"
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="red"/></svg>\n' \
    > "$STATE_DIR/repo-images/icon.svg"

  run bash bin/describe-images reviewer
  assert_success
  # No images found → no descriptions file written.
  assert [ ! -f "$STATE_DIR/.image-descriptions.md" ]
}

@test "describe-images: empty dirs exit 0 with no descriptions file" {
  run bash bin/describe-images reviewer
  assert_success
  assert [ ! -f "$STATE_DIR/.image-descriptions.md" ]
}

@test "describe-images: attachment dirs still use bare-filename headings" {
  write_png "$STATE_DIR/attachments/screenshot.png"

  run bash bin/describe-images reviewer
  assert_success
  assert [ -f "$STATE_DIR/.image-descriptions.md" ]
  run grep -q "^## screenshot.png" "$STATE_DIR/.image-descriptions.md"
  assert_success
  run grep -q "^## attachments/screenshot.png" "$STATE_DIR/.image-descriptions.md"
  assert_failure
}
