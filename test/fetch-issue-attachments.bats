#!/usr/bin/env bats
# test/fetch-issue-attachments.bats — smoke + pure-logic tests for bin/fetch-issue-attachments.
#
# bin/fetch-issue-attachments has no BASH_SOURCE guard and executes its full
# body on source: it calls glab api to fetch the issue, makes network
# requests with curl, writes manifest/env files, etc. The script has no
# user-defined functions — it's all top-level imperative code.
#
# These tests cover what we can: syntax validity, the upload-path
# extraction regex (a key piece of pure logic), the filename
# sanitization rule, and the script's required-env guards.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
}

# Extract the upload-path regex from the GitLab forge backend. The regex
# moved out of bin/fetch-issue-attachments into
# forge_attachments_extract() (bin/forge/gitlab.sh) during the
# forge-abstraction port — the script now delegates extraction to the
# contract function. We pull the single-quoted grep -oE pattern from the
# backend so tests stay faithful to real behavior. Output is the regex
# string suitable for `grep -E`.
upload_regex() {
  sed -n '/^forge_attachments_extract()/,/^}/p' bin/forge/gitlab.sh \
    | grep -m1 -oE "'[^']+'" \
    | tr -d "'"
}

# Write the upload regex to a fresh temp file, returning the path via
# the global UPLOAD_REGEX_FILE. The file contains a single-quoted
# assignment `RE='<regex>'` that the test can `source` to set $RE
# without running into shell-quoting headaches. (Single quotes are safe
# because the backend regex contains a literal `"` — in `[^" )]` — but
# no `'`; the old inline script regex had the opposite quoting problem.)
write_upload_regex_file() {
  UPLOAD_REGEX_FILE="$(mktemp)"
  local re
  re=$(upload_regex)
  printf "RE='%s'\n" "$re" > "$UPLOAD_REGEX_FILE"
}

teardown() {
  # UPLOAD_REGEX_FILE is only set by tests that called
  # write_upload_regex_file. Always return 0 from teardown so bats
  # doesn't flag a missing file as a failure.
  if [ -n "${UPLOAD_REGEX_FILE:-}" ] && [ -f "$UPLOAD_REGEX_FILE" ]; then
    rm -f "$UPLOAD_REGEX_FILE"
  fi
  return 0
}

# ── Syntax ────────────────────────────────────────────────────────────

@test "bin/fetch-issue-attachments parses without syntax error" {
  run bash -n bin/fetch-issue-attachments
  assert_success
}

# ── Required env vars ────────────────────────────────────────────────

@test "bin/fetch-issue-attachments requires BOUCLE_ISSUE" {
  run env -u BOUCLE_ISSUE bash bin/fetch-issue-attachments
  assert_failure
}

@test "bin/fetch-issue-attachments requires BOUCLE_TOKEN" {
  run env -u BOUCLE_TOKEN BOUCLE_ISSUE=1 bash bin/fetch-issue-attachments
  assert_failure
}

@test "bin/fetch-issue-attachments requires CI_PROJECT_ID" {
  run env -u CI_PROJECT_ID BOUCLE_ISSUE=1 BOUCLE_TOKEN=t bash bin/fetch-issue-attachments
  assert_failure
}

# ── Pure regex: extract /uploads/... paths (any extension) ───────────
# The script uses `grep -oiE "/uploads/[^[:space:]\"')]+"` to find all
# upload attachments in issue/note markdown (images, PDFs, archives, etc.).
# We test that the same regex extracted from the script behaves as expected.

@test "regex extracts /uploads/ PNG path" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; echo '![alt](/uploads/abc123/screenshot.png)' | grep -oiE \"\$RE\""
  assert_success
  assert_output "/uploads/abc123/screenshot.png"
}

@test "regex extracts /uploads/ JPG path" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; echo '![img](/uploads/xyz/pic.jpg)' | grep -oiE \"\$RE\""
  assert_success
  assert_output "/uploads/xyz/pic.jpg"
}

@test "regex extracts /uploads/ jpeg path" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; echo 'see /uploads/h/photo.jpeg here' | grep -oiE \"\$RE\""
  assert_success
  assert_output "/uploads/h/photo.jpeg"
}

@test "regex extracts /uploads/ gif, webp, avif, svg" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; printf '%s\n' '![a](/uploads/x/a.gif)' '![b](/uploads/x/b.webp)' '![c](/uploads/x/c.avif)' '![d](/uploads/x/d.svg)' | grep -oiE \"\$RE\" | sort -u"
  assert_success
  assert_output --partial "/uploads/x/a.gif"
  assert_output --partial "/uploads/x/b.webp"
  assert_output --partial "/uploads/x/c.avif"
  assert_output --partial "/uploads/x/d.svg"
}

@test "regex extracts /uploads/ non-image paths (pdf, zip)" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; printf '%s\n' '[file](/uploads/x/doc.pdf)' '[archive](/uploads/x/backup.zip)' | grep -oiE \"\$RE\" | sort -u"
  assert_success
  assert_output --partial "/uploads/x/doc.pdf"
  assert_output --partial "/uploads/x/backup.zip"
}

@test "regex ignores external URLs" {
  write_upload_regex_file
  run bash -c "source '$UPLOAD_REGEX_FILE'; echo '![ext](https://example.com/img.png)' | grep -oiE \"\$RE\""
  assert_failure
}

# ── Pure: filename sanitization ──────────────────────────────────────
# The script sanitizes filenames with: filename=$(echo "$filename" | tr -cd '[:alnum:]._-')
# Test that rule in isolation.

@test "filename sanitization strips path separators" {
  run bash -c 'echo "../../etc/passwd" | tr -cd "[:alnum:]._-"'
  assert_success
  # / is not in the allowed set; . is. Slashes removed, dots kept.
  assert_output "....etcpasswd"
}

@test "filename sanitization keeps allowed chars" {
  run bash -c 'echo "img_1.0-beta.png" | tr -cd "[:alnum:]._-"'
  assert_success
  assert_output "img_1.0-beta.png"
}

@test "filename sanitization strips spaces and shell metachars" {
  run bash -c 'echo "bad name;rm.png" | tr -cd "[:alnum:]._-"'
  assert_success
  assert_output "badnamerm.png"
}
