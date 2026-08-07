# Human-Readable Spec Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a mandatory non-technical TL;DR to the triage comment (so non-technical humans can validate specs) plus a systematic, mandatory PNG visual preview (via Chromium) for UI/UX issues. Non-UI/UX issues never trigger Chromium — zero overhead because they don't write `RENDER_REQUEST`.

**Architecture:** Agent produces content (TL;DR text + `preview.html`/`RENDER_REQUEST` files to `.boucle/<issue>/` for UI/UX issues). CI handles infrastructure (Chromium render, GitLab upload, comment edit). For UI/UX issues, the visual preview is mandatory; for non-UI/UX issues, the absence of `RENDER_REQUEST` skips the block entirely (zero cost). The visual-preview block fires for ALL READY dispositions (Size S/M/L, gated or not) — it sits after the READY case routing, outside the `SHOULD_GATE` if/else. Strict separation: agent=content, CI=infrastructure.

**Tech Stack:** Bash (GitLab CI), Node.js (render script), `puppeteer-core` + `@sparticuz/chromium` (installed on-demand in `/tmp`, never persisted), GitLab uploads API + notes API.

**Spec:** `docs/superpowers/specs/2026-07-31-human-readable-spec-validation-design.md`

**Testing note:** This project has no test framework (no `tests/` dir, no test runner in `package.json`). Per spec §6, verification is minimal and targeted: shell grep assertions + `node --check` syntax validation + a mock render dry-run. Do NOT introduce a test framework — that is out of scope.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `.opencode/agents/triage.md` | Modify | Add mandatory `## TL;DR` section (first) + mandatory visual rules (for UI/UX) to agent output format |
| `.gitlab-ci.yml` | Modify | (1) Repoint `SPEC_MSG` to TL;DR (line 616), (2) insert inline render block after READY case routing (after line 618, outside `SHOULD_GATE` if/else — fires for all READY dispositions) |
| `bin/render-preview.cjs` | Create | Self-contained Node script: renders `preview.html` → `preview.png` via `@sparticuz/chromium` + puppeteer-core |

**Write ownership:** Tasks 1 and 3 touch independent files (`.opencode/agents/triage.md` and `bin/render-preview.cjs`) — parallelizable. Tasks 2 and 4 both modify `.gitlab-ci.yml` — must be sequential (Task 2 before Task 4, both edit the same region). Task 4 depends on Task 3 (CI calls the render script).

---

## Task 1: Add TL;DR section + visual rules to triage agent

**Files:**
- Modify: `.opencode/agents/triage.md` (output format block lines 32-51, rules section lines 53+)

- [ ] **Step 1: Verify current state lacks TL;DR**

Run: `grep -c '## TL;DR' .opencode/agents/triage.md`
Expected: `0` (no TL;DR section yet)

- [ ] **Step 2: Add `## TL;DR` to the output format block**

In `.opencode/agents/triage.md`, the output format block (starting at line 33 with `<!-- boucle:triage v=1 -->`) currently begins with `## Analysis`. Insert `## TL;DR` BEFORE `## Analysis`.

Replace this exact block (lines 33-37):

```
<!-- boucle:triage v=1 -->
## Analysis
<what the issue actually asks for, in your own words>

## Draft acceptance criteria
```

with:

```
<!-- boucle:triage v=1 -->
## TL;DR
<2-4 phrases en langage courant, non-technique. Décrit le résultat visible pour l'utilisateur, pas le mécanisme d'implémentation.>

## Analysis
<what the issue actually asks for, in your own words>

## Draft acceptance criteria
```

- [ ] **Step 3: Add TL;DR rules to the Rules section**

In the `## Rules` section (after line 54 `- **Do NOT** write any \`boucle:*\` labels...`), add a new subsection for TL;DR rules. Insert after the existing rules block (after the line `- **Do NOT** implement anything — you are analysis only.`):

```
### TL;DR rules (ENFORCED)

- **Always present**, whatever the size or domain of the issue.
- 2-4 phrases, plain non-technical language.
- Describes the **user-visible result**, not the implementation mechanism.
- If you cannot summarize the issue in 4 plain phrases, the issue is probably NEEDS-SPLIT or NEEDS-INFO — flag it accordingly.
```

- [ ] **Step 4: Add visual rules to the Rules section**

Immediately after the TL;DR rules block added in Step 3, add:

```
### Visual preview rules (mandatory for UI/UX)

- **Mandatory for UI/UX issues** — every UI/UX triage MUST write the two files below. Non-UI/UX issues (backend, infra, docs, chore, refactor) MUST NOT write them (no `RENDER_REQUEST` → CI skips the block → zero Chromium cost).
- The default is mandatory for UI/UX issues; for non-UI/UX issues, the default is zero overhead.
- If justified (i.e. the issue is UI/UX), write two files to `.boucle/<issue>/`:
  - `preview.html` — self-contained HTML mockup (inline CSS, no external dependencies, mobile + desktop in one file).
  - `RENDER_REQUEST` — one line of justification (why this mockup helps for this issue).
- An empty or generic `RENDER_REQUEST` → the CI ignores the request.
- One mockup per issue, showing the proposed outcome.
- You do NOT render, upload, or touch the comment image — the CI handles that.
```

- [ ] **Step 5: Verify TL;DR section is present and first**

Run: `grep -c '## TL;DR' .opencode/agents/triage.md`
Expected: `1` (or more — the format block + rules reference)

Run: `awk '/<!-- boucle:triage v=1 -->/{found=1} found && /^## /{print; exit}' .opencode/agents/triage.md`
Expected: `## TL;DR` (confirms TL;DR is the first `## ` section after the marker)

- [ ] **Step 6: Verify visual rules are present**

Run: `grep -c 'RENDER_REQUEST' .opencode/agents/triage.md`
Expected: `2` (mentioned in visual rules: the file write rule + the empty/generic rule)

- [ ] **Step 7: Commit**

```bash
git add .opencode/agents/triage.md
git commit -m "feat(triage): add mandatory TL;DR section + mandatory visual preview rules for UI/UX"
```

---

## Task 2: Repoint SPEC_MSG to TL;DR

**Files:**
- Modify: `.gitlab-ci.yml:616`

- [ ] **Step 1: Verify current SPEC_MSG points at acceptance criteria**

Run: `grep -n 'Review the acceptance criteria above' .gitlab-ci.yml`
Expected: line 616 contains `Review the acceptance criteria above`

- [ ] **Step 2: Change SPEC_MSG to point at TL;DR**

In `.gitlab-ci.yml` line 616, replace:

```
              SPEC_MSG=$(printf 'Review the acceptance criteria above. If they match what you want:\n- React with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR\n- Reply to this issue with any comment.\nIf not, reply with corrections.')
```

with:

```
              SPEC_MSG=$(printf 'Review the **TL;DR** above. If it matches what you want:\n- React with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR\n- Reply to this issue with any comment.\nIf not, reply with corrections.')
```

Only `acceptance criteria above` → `**TL;DR** above` changes. The reaction instructions are already present.

- [ ] **Step 3: Verify SPEC_MSG now points at TL;DR**

Run: `grep -c 'Review the \*\*TL;DR\*\* above' .gitlab-ci.yml`
Expected: `1`

Run: `grep -c 'acceptance criteria above' .gitlab-ci.yml`
Expected: `0` (old wording gone)

- [ ] **Step 4: Verify YAML still parses**

Run: `node -e "require('fs').readFileSync('.gitlab-ci.yml','utf8'); console.log('YAML read OK')"`
Expected: `YAML read OK`

If `yamllint` is available, also run: `yamllint -d relaxed .gitlab-ci.yml` (warnings OK, errors must be zero).

- [ ] **Step 5: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): repoint spec-review message to TL;DR instead of acceptance criteria"
```

---

## Task 3: Create render-preview script

**Files:**
- Create: `bin/render-preview.cjs`

- [ ] **Step 1: Verify script does not exist yet**

Run: `ls bin/render-preview.cjs 2>&1`
Expected: `ls: cannot access 'bin/render-preview.cjs': No such file or directory`

- [ ] **Step 2: Write the render script**

Create `bin/render-preview.cjs`:

```js
#!/usr/bin/env node
// bin/render-preview.cjs — renders preview.html → preview.png via @sparticuz/chromium
// Called by the triage CI job's visual-preview block (mandatory for UI/UX,
// skipped for non-UI/UX since they don't write RENDER_REQUEST).
// Usage: NODE_PATH=/tmp/node_modules node bin/render-preview.cjs <input.html> <output.png>
//
// Self-contained: no project dependencies. Relies on puppeteer-core +
// @sparticuz/chromium being resolvable via NODE_PATH (installed on-demand
// by the CI block into /tmp/node_modules).
const puppeteer = require('puppeteer-core');
const chromium = require('@sparticuz/chromium');
const path = require('path');

const [,, input, output] = process.argv;

if (!input || !output) {
  console.error('Usage: node bin/render-preview.cjs <input.html> <output.png>');
  process.exit(2);
}

(async () => {
  const browser = await puppeteer.launch({
    args: chromium.args,
    executablePath: await chromium.executablePath(),
    headless: chromium.headless,
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1280, height: 800 });
    await page.goto('file://' + path.resolve(input), { waitUntil: 'networkidle0' });
    await page.screenshot({ path: output, fullPage: true });
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error('render-preview failed:', e);
  process.exit(1);
});
```

- [ ] **Step 3: Verify script syntax**

Run: `node --check bin/render-preview.cjs`
Expected: no output (syntax OK)

- [ ] **Step 4: Verify script rejects missing args**

Run: `node bin/render-preview.cjs`
Expected: exit code 2, stderr contains `Usage: node bin/render-preview.cjs <input.html> <output.png>`

- [ ] **Step 5: Make script executable**

Run: `chmod +x bin/render-preview.cjs`
Expected: no output

- [ ] **Step 6: Commit**

```bash
git add bin/render-preview.cjs
git commit -m "feat(bin): add render-preview.cjs for UI/UX HTML→PNG via @sparticuz/chromium"
```

---

## Task 4: Insert inline visual render block in CI

**Files:**
- Modify: `.gitlab-ci.yml` (insert after line 618, after the READY case routing, OUTSIDE the `SHOULD_GATE` if/else — fires for all READY dispositions, gated or not)

**Depends on:** Task 3 (CI calls `bin/render-preview.cjs`).

- [ ] **Step 1: Verify insertion point**

Run: `sed -n '616,619p' .gitlab-ci.yml`
Expected output (4 lines):
```
              SPEC_MSG=$(printf 'Review the **TL;DR** above. If it matches what you want:\n- React with 👍 ✅ ☑️ ✔️ 🆗 or 👌 on this comment to approve, OR\n- Reply to this issue with any comment.\nIf not, reply with corrections.')
              glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                -f body="$SPEC_MSG" > /dev/null
            else
```

The new block inserts between line 618 (`-f body="$SPEC_MSG" > /dev/null`) and line 619 (`else`), at 14 spaces indentation (matching the `SPEC_MSG` lines).

- [ ] **Step 2: Insert the visual render block**

In `.gitlab-ci.yml`, replace this exact text (lines 617-619):

```
              glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                -f body="$SPEC_MSG" > /dev/null
            else
```

with:

```
              glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                -f body="$SPEC_MSG" > /dev/null

              # ── Aperçu visuel (systématique pour les issues UI/UX) ──────────
              # S'exécute pour toute disposition READY (Size S/M/L, gated ou non)
              # si l'agent a écrit RENDER_REQUEST + preview.html (UI/UX uniquement).
              # Issues non-UI/UX: pas de RENDER_REQUEST → bloc skippé, zéro coût
              # Chromium. Échec isolé: ne bloque jamais la boucle (note fallback
              # postée, exit code inchangé).
              PREVIEW_HTML="$CI_PROJECT_DIR/.boucle/$IID/preview.html"
              RENDER_REQUEST_FILE="$CI_PROJECT_DIR/.boucle/$IID/RENDER_REQUEST"

              if [ -s "$RENDER_REQUEST_FILE" ] && [ -s "$PREVIEW_HTML" ]; then
                echo "[boucle] RENDER_REQUEST found — attempting visual preview"

                # 1. Résoudre le note_id du commentaire de triage (fetch séparé
                #    pour ne pas perturber le parse existant du commentaire).
                TRIAGE_NOTE_ID=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
                  "/projects/$CI_PROJECT_ID/issues/$IID/notes" 2>/dev/null \
                  | jq -r '[.[] | select(.body | contains("<!-- boucle:triage") and contains("## Disposition"))]
                      | sort_by(.created_at) | last | .id' 2>/dev/null || echo "")

                if [ -z "$TRIAGE_NOTE_ID" ]; then
                  echo "[boucle] WARN: triage comment not found — cannot embed preview"
                else
                  # 2. Installer Chromium + puppeteer-core (uniquement maintenant, /tmp).
                  if npm install --prefix /tmp puppeteer-core @sparticuz/chromium >/dev/null 2>&1; then
                    # 3. Rendre preview.html → preview.png (1280x800, fullPage).
                    #    NODE_PATH=/tmp/node_modules pour que le script (bin/)
                    #    résolve les modules installés dans /tmp.
                    PREVIEW_PNG="$CI_PROJECT_DIR/.boucle/$IID/preview.png"
                    if NODE_PATH=/tmp/node_modules node "$CI_PROJECT_DIR/bin/render-preview.cjs" "$PREVIEW_HTML" "$PREVIEW_PNG" 2>/dev/null; then
                      # 4. Uploader le PNG via l'API uploads GitLab.
                      UPLOAD_RESP=$(curl -s --request POST \
                        --header "PRIVATE-TOKEN: $BOUCLE_TOKEN" \
                        --form "file=@$PREVIEW_PNG" \
                        "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/uploads" 2>/dev/null)
                      IMG_URL=$(echo "$UPLOAD_RESP" | jq -r '.markdown // empty' 2>/dev/null)

                      if [ -n "$IMG_URL" ]; then
                        # 5. Fetch du commentaire existant, append section Aperçu, PUT.
                        EXISTING_BODY=$(glab api --hostname "$BOUCLE_FORGE_HOST" \
                          "/projects/$CI_PROJECT_ID/issues/$IID/notes/$TRIAGE_NOTE_ID" 2>/dev/null \
                          | jq -r '.body' 2>/dev/null)
                        NEW_BODY=$(printf '%s\n\n## Aperçu\n%s\n' "$EXISTING_BODY" "$IMG_URL")
                        if glab api --hostname "$BOUCLE_FORGE_HOST" -X PUT \
                          "/projects/$CI_PROJECT_ID/issues/$IID/notes/$TRIAGE_NOTE_ID" \
                          -f body="$NEW_BODY" >/dev/null 2>&1; then
                          # 6. Idempotence: supprimer RENDER_REQUEST (pas de re-render au retry).
                          rm -f "$RENDER_REQUEST_FILE"
                          echo "[boucle] Visual preview embedded in triage comment #$TRIAGE_NOTE_ID"
                        else
                          echo "[boucle] WARN: PUT notes failed — RENDER_REQUEST kept for retry"
                        fi
                      else
                        echo "[boucle] WARN: PNG upload failed — posting fallback note"
                        glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
                          "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                          -f body="Aperçu indisponible (échec upload) — validez sur le TL;DR." >/dev/null 2>&1
                      fi
                    else
                      echo "[boucle] WARN: Chromium render failed — posting fallback note"
                      glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
                        "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                        -f body="Aperçu indisponible (échec rendu) — validez sur le TL;DR." >/dev/null 2>&1
                    fi
                  else
                    echo "[boucle] WARN: Chromium install failed — posting fallback note"
                    glab api --hostname "$BOUCLE_FORGE_HOST" -X POST \
                      "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
                      -f body="Aperçu indisponible (Chromium indisponible) — validez sur le TL;DR." >/dev/null 2>&1
                  fi
                fi
              fi
            else
```

- [ ] **Step 3: Verify the block is present and the else still follows**

Run: `grep -c 'Aperçu visuel (systématique pour les issues UI/UX)' .gitlab-ci.yml`
Expected: `1`

Run: `grep -c 'RENDER_REQUEST found — attempting visual preview' .gitlab-ci.yml`
Expected: `1`

Run: `grep -c 'NODE_PATH=/tmp/node_modules node' .gitlab-ci.yml`
Expected: `1`

Run: `grep -n 'rm -f "$RENDER_REQUEST_FILE"' .gitlab-ci.yml`
Expected: one line (idempotence delete)

- [ ] **Step 4: Verify the else branch (default path) is still intact**

Run: `sed -n '/Visual preview embedded\|RENDER_REQUEST kept for retry\|fi$/,/else$/p' .gitlab-ci.yml | tail -5`
Expected: ends with `fi` then `else` (the default-path `else` branch follows the render block)

Run: `grep -c 'set_boucle_label "$IID" "boucle:todo,size:' .gitlab-ci.yml`
Expected: `1` (default-path label set still present in the else branch)

- [ ] **Step 5: Verify YAML still parses**

Run: `node -e "const yaml=require('fs').readFileSync('.gitlab-ci.yml','utf8'); if(!yaml.includes('stages:')) throw new Error('missing stages'); console.log('YAML structure OK')"`
Expected: `YAML structure OK`

If `yamllint` is available: `yamllint -d relaxed .gitlab-ci.yml` (warnings OK, errors must be zero).

- [ ] **Step 6: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): add systematic visual preview block for UI/UX issues (Chromium only when triggered)"
```

---

## Task 5: Integration verification (spec §6 checklist)

**Files:**
- Read-only verification across all changed files

- [ ] **Step 1: Verify TL;DR is first section in agent output format**

Run: `awk '/<!-- boucle:triage v=1 -->/{found=1} found && /^## /{print; exit}' .opencode/agents/triage.md`
Expected: `## TL;DR`

- [ ] **Step 2: Verify SPEC_MSG mentions TL;DR and reactions**

Run: `grep 'Review the \*\*TL;DR\*\* above' .gitlab-ci.yml | grep -c '👍'`
Expected: `1` (TL;DR message + reaction emoji present on same line)

- [ ] **Step 3: Verify default path skips Chromium (no RENDER_REQUEST → block skipped)**

Run: `grep -c '\[ -s "$RENDER_REQUEST_FILE" \] && \[ -s "$PREVIEW_HTML" \]' .gitlab-ci.yml`
Expected: `1` (the guard condition that skips the whole block by default)

Confirm the guard is the FIRST thing in the block (before any npm install):
Run: `awk '/Aperçu visuel \(systématique/{f=1} f&&/npm install --prefix \/tmp/{print NR; exit}' .gitlab-ci.yml`
Expected: a line number GREATER than the guard line (npm install only runs inside the guard)

- [ ] **Step 4: Verify render script exists and is syntactically valid**

Run: `node --check bin/render-preview.cjs && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 5: Verify idempotence (RENDER_REQUEST deleted after success)**

Run: `grep -c 'rm -f "$RENDER_REQUEST_FILE"' .gitlab-ci.yml`
Expected: `1` (exactly one delete, inside the success path)

- [ ] **Step 6: Verify failure isolation (fallback notes posted, loop not blocked)**

Run: `grep -c 'Aperçu indisponible' .gitlab-ci.yml`
Expected: `3` (three fallback notes: upload fail, render fail, Chromium unavailable)

Run: `grep -c 'validez sur le TL;DR' .gitlab-ci.yml`
Expected: `3` (all three fallback notes point human back to TL;DR)

- [ ] **Step 7: Verify no exit 1 / exit non-zero in the render block (loop never blocked)**

Run: `awk '/Aperçu visuel \(systématique/,/^            else$/' .gitlab-ci.yml | grep -c 'exit 1\|exit 2'`
Expected: `0` (the render block never exits the job — failures post a note and continue)

- [ ] **Step 8: Final commit check (if any verification fixed something)**

Run: `git status --porcelain`
Expected: empty (all changes committed in Tasks 1-4)

If not empty, commit remaining:
```bash
git add -A && git commit -m "fix: integration verification corrections"
```

- [ ] **Step 9: Verify commit history**

Run: `git log --oneline -5`
Expected: 4 commits on top of `f62890b` (the spec commit), one per task:
1. `feat(triage): add mandatory TL;DR section + mandatory visual preview rules for UI/UX`
2. `feat(ci): repoint spec-review message to TL;DR instead of acceptance criteria`
3. `feat(bin): add render-preview.cjs for UI/UX HTML→PNG via @sparticuz/chromium`
4. `feat(ci): add systematic visual preview block for UI/UX issues (Chromium only when triggered)`

---

## Self-Review Notes

**Spec coverage check:**
- §4.2 agent TL;DR section → Task 1 (Steps 2-3) ✓
- §4.2 agent visual rules → Task 1 (Step 4) ✓
- §4.3.1 SPEC_MSG repoint → Task 2 ✓
- §4.3.2 inline render block → Task 4 ✓
- §4.3.3 render script → Task 3 ✓
- §4.4 default path unchanged → Task 5 Step 3 (guard skips block) ✓
- §5 error handling (fallback notes, idempotence, no exit) → Task 4 (block includes all fallback paths) + Task 5 Steps 5-7 ✓
- §6 test checklist → Task 5 (all 6 spec checks mapped to Steps 1-7) ✓

**Type/name consistency:**
- `RENDER_REQUEST` / `RENDER_REQUEST_FILE` — consistent across agent rules (Task 1), CI block (Task 4), verification (Task 5) ✓
- `preview.html` / `PREVIEW_HTML` — consistent ✓
- `preview.png` / `PREVIEW_PNG` — consistent ✓
- `bin/render-preview.cjs` — consistent across Task 3 (create) and Task 4 (CI call with `NODE_PATH=/tmp/node_modules`) ✓
- `TRIAGE_NOTE_ID` — consistent within Task 4 block ✓
- `$IID` — matches existing CI variable usage (lines 609, 617) ✓

**No placeholders:** All code blocks contain complete content. No TBD/TODO.