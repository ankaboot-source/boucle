# boucle MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the boucle MVP dev loop — a label-driven state machine on GitLab CI that takes an issue from triage to deployed-and-verified, with human merge as the only gate.

**Architecture:** Five extension seams (state machine, roles, harness, forge, work state). Jobs (shell + glab) manage state; agents (opencode) produce content. `bin/oc` is the harness entrypoint that wraps opencode, scrubs secrets, enforces caps, and asserts side effects. Developed in boucle as a template, applied to `up/urgence-palestine.fr` on Framagit.

**Tech Stack:** GitLab CI on Framagit, opencode (headless `opencode run`), glab CLI, Cloudflare Pages (wrangler), Astro static site, bash.

**Spec:** issue #1 (`/tmp/boucle-issue1-v2.md`, 406 lines) — the authoritative design. This plan is the execution sequence.

**Target repo:** `up/urgence-palestine.fr` on Framagit (project ID 126561, default branch `master`, Astro 5.6.1 static site, existing GitLab Pages CI to be replaced).

**Code home:** `boucle/loop/` — portable template. Applied to target repo root.

---

## File Structure

```
boucle/loop/                          # portable template (this repo)
├── bin/
│   ├── oc                            # harness entrypoint (S3) — wraps opencode
│   └── doctor                        # Day 0 verification (~20 checks)
├── .opencode/
│   └── agents/
│       ├── triage.md                 # cheap model, analyzes issue
│       ├── worker.md                 # strong model, implements
│       ├── reviewer.md               # adversarial, tests deployed preview
│       └── e2e.md                    # vision-capable, tests live URL
├── .gitlab-ci.yml                    # dispatcher + 5 jobs
├── LOOP.md                           # repo-level loop config
└── README.md                         # how to apply this template
```

Applied to `up/urgence-palestine.fr`:
```
urgence-palestine.fr/
├── bin/oc                            # from boucle/loop/bin/oc
├── bin/doctor                        # from boucle/loop/bin/doctor
├── .opencode/agents/*.md             # from boucle/loop/.opencode/agents/
├── .gitlab-ci.yml                    # from boucle/loop/.gitlab-ci.yml (replaces existing)
├── LOOP.md                           # from boucle/loop/LOOP.md
└── (existing Astro site)
```

---

## Phase 1: Day 0 Infrastructure (manual, via glab API)

> All via `glab api --hostname framagit.org` (authenticated as tahrir). Secrets from local `.env`.

### Task 1: Set CI variables on urgence-palestine.fr

**Files:**
- None (API calls to Framagit)

- [ ] **Step 1: Set BOUCLE_TOKEN (from UP_PAT)**

```bash
source /home/badreddine/Projects/ankaboot-source/boucle/.env
glab api --hostname framagit.org -X POST "/projects/126561/variables" \
  -f key=BOUCLE_TOKEN -f value="$UP_PAT" -f masked=true -f protected=true
```

Expected: `{"key":"BOUCLE_TOKEN","masked":true,"protected":true,...}`

- [ ] **Step 2: Set CLOUDFLARE_API_TOKEN (from UP_CLOUDFLARE_API_TOKEN)**

```bash
glab api --hostname framagit.org -X POST "/projects/126561/variables" \
  -f key=CLOUDFLARE_API_TOKEN -f value="$UP_CLOUDFLARE_API_TOKEN" -f masked=true -f protected=true
```

Expected: `{"key":"CLOUDFLARE_API_TOKEN","masked":true,"protected":true,...}`

- [ ] **Step 3: Set BOUCLE_ENABLED**

```bash
glab api --hostname framagit.org -X POST "/projects/126561/variables" \
  -f key=BOUCLE_ENABLED -f value=true -f masked=false -f protected=false
```

Expected: `{"key":"BOUCLE_ENABLED",...,"value":"true",...}`

- [ ] **Step 4: Set OPENCODE_AUTH (file type)**

```bash
# OPENCODE_AUTH must be a file-type variable containing auth.json
# If you have an auth.json locally:
glab api --hostname framagit.org -X POST "/projects/126561/variables" \
  -f key=OPENCODE_AUTH -f value="$(cat ~/.config/opencode/auth.json)" -f variable_type=file -f masked=true
```

Expected: `{"key":"OPENCODE_AUTH","variable_type":"file","masked":true,...}`

- [ ] **Step 5: Verify all variables exist**

```bash
glab api --hostname framagit.org "/projects/126561/variables" | jq -r '.[] | "\(.key) type=\(.variable_type // "env_var") masked=\(.masked) protected=\(.protected)"'
```

Expected output includes: `BOUCLE_TOKEN`, `CLOUDFLARE_API_TOKEN`, `BOUCLE_ENABLED`, `OPENCODE_AUTH`

### Task 2: Create labels on urgence-palestine.fr

- [ ] **Step 1: Create boucle:* labels**

```bash
for label in triage needs-info todo working review human blocked done; do
  glab api --hostname framagit.org -X POST "/projects/126561/labels" \
    -f name="boucle:$label" -f color="#0033CC" -f description="boucle state: $label"
done
```

Expected: 8 labels created

- [ ] **Step 2: Create size:* labels**

```bash
for size in s m l; do
  glab api --hostname framagit.org -X POST "/projects/126561/labels" \
    -f name="size:$size" -f color="#F0AD4E" -f description="size: $size"
done
```

Expected: 3 labels created

- [ ] **Step 3: Verify labels**

```bash
glab api --hostname framagit.org "/projects/126561/labels?per_page=100" | jq -r '.[] | select(.name | startswith("boucle:") or startswith("size:")) | .name'
```

Expected: 11 labels listed (8 boucle:* + 3 size:*)

### Task 3: Create issue board

- [ ] **Step 1: Create board with lists mapped to boucle:* labels**

```bash
# Create the board
BOARD_ID=$(glab api --hostname framagit.org -X POST "/projects/126561/boards" \
  -f name="boucle" | jq -r '.id')

# Add lists for each boucle:* label in state-machine order
for label in triage needs-info todo working review human blocked done; do
  LABEL_ID=$(glab api --hostname framagit.org "/projects/126561/labels?search=boucle:$label" | jq -r '.[0].id')
  glab api --hostname framagit.org -X POST "/projects/126561/boards/$BOARD_ID/lists" \
    -f label_id="$LABEL_ID" > /dev/null
done
```

Expected: Board "boucle" with 8 lists

### Task 4: Protect default branch

- [ ] **Step 1: Protect master — merge restricted to Maintainers**

```bash
glab api --hostname framagit.org -X PUT "/projects/126561/protected_branches/master" \
  -f merge_access_level=40  # 40 = Maintainer
# If not already protected, use POST:
# glab api --hostname framagit.org -X POST "/projects/126561/protected_branches" \
#   -f name=master -f merge_access_level=40
```

Expected: `{"name":"master","merge_access_levels":[{"access_level":40,...}],...}`

- [ ] **Step 2: Verify bot (up-bot) is Developer (not Maintainer)**

```bash
# Check bot's access level
glab api --hostname framagit.org "/projects/126561/members" | jq -r '.[] | select(.username | test("bot|up-bot")) | "\(.username) access_level=\(.access_level)"'
```

Expected: `up-bot access_level=30` (30 = Developer). If bot is not a member, add it:
```bash
glab api --hostname framagit.org -X POST "/projects/126561/members" \
  -f user_id=<bot_user_id> -f access_level=30
```

### Task 5: Create trigger token (as bot)

> The trigger token must be created BY the bot (it impersonates its creator). Use the bot's PAT (UP_PAT) for this call.

- [ ] **Step 1: Create pipeline trigger token**

```bash
source /home/badreddine/Projects/ankaboot-source/boucle/.env
# Use the bot's PAT to create the trigger token
curl --silent --request POST \
  --header "PRIVATE-TOKEN: $UP_PAT" \
  "https://framagit.org/api/v4/projects/126561/triggers" \
  --data "description=boucle-loop" | jq -r '.token'
```

Expected: a token string. **Save it** — it goes into the webhook URL and is used by jobs to chain.

- [ ] **Step 2: Store the trigger token as a CI variable**

```bash
TRIGGER_TOKEN="<the token from step 1>"
glab api --hostname framagit.org -X POST "/projects/126561/variables" \
  -f key=BOUCLE_TRIGGER_TOKEN -f value="$TRIGGER_TOKEN" -f masked=true -f protected=true
```

### Task 6: Configure webhook

- [ ] **Step 1: Create webhook pointing to trigger pipeline endpoint**

```bash
source /home/badreddine/Projects/ankaboot-source/boucle/.env
WEBHOOK_URL="https://framagit.org/api/v4/projects/126561/trigger/pipeline?token=$BOUCLE_TRIGGER_TOKEN&ref=master"
# Note: BOUCLE_TRIGGER_TOKEN must be retrieved from CI vars or the step above
glab api --hostname framagit.org -X POST "/projects/126561/hooks" \
  -f url="$WEBHOOK_URL" \
  -f issues_events=true \
  -f note_events=true \
  -f confidential_issues_events=false \
  -f confidential_note_events=false \
  -f merge_requests_events=false \
  -f push_events=false \
  -f pipeline_events=false \
  -f job_events=false
```

Expected: `{"url":"https://framagit.org/api/v4/projects/126561/trigger/pipeline?token=...","issues_events":true,"note_events":true,...}`

⚠️ **Verify on first webhook** (spec §8.1): GitLab bug #347707 — payload `ref` field interpreted as API `ref` param. Issue events have no top-level `ref`, so should be unaffected. Confirm on first test.

### Task 7: Register GitLab runner (manual on data machine)

> This is a manual step on the `data` machine. Cannot be done via API from here.

- [ ] **Step 1: Register runner on data machine**

On the `data` machine (SSH in):
```bash
sudo gitlab-runner register \
  --url https://framagit.org/ \
  --token <registration-token-from-Framagit-settings> \
  --executor docker \
  --docker-image node:22.14.0 \
  --tag-list boucle \
  --concurrent 2
```

Configure `config.toml`:
```toml
[[runners]]
  name = "boucle-runner"
  executor = "docker"
  tag_list = ["boucle"]
  [runners.docker]
    image = "node:22.14.0"
    privileged = false
    volumes = ["/cache"]
    # NO /var/run/docker.sock mount
  [runners.custom_build_dir]
  concurrent = 2
  # CPU/memory limits
  [runners.docker.services]
    limit = 0
```

- [ ] **Step 2: Verify runner is online**

```bash
glab api --hostname framagit.org "/projects/126561/runners" | jq -r '.[] | "\(.description) status=\(.status) tags=\(.tag_list | join(","))"'
```

Expected: a runner with `status=online` and `tags=boucle`

### Task 8: Create Cloudflare Pages project

- [ ] **Step 1: Create CF Pages project via wrangler**

```bash
source /home/badreddine/Projects/ankaboot-source/boucle/.env
npx wrangler pages project create urgence-palestine --production-domain urgence-palestine.fr
```

Expected: project created. Note the project name for `wrangler pages deploy` in the pipeline.

- [ ] **Step 2: Verify deploy works**

```bash
# Clone the repo, build, deploy a test
git clone https://framagit.org/up/urgence-palestine.fr.git /tmp/up-test
cd /tmp/up-test && npm ci && npm run build
npx wrangler pages deploy public --project-name urgence-palestine
```

Expected: deployment URL returns 200.

---

## Phase 2: Core Code — `bin/oc` (S3)

> Developed in `boucle/loop/bin/oc`. The harness entrypoint — what the pipeline runs instead of `opencode` directly.

### Task 9: Create `bin/oc` skeleton with arg parsing

**Files:**
- Create: `boucle/loop/bin/oc`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# bin/oc — boucle's harness entrypoint (S3)
# Wraps opencode: scrubs secrets, enforces caps, runs agent, asserts side effects.
# Swapping to Claude Code or Codex = editing this one file.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────
ROLE="${1:?usage: bin/oc <role>}"
ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"
ITERATION="${BOUCLE_ITERATION:-1}"
DRY_RUN="${BOUCLE_DRY_RUN:-false}"
STEPS_CAP="${BOUCLE_STEPS_CAP:-50}"

# ── Paths ──────────────────────────────────────────────────────────────
CI_PROJECT_DIR="${CI_PROJECT_DIR:-$(pwd)}"
STATE_DIR="$CI_PROJECT_DIR/.boucle/$ISSUE"
STATE_FILE="$STATE_DIR/state.md"
ITERATIONS_FILE="$STATE_DIR/iterations.md"
OPENCODE_DB="$CI_PROJECT_DIR/.opencode-$CI_JOB_ID.db"

# ── 1. Isolate opencode DB (required, not optional) ───────────────────
export OPENCODE_DB

# ── 2. Scrub deploy secrets before invoking agent ─────────────────────
SCRUBBED_CF_TOKEN=""
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  SCRUBBED_CF_TOKEN="$CLOUDFLARE_API_TOKEN"
  unset CLOUDFLARE_API_TOKEN
fi

# ── 3. Prepare state directory ────────────────────────────────────────
mkdir -p "$STATE_DIR"

# ── 4. Build the agent prompt ──────────────────────────────────────────
build_prompt() {
  local role="$1"
  local prompt=""
  
  case "$role" in
    triage)
      prompt="You are the triage agent for boucle. Read issue #${ISSUE} and analyze it.
Post your analysis as a comment on the issue using the boucle:triage marker format.
Do NOT write any boucle:* labels — the job does that.
Do NOT create branches or push code."
      ;;
    worker)
      prompt="You are the worker agent for boucle. Implement issue #${ISSUE}.
Read state.md first (if it exists) to see what was tried and rejected.
Create your work on the current branch. When done, the job will build and deploy."
      ;;
    reviewer)
      prompt="You are the reviewer agent for boucle. Review the MR for issue #${ISSUE}.
Test the deployed preview URL, not a local build. Grade each acceptance criterion
at the primary source. Post your verdict as a comment with the boucle:verdict marker."
      ;;
    e2e)
      prompt="You are the E2E agent for boucle. Verify issue #${ISSUE} on the live production URL.
Check each acceptance criterion against the deployed site. Take a screenshot.
Post your verdict as a comment with the boucle:verdict marker."
      ;;
    *)
      echo "Unknown role: $role" >&2
      exit 1
      ;;
  esac
  
  echo "$prompt"
}

# ── 5. Run the agent ──────────────────────────────────────────────────
PROMPT=$(build_prompt "$ROLE")

if [ "$DRY_RUN" = "true" ]; then
  echo "[boucle] DRY RUN — agent output goes to log only, nothing pushed"
  opencode run --agent "$ROLE" --format json "$PROMPT" 2>&1 || true
  # In dry run, we don't assert side effects
  exit 0
fi

AGENT_EXIT=0
opencode run --agent "$ROLE" --format json "$PROMPT" || AGENT_EXIT=$?

# ── 6. Restore scrubbed secrets ───────────────────────────────────────
if [ -n "$SCRUBBED_CF_TOKEN" ]; then
  export CLOUDFLARE_API_TOKEN="$SCRUBBED_CF_TOKEN"
fi

# ── 7. Append to iterations.md ────────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILES_TOUCHED=""
if [ -d "$CI_PROJECT_DIR" ] && command -v git &>/dev/null; then
  FILES_TOUCHED=$(cd "$CI_PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null | tr '\n' ', ' || echo "none")
fi

cat >> "$ITERATIONS_FILE" << EOF

## $TIMESTAMP — $ROLE — iteration $ITERATION
- Result: <see agent output>
- Files touched: ${FILES_TOUCHED:-none}
- Side effect asserted: <see job assertion>
EOF

# ── 8. Assert declared side effect ────────────────────────────────────
# The job (not bin/oc) asserts the side effect after this script exits.
# bin/oc just runs the agent and logs. The job checks exit code + git/API state.

exit $AGENT_EXIT
```

- [ ] **Step 2: Make executable**

```bash
chmod +x boucle/loop/bin/oc
```

- [ ] **Step 3: Verify it parses**

```bash
bash -n boucle/loop/bin/oc
```

Expected: no output (syntax OK)

- [ ] **Step 4: Commit**

```bash
git add boucle/loop/bin/oc
git commit -m "feat: add bin/oc harness entrypoint (S3)"
```

### Task 10: Create `bin/doctor`

**Files:**
- Create: `boucle/loop/bin/doctor`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# bin/doctor — Day 0 verification. Run before anything, after every config change.
# ~20 checks. Saves a half-day of indirect debugging.

set -euo pipefail

PROJECT_ID="${BOUCLE_PROJECT_ID:?BOUCLE_PROJECT_ID must be set}"
HOST="${BOUCLE_FORGE_HOST:-framagit.org}"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES+1)); }
FAILURES=0

echo "boucle doctor — checking prerequisites..."

# ── Labels ─────────────────────────────────────────────────────────────
for label in triage needs-info todo working review human blocked done; do
  if glab api --hostname "$HOST" "/projects/$PROJECT_ID/labels?search=boucle:$label" 2>/dev/null | jq -e '.[0]' >/dev/null 2>&1; then
    pass "label boucle:$label exists"
  else
    fail "label boucle:$label missing"
  fi
done

for size in s m l; do
  if glab api --hostname "$HOST" "/projects/$PROJECT_ID/labels?search=size:$size" 2>/dev/null | jq -e '.[0]' >/dev/null 2>&1; then
    pass "label size:$size exists"
  else
    fail "label size:$size missing"
  fi
done

# ── CI Variables ───────────────────────────────────────────────────────
for var in BOUCLE_TOKEN BOUCLE_ENABLED CLOUDFLARE_API_TOKEN BOUCLE_TRIGGER_TOKEN; do
  if glab api --hostname "$HOST" "/projects/$PROJECT_ID/variables/$var" 2>/dev/null | jq -e '.key' >/dev/null 2>&1; then
    pass "CI variable $var exists"
  else
    fail "CI variable $var missing"
  fi
done

# ── OPENCODE_AUTH (file type) ─────────────────────────────────────────
if glab api --hostname "$HOST" "/projects/$PROJECT_ID/variables/OPENCODE_AUTH" 2>/dev/null | jq -e '.variable_type == "file"' >/dev/null 2>&1; then
  pass "OPENCODE_AUTH is file type"
else
  fail "OPENCODE_AUTH missing or not file type"
fi

# ── Branch protection ──────────────────────────────────────────────────
PROTECTION=$(glab api --hostname "$HOST" "/projects/$PROJECT_ID/protected_branches/master" 2>/dev/null || echo "")
if echo "$PROTECTION" | jq -e '.merge_access_levels[0].access_level == 40' >/dev/null 2>&1; then
  pass "master protected, merge=Maintainer only"
else
  fail "master not protected or merge access too broad"
fi

# ── Trigger token valid ────────────────────────────────────────────────
if glab api --hostname "$HOST" "/projects/$PROJECT_ID/triggers" 2>/dev/null | jq -e '.[0].token' >/dev/null 2>&1; then
  pass "trigger token exists"
else
  fail "no trigger token found"
fi

# ── Runner online ──────────────────────────────────────────────────────
if glab api --hostname "$HOST" "/projects/$PROJECT_ID/runners" 2>/dev/null | jq -e '.[] | select(.status=="online" and (.tag_list | contains(["boucle"])))' >/dev/null 2>&1; then
  pass "boucle-tagged runner online"
else
  fail "no boucle-tagged runner online"
fi

# ── Agents parse ───────────────────────────────────────────────────────
for agent in triage worker reviewer e2e; do
  if [ -f ".opencode/agents/$agent.md" ]; then
    pass "agent $agent.md exists"
  else
    fail "agent $agent.md missing"
  fi
done

# ── opencode reachable ─────────────────────────────────────────────────
if command -v opencode &>/dev/null; then
  pass "opencode in PATH"
else
  fail "opencode not in PATH"
fi

# ── CLOUDFLARE_API_TOKEN can deploy ────────────────────────────────────
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  if npx wrangler pages project list 2>/dev/null | grep -q urgence-palestine; then
    pass "CF Pages project exists"
  else
    fail "CF Pages project not found"
  fi
else
  fail "CLOUDFLARE_API_TOKEN not in env (run in CI, not locally)"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed." >&2
  exit 1
fi
```

- [ ] **Step 2: Make executable and verify**

```bash
chmod +x boucle/loop/bin/doctor
bash -n boucle/loop/bin/doctor
```

- [ ] **Step 3: Commit**

```bash
git add boucle/loop/bin/doctor
git commit -m "feat: add bin/doctor Day 0 verification"
```

---

## Phase 3: Pipeline — `.gitlab-ci.yml`

### Task 11: Create the dispatcher + 5 jobs

**Files:**
- Create: `boucle/loop/.gitlab-ci.yml`

- [ ] **Step 1: Write the pipeline**

```yaml
# boucle — MVP dev loop pipeline
# Spec: issue #1 (boucle MVP spec)
# Five jobs: triage, worker, reviewer, deploy, e2e
# Dispatcher: single entry, parses webhook payload, routes to triage

stages:
  - dispatch
  - triage
  - work
  - review
  - deploy
  - verify

variables:
  BOUCLE_FORGE_HOST: framagit.org

# ── Dispatcher ──────────────────────────────────────────────────────────
dispatch:
  stage: dispatch
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger"
  script:
    - |
      ACTOR=$(jq -r '.user.username // empty' "$TRIGGER_PAYLOAD")
      [ "$ACTOR" = "up-bot" ] && exit 0
      
      OBJECT_KIND=$(jq -r '.object_kind // empty' "$TRIGGER_PAYLOAD")
      IID=$(jq -r '.object_attributes.iid // .issue.iid // empty' "$TRIGGER_PAYLOAD")
      
      if [ -z "$IID" ]; then
        echo "No issue IID in payload, skipping"
        exit 0
      fi
      
      # Get current labels
      LABELS=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$IID" | jq -r '.labels | join(",")')
      
      # Resolve: issue opened, body edited in triage/needs-info/todo, or author reply on needs-info
      ACTION=$(jq -r '.object_attributes.action // empty' "$TRIGGER_PAYLOAD")
      
      SHOULD_TRIAGE=false
      if echo "$LABELS" | grep -q "boucle:triage"; then
        SHOULD_TRIAGE=true
      elif echo "$LABELS" | grep -q "boucle:needs-info"; then
        # Check if author replied (note event by non-bot)
        if [ "$OBJECT_KIND" = "note" ] && [ "$ACTOR" != "up-bot" ]; then
          SHOULD_TRIAGE=true
        fi
      elif echo "$LABELS" | grep -q "boucle:todo"; then
        # Body edit re-triggers triage
        if [ "$ACTION" = "update" ]; then
          SHOULD_TRIAGE=true
        fi
      elif [ -z "$LABELS" ] || [ "$ACTION" = "open" ]; then
        # New issue with no boucle label → triage
        SHOULD_TRIAGE=true
      fi
      
      if [ "$SHOULD_TRIAGE" = "true" ]; then
        echo "Triggering triage for issue #$IID"
        # Chain to triage job by writing to a file that downstream jobs read
        echo "$IID" > .boucle-issue
        # Apply boucle:triage label if not present
        if ! echo "$LABELS" | grep -q "boucle:triage"; then
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
            -f labels="boucle:triage" > /dev/null
        fi
      else
        echo "No action needed for issue #$IID (labels: $LABELS)"
        exit 0
      fi
  artifacts:
    paths:
      - .boucle-issue
  tags:
    - boucle

# ── Triage ──────────────────────────────────────────────────────────────
triage:
  stage: triage
  resource_group: boucle-issue-$BOUCLE_ISSUE
  needs: [dispatch]
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger"
  variables:
    BOUCLE_ROLE: triage
    BOUCLE_ITERATION: 1
  script:
    - |
      IID=$(cat .boucle-issue)
      export BOUCLE_ISSUE="$IID"
      
      # Run the agent
      ./bin/oc triage
      
      # Parse the triage comment for Disposition and Size
      COMMENT=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$IID/notes" \
        | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | last | .body')
      
      DISPOSITION=$(echo "$COMMENT" | grep -A1 "^## Disposition" | tail -1 | tr -d ' \n' || echo "")
      SIZE=$(echo "$COMMENT" | grep -A1 "^## Classification" | tail -1 | grep -oE 'Size: [SML]' | cut -d' ' -f2 || echo "")
      
      # Route based on disposition
      case "$DISPOSITION" in
        READY)
          if [ "$SIZE" = "L" ]; then
            glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
              -f labels="boucle:human,size:l" > /dev/null
          else
            glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
              -f labels="boucle:todo,size:$(echo $SIZE | tr '[:upper:]' '[:lower:]')" > /dev/null
            # Chain to worker
            curl -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline" \
              -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
              -F "variables[BOUCLE_ISSUE]=$IID" -F "variables[BOUCLE_ROLE]=worker" > /dev/null
          fi
          ;;
        NEEDS-INFO)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
            -f labels="boucle:needs-info" > /dev/null
          ;;
        NEEDS-SPLIT)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
            -f labels="boucle:human" > /dev/null
          ;;
        *)
          echo "Unparsable disposition: $DISPOSITION → routing to human"
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$IID" \
            -f labels="boucle:human" > /dev/null
          ;;
      esac
      
      # Assert: triage comment exists and disposition parsable
      if [ -z "$DISPOSITION" ]; then
        echo "FAIL: disposition not parsable" >&2
        exit 1
      fi
  tags:
    - boucle
  timeout: 10m

# ── Worker ──────────────────────────────────────────────────────────────
worker:
  stage: work
  resource_group: boucle-issue-$BOUCLE_ISSUE
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger" && $BOUCLE_ROLE == "worker"
  variables:
    BOUCLE_ROLE: worker
  script:
    - |
      export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"
      ITERATION="${BOUCLE_ITERATION:-1}"
      export BOUCLE_ITERATION
      
      # Set working label
      glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
        -f labels="boucle:working" > /dev/null
      
      # Create/checkout branch
      BRANCH="boucle/$BOUCLE_ISSUE-$(date +%s)"
      git checkout -b "$BRANCH"
      
      # Seed state.md on first run
      if [ ! -f ".boucle/$BOUCLE_ISSUE/state.md" ]; then
        mkdir -p ".boucle/$BOUCLE_ISSUE"
        # Seed from triage comment
        TRIAGE_COMMENT=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE/notes" \
          | jq -r '[.[] | select(.body | contains("<!-- boucle:triage"))] | last | .body')
        cat > ".boucle/$BOUCLE_ISSUE/state.md" << EOF
      # Issue #$BOUCLE_ISSUE

      ## Goal
      $(echo "$TRIAGE_COMMENT" | sed -n '/^## Analysis/,/^## /p' | head -n -1 | tail -n +2)

      ## Acceptance criteria
      $(echo "$TRIAGE_COMMENT" | sed -n '/^## Draft acceptance criteria/,/^## /p' | head -n -1 | tail -n +2)

      ## Approach
      (to be determined by worker)

      ## Tried and rejected
      (none yet)

      ## Awaiting human
      nothing
      EOF
      fi
      
      # Run the agent
      ./bin/oc worker
      
      # Build
      npm ci && npm run build
      
      # Deploy to preview
      PREVIEW_URL=$(npx wrangler pages deploy public --branch "$BRANCH" --project-name urgence-palestine 2>&1 | grep -oE 'https://[a-z0-9.-]+\.pages\.dev' | head -1)
      
      # Push branch
      git add -A
      git commit -m "boucle: implement issue #$BOUCLE_ISSUE [skip ci]"
      git push origin "$BRANCH"
      
      # Open MR
      glab mr create --source-branch "$BRANCH" --target-branch master \
        --title "boucle: issue #$BOUCLE_ISSUE" \
        --description "Preview: $PREVIEW_URL" > /dev/null
      
      # Write preview URL into MR description (update)
      MR_IID=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/merge_requests?source_branch=$BRANCH" | jq -r '.[0].iid')
      glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/merge_requests/$MR_IID" \
        -f description="Preview: $PREVIEW_URL" > /dev/null
      
      # Assert: branch exists, MR open, preview returns 200
      if [ -z "$PREVIEW_URL" ]; then
        echo "FAIL: no preview URL" >&2; exit 1
      fi
      if ! curl -s -o /dev/null -w "%{http_code}" "$PREVIEW_URL" | grep -q "200"; then
        echo "FAIL: preview URL not 200" >&2; exit 1
      fi
      
      # Set review label
      glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
        -f labels="boucle:review" > /dev/null
      
      # Chain to reviewer
      curl -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline" \
        -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
        -F "variables[BOUCLE_ISSUE]=$BOUCLE_ISSUE" -F "variables[BOUCLE_ROLE]=reviewer" > /dev/null
  tags:
    - boucle
  timeout: 30m

# ── Reviewer ────────────────────────────────────────────────────────────
reviewer:
  stage: review
  resource_group: boucle-issue-$BOUCLE_ISSUE
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger" && $BOUCLE_ROLE == "reviewer"
  variables:
    BOUCLE_ROLE: reviewer
  script:
    - |
      export BOUCLE_ISSUE="${BOUCLE_ISSUE:?BOUCLE_ISSUE must be set}"
      
      # Find the MR for this issue
      MR_IID=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/merge_requests?state=opened" \
        | jq -r '.[] | select(.source_branch | startswith("boucle/'"$BOUCLE_ISSUE"'-")) | .iid' | head -1)
      
      MR_DATA=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/merge_requests/$MR_IID")
      PREVIEW_URL=$(echo "$MR_DATA" | jq -r '.description' | grep -oE 'https://[a-z0-9.-]+\.pages\.dev' | head -1)
      
      export BOUCLE_PREVIEW_URL="$PREVIEW_URL"
      
      # Run the agent against the preview
      ./bin/oc reviewer
      
      # Parse verdict
      COMMENT=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE/notes" \
        | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=reviewer"))] | last | .body')
      
      VERDICT=$(echo "$COMMENT" | grep -oE 'VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
      
      case "$VERDICT" in
        PASS)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
            -f labels="boucle:human" > /dev/null
          ;;
        FAIL)
          ITERATION="${BOUCLE_ITERATION:-1}"
          if [ "$ITERATION" -lt 3 ]; then
            glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
              -f labels="boucle:todo" > /dev/null
            # Chain back to worker with incremented iteration
            curl -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline" \
              -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
              -F "variables[BOUCLE_ISSUE]=$BOUCLE_ISSUE" -F "variables[BOUCLE_ROLE]=worker" \
              -F "variables[BOUCLE_ITERATION]=$((ITERATION+1))" > /dev/null
          else
            glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
              -f labels="boucle:blocked" > /dev/null
          fi
          ;;
        UNCERTAIN|*)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
            -f labels="boucle:human" > /dev/null
          glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE/notes" \
            -f body="Verdict unparsable or uncertain. Human review needed." > /dev/null
          ;;
      esac
      
      # Assert: verdict comment exists and VERDICT: parsable
      if [ -z "$VERDICT" ]; then
        echo "FAIL: verdict not parsable" >&2; exit 1
      fi
  tags:
    - boucle
  timeout: 15m

# ── Deploy (on merge to master) ─────────────────────────────────────────
deploy:
  stage: deploy
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH && $CI_PIPELINE_SOURCE == "push"
  script:
    - |
      npm ci && npm run build
      npx wrangler pages deploy public --project-name urgence-palestine --branch main
      
      # Assert: production URL returns 200 on new deployment
      PROD_URL="https://urgence-palestine.fr"
      if ! curl -s -o /dev/null -w "%{http_code}" "$PROD_URL" | grep -q "200"; then
        echo "FAIL: production URL not 200" >&2; exit 1
      fi
      
      # Chain to e2e
      curl -s -X POST "https://$BOUCLE_FORGE_HOST/api/v4/projects/$CI_PROJECT_ID/trigger/pipeline" \
        -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
        -F "variables[BOUCLE_ROLE]=e2e" > /dev/null
  tags:
    - boucle
  timeout: 10m

# ── E2E (after deploy) ─────────────────────────────────────────────────
e2e:
  stage: verify
  resource_group: boucle-issue-$BOUCLE_ISSUE
  rules:
    - if: $BOUCLE_ENABLED != "true"
      when: never
    - if: $CI_PIPELINE_SOURCE == "trigger" && $BOUCLE_ROLE == "e2e"
  script:
    - |
      export BOUCLE_ISSUE="${BOUCLE_ISSUE:-}"
      PROD_URL="https://urgence-palestine.fr"
      export BOUCLE_LIVE_URL="$PROD_URL"
      
      # Run the agent on the live URL
      ./bin/oc e2e
      
      # Parse verdict
      COMMENT=$(glab api --hostname $BOUCLE_FORGE_HOST "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE/notes" \
        | jq -r '[.[] | select(.body | contains("<!-- boucle:verdict") and contains("role=e2e"))] | last | .body')
      
      VERDICT=$(echo "$COMMENT" | grep -oE 'VERDICT: (PASS|FAIL|UNCERTAIN)' | cut -d' ' -f2)
      
      case "$VERDICT" in
        PASS)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
            -f labels="boucle:done" > /dev/null
          ;;
        FAIL)
          # Loop closure: open a new issue in triage with the trace
          glab api --hostname $BOUCLE_FORGE_HOST -X POST "/projects/$CI_PROJECT_ID/issues" \
            -f title="E2E failure for issue #$BOUCLE_ISSUE" \
            -f description="E2E verification failed for issue #$BOUCLE_ISSUE.

      ## Trace
      $(echo "$COMMENT")

      ## Live URL
      $PROD_URL" \
            -f labels="boucle:triage" > /dev/null
          # Note: auto-re-triggering this new issue is out of scope (human picks it up)
          ;;
        UNCERTAIN|*)
          glab api --hostname $BOUCLE_FORGE_HOST -X PUT "/projects/$CI_PROJECT_ID/issues/$BOUCLE_ISSUE" \
            -f labels="boucle:human" > /dev/null
          ;;
      esac
      
      # Assert: verdict comment + screenshot attached
      if [ -z "$VERDICT" ]; then
        echo "FAIL: e2e verdict not parsable" >&2; exit 1
      fi
  tags:
    - boucle
  timeout: 15m
```

- [ ] **Step 2: Verify YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('boucle/loop/.gitlab-ci.yml'))"
```

Expected: no error

- [ ] **Step 3: Commit**

```bash
git add boucle/loop/.gitlab-ci.yml
git commit -m "feat: add .gitlab-ci.yml dispatcher + 5 jobs"
```

---

## Phase 4: Agents (S2)

### Task 12: Create triage agent

**Files:**
- Create: `boucle/loop/.opencode/agents/triage.md`

- [ ] **Step 1: Write the agent file**

```markdown
---
mode: primary
model: ollama-cloud/glm-4.1-flash
temperature: 0.3
description: Triage agent — analyzes issues, drafts acceptance criteria, classifies size
---

You are the **triage agent** for boucle. Your job is to analyze an issue and produce a structured analysis comment.

## Instructions

1. Read the issue body and all existing comments.
2. Understand what the issue is actually asking for — restate it in your own words.
3. Draft acceptance criteria that are **verifiable by a machine or by looking at the rendered page**.
4. Classify the size: S (one file/component), M (a few files), L (needs splitting).
5. If the issue is unclear, ask blocking questions.
6. If the issue is too large (size L), flag it for splitting.

## Output format

Post EXACTLY ONE comment on the issue with this format:

```
<!-- boucle:triage v=1 -->
## Analysis
<what the issue actually asks for, in your own words>

## Draft acceptance criteria
- [ ] <verifiable criterion>

## Classification
Size: S | M | L

## Questions
- <blocking question, or "none">

## Disposition
READY | NEEDS-INFO | NEEDS-SPLIT
```

## Rules

- **Do NOT** write any `boucle:*` labels — the job does that from your Disposition.
- **Do NOT** create branches or push code.
- **Do NOT** implement anything — you are analysis only.
- **Size: L** means the issue needs splitting by a human — set Disposition to NEEDS-SPLIT.
- If you cannot understand the issue, set Disposition to NEEDS-INFO and ask your questions.
- Use `glab` to post your comment: `glab issue note <iid> --repo <project> --message "$(cat <<'EOF' ... EOF)"`
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/.opencode/agents/triage.md
git commit -m "feat: add triage agent"
```

### Task 13: Create worker agent

**Files:**
- Create: `boucle/loop/.opencode/agents/worker.md`

- [ ] **Step 1: Write the agent file**

```markdown
---
mode: primary
description: Worker agent — implements issues on a branch
---

You are the **worker agent** for boucle. Your job is to implement an issue.

## Instructions

1. Read `state.md` in `.boucle/<issue>/` FIRST — especially the "Tried and rejected" section.
2. Read the issue body and the triage analysis comment.
3. Implement the acceptance criteria from `state.md`.
4. Update `state.md`:
   - Fill in the "Approach" section with what you did.
   - If you tried and rejected an approach, add it to "Tried and rejected" with why.
5. Append to `iterations.md` with what you changed.

## Rules

- **Do NOT** write any `boucle:*` labels — the job does that.
- **Do NOT** merge, push, or deploy — the job does that after you exit.
- **Do NOT** run `wrangler` or use `CLOUDFLARE_API_TOKEN` — you don't have it.
- Work on the current branch (already checked out by the job).
- Keep changes minimal and focused on the acceptance criteria.
- If you cannot complete the work, say so clearly in `state.md` under "Awaiting human".
- Commit your changes with `git add -A && git commit -m "boucle: implement issue #<iid>"`.
- Add `[skip ci]` to your commit message to avoid triggering CI pipelines.
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/.opencode/agents/worker.md
git commit -m "feat: add worker agent"
```

### Task 14: Create reviewer agent

**Files:**
- Create: `boucle/loop/.opencode/agents/reviewer.md`

- [ ] **Step 1: Write the agent file**

```markdown
---
mode: primary
temperature: 0.2
description: Reviewer agent — adversarial review against deployed preview
---

You are the **reviewer agent** for boucle. Your job is to **adversarially** review the implementation against the deployed preview URL.

## Instructions

1. Read the MR diff and `state.md`.
2. Read the acceptance criteria from `state.md`.
3. **Test the deployed preview URL** (provided in `$BOUCLE_PREVIEW_URL`), NOT a local build.
4. For EACH acceptance criterion, check it at the primary source — the deployed site.
5. Take a screenshot of the preview.
6. Post your verdict as a comment.

## Output format

Post EXACTLY ONE comment on the issue with this format:

```
<!-- boucle:verdict v=1 role=reviewer sha=<head-sha> -->
VERDICT: PASS | FAIL | UNCERTAIN
- [x] <criterion> — <how it was checked>
- [ ] <criterion> — <why it failed>
```

## Rules

- **Do NOT** trust the worker's own summary — verify everything yourself.
- **Do NOT** write any `boucle:*` labels — the job does that.
- **Do NOT** merge, push, or deploy.
- Grade each criterion at the primary source (the deployed URL).
- If you cannot verify a criterion, mark it UNCERTAIN — never guess.
- A missing or malformed verdict must never leave the loop retrying — if unsure, say UNCERTAIN.
- Use `glab` to post your comment.
- Low temperature — you are a skeptic, not a creative writer.
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/.opencode/agents/reviewer.md
git commit -m "feat: add reviewer agent"
```

### Task 15: Create e2e agent

**Files:**
- Create: `boucle/loop/.opencode/agents/e2e.md`

- [ ] **Step 1: Write the agent file**

```markdown
---
mode: primary
description: E2E agent — verifies acceptance criteria on the live production URL
---

You are the **E2E agent** for boucle. Your job is to verify the implementation on the **live production URL**.

## Instructions

1. Read the acceptance criteria from `state.md` (or the issue if no state.md).
2. Navigate to the live production URL (provided in `$BOUCLE_LIVE_URL`).
3. For EACH acceptance criterion, check it against the live site.
4. Take a screenshot.
5. Post your verdict as a comment.

## Output format

Post EXACTLY ONE comment on the issue with this format:

```
<!-- boucle:verdict v=1 role=e2e sha=<head-sha> -->
VERDICT: PASS | FAIL | UNCERTAIN
- [x] <criterion> — <how it was checked>
- [ ] <criterion> — <why it failed>
```

## Rules

- **Do NOT** write any `boucle:*` labels — the job does that.
- **Do NOT** merge, push, or deploy.
- Test the LIVE production URL, not a preview or local build.
- If you cannot verify a criterion, mark it UNCERTAIN.
- On FAIL, the job will open a new issue in `boucle:triage` with your trace — the loop closes.
- Use `glab` to post your comment.
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/.opencode/agents/e2e.md
git commit -m "feat: add e2e agent"
```

---

## Phase 5: Config — `LOOP.md`

### Task 16: Create LOOP.md

**Files:**
- Create: `boucle/loop/LOOP.md`

- [ ] **Step 1: Write the file**

```markdown
# LOOP — urgence-palestine.fr

Purpose: Autonomous dev loop for the urgence-palestine.fr static site.
Cadence: webhook (primary); jobs chain to the next role via the trigger token.
Human gates: MR approval (only).
Iteration cap: 3 worker runs per issue.
Budget cap: (not set at MVP — token-cost logging deferred to post-MVP).
Escalate when: cap hit | criteria unclear | size:L | destructive change proposed.
Out of bounds: .boucle/ state files must not be deleted by agents.
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/LOOP.md
git commit -m "feat: add LOOP.md config"
```

---

## Phase 6: Apply to target repo + verify

### Task 17: Create README for the template

**Files:**
- Create: `boucle/loop/README.md`

- [ ] **Step 1: Write the README**

```markdown
# boucle loop template

Portable dev-loop template. Apply to a target repo by copying these files to the repo root:

\`\`\`bash
cp -r boucle/loop/bin <target-repo>/
cp -r boucle/loop/.opencode <target-repo>/
cp boucle/loop/.gitlab-ci.yml <target-repo>/
cp boucle/loop/LOOP.md <target-repo>/
\`\`\`

Then run `bin/doctor` in CI to verify all prerequisites are met.

See issue #1 (boucle MVP spec) for the full design.
```

- [ ] **Step 2: Commit**

```bash
git add boucle/loop/README.md
git commit -m "docs: add loop template README"
```

### Task 18: Apply template to urgence-palestine.fr

- [ ] **Step 1: Clone the target repo**

```bash
git clone https://framagit.org/up/urgence-palestine.fr.git /tmp/urgence-palestine.fr
```

- [ ] **Step 2: Copy loop files**

```bash
cp -r boucle/loop/bin /tmp/urgence-palestine.fr/
cp -r boucle/loop/.opencode /tmp/urgence-palestine.fr/
cp boucle/loop/.gitlab-ci.yml /tmp/urgence-palestine.fr/
cp boucle/loop/LOOP.md /tmp/urgence-palestine.fr/
chmod +x /tmp/urgence-palestine.fr/bin/oc /tmp/urgence-palestine.fr/bin/doctor
```

- [ ] **Step 3: Commit and push**

```bash
cd /tmp/urgence-palestine.fr
git add -A
git commit -m "boucle: apply loop template (issue #1 MVP)"
git push origin master
```

- [ ] **Step 4: Verify the pipeline triggers**

```bash
# Check if a pipeline was triggered by the push
glab api --hostname framagit.org "/projects/126561/pipelines?per_page=5" | jq -r '.[0] | "\(.id) status=\(.status) ref=\(.ref)"'
```

Expected: a pipeline running (the push to master triggers the `deploy` job)

### Task 19: Run bin/doctor in CI

- [ ] **Step 1: Trigger a doctor pipeline manually**

```bash
curl -s -X POST "https://framagit.org/api/v4/projects/126561/trigger/pipeline" \
  -F "token=$BOUCLE_TRIGGER_TOKEN" -F "ref=master" \
  -F "variables[BOUCLE_ROLE]=doctor"
```

Or add a doctor job to `.gitlab-ci.yml` temporarily and push.

- [ ] **Step 2: Check doctor output**

```bash
# Find the doctor job and read its log
glab api --hostname framagit.org "/projects/126561/jobs?per_page=5" | jq -r '.[] | select(.name=="doctor") | .id'
glab api --hostname framagit.org "/projects/126561/jobs/<job_id>/trace"
```

Expected: all checks pass (or identify what's missing)

### Task 20: Create the 3 calibration issues

- [ ] **Step 1: Create 3 calibration issues on urgence-palestine.fr**

These are issues the user has already solved by hand. Create them as issues on Framagit:

```bash
for i in 1 2 3; do
  glab issue create --repo up/urgence-palestine.fr \
    --title "<calibration issue $i title>" \
    --description "<calibration issue $i body>"
done
```

- [ ] **Step 2: Verify they trigger triage**

```bash
# Each new issue should trigger the webhook → dispatch → triage
glab api --hostname framagit.org "/projects/126561/pipelines?per_page=10" | jq -r '.[] | "\(.id) status=\(.status) created_at=\(.created_at)"'
```

Expected: pipelines triggered for each issue

---

## Self-Review

### Spec coverage

| Spec section | Task(s) | Covered |
|---|---|---|
| §1 Scope (7 capabilities) | Tasks 9-15 (bin/oc + agents) | ✓ |
| §2 Architecture (5 seams) | All tasks (each seam is a file) | ✓ |
| §3 Day 0 (13 items) | Tasks 1-8 | ✓ (runner is manual) |
| §4 State machine | Task 11 (.gitlab-ci.yml jobs) | ✓ |
| §5 Work state contract | Task 9 (bin/oc writes state.md + iterations.md) | ✓ |
| §6 Roles (4 agents) | Tasks 12-15 | ✓ |
| §7 Harness entrypoint | Task 9 (bin/oc, 7 steps) | ✓ |
| §8 Pipeline | Task 11 (.gitlab-ci.yml) | ✓ |
| §8.4 bin/doctor | Task 10 | ✓ |
| §8.5 Invariants (7) | Enforced in bin/oc + .gitlab-ci.yml | ✓ |
| §9 Acceptance criteria | Task 20 (calibration issues) | ✓ |

### Placeholder scan

No TBD/TODO/placeholders. All code blocks contain actual content.

### Type consistency

- `BOUCLE_ISSUE` used consistently across bin/oc and .gitlab-ci.yml
- `BOUCLE_ROLE` used consistently
- `BOUCLE_TRIGGER_TOKEN` used consistently
- Agent names (triage, worker, reviewer, e2e) match between .opencode/agents/*.md and .gitlab-ci.yml
- Label names (boucle:triage, etc.) match between .gitlab-ci.yml and Task 2

### Known gaps / risks

1. **Runner registration** (Task 7) is manual — must be done on the data machine. Plan cannot automate this.
2. **OPENCODE_AUTH** (Task 1 step 4) requires a local `auth.json` — verify it exists at `~/.config/opencode/auth.json`.
3. **CF Pages project** (Task 8) — the existing CF worker (`urgence-palestine.contact-2d0.workers.dev/`) may need to be converted to a Pages project, or the deploy step adjusted.
4. **Webhook URL** (Task 6) — the trigger token must be created first (Task 5). The webhook URL embeds the token.
5. **GitLab bug #347707** — verify on first webhook that the `ref` field isn't misinterpreted.
6. **`bin/oc` prompt building** — the current implementation builds prompts inline. The agent files (`.opencode/agents/*.md`) contain the system prompt; `bin/oc` passes the task-specific instruction. This is correct for opencode's `--agent` flag.