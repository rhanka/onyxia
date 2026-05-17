import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import url from 'node:url';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const ENTRY = path.join(__dirname, '..', 'sentropic-to-onyxia.mjs');

const BASE_ENV = {
  SENTROPIC_HEADER_LOGO_URL: 'https://cdn.example.com/logo.svg',
  SENTROPIC_HEADER_TEXT_BOLD: 'sent-tech',
  SENTROPIC_HEADER_TEXT_FOCUS: 'Datalab',
  SENTROPIC_TAB_TITLE: 'sent-tech · Onyxia',
  SENTROPIC_FAVICON_URL: 'https://cdn.example.com/favicon.svg'
};

test('generator — emits the 7 always-on web.env keys (FONT skipped by default)', () => {
  const out = execFileSync('node', [ENTRY], {
    env: { ...process.env, ...BASE_ENV },
    encoding: 'utf8'
  });

  for (const key of [
    'PALETTE_OVERRIDE_LIGHT:',
    'PALETTE_OVERRIDE_DARK:',
    'HEADER_LOGO:',
    'HEADER_TEXT_BOLD:',
    'HEADER_TEXT_FOCUS:',
    'TAB_TITLE:',
    'FAVICON:'
  ]) {
    assert.ok(out.includes(key), `missing ${key} in:\n${out}`);
  }

  // FONT is off by default: ensureUrlIsSafe rejects the external jsdelivr URL
  // and crashes Onyxia. We must NOT emit a FONT block until fonts are local.
  assert.ok(
    !/^FONT:/m.test(out),
    `FONT block was emitted while SENTROPIC_INJECT_FONT was unset:\n${out}`
  );
});

test('generator — emits FONT when SENTROPIC_INJECT_FONT=true', () => {
  const out = execFileSync('node', [ENTRY], {
    env: { ...process.env, ...BASE_ENV, SENTROPIC_INJECT_FONT: 'true' },
    encoding: 'utf8'
  });
  assert.ok(/^FONT:/m.test(out), `FONT block missing when toggle is on:\n${out}`);
  // And the dirUrl invariant from the mapping fix: no `//` in the basename path.
  assert.ok(
    !out.includes('/fonts//'),
    `double-slash sneaked back into FONT dirUrl:\n${out}`
  );
});

test('generator — fails loudly if required header env vars are missing', () => {
  assert.throws(() => {
    execFileSync('node', [ENTRY], {
      env: { ...process.env, SENTROPIC_HEADER_LOGO_URL: '' },
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
  }, /SENTROPIC_HEADER_LOGO_URL/);
});
