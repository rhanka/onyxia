import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import url from 'node:url';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const ENTRY = path.join(__dirname, '..', 'sentropic-to-onyxia.mjs');

test('generator — emits all 8 web.env keys', () => {
  const out = execFileSync('node', [ENTRY], {
    env: {
      ...process.env,
      SENTROPIC_HEADER_LOGO_URL: 'https://cdn.example.com/logo.svg',
      SENTROPIC_HEADER_TEXT_BOLD: 'sent-tech',
      SENTROPIC_HEADER_TEXT_FOCUS: 'Datalab',
      SENTROPIC_TAB_TITLE: 'sent-tech · Onyxia',
      SENTROPIC_FAVICON_URL: 'https://cdn.example.com/favicon.svg'
    },
    encoding: 'utf8'
  });

  for (const key of [
    'PALETTE_OVERRIDE_LIGHT:',
    'PALETTE_OVERRIDE_DARK:',
    'FONT:',
    'HEADER_LOGO:',
    'HEADER_TEXT_BOLD:',
    'HEADER_TEXT_FOCUS:',
    'TAB_TITLE:',
    'FAVICON:'
  ]) {
    assert.ok(out.includes(key), `missing ${key} in:\n${out}`);
  }
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
