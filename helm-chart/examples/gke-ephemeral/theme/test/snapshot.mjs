#!/usr/bin/env node
// Usage:
//   ONYXIA_URL=https://onyxia.example.com \
//   REFERENCE=test/fixtures/sent-tech-home.png \
//   node test/snapshot.mjs
//
// Loads the URL in headless Chromium, screenshots the viewport, and diffs
// it against the reference PNG. Exits 0 if diff fraction <= THRESHOLD,
// 1 otherwise. The threshold is intentionally loose (5%) — this is a
// "did the theme actually paint?" smoke test, not a pixel-perfect contract.

import { chromium } from 'playwright';
import pixelmatch from 'pixelmatch';
import { PNG } from 'pngjs';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const URL = process.env.ONYXIA_URL || 'http://localhost:3000';
const REF = process.env.REFERENCE || 'test/fixtures/sent-tech-home.png';
const OUT = process.env.OUT || 'test/last-snapshot.png';
const DIFF = process.env.DIFF || 'test/last-diff.png';
const THRESHOLD = Number(process.env.THRESHOLD || '0.05');  // 5 %

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto(URL, { waitUntil: 'networkidle', timeout: 30_000 });
await page.screenshot({ path: OUT, fullPage: false });
await browser.close();

if (!existsSync(REF)) {
  console.log(`No reference at ${REF} — captured ${OUT}. Commit ${OUT} as the new reference if it looks right.`);
  process.exit(0);
}

const ref = PNG.sync.read(readFileSync(REF));
const act = PNG.sync.read(readFileSync(OUT));
if (ref.width !== act.width || ref.height !== act.height) {
  console.error(`ERROR: dimensions differ (ref=${ref.width}x${ref.height} act=${act.width}x${act.height})`);
  process.exit(1);
}

const diff = new PNG({ width: ref.width, height: ref.height });
const mismatched = pixelmatch(ref.data, act.data, diff.data, ref.width, ref.height, { threshold: 0.1 });
writeFileSync(DIFF, PNG.sync.write(diff));

const fraction = mismatched / (ref.width * ref.height);
console.log(`mismatched=${mismatched} fraction=${fraction.toFixed(4)} threshold=${THRESHOLD}`);
if (fraction > THRESHOLD) {
  console.error(`FAIL: diff fraction ${fraction.toFixed(4)} > ${THRESHOLD}`);
  process.exit(1);
}
console.log('PASS');
