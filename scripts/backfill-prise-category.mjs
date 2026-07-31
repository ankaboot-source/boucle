#!/usr/bin/env node
/*
 * Backfill the `category` frontmatter on every Markdown entry that
 * lives under `src/content/prises-de-parole/`. One-off script invoked
 * by the worker when implementing issue #25 (taxonomy + collection
 * rename). Safe to re-run: it parses each file, decides a value, and
 * only writes back if the field is missing or has changed.
 *
 * Rules (matching the triage decision recorded in .boucle/25/state.md):
 *   - slug starts with `analyse-`    → "analyse"
 *   - slug starts with `8mars`       → "appel-a-mobilisation"
 *   - slug contains `mobilis`        → "appel-a-mobilisation"
 *   - everything else (default)      → "communique"
 *
 * The script never rewrites the existing frontmatter for entries that
 * already carry a valid `category` value — that keeps editorial
 * overrides (e.g. an SM-style `appel` marked as `communique`) intact.
 */

import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const CONTENT_DIR = "src/content/prises-de-parole";
const ALLOWED = new Set(["communique", "analyse", "appel-a-mobilisation"]);

const categorize = (id) => {
	// Strip the `YYYY-MM-DD-` date prefix the migration script uses,
	// so the categorisation rules can match the editorial slug part
	// directly (matches what `/prises-de-parole/<slug>/` exposes).
	const slug = id.replace(/^\d{4}-\d{2}-\d{2}-/, "");
	if (slug.startsWith("analyse-")) return "analyse";
	if (slug.startsWith("8mars")) return "appel-a-mobilisation";
	if (slug.includes("mobilis")) return "appel-a-mobilisation";
	return "communique";
};

const splitFrontmatter = (raw) => {
	// Astro / Sveltia convention: frontmatter is fenced by `---` lines at
	// the start of the file. Returns [fm, body] (both trimmed).
	const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
	if (!m) return null;
	return { fm: m[1], body: m[2] };
};

const updateEntry = (filePath, id, dryRun) => {
	const raw = readFileSync(filePath, "utf8");
	const split = splitFrontmatter(raw);
	if (!split) {
		console.warn(`  skip (no frontmatter): ${id}`);
		return "skip-no-fm";
	}
	const lines = split.fm.split(/\r?\n/);
	const hasCategoryLine = lines.findIndex((l) => /^category\s*:/.test(l));
	const desired = categorize(id);

	if (hasCategoryLine !== -1) {
		const current = lines[hasCategoryLine].match(/^category\s*:\s*(.+?)\s*$/);
		const currentVal = current ? current[1].replace(/^["']|["']$/g, "") : null;
		if (currentVal === desired) {
			console.log(`  keep  (${desired}): ${id}`);
			return "keep";
		}
		if (currentVal && ALLOWED.has(currentVal)) {
			console.log(`  keep-existing (${currentVal}, override): ${id}`);
			return "keep-existing";
		}
		// Stale or invalid value: overwrite.
		lines[hasCategoryLine] = `category: ${desired}`;
	} else {
		// Insert right after the `title:` line if present, otherwise at
		// the top — keeps hand-authored frontmatter readable.
		const titleIdx = lines.findIndex((l) => /^title\s*:/.test(l));
		if (titleIdx !== -1) {
			lines.splice(titleIdx + 1, 0, `category: ${desired}`);
		} else {
			lines.unshift(`category: ${desired}`);
		}
	}

	const newFm = lines.join("\n");
	const newRaw = `---\n${newFm}\n---\n${split.body}`;
	if (!dryRun) {
		writeFileSync(filePath, newRaw, "utf8");
	}
	console.log(`  write (${desired}): ${id}`);
	return "write";
};

const main = () => {
	const dryRun = process.argv.includes("--dry-run");
	const entries = readdirSync(CONTENT_DIR)
		.filter((f) => f.endsWith(".md"))
		.sort();

	let written = 0;
	let kept = 0;
	let skipped = 0;
	for (const f of entries) {
		const filePath = join(CONTENT_DIR, f);
		if (!statSync(filePath).isFile()) continue;
		const id = f.replace(/\.md$/, "");
		const result = updateEntry(filePath, id, dryRun);
		if (result === "write") written++;
		else if (result === "keep" || result === "keep-existing") kept++;
		else skipped++;
	}

	console.log(
		`\n${
			dryRun ? "[dry-run] " : ""
		}${entries.length} entries processed — ${written} written, ${kept} kept (already OK or override), ${skipped} skipped.`,
	);
};

main();
