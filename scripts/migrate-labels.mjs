#!/usr/bin/env node
// scripts/migrate-labels.mjs — relabel existing issues from the legacy
// single-colon `boucle:*` label scheme to the new double-colon scoped
// scheme (`boucle::*` for the detail axis, `loop::*` for the gross axis).
//
// Why this script exists
// ----------------------
// Boucle used to drive its lifecycle with ordinary labels of the form
// `boucle:triage`, `boucle:todo`, `boucle:needs-info`, …, all sharing a
// single namespace. It now uses scoped labels with TWO independent axes:
//
//   - `boucle::<detail>` — the bucket inside the boucle loop
//     (e.g. `boucle::triage`, `boucle::todo`, `boucle::needs-info`).
//   - `loop::<gross>` — who owns the work at this instant
//     (`loop::bot`, `loop::human`, `loop::done`).
//
// The mapping table below is the source of truth for the transition.
// `boucle:approved` and `boucle:spec-approved` are dropped (no successor);
// `boucle:blocked` is *fused* into `boucle::human` + `loop::human`. Size
// labels (`size:s`, `size:m`, `size:l`) and any other non-boucle labels
// are preserved untouched.
//
// Usage
// -----
//   node scripts/migrate-labels.mjs                        # dry-run
//   node scripts/migrate-labels.mjs --apply                # actually write
//   node scripts/migrate-labels.mjs --project group/foo    # pick a project
//
// The default project is read from $CI_PROJECT_ID (when running under
// GitLab CI). The default forge host is read from $BOUCLE_FORGE_HOST,
// falling back to "framagit.org". Authentication relies on the ambient
// `glab` CLI having already logged in or being supplied a token via
// `GITLAB_TOKEN` / `GITLAB_ACCESS_TOKEN` / `glab auth login`.
//
// Exits 0 on success (whether dry-run or apply), or 1 if any --apply
// call failed. Re-running the script is safe: issues already carrying
// any `boucle::*` label are reported and skipped.

import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

// ---- configuration ----------------------------------------------------------

// Old `boucle:*` label → new detail label (single colon, human-facing).
// For most labels this is identity (the detail axis reverts to the original
// single-colon scheme). null means "drop this label, do NOT add a successor"
// (used for `boucle:approved` and `boucle:spec-approved`, which are dead/transient).
const DETAIL_MAP = new Map([
  ["boucle:triage", "boucle:triage"],
  ["boucle:todo", "boucle:todo"],
  ["boucle:working", "boucle:working"],
  ["boucle:review", "boucle:review"],
  ["boucle:merging", "boucle:merging"],
  ["boucle:split", "boucle:split"],
  ["boucle:needs-info", "boucle:needs-info"],
  ["boucle:spec-review", "boucle:spec-review"],
  ["boucle:approval", "boucle:approval"],
  ["boucle:human", "boucle:human"],
  // `boucle:blocked` does NOT appear here: it's fused, see BLOCKED_DETAIL.
  ["boucle:done", "boucle:done"],
]);

// Old `boucle:*` label → new `boucle::status::*` gross (nested scoped, board columns).
const GROSS_MAP = new Map([
  ["boucle:triage", "boucle::status::bot"],
  ["boucle:todo", "boucle::status::bot"],
  ["boucle:working", "boucle::status::bot"],
  ["boucle:review", "boucle::status::bot"],
  ["boucle:merging", "boucle::status::bot"],
  ["boucle:split", "boucle::status::bot"],
  ["boucle:needs-info", "boucle::status::human"],
  ["boucle:spec-review", "boucle::status::human"],
  ["boucle:approval", "boucle::status::human"],
  ["boucle:human", "boucle::status::human"],
  ["boucle:done", "boucle::status::done"],
]);

// `boucle:blocked` is special: it has no direct equivalent in the new
// scheme, so we fold it into the `boucle:human` / `boucle::status::human` pair.
const BLOCKED_DETAIL = "boucle:human";
const BLOCKED_GROSS = "boucle::status::human";

// Intermediate-scheme normalization: projects migrated to the short-lived
// `boucle::*` + `loop::*` scheme need those labels converted back to the
// final scheme. This map reverts intermediate detail labels to single colon.
const INTERMEDIATE_DETAIL = new Map([
  ["boucle::triage", "boucle:triage"],
  ["boucle::todo", "boucle:todo"],
  ["boucle::working", "boucle:working"],
  ["boucle::review", "boucle:review"],
  ["boucle::merging", "boucle:merging"],
  ["boucle::split", "boucle:split"],
  ["boucle::needs-info", "boucle:needs-info"],
  ["boucle::spec-review", "boucle:spec-review"],
  ["boucle::approval", "boucle:approval"],
  ["boucle::human", "boucle:human"],
  ["boucle::done", "boucle:done"],
]);

// Intermediate gross labels: `loop::*` → `boucle::status::*`.
const INTERMEDIATE_GROSS = new Map([
  ["loop::bot", "boucle::status::bot"],
  ["loop::human", "boucle::status::human"],
  ["loop::done", "boucle::status::done"],
]);

// ---- helpers ----------------------------------------------------------------

const log = (...args) => console.log("[migrate-labels]", ...args);
const warn = (...args) => console.warn("[migrate-labels] WARN", ...args);
const err = (...args) => console.error("[migrate-labels] ERROR", ...args);

// Run `glab` and return parsed JSON. We use Node's built-in JSON.parse
// directly (rather than shelling out to `jq` the way the bash scripts
// do) because we're already in a Node process — one fewer fork per
// API call matters less in bash, but here the script may iterate over
// hundreds of issues.
function glabJSON(args, { allowEmpty = false } = {}) {
  const out = execFileSync("glab", args, {
    encoding: "utf8",
    // Suppress glab's stderr noise (update notifier, etc.) — matches the
    // suppression done in CI: see .gitlab-ci.yml `silence-glab()` step.
    stdio: ["ignore", "pipe", "pipe"],
  });
  const text = out.trim();
  if (!text) {
    if (allowEmpty) return null;
    throw new Error(`empty response from glab ${args.join(" ")}`);
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(`invalid JSON from glab ${args.join(" ")}: ${(e).message}\n--- body ---\n${text}\n--- end ---`);
  }
}

function glabString(args) {
  const out = execFileSync("glab", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return out.trim();
}

// Decide which new labels an issue should receive, given its current
// label set. Returns { next, dropped, added, fused }. `next` is the full
// ordered label list to PUT back; `dropped`/`added`/`fused` are just for
// the per-issue log line.
function planNewLabels(currentLabels) {
  // Partition: non-boucle/loop labels are kept verbatim; boucle:* and loop::*
  // labels are translated via the mapping tables above.
  const keptNonBoucle = [];
  const oldBoucle = [];
  for (const l of currentLabels) {
    if (l.startsWith("boucle:") || l.startsWith("loop::")) oldBoucle.push(l);
    else keptNonBoucle.push(l);
  }

  const added = new Set();
  const dropped = [];
  const fused = [];

  for (const old of oldBoucle) {
    // Dead / transient — no successor.
    if (old === "boucle:approved" || old === "boucle:spec-approved") {
      dropped.push(old);
      continue;
    }
    // Fuses into the human pair.
    if (old === "boucle:blocked") {
      dropped.push(old);
      fused.push(old);
      added.add(BLOCKED_DETAIL);
      added.add(BLOCKED_GROSS);
      continue;
    }

    // Intermediate-scheme detail labels (boucle::triage etc.) → revert to single colon.
    if (INTERMEDIATE_DETAIL.has(old)) {
      dropped.push(old);
      added.add(INTERMEDIATE_DETAIL.get(old));
      continue;
    }
    // Intermediate-scheme gross labels (loop::bot etc.) → boucle::status::*.
    if (INTERMEDIATE_GROSS.has(old)) {
      dropped.push(old);
      added.add(INTERMEDIATE_GROSS.get(old));
      continue;
    }

    // Original single-colon scheme: map via DETAIL_MAP + GROSS_MAP.
    const detail = DETAIL_MAP.get(old);
    const gross = GROSS_MAP.get(old);
    dropped.push(old);
    if (detail) added.add(detail);
    if (gross) added.add(gross);
  }

  // Preserve insertion order of non-boucle labels, then append new ones
  // in the order they were added (which mirrors the mapping table).
  const next = [...keptNonBoucle, ...added];
  return {
    next,
    dropped,
    added: [...added],
    fused,
    hadBoucle: oldBoucle.length > 0,
  };
}

function isAlreadyMigrated(labels) {
  // Final scheme: issues already have boucle::status::* gross labels.
  // Intermediate scheme (boucle::triage + loop::bot) is NOT "already migrated".
  return labels.some((l) => l.startsWith("boucle::status::"));
}

// ---- main -------------------------------------------------------------------

function parseArgs(argv) {
  const out = { apply: false, project: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") out.apply = true;
    else if (a === "--dry-run") out.apply = false;
    else if (a === "--project") {
      out.project = argv[++i];
    } else if (a === "--help" || a === "-h") {
      console.log(
        "Usage: node scripts/migrate-labels.mjs [--apply] [--project <path|id>]",
      );
      process.exit(0);
    } else {
      warn(`ignoring unknown arg: ${a}`);
    }
  }
  return out;
}

async function main() {
  const { apply, project } = parseArgs(process.argv.slice(2));

  const HOST = process.env.BOUCLE_FORGE_HOST || "framagit.org";
  // CI_PROJECT_ID is a number; we accept it as either number-string or a
  // project path (e.g. "group/subgroup/foo"). The glab CLI's URL form
  // accepts either, but URL-encoding of "/" must happen before reaching
  // the shell — glab's URL parser handles unencoded slashes fine, but
  // we normalise here to match the rest of the project's style.
  const projectRef =
    project || process.env.CI_PROJECT_ID || process.env.BOUCLE_PROJECT_ID;
  if (!projectRef) {
    err(
      "no project specified — pass --project <path> or set CI_PROJECT_ID / BOUCLE_PROJECT_ID",
    );
    process.exit(2);
  }
  const PID = String(projectRef);

  log(`Forge host : ${HOST}`);
  log(`Project    : ${PID}`);
  log(`Mode       : ${apply ? "APPLY (writes to GitLab)" : "DRY-RUN (no writes)"}`);
  log("");

  // Paginate through all open issues. We use per_page=100 (the max
  // GitLab exposes for issues) and follow `x-next-page` via the link
  // header — but `glab api -F per_page=100` doesn't expose headers, so
  // we walk pages by re-requesting with `page=N`. If we ever see
  // <per_page issues returned, we know it's the last page.
  const issues = [];
  for (let page = 1; ; page++) {
    const batch = glabJSON([
      "api",
      "--hostname",
      HOST,
      `/projects/${encodeURIComponent(PID)}/issues?state=opened&per_page=100&page=${page}`,
    ]);
    if (!Array.isArray(batch) || batch.length === 0) break;
    for (const issue of batch) issues.push(issue);
    if (batch.length < 100) break;
    if (page > 200) {
      // Safety stop — prevent infinite loops on misbehaving endpoints.
      warn(`stopped paginating at page ${page}`);
      break;
    }
  }

  log(`Scanned ${issues.length} open issue(s).`);
  log("");

  // Counters
  let alreadyMigrated = 0;
  let noBoucleLabels = 0;
  let toMigrate = 0;
  let applied = 0;
  const errors = [];

  // Cache so we don't re-run the planning pass twice for issues we'd
  // skip anyway.
  const plans = [];
  for (const issue of issues) {
    const iid = issue.iid;
    const currentLabels = Array.isArray(issue.labels) ? issue.labels : [];

    if (isAlreadyMigrated(currentLabels)) {
      alreadyMigrated++;
      if (!apply) log(`Issue #${iid}: already migrated (has boucle::*) — skip`);
      continue;
    }

    const plan = planNewLabels(currentLabels);
    if (!plan.hadBoucle) {
      noBoucleLabels++;
      if (!apply) log(`Issue #${iid}: no boucle labels — skip`);
      continue;
    }
    toMigrate++;

    // Show every would-be change in dry-run; in --apply, only log when
    // we're about to write (the success line comes after the PUT).
    if (!apply) {
      log(
        `Issue #${iid}: [${currentLabels.join(", ")}] → [${plan.next.join(", ")}]`,
      );
      if (plan.dropped.length || plan.fused.length) {
        const notes = [];
        if (plan.dropped.length) notes.push(`dropped: ${plan.dropped.join(", ")}`);
        if (plan.fused.length) notes.push(`fused: ${plan.fused.join(", ")}`);
        log(`           ${notes.join(" | ")}`);
      }
    }
    plans.push({ iid, currentLabels, plan });
  }

  if (!apply) {
    log("");
    log("──────────────────────────────────");
    log(`Total open issues         : ${issues.length}`);
    log(`Need migration            : ${toMigrate}`);
    log(`Already migrated (skip)   : ${alreadyMigrated}`);
    log(`No boucle labels (skip)   : ${noBoucleLabels}`);
    log("");
    log("Re-run with --apply to actually write the changes.");
    process.exit(0);
  }

  // --apply mode: actually PUT each planned set.
  log(`Applying changes to ${plans.length} issue(s)…`);
  log("");
  for (const { iid, currentLabels, plan } of plans) {
    const labelsCSV = plan.next.join(",");
    log(
      `Issue #${iid}: [${currentLabels.join(", ")}] → [${plan.next.join(", ")}]`,
    );
    try {
      // glab's `-f` flags form-encode the value, so commas in the CSV
      // arrive as a single field. GitLab's PUT /issues/:id interprets
      // labels as a comma-separated list — this matches the pattern
      // already used in .gitlab-ci.yml::set_boucle_label.
      glabString([
        "api",
        "--hostname",
        HOST,
        "-X",
        "PUT",
        `/projects/${encodeURIComponent(PID)}/issues/${iid}`,
        `-f`,
        `labels=${labelsCSV}`,
      ]);
      applied++;
    } catch (e) {
      err(`Issue #${iid}: FAILED — ${e.message}`);
      errors.push({ iid, message: e.message });
    }
  }

  log("");
  log("──────────────────────────────────");
  log(`Total issues scanned      : ${issues.length}`);
  log(`Successfully migrated     : ${applied}`);
  log(`Errors                    : ${errors.length}`);
  log(`Already migrated (skip)   : ${alreadyMigrated}`);
  log(`No boucle labels (skip)   : ${noBoucleLabels}`);
  log(`Needed migration          : ${toMigrate}`);

  if (errors.length) {
    log("");
    err("Per-issue failures:");
    for (const e of errors) err(`  #${e.iid}: ${e.message}`);
    process.exit(1);
  }
  process.exit(0);
}

main().catch((e) => {
  err(e.stack || e.message);
  process.exit(1);
});
