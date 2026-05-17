import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isOklch, oklchToHex, normalizeColorsDeep } from '../lib/oklch.mjs';

test('isOklch — detects oklch() strings (case-insensitive)', () => {
  assert.ok(isOklch('oklch(50% 0.134 242.749)'));
  assert.ok(isOklch('OKLCH(0.5 0.134 242)'));
  assert.equal(isOklch('#ff00aa'), false);
  assert.equal(isOklch('rgb(1,2,3)'), false);
  assert.equal(isOklch(null), false);
  assert.equal(isOklch(42), false);
});

test('oklchToHex — pure black / white round-trip in sRGB', () => {
  assert.equal(oklchToHex('oklch(0% 0 0)'), '#000000');
  assert.equal(oklchToHex('oklch(100% 0 0)'), '#ffffff');
});

test('oklchToHex — sentropic action.primary (sRGB blue)', () => {
  // Sanity-check: must land in the deep-blue family, not a random color.
  const hex = oklchToHex('oklch(50% 0.134 242.749)');
  assert.match(hex, /^#[0-9a-f]{6}$/);
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  assert.ok(b > g && b > r, `expected blue-dominant, got ${hex}`);
});

test('oklchToHex — accepts L without % and bare chroma', () => {
  const a = oklchToHex('oklch(0.5 0.134 242.749)');
  const b = oklchToHex('oklch(50% 0.134 242.749)');
  assert.equal(a, b);
});

test('normalizeColorsDeep — walks objects, leaves non-oklch alone', () => {
  const input = {
    main: 'oklch(50% 0.134 242.749)',
    light: '#ffffff',
    nested: { x: 'oklch(0% 0 0)', y: 'rgba(1,2,3,0.5)' },
    list: ['oklch(100% 0 0)', '#abc']
  };
  const out = normalizeColorsDeep(input);
  assert.equal(out.main.startsWith('#'), true);
  assert.equal(out.light, '#ffffff');
  assert.equal(out.nested.x, '#000000');
  assert.equal(out.nested.y, 'rgba(1,2,3,0.5)');
  assert.equal(out.list[0], '#ffffff');
  assert.equal(out.list[1], '#abc');
});
