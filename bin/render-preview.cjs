#!/usr/bin/env node
// bin/render-preview.cjs — renders preview.html → one PNG per viewport
// Called by the triage CI job's visual-preview block (opt-in, exceptional).
// Usage: NODE_PATH=/tmp/node_modules node bin/render-preview.cjs <input.html|http(s)://url> <output.png>
// The input may be a local HTML file (rendered via file://) or an http(s)://
// URL (e.g. a page served by `python3 -m http.server`), which is navigated to
// directly.
//
// Viewports come from BOUCLE_PREVIEW_VIEWPORTS (comma-separated WxH,
// default "390x844,1440x900" — one phone, one desktop). The human approving
// a spec on a phone-first site cannot judge it from a desktop shot alone,
// and boucle's audience is Product Builders who read a screenshot, not a
// media query.
//
// Output: <output-stem>-<W>x<H>.png per viewport. Each produced path is
// printed on stdout, one per line, so the caller uploads them in order
// without re-deriving the names.
//
// Self-contained: no project dependencies. Relies on puppeteer-core +
// @sparticuz/chromium being resolvable via NODE_PATH (installed on-demand
// by the CI block into /tmp/node_modules).
const path = require('path');

const [, , input, output] = process.argv;


// Parse "390x844,1440x900" → [{width, height}]. A malformed entry is skipped
// with a warning rather than failing the render: a bad viewport must not cost
// the human the preview entirely.
function parseViewports(spec) {
  const out = [];
  for (const raw of String(spec).split(',')) {
    const entry = raw.trim();
    if (!entry) continue;
    const m = /^(\d+)x(\d+)$/i.exec(entry);
    if (!m) {
      console.error(`render-preview: ignoring malformed viewport "${entry}" (expected WxH)`);
      continue;
    }
    out.push({ width: parseInt(m[1], 10), height: parseInt(m[2], 10) });
  }
  return out;
}

const DEFAULT_VIEWPORTS = '390x844,1440x900';

// Guarded so parseViewports can be unit-tested by requiring this file
// without launching Chromium or needing argv.
async function main() {
  if (!input || !output) {
    console.error('Usage: node bin/render-preview.cjs <input.html> <output.png>');
    process.exit(2);
  }
  let viewports = parseViewports(process.env.BOUCLE_PREVIEW_VIEWPORTS || DEFAULT_VIEWPORTS);
  if (viewports.length === 0) viewports = parseViewports(DEFAULT_VIEWPORTS);
  const ext = path.extname(output) || '.png';
  const stem = path.join(path.dirname(output), path.basename(output, ext));
  // Resolved at call time so NODE_PATH=/tmp/node_modules (installed on-demand
  // by the CI block) takes effect — keeping these requires inside the IIFE.
  const puppeteer = require('puppeteer-core');
  // @sparticuz/chromium v149+ restructured its exports as an ES module:
  // the named exports (executablePath, args, headless) moved under `.default`.
  // Older versions expose them at the top level. Support both shapes so an
  // unpinned `npm install` in CI doesn't break the render on a version bump.
  const chromiumMod = require('@sparticuz/chromium');
  const chromium = chromiumMod.default || chromiumMod;
  const browser = await puppeteer.launch({
    args: chromium.args,
    executablePath: typeof chromium.executablePath === 'function'
      ? await chromium.executablePath()
      : chromium.executablePath,
    headless: chromium.headless,
  });
  const produced = [];
  try {
    const page = await browser.newPage();
    const url = /^https?:\/\//i.test(input) ? input : 'file://' + path.resolve(input);
    for (const vp of viewports) {
      const target = `${stem}-${vp.width}x${vp.height}${ext}`;
      try {
        await page.setViewport({ width: vp.width, height: vp.height });
        await page.goto(url, { waitUntil: 'networkidle0' });
        await page.screenshot({ path: target, fullPage: true });
        produced.push(target);
      } catch (e) {
        // One viewport failing must not lose the others. A partial set of
        // screenshots still lets the human judge the proposal.
        console.error(`render-preview: viewport ${vp.width}x${vp.height} failed:`, e.message);
      }
    }
  } finally {
    await browser.close();
  }
  if (produced.length === 0) {
    console.error('render-preview: every viewport failed');
    process.exit(1);
  }
  for (const p of produced) console.log(p);
}

module.exports = { parseViewports };

if (require.main === module) {
  main().catch((e) => {
    console.error('render-preview failed:', e);
    process.exit(1);
  });
}
