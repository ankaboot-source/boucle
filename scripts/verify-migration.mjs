#!/usr/bin/env node
// Verify the migration:
//   1. Every migrated post has valid frontmatter (title + parseable date).
//   2. Every image reference in any migrated post resolves to a file
//      under static/ (and starts with `/communiques/…`).
//   3. Every image file under static/communiques/ is referenced by at
//      least one post (no orphan files).
//   4. Every entry in migration-inventory.md corresponds to an actual
//      file in src/content/communiques/ (and vice-versa).
//
// Exits 0 on success, 1 on any failure.

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const COMMUNIQUES_DIR = join(ROOT, "src/content/communiques");
const STATIC_DIR = join(ROOT, "static/communiques");
const INVENTORY = join(ROOT, "migration-inventory.md");

let errors = 0;
const check = (cond, msg) => {
  if (cond) {
    console.log("  ok  ", msg);
  } else {
    console.error("  FAIL", msg);
    errors++;
  }
};

console.log("== Verifying migration ==");

// 1. List all .md files in communiques/ (excluding README, etc.)
const mdFiles = readdirSync(COMMUNIQUES_DIR)
  .filter((f) => f.endsWith(".md"))
  .map((f) => join(COMMUNIQUES_DIR, f));
console.log(`  ${mdFiles.length} Markdown files found`);

// 2. Inventory entries
const invText = readFileSync(INVENTORY, "utf8");
const invLines = invText
  .split("\n")
  .filter(
    (l) =>
      l.startsWith("- ") &&
      (l.includes("→") || l.includes("->")) &&
      // skip the example in the docstring
      !l.includes("<legacy URL>") &&
      !l.includes("<new file path>"),
  );
// Split on the arrow (could be `→` or `->`)
const invEntries = invLines
  .map((l) => {
    const m = l.match(/^-\s+(.+?)\s+(?:→|->)\s+(.+?)\s*$/);
    return m ? { url: m[1], path: m[2] } : null;
  })
  .filter(Boolean);
console.log(`  ${invEntries.length} inventory entries`);

// 3. For each .md, parse frontmatter and check the schema.
const allRefs = new Set();
for (const file of mdFiles) {
  const text = readFileSync(file, "utf8");
  const fmMatch = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!fmMatch) {
    check(false, `${file}: no YAML frontmatter`);
    continue;
  }
  const [, fm, body] = fmMatch;

  // Title required
  const titleMatch = fm.match(/^title:\s*(.+)$/m);
  check(!!titleMatch, `${file}: has title`);
  if (titleMatch) {
    const t = titleMatch[1].trim();
    const ok = t.startsWith('"') ? t.length >= 3 : t.length > 0;
    check(ok, `${file}: title non-empty (${t})`);
  }
  // Date required
  const dateMatch = fm.match(/^date:\s*(.+)$/m);
  check(!!dateMatch, `${file}: has date`);
  if (dateMatch) {
    const d = new Date(dateMatch[1].trim());
    check(!isNaN(d.getTime()), `${file}: date is parseable (${dateMatch[1]})`);
  }

  // 4. Check all image references in the body
  const imgRefs = [...body.matchAll(/!\[.*?\]\((\/[^)]+)\)/g)].map(
    (m) => m[1],
  );
  for (const ref of imgRefs) {
    if (!ref.startsWith("/communiques/")) {
      check(false, `${file}: image ref doesn't start with /communiques/: ${ref}`);
      continue;
    }
    const local = join(ROOT, "static", ref);
    if (!existsSync(local)) {
      check(false, `${file}: image ref not found on disk: ${ref}`);
    } else {
      allRefs.add(ref);
    }
  }
}

// 5. Check no orphan files (every static/communiques file is referenced)
function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}
const allStatic = walk(STATIC_DIR);
console.log(`  ${allStatic.length} static image files`);
let orphans = 0;
for (const p of allStatic) {
  const rel = "/" + p.slice(ROOT.length + 1).replace(/^static\//, "");
  if (!allRefs.has(rel)) {
    console.warn(`  orphan: ${rel}`);
    orphans++;
  }
}
check(orphans === 0, "no orphan static image files");

// 6. Inventory consistency: every entry's path is an actual file
for (const { url, path } of invEntries) {
  const abs = join(ROOT, path);
  if (!existsSync(abs)) {
    check(false, `inventory: missing file ${path} (${url})`);
  }
}
check(
  invEntries.length === invEntries.filter((e) =>
    existsSync(join(ROOT, e.path)),
  ).length,
  "every inventory entry points to a real file",
);

// 7. Run a build to ensure no schema errors.
console.log("\n== Running `astro build` ==");
try {
  execSync("npm run build", { cwd: ROOT, stdio: "inherit" });
  check(true, "astro build succeeded");
} catch (e) {
  check(false, `astro build failed: ${e.message}`);
}

console.log("");
if (errors === 0) {
  console.log("All checks passed.");
  process.exit(0);
} else {
  console.error(`${errors} check(s) failed.`);
  process.exit(1);
}
