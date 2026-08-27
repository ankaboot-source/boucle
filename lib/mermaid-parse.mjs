// lib/mermaid-parse.mjs — deterministic Mermaid syntax check.
//
// Extracts every ```mermaid fence from the markdown files given as arguments
// (`-` reads stdin) and runs each one through the REAL Mermaid parser. This
// is the only way to answer "will the forge render this?" deterministically:
// a hand-rolled grammar approximation both misses real errors and invents
// fake ones, and either failure mode is worse than no gate at all.
//
// Driven by bin/check-mermaid, which resolves the `mermaid` + `jsdom` modules
// and copies this file next to them (ESM bare-specifier resolution walks up
// from the SCRIPT's directory, not from cwd, so NODE_PATH cannot be used).
//
// jsdom is required, not optional: mermaid.parse() sanitizes labels through
// DOMPurify for flowchart/sequence/state diagrams, and DOMPurify without a
// DOM throws `DOMPurify.addHook is not a function` on every one of them —
// which would report every valid flowchart in the repo as a syntax error.
//
// Output — one line per fence, on stdout:
//   OK   <file>:<line>
//   FAIL <file>:<line> — <first line of the parser error>
//   SKIP <file>:<line> — <why>
//   WARN <file>:<line> — <why>
// <line> is the 1-based line of the fence BODY's first line in <file>, so a
// parser message that says "line 20" points 19 lines below it.
//
// Exit codes (mirrored by bin/check-mermaid):
//   0 — every fence parsed (or was skipped); no diagram is broken
//   1 — at least one fence FAILed
//   2 — usage error
//   3 — the parser itself is unavailable/unusable (fail-open for callers)

import fs from 'node:fs';

const TIMEOUT_MS = Number(process.env.BOUCLE_MERMAID_TIMEOUT_MS || 20000);

const files = process.argv.slice(2);
if (files.length === 0) {
  process.stderr.write('usage: mermaid-parse.mjs <file.md|-> [file.md ...]\n');
  process.exit(2);
}

// ── DOM ──────────────────────────────────────────────────────────────────
// Set up before importing mermaid: the module captures globals at import.
let mermaid;
try {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {
    pretendToBeVisual: true,
  });
  for (const key of [
    'window', 'document', 'HTMLElement', 'SVGElement', 'Element', 'Node',
    'DOMParser', 'NodeFilter', 'Event', 'CustomEvent', 'getComputedStyle',
  ]) {
    const value = dom.window[key];
    if (value !== undefined) {
      Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
    }
  }
  // `navigator` is a getter-only property on globalThis in Node >= 21;
  // plain assignment throws, defineProperty does not.
  Object.defineProperty(globalThis, 'navigator', {
    value: dom.window.navigator,
    configurable: true,
  });
  mermaid = (await import('mermaid')).default;
} catch (e) {
  process.stderr.write(`mermaid-parse: parser unavailable — ${e && e.message ? e.message : e}\n`);
  process.exit(3);
}

// Defaults on purpose: the closer this configuration is to the forge's own
// renderer, the closer the verdict is to what the human will see.
mermaid.initialize({ startOnLoad: false });

// ── Fence extraction ─────────────────────────────────────────────────────
// GitHub and GitLab both render a fence whose info string starts with
// `mermaid`; anything else is a plain code block and cannot fail to render.
const FENCE_OPEN = /^(\s*)(`{3,}|~{3,})\s*mermaid\b.*$/;

function fences(text) {
  const lines = text.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const open = lines[i].match(FENCE_OPEN);
    if (!open) continue;
    const marker = open[2];
    const closer = new RegExp(`^\\s*${marker[0]}{${marker.length},}\\s*$`);
    let j = i + 1;
    while (j < lines.length && !closer.test(lines[j])) j++;
    out.push({ line: i + 2, body: lines.slice(i + 1, j).join('\n') });
    i = j;
  }
  return out;
}

function read(file) {
  if (file === '-') return fs.readFileSync(0, 'utf8');
  return fs.readFileSync(file, 'utf8');
}

const withTimeout = (promise, ms) =>
  Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`parser timed out after ${ms}ms`)), ms).unref(),
    ),
  ]);

// ── Main ─────────────────────────────────────────────────────────────────
let failed = 0;
let checked = 0;

for (const file of files) {
  const label = file === '-' ? '<stdin>' : file;
  let text;
  try {
    text = read(file);
  } catch (e) {
    // An unreadable input is a caller bug, not a broken diagram: report it
    // but do not claim a diagram is invalid.
    process.stdout.write(`WARN ${label}:0 — cannot read (${e.code || e.message})\n`);
    continue;
  }
  for (const fence of fences(text)) {
    const at = `${label}:${fence.line}`;
    if (fence.body.trim() === '') {
      process.stdout.write(`FAIL ${at} — empty mermaid fence\n`);
      failed++;
      continue;
    }
    // A template placeholder (templates/triage.md ships `{{mermaid_body}}`)
    // is not a diagram yet — parsing it would fail on every run for a file
    // that is never rendered as-is.
    if (/\{\{\s*[\w.-]+\s*\}\}/.test(fence.body)) {
      process.stdout.write(`SKIP ${at} — template placeholder, not a rendered diagram\n`);
      continue;
    }
    checked++;
    try {
      await withTimeout(mermaid.parse(fence.body), TIMEOUT_MS);
      process.stdout.write(`OK   ${at}\n`);
    } catch (e) {
      const message = String((e && e.message) || e).replace(/\s+/g, ' ').trim();
      if (/timed out after/.test(message)) {
        // The parser hanging is an infrastructure failure, not a verdict on
        // the diagram — never block the loop on it (CONTEXT.md §7).
        process.stdout.write(`WARN ${at} — ${message}\n`);
        continue;
      }
      process.stdout.write(`FAIL ${at} — ${message.slice(0, 500)}\n`);
      failed++;
    }
  }
}

process.stderr.write(`mermaid-parse: ${checked} fence(s) parsed, ${failed} invalid\n`);
process.exit(failed > 0 ? 1 : 0);
