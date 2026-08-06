#!/usr/bin/env node
// bin/render-preview.cjs — renders preview.html → preview.png via @sparticuz/chromium
// Called by the triage CI job's visual-preview block (opt-in, exceptional).
// Usage: NODE_PATH=/tmp/node_modules node bin/render-preview.cjs <input.html> <output.png>
//
// Self-contained: no project dependencies. Relies on puppeteer-core +
// @sparticuz/chromium being resolvable via NODE_PATH (installed on-demand
// by the CI block into /tmp/node_modules).
const path = require('path');

const [,, input, output] = process.argv;

if (!input || !output) {
  console.error('Usage: node bin/render-preview.cjs <input.html> <output.png>');
  process.exit(2);
}

(async () => {
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
